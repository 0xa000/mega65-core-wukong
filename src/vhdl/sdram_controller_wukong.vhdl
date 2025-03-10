library IEEE;
use IEEE.STD_LOGIC_1164.all;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;
use work.cputypes.all;

entity sdram_controller_wukong is
  port (
        -- For slow devices bus interface is actually on pixelclock to reduce
        -- latencies
        reset             : in std_logic;
        pixelclock        : in std_logic;
        clock200          : in std_logic;
        clock324          : in std_logic;
        clock324p90       : in std_logic;

        read_request      : in std_logic;
        write_request     : in std_logic;
        address           : in unsigned(26 downto 0);
        wdata             : in unsigned(7 downto 0);
        rdata             : out unsigned(7 downto 0);
        data_ready_toggle : out std_logic := '0';
        -- Starts busy until SDRAM is initialised
        busy              : out std_logic := '1';
        stuck             : out std_logic := '0';

        -- Export current cache line for speeding up reads from slow_devices controller
        -- by skipping the need to hand us the request and get the response back.
        current_cache_line                          : out   cache_row_t           := (others => (others => '0'));
        current_cache_line_address                  : inout unsigned(26 downto 3) := (others => '0');
        current_cache_line_valid                    : out   std_logic             := '0';
        expansionram_current_cache_line_next_toggle : in    std_logic             := '0';
        expansionram_current_cache_line_prev_toggle : in    std_logic             := '0';

        -- Simple counter for number of requests received
        request_counter : out std_logic := '0';

        -- If '1' DDR3 calibration was completed.
        calib_complete : out std_logic := '0';

        sdram_ack : out std_logic := '0';
        sdram_stall : out std_logic := '0';

        -- DDR3 SDRAM interface
        sdram_clk_p   : out   std_logic;
        sdram_clk_n   : out   std_logic;
        sdram_reset_n : out   std_logic;
        sdram_cke     : out   std_logic;
        sdram_ras_n   : out   std_logic;
        sdram_cas_n   : out   std_logic;
        sdram_we_n    : out   std_logic;
        sdram_addr    : out   std_logic_vector(13 downto 0);
        sdram_ba      : out   std_logic_vector(2 downto 0);
        sdram_dq      : inout std_logic_vector(15 downto 0);
        sdram_dqs_p   : inout std_logic_vector(1 downto 0);
        sdram_dqs_n   : inout std_logic_vector(1 downto 0);
        sdram_dm      : out   std_logic_vector(1 downto 0);
        sdram_odt     : out   std_logic
        );
end sdram_controller_wukong;

architecture tacoma_narrows of sdram_controller_wukong is

  -- integer, real, string, boolean
  component ddr3_top_wukong is
    generic (
      -- ps, clock period of the controller interface
      CONTROLLER_CLK_PERIOD : integer := 12000;
      -- ps, clock period of the DDR3 RAM device (must be 1/4 of the CONTROLLER_CLK_PERIOD)
      DDR3_CLK_PERIOD : integer := 3000
    );
    port
    (
        --i_controller_clk = CONTROLLER_CLK_PERIOD, i_ddr3_clk = DDR3_CLK_PERIOD, i_ref_clk = 200MHz
        i_controller_clk : in std_logic;
        i_ddr3_clk : in std_logic;
        i_ref_clk : in std_logic;
        -- required only when ODELAY_SUPPORTED is zero
        i_ddr3_clk_90 : in std_logic;
        i_rst_n : in std_logic;
        --
        -- Wishbone inputs
        -- bus cycle active (1 = normal operation, 0 = all ongoing transaction are to be cancelled)
        i_wb_cyc : in std_logic;
        -- request a transfer
        i_wb_stb : in std_logic;
        -- write-enable (1 = write, 0 = read)
        i_wb_we : in std_logic;
        -- burst-addressable {row,bank,col}
        i_wb_addr : in std_logic_vector(23 downto 0);
        -- write data, for a 4:1 controller data width is 8 times the number of pins on the device
        i_wb_data : in std_logic_vector(127 downto 0);
        -- byte strobe for write (1 = write the byte)
        i_wb_sel : in std_logic_vector(15 downto 0);
        -- Wishbone outputs
        -- 1 = busy, cannot accept requests
        o_wb_stall : out std_logic;
        -- 1 = read/write request has completed
        o_wb_ack : out std_logic;
        -- 1 = Error due to ECC double bit error (fixed to 0 if WB_ERROR = 0)
        o_wb_err : out std_logic;
        -- read data, for a 4:1 controller data width is 8 times the number of pins on the device
        o_wb_data : out std_logic_vector(127 downto 0);
        --
        -- DDR3 I/O Interface
        o_ddr3_clk_p : out std_logic;
        o_ddr3_clk_n : out std_logic;
        o_ddr3_reset_n : out std_logic;
        o_ddr3_cke : out std_logic;
        o_ddr3_cs_n : out std_logic;
        o_ddr3_ras_n : out std_logic;
        o_ddr3_cas_n : out std_logic;
        o_ddr3_we_n : out std_logic;
        o_ddr3_addr : out std_logic_vector(13 downto 0);
        o_ddr3_ba_addr : out std_logic_vector(2 downto 0);
        io_ddr3_dq : inout std_logic_vector(15 downto 0);
        io_ddr3_dqs : inout std_logic_vector(1 downto 0);
        io_ddr3_dqs_n : inout std_logic_vector(1 downto 0);
        o_ddr3_dm : out std_logic_vector(1 downto 0);
        o_ddr3_odt : out std_logic;
        --
        -- Done Calibration pin
        --
        o_calib_complete : out std_logic;
        -- Debug outputs
        o_debug1 : out std_logic_vector(31 downto 0)
    );
  end component ddr3_top_wukong;

  signal last_data_ready_toggle : std_logic := '0';

  -- SDRAM state machine.  IDLE must be the last in the list,
  -- so that the shallow auto-progression logic can progress
  -- through.
  type sdram_state_t is (IDLE,
                         SDRAM_READ_WAIT_STALL,
                         SDRAM_READ_CHECK_STALL,
                         SDRAM_READ_WAIT_ACK,
                         SDRAM_WRITE_WAIT_STALL,
                         SDRAM_WRITE_CHECK_STALL,
                         SDRAM_WRITE_WAIT_ACK);
  signal sdram_state : sdram_state_t := IDLE;


  signal write_burst_data   : std_logic_vector(127 downto 0);
  signal write_burst_select : std_logic_vector(15 downto 0);

  signal write_burst_address_latched : std_logic_vector(23 downto 0);
  signal write_burst_data_latched    : std_logic_vector(127 downto 0);
  signal write_burst_select_latched  : std_logic_vector(15 downto 0);

  signal read_burst_data   : std_logic_vector(127 downto 0);
  signal read_burst_byte   : std_logic_vector(7 downto 0);

  signal write_cache_data    : std_logic_vector(127 downto 0);
  signal write_cache_address : std_logic_vector(23 downto 0);
  signal write_cache_select  : std_logic_vector(15 downto 0);

  signal rdata_line       : unsigned(127 downto 0);
  signal latched_address  : unsigned(26 downto 0);
  signal rdata_buf        : unsigned(7 downto 0);
  --signal rdata_hi_buf     : unsigned(7 downto 0);
  signal read_latched     : std_logic := '0';
  signal write_latched    : std_logic := '0';
  signal wdata_latched    : unsigned(7 downto 0);

  --signal wdata_line : std_logic_vector(127 downto 0);
  --signal wdata_sel : std_logic_vector(15 downto 0);

  --signal wdata_hi_latched : unsigned(7 downto 0);
  --signal latched_wen_lo   : std_logic := '0';
  --signal latched_wen_hi   : std_logic := '0';

  signal read_jobs  : unsigned(7 downto 0) := to_unsigned(0, 8);
  signal write_jobs : unsigned(7 downto 0) := to_unsigned(0, 8);

  signal nonram_val : unsigned(7 downto 0);

  signal reactive_cache_line_if_safe  : std_logic := '0';
  signal write_targets_cache_line     : std_logic := '0';
  signal current_cache_line_valid_int : std_logic := '0';
  signal sdram_dq_latched             : unsigned(15 downto 0);

  signal next_toggle_drive : std_logic := '0';
  signal prev_toggle_drive : std_logic := '0';

  signal prev_current_cache_line_next_toggle : std_logic := '0';
  signal prev_current_cache_line_prev_toggle : std_logic := '0';
  signal cache_line_prev_address             : unsigned(26 downto 3);
  signal cache_line_next_address             : unsigned(26 downto 3);
  signal silent_read                         : std_logic := '0';

  -- 8K refreshes required every 64ms.
  -- ie one every 7.812 usec
  -- We have 162 clock cycles per usec, so one refresh every
  -- 1,265 cycles is required.
  constant refresh_interval    : integer   := 1265;
  signal refresh_due           : std_logic := '0';
  signal refresh_due_countdown : integer   := refresh_interval - 1;

  signal read_complete_strobe : std_logic              := '0';
  signal read_publish_strobe  : std_logic              := '0';
  signal active_row           : std_logic              := '0';
  signal active_row_addr      : unsigned(25 downto 11) := (others => '0');

  signal resets : unsigned(7 downto 0) := x"00";

  --signal wb_cyc   : std_logic;
  signal wb_stb   : std_logic;
  signal wb_we    : std_logic;
  signal wb_addr  : std_logic_vector(23 downto 0);
  signal wb_wdata : std_logic_vector(127 downto 0);
  signal wb_sel   : std_logic_vector(15 downto 0);
  signal wb_stall : std_logic;
  signal wb_ack   : std_logic;
  signal wb_rdata : std_logic_vector(127 downto 0);

  signal reset_n_int : std_logic := '0';
  signal debug : std_logic_vector(31 downto 0);

  --signal stuck_int : std_logic := '0';
  --signal stuck_counter : natural := 0;

begin

  reset_n_int <= not reset;

  --stuck <= stuck_int;

  ddr3_ram : component ddr3_top_wukong
    generic map (
      CONTROLLER_CLK_PERIOD => 12346,
      DDR3_CLK_PERIOD => 3086
    )
    port map (
        --i_controller_clk = CONTROLLER_CLK_PERIOD, i_ddr3_clk = DDR3_CLK_PERIOD, i_ref_clk = 200MHz
        i_controller_clk => pixelclock,
        i_ddr3_clk => clock324,
        i_ref_clk => clock200,
        -- required only when ODELAY_SUPPORTED is zero
        i_ddr3_clk_90 => clock324p90,
        i_rst_n => reset_n_int,
        --
        -- Wishbone inputs
        -- bus cycle active (1 = normal operation, 0 = all ongoing transaction are to be cancelled)
        i_wb_cyc => '1',
        -- request a transfer
        i_wb_stb => wb_stb,
        -- write-enable (1 = write, 0 = read)
        i_wb_we => wb_we,
        -- burst-addressable {row,bank,col}
        i_wb_addr => wb_addr,
        -- write data, for a 4:1 controller data width is 8 times the number of pins on the device
        i_wb_data => wb_wdata,
        -- byte strobe for write (1 = write the byte)
        i_wb_sel => wb_sel,
        -- Wishbone outputs
        -- 1 = busy, cannot accept requests
        o_wb_stall => wb_stall,
        -- 1 = read/write request has completed
        o_wb_ack => wb_ack,
        -- 1 = Error due to ECC double bit error (fixed to 0 if WB_ERROR = 0)
        o_wb_err => open,
        -- read data, for a 4:1 controller data width is 8 times the number of pins on the device
        o_wb_data => wb_rdata,
        --
        -- DDR3 I/O Interface
        o_ddr3_clk_p   => sdram_clk_p  ,
        o_ddr3_clk_n   => sdram_clk_n  ,
        o_ddr3_reset_n => sdram_reset_n,
        o_ddr3_cke     => sdram_cke    ,
        o_ddr3_cs_n    => open         ,
        o_ddr3_ras_n   => sdram_ras_n  ,
        o_ddr3_cas_n   => sdram_cas_n  ,
        o_ddr3_we_n    => sdram_we_n   ,
        o_ddr3_addr    => sdram_addr   ,
        o_ddr3_ba_addr => sdram_ba     ,
        io_ddr3_dq     => sdram_dq     ,
        io_ddr3_dqs    => sdram_dqs_p  ,
        io_ddr3_dqs_n  => sdram_dqs_n  ,
        o_ddr3_dm      => sdram_dm     ,
        o_ddr3_odt     => sdram_odt    ,
        --
        -- Done Calibration pin
        --
        o_calib_complete => open,
        -- Debug outputs
        o_debug1         => debug
    );


  process (wdata) is
  begin

    write_burst_data   <= (others => '0');
    write_burst_select <= (others => '0');

    case address(3 downto 0) is
      when "0000" =>
        write_burst_data(7 downto 0) <= std_logic_vector(wdata);
        write_burst_select(0) <= '1';
      when "0001" =>
        write_burst_data(15 downto 8) <= std_logic_vector(wdata);
        write_burst_select(1) <= '1';
      when "0010" =>
        write_burst_data(23 downto 16) <= std_logic_vector(wdata);
        write_burst_select(2) <= '1';
      when "0011" =>
        write_burst_data(31 downto 24) <= std_logic_vector(wdata);
        write_burst_select(3) <= '1';
      when "0100" =>
        write_burst_data(39 downto 32) <= std_logic_vector(wdata);
        write_burst_select(4) <= '1';
      when "0101" =>
        write_burst_data(47 downto 40) <= std_logic_vector(wdata);
        write_burst_select(5) <= '1';
      when "0110" =>
        write_burst_data(55 downto 48) <= std_logic_vector(wdata);
        write_burst_select(6) <= '1';
      when "0111" =>
        write_burst_data(63 downto 56) <= std_logic_vector(wdata);
        write_burst_select(7) <= '1';
      when "1000" =>
        write_burst_data(71 downto 64) <= std_logic_vector(wdata);
        write_burst_select(8) <= '1';
      when "1001" =>
        write_burst_data(79 downto 72) <= std_logic_vector(wdata);
        write_burst_select(9) <= '1';
      when "1010" =>
        write_burst_data(87 downto 80) <= std_logic_vector(wdata);
        write_burst_select(10) <= '1';
      when "1011" =>
        write_burst_data(95 downto 88) <= std_logic_vector(wdata);
        write_burst_select(11) <= '1';
      when "1100" =>
        write_burst_data(103 downto 96) <= std_logic_vector(wdata);
        write_burst_select(12) <= '1';
      when "1101" =>
        write_burst_data(111 downto 104) <= std_logic_vector(wdata);
        write_burst_select(13) <= '1';
      when "1110" =>
        write_burst_data(119 downto 112) <= std_logic_vector(wdata);
        write_burst_select(14) <= '1';
      when others =>
        write_burst_data(127 downto 120) <= std_logic_vector(wdata);
        write_burst_select(15) <= '1';
    end case;
  end process;

  process (wb_rdata) is
  begin
    case latched_address(3 downto 0) is
      when "0000" =>
        read_burst_byte <= wb_rdata(7 downto 0);
      when "0001" =>
        read_burst_byte <= wb_rdata(15 downto 8);
      when "0010" =>
        read_burst_byte <= wb_rdata(23 downto 16);
      when "0011" =>
        read_burst_byte <= wb_rdata(31 downto 24);
      when "0100" =>
        read_burst_byte <= wb_rdata(39 downto 32);
      when "0101" =>
        read_burst_byte <= wb_rdata(47 downto 40);
      when "0110" =>
        read_burst_byte <= wb_rdata(55 downto 48);
      when "0111" =>
        read_burst_byte <= wb_rdata(63 downto 56);
      when "1000" =>
        read_burst_byte <= wb_rdata(71 downto 64);
      when "1001" =>
        read_burst_byte <= wb_rdata(79 downto 72);
      when "1010" =>
        read_burst_byte <= wb_rdata(87 downto 80);
      when "1011" =>
        read_burst_byte <= wb_rdata(95 downto 88);
      when "1100" =>
        read_burst_byte <= wb_rdata(103 downto 96);
      when "1101" =>
        read_burst_byte <= wb_rdata(111 downto 104);
      when "1110" =>
        read_burst_byte <= wb_rdata(119 downto 112);
      when others =>
        read_burst_byte <= wb_rdata(127 downto 120);
    end case;
  end process;

  process(pixelclock) is
  begin
    if reset = '1' then
      busy              <= '1';
      calib_complete    <= '0';
      data_ready_toggle <= '0';
      sdram_state       <= IDLE;

      write_cache_data     <= (others => '0');
      write_cache_address  <= (others => '0');
      write_cache_select   <= (others => '0');

    else
      if rising_edge(pixelclock) then

        sdram_ack   <= wb_ack;
        sdram_stall <= wb_stall;

        wb_stb   <= '0';
        wb_we    <= '0';
        wb_addr  <= (others => '0');
        wb_wdata <= (others => '0');
        wb_sel   <= (others => '0');

        data_ready_toggle <= '0';

        -- Temporarily disable caching.
        current_cache_line_valid <= '0';

        -- Ensure we go non-busy eventually (temporary hack).
        if debug(4 downto 0) = "10111" then
          calib_complete <= '1';
          if (sdram_state = IDLE) then
            busy <= '0';
          end if;
        else
          calib_complete <= '0';
          busy <= '1';
        end if;

        --if current_cache_line_address(26 downto 3) /= latched_address(26 downto 3) then
        --  write_targets_cache_line <= '0';
        --else
        --  write_targets_cache_line <= '1';
        --end if;

        --cache_line_prev_address <= current_cache_line_address(26 downto 3) - 1;
        --cache_line_next_address <= current_cache_line_address(26 downto 3) + 1;

        --if reactive_cache_line_if_safe = '1' and write_targets_cache_line = '0' then
        --  current_cache_line_valid     <= '1';
        --  current_cache_line_valid_int <= '1';
        --  reactive_cache_line_if_safe  <= '0';
        --end if;

        -- Keep logic flat by pre-extracting read data
        -- report "RDATA_BUF: Reading from offset " & to_string(std_logic_vector(latched_address(2 downto 0))) &
        -- ", = $" & to_hexstring(rdata_line);
        --case latched_address(2 downto 0) is
        --  when "000" =>
        --    rdata_buf    <= rdata_line(7 downto 0);
        --    --rdata_hi_buf <= rdata_line(15 downto 8);
        --  when "001" =>
        --    rdata_buf    <= rdata_line(15 downto 8);
        --    --rdata_hi_buf <= rdata_line(23 downto 16);
        --  when "010" =>
        --    rdata_buf    <= rdata_line(23 downto 16);
        --    --rdata_hi_buf <= rdata_line(31 downto 24);
        --  when "011" =>
        --    rdata_buf    <= rdata_line(31 downto 24);
        --    --rdata_hi_buf <= rdata_line(39 downto 32);
        --  when "100" =>
        --    rdata_buf    <= rdata_line(39 downto 32);
        --    --rdata_hi_buf <= rdata_line(47 downto 40);
        --  when "101" =>
        --    rdata_buf    <= rdata_line(47 downto 40);
        --    --rdata_hi_buf <= rdata_line(55 downto 48);
        --  when "110" =>
        --    rdata_buf    <= rdata_line(55 downto 48);
        --    --rdata_hi_buf <= rdata_line(63 downto 56);
        --  when others =>                  -- "111" =>
        --    rdata_buf    <= rdata_line(63 downto 56);
        --    --rdata_hi_buf <= rdata_line(7 downto 0);
        --end case;

        --wdata_line <= (others => '0');
        --wdata_sel <= (others => '0');

        --case latched_address(2 downto 0) is
        --  when "000" =>
        --    wdata_line(7 downto 0) <= std_logic_vector(wdata_latched);
        --    wdata_sel(0) <= '1';
        --  when "001" =>
        --    wdata_line(15 downto 8) <= std_logic_vector(wdata_latched);
        --    wdata_sel(1) <= '1';
        --  when "010" =>
        --    wdata_line(23 downto 16) <= std_logic_vector(wdata_latched);
        --    wdata_sel(2) <= '1';
        --  when "011" =>
        --    wdata_line(31 downto 24) <= std_logic_vector(wdata_latched);
        --    wdata_sel(3) <= '1';
        --  when "100" =>
        --    wdata_line(39 downto 32) <= std_logic_vector(wdata_latched);
        --    wdata_sel(4) <= '1';
        --  when "101" =>
        --    wdata_line(47 downto 40) <= std_logic_vector(wdata_latched);
        --    wdata_sel(5) <= '1';
        --  when "110" =>
        --    wdata_line(55 downto 48) <= std_logic_vector(wdata_latched);
        --    wdata_sel(6) <= '1';
        --  when others =>                  -- "111" =>
        --    wdata_line(63 downto 56) <= std_logic_vector(wdata_latched);
        --    wdata_sel(7) <= '1';
        --end case;

        --case latched_address(7 downto 0) is
        --  -- "SDRAM" at $C000000
        --  when x"00" =>
        --    nonram_val <= x"53"; -- 83
        --  when x"01" =>
        --    nonram_val <= x"44"; -- 68
        --  when x"02" =>
        --    nonram_val <= x"52"; -- 82
        --  when x"03" =>
        --    nonram_val <= x"41"; -- 65
        --  when x"04" =>
        --    nonram_val <= x"4d"; -- 77
        --  -- Number of reads and writes done
        --  when x"05" =>
        --    nonram_val <= read_jobs;
        --  when x"06" =>
        --    nonram_val <= write_jobs;
        --  when x"07" =>
        --    nonram_val <= resets;
        --  when others => nonram_val <= x"42"; -- 66
        --end case;

        -- Latch incoming requests (those come in on the 81MHz pixel clock)
        --if read_request = '1' and write_request = '0' and write_latched = '0' and read_latched = '0' then
        --  report "Latching read request for $" & to_hexstring(address);
        --  report "BUSY: Asserting busy";
        --  busy         <= '1';
        --  read_latched <= '1';
        --  latched_address <= address;
        --  silent_read  <= '0';
        --end if;
        --if read_request = '0' and write_request = '1' and write_latched = '0' and read_latched = '0' then
        --  report "Latching write request";
        --  report "BUSY: Asserting busy";
        --  busy          <= '1';
        --  write_latched <= '1';
        --  latched_address  <= address;
        --  wdata_latched <= wdata;
        --  --if rdata_16en = '1' then
        --  --  wdata_hi_latched <= wdata_hi;
        --  --  latched_wen_lo   <= wen_lo;
        --  --  latched_wen_hi   <= wen_hi;
        --  --else
        --  --  wdata_hi_latched <= wdata;
        --  --  latched_wen_lo   <= address(0);
        --  --  latched_wen_hi   <= not address(0);
        --  --end if;
        --end if;

        --if read_publish_strobe = '1' then
        --  read_publish_strobe <= '0';
        --  report "rdata_line = $" & to_hexstring(rdata_line);
        --  report "latched_address bits = " & to_string(std_logic_vector(latched_address(2 downto 0)));
        --  --report "PUBLISH: rdata <= $" & to_hexstring(rdata_hi_buf) & to_hexstring(rdata_buf) & ", silent=" & std_logic'image(silent_read);
        --  -- When prefetching cache lines, we don't present the output.
        --  -- I.E., the read is "silent"
        --  if silent_read = '0' then
        --    rdata                  <= rdata_buf;
        --    --rdata_hi               <= rdata_hi_buf;
        --    data_ready_toggle      <= not last_data_ready_toggle;
        --    last_data_ready_toggle <= not last_data_ready_toggle;
        --    report "BUSY: Clearing busy via read_publish_strobe";
        --    busy                   <= '0';
        --    read_latched           <= '0';
        --  end if;
        --end if;
        --if read_complete_strobe = '1' then
        --  read_complete_strobe <= '0';
        --  report "READCOMPLETE: Publishing cache line $" & to_hexstring(rdata_line);
        --  -- We also update the read cache line here
        --  --for b in 0 to 7 loop
        --  --  current_cache_line(b) <= rdata_line((b*8+7) downto (b*8));
        --  --end loop;
        --  --current_cache_line_address(26 downto 3) <= latched_address(26 downto 3);
        --  --current_cache_line_valid                <= '1';
        --  --current_cache_line_valid_int            <= '1';

        --  read_publish_strobe <= '1';
        --end if;

        --next_toggle_drive <= expansionram_current_cache_line_next_toggle;
        --prev_toggle_drive <= expansionram_current_cache_line_prev_toggle;

        --if read_request = '0' and write_request = '0' and write_latched = '0' and read_latched = '0' and
        --  (prev_toggle_drive /= prev_current_cache_line_prev_toggle) then
        --  -- Read previous cache line
        --  report "Latching read or write request for previous cache line";
        --  report "prev_toggle_drive = " & std_logic'image(prev_toggle_drive) & ", "
        --    & "prev_current_cache_line_prev_toggle = " & std_logic'image(prev_current_cache_line_prev_toggle);
        --  report "BUSY: Asserting busy";
        --  busy                                <= '1';
        --  read_latched                        <= '1';
        --  latched_address(26 downto 3)           <= cache_line_prev_address;
        --  latched_address(2 downto 0)            <= "000";
        --  silent_read                         <= '1';
        --  prev_current_cache_line_prev_toggle <= prev_toggle_drive;
        --end if;

        --if read_request = '0' and write_request = '0' and write_latched = '0' and read_latched = '0' and
        --  (next_toggle_drive /= prev_current_cache_line_next_toggle) then
        --  -- Read next cache line
        --  report "Latching read or write request for next cache line";
        --  report "BUSY: Asserting busy";
        --  busy                                <= '1';
        --  read_latched                        <= '1';
        --  latched_address(26 downto 3)           <= cache_line_next_address;
        --  latched_address(2 downto 0)            <= "000";
        --  silent_read                         <= '1';
        --  prev_current_cache_line_next_toggle <= next_toggle_drive;
        --end if;

        --if sdram_state /= IDLE then
        --  sdram_state <= sdram_state_t'succ(sdram_state);
        --end if;

        --if sdram_state /= IDLE then
        --  if stuck_counter = 1000 then
        --    stuck_int <= '1';
        --  else
        --    stuck_counter <= stuck_counter + 1;
        --  end if;
        --else
        --  stuck_int <= '0';
        --  stuck_counter <= 0;
        --end if;

        case sdram_state is

          when IDLE =>

            if read_request = '1' then

              if std_logic_vector(address(26 downto 4)) = write_cache_address(22 downto 0) and
                write_cache_select(to_integer(address(3 downto 0))) = '1' then

                case address(3 downto 0) is
                  when "0000" =>
                    rdata <= unsigned(write_cache_data(7 downto 0));
                  when "0001" =>
                    rdata <= unsigned(write_cache_data(15 downto 8));
                  when "0010" =>
                    rdata <= unsigned(write_cache_data(23 downto 16));
                  when "0011" =>
                    rdata <= unsigned(write_cache_data(31 downto 24));
                  when "0100" =>
                    rdata <= unsigned(write_cache_data(39 downto 32));
                  when "0101" =>
                    rdata <= unsigned(write_cache_data(47 downto 40));
                  when "0110" =>
                    rdata <= unsigned(write_cache_data(55 downto 48));
                  when "0111" =>
                    rdata <= unsigned(write_cache_data(63 downto 56));
                  when "1000" =>
                    rdata <= unsigned(write_cache_data(71 downto 64));
                  when "1001" =>
                    rdata <= unsigned(write_cache_data(79 downto 72));
                  when "1010" =>
                    rdata <= unsigned(write_cache_data(87 downto 80));
                  when "1011" =>
                    rdata <= unsigned(write_cache_data(95 downto 88));
                  when "1100" =>
                    rdata <= unsigned(write_cache_data(103 downto 96));
                  when "1101" =>
                    rdata <= unsigned(write_cache_data(111 downto 104));
                  when "1110" =>
                    rdata <= unsigned(write_cache_data(119 downto 112));
                  when others =>
                    rdata <= unsigned(write_cache_data(127 downto 120));
                end case;

                data_ready_toggle <= '1';
                sdram_state       <= IDLE;
                --busy              <= '0';

              else

                latched_address <= address;
                busy <= '1';

                if wb_stall = '0' then
                  wb_stb  <= '1';
                  wb_we   <= '0';
                  wb_addr <= "0" & std_logic_vector(address(26 downto 4));
                  sdram_state <= SDRAM_READ_CHECK_STALL;
                else
                  sdram_state <= SDRAM_READ_WAIT_STALL;
                end if;
              end if;

            elsif write_request = '1' then

              if std_logic_vector(address(26 downto 4)) = write_cache_address(22 downto 0) then

                case address(3 downto 0) is
                  when "0000" =>
                    write_cache_data(7 downto 0) <= std_logic_vector(wdata);
                    write_cache_select(0)        <= '1';
                  when "0001" =>
                    write_cache_data(15 downto 8) <= std_logic_vector(wdata);
                    write_cache_select(1)        <= '1';
                  when "0010" =>
                    write_cache_data(23 downto 16) <= std_logic_vector(wdata);
                    write_cache_select(2)        <= '1';
                  when "0011" =>
                    write_cache_data(31 downto 24) <= std_logic_vector(wdata);
                    write_cache_select(3)        <= '1';
                  when "0100" =>
                    write_cache_data(39 downto 32) <= std_logic_vector(wdata);
                    write_cache_select(4)        <= '1';
                  when "0101" =>
                    write_cache_data(47 downto 40) <= std_logic_vector(wdata);
                    write_cache_select(5)        <= '1';
                  when "0110" =>
                    write_cache_data(55 downto 48) <= std_logic_vector(wdata);
                    write_cache_select(6)        <= '1';
                  when "0111" =>
                    write_cache_data(63 downto 56) <= std_logic_vector(wdata);
                    write_cache_select(7)        <= '1';
                  when "1000" =>
                    write_cache_data(71 downto 64) <= std_logic_vector(wdata);
                    write_cache_select(8)        <= '1';
                  when "1001" =>
                    write_cache_data(79 downto 72) <= std_logic_vector(wdata);
                    write_cache_select(9)        <= '1';
                  when "1010" =>
                    write_cache_data(87 downto 80) <= std_logic_vector(wdata);
                    write_cache_select(10)        <= '1';
                  when "1011" =>
                    write_cache_data(95 downto 88) <= std_logic_vector(wdata);
                    write_cache_select(11)        <= '1';
                  when "1100" =>
                    write_cache_data(103 downto 96) <= std_logic_vector(wdata);
                    write_cache_select(12)        <= '1';
                  when "1101" =>
                    write_cache_data(111 downto 104) <= std_logic_vector(wdata);
                    write_cache_select(13)        <= '1';
                  when "1110" =>
                    write_cache_data(119 downto 112) <= std_logic_vector(wdata);
                    write_cache_select(14)        <= '1';
                  when others =>
                    write_cache_data(127 downto 120) <= std_logic_vector(wdata);
                    write_cache_select(15)        <= '1';
                end case;

                sdram_state <= IDLE;
                --busy        <= '0';

              else

                write_cache_address <= "0" & std_logic_vector(address(26 downto 4));
                write_cache_data    <= write_burst_data;
                write_cache_select  <= write_burst_select;

                write_burst_address_latched <= write_cache_address;
                write_burst_data_latched    <= write_cache_data;
                write_burst_select_latched  <= write_cache_select;

                busy <= '1';

                if wb_stall = '0' then
                  wb_stb   <= '1';
                  wb_we    <= '1';
                  wb_addr  <= write_cache_address;
                  wb_wdata <= write_cache_data;
                  wb_sel   <= write_cache_select;

                  sdram_state <= SDRAM_WRITE_CHECK_STALL;
                else
                  sdram_state <= SDRAM_WRITE_WAIT_STALL;
                end if;

              end if;
            end if;

          when SDRAM_READ_WAIT_STALL =>

            if wb_stall = '0' then
                wb_stb  <= '1';
                wb_we   <= '0';
                wb_addr <= "0" & std_logic_vector(latched_address(26 downto 4));
                sdram_state <= SDRAM_READ_CHECK_STALL;
            end if;

          when SDRAM_WRITE_WAIT_STALL =>

            if wb_stall = '0' then
                wb_stb      <= '1';
                wb_we       <= '1';
                wb_addr     <= write_burst_address_latched;
                wb_wdata    <= write_burst_data_latched;
                wb_sel      <= write_burst_select_latched;
                sdram_state <= SDRAM_WRITE_CHECK_STALL;
            end if;

          when SDRAM_READ_CHECK_STALL =>

            if wb_stall = '1' then
              sdram_state <= SDRAM_READ_WAIT_STALL;
            elsif wb_ack = '1' then
              rdata             <= unsigned(read_burst_byte);
              --data_ready_toggle      <= not last_data_ready_toggle;
              --last_data_ready_toggle <= not last_data_ready_toggle;
              data_ready_toggle <= '1';
              sdram_state       <= IDLE;
              busy              <= '0';
            else
              sdram_state <= SDRAM_READ_WAIT_ACK;
            end if;

          when SDRAM_READ_WAIT_ACK =>

            if wb_ack = '1' then
              rdata <= unsigned(read_burst_byte);
              --data_ready_toggle      <= not last_data_ready_toggle;
              --last_data_ready_toggle <= not last_data_ready_toggle;
              data_ready_toggle <= '1';
              sdram_state       <= IDLE;
              busy              <= '0';
            end if;

          when SDRAM_WRITE_CHECK_STALL =>

            if wb_stall = '1' then
              sdram_state <= SDRAM_WRITE_WAIT_STALL;
            elsif wb_ack = '1' then
              sdram_state <= IDLE;
              busy        <= '0';
            else
              sdram_state <= SDRAM_WRITE_WAIT_ACK;
            end if;

          when SDRAM_WRITE_WAIT_ACK =>

            if wb_ack = '1' then
              sdram_state <= IDLE;
              busy        <= '0';
            end if;

        end case;
      end if;
    end if;
  end process;

end tacoma_narrows;
