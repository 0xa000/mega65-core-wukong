library IEEE;
use IEEE.STD_LOGIC_1164.all;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;
use work.cputypes.all;

entity sdram_controller is
  generic (in_simulation : in boolean := false;
           -- Power-on READ-to-capture latency ($C00000A).  The default of
           -- 3 reproduces the original fixed wait chain (correct for the
           -- MEGA65 R4+ boards and the zero-delay simulation model);
           -- boards with different trace delays pass their measured value.
           read_latency_init : integer range 0 to 15 := 3);
  port (pixelclock : in std_logic;      -- For slow devices bus interface is
        -- actually on pixelclock to reduce latencies
        -- Also pixelclock is the natural clock speed we apply to the HyperRAM.
        -- Nominal 162MHz SDRAM clock (162.5MHz on MEGA65 R4+ boards,
        -- 162.0MHz on boards clocked from the 810MHz VCO family)
        clock162   : in std_logic;

        clock162r  : in std_logic;      -- read register clock

        identical_clocks : in std_logic;

        -- Fine phase-shift control for the read register clock (clock162r),
        -- pulsed by writing to $C000008 (bit 0 = direction).  The current
        -- step count is readable at $C000008/$C000009 and is a RELATIVE
        -- offset from the statically calibrated capture phase (the MMCM
        -- bakes in the measured eye centre; 0 = calibrated centre).
        sdram_ps_en     : out std_logic := '0';
        sdram_ps_incdec : out std_logic := '0';

        -- Option to ignore 100usec initialisation sequence for SDRAM (to
        -- speed up simulation)
        enforce_100us_delay : in boolean := true;

        -- Simple counter for number of requests received
        request_counter : out std_logic := '0';

        read_request  : in std_logic;
        write_request : in std_logic;
        address       : in unsigned(26 downto 0);
        wdata         : in unsigned(7 downto 0);

        -- Optional 16-bit interface (for Amiga core use)
        -- (That it is optional, is why the write_en is inverted for the
        -- low-byte).
        -- 16-bit transactions MUST occur on an even numbered address, or
        -- else expect odd and horrible things to happen.
        wdata_hi   : in  unsigned(7 downto 0) := x"00";
        wen_hi     : in  std_logic            := '0';
        wen_lo     : in  std_logic            := '1';
        rdata_hi   : out unsigned(7 downto 0);
        rdata_16en : in  std_logic            := '0';  -- set this high to be able
                                                       -- to read 16-bit values

        rdata : out unsigned(7 downto 0);

        data_ready_toggle : out std_logic := '0';

        -- Starts busy until SDRAM is initialised
        busy : out std_logic := '1';

        -- Export current cache line for speeding up reads from slow_devices controller
        -- by skipping the need to hand us the request and get the response back.
        current_cache_line                          : out   cache_row_t           := (others => (others => '0'));
        current_cache_line_address                  : inout unsigned(26 downto 3) := (others => '0');
        current_cache_line_valid                    : out   std_logic             := '0';
        expansionram_current_cache_line_next_toggle : in    std_logic             := '0';
        expansionram_current_cache_line_prev_toggle : in    std_logic             := '0';

        -- Allow VIC-IV to request lines of data also.
        -- We then pump it out byte-by-byte when ready
        -- VIC-IV can address only 512KB at a time, so we have a banking register
        viciv_addr           : in  unsigned(18 downto 3) := (others => '0');
        viciv_request_toggle : in  std_logic             := '0';
        viciv_data_out       : out unsigned(7 downto 0)  := x"00";
        viciv_data_strobe    : out std_logic             := '0';

        -- SDRAM interface (e.g. AS4C16M16SA-6TCN, IS42S16400F, etc.)
        sdram_a     : out   unsigned(12 downto 0);
        sdram_ba    : out   unsigned(1 downto 0);
        sdram_dq    : inout unsigned(15 downto 0);
        sdram_cke   : out   std_logic := '1';
        sdram_cs_n  : out   std_logic := '0';
        sdram_ras_n : out   std_logic;
        sdram_cas_n : out   std_logic;
        sdram_we_n  : out   std_logic;
        sdram_dqml  : out   std_logic;
        sdram_dqmh  : out   std_logic

        );
end sdram_controller;

architecture tacoma_narrows of sdram_controller is

  signal last_data_ready_toggle : std_logic := '0';

  signal sdram_prepped         : std_logic             := '0';
  -- The SDRAM requires a 100us setup time
  signal sdram_100us_countdown : integer               := 16_200;
  -- Held off until the 100usec delay has expired (or immediately when
  -- enforce_100us_delay is false, for simulation). Writing any non-RAM
  -- address ($C00xxxx) re-runs the initialisation sequence; the number of
  -- runs is readable at $C000007.
  signal sdram_do_init         : std_logic             := '0';
  signal sdram_init_phase      : integer range 0 to 63 := 0;

  type sdram_cmd_t is (CMD_NOP, CMD_SET_MODE_REG,
                       CMD_PRECHARGE,
                       CMD_AUTO_REFRESH,
                       CMD_ACTIVATE_ROW,
                       CMD_READ,
                       CMD_WRITE,
                       CMD_STOP
                       );

  -- Initialisation sequence required for SDRAM according to
  -- the "INITIALIZE AND LOAD MODE REGISTER" section of the
  -- datasheet.
  type sdram_init_t is array (0 to 31) of sdram_cmd_t;
  signal init_cmds : sdram_init_t := (
    2      => CMD_PRECHARGE,
    6      => CMD_AUTO_REFRESH,
    16     => CMD_AUTO_REFRESH,
    30     => CMD_SET_MODE_REG,
    others => CMD_NOP);

  -- SDRAM state machine.  IDLE must be the last in the list,
  -- so that the shallow auto-progression logic can progress
  -- through.
  type sdram_state_t is (CLOSE_AND_SWITCH_ROW,
                         CLOSE_AND_SWITCH_ROW_2,
                         CLOSE_AND_SWITCH_ROW_3,
                         CLOSE_AND_SWITCH_ROW_4,
                         ACTIVATE_WAIT,
                         ACTIVATE_WAIT_1,
                         ACTIVATE_WAIT_2,
                         READ_WAIT,
                         READ_0,
                         READ_1,
                         READ_2,
                         READ_3,
                         READ_4,
                         FLUSH_0,
                         FLUSH_1,
                         FLUSH_2,
                         FLUSH_3,
                         FLUSH_RECOVER,
                         CLOSE_FOR_REFRESH,
                         CLOSE_FOR_REFRESH_2,
                         CLOSE_FOR_REFRESH_3,
                         CLOSE_FOR_REFRESH_4,
                         REFRESH_1,
                         REFRESH_2,
                         REFRESH_3,
                         REFRESH_4,
                         REFRESH_5,
                         REFRESH_6,
                         REFRESH_7,
                         REFRESH_8,
                         REFRESH_9,
                         NON_RAM_READ,
                         IDLE);
  signal sdram_state : sdram_state_t := IDLE;

  signal rdata_line       : unsigned(63 downto 0);
  signal latched_addr     : unsigned(26 downto 0);
  signal rdata_buf        : unsigned(7 downto 0);
  signal rdata_hi_buf     : unsigned(7 downto 0);
  signal read_latched     : std_logic := '0';
  signal write_latched    : std_logic := '0';
  signal wdata_latched    : unsigned(7 downto 0);
  signal wdata_hi_latched : unsigned(7 downto 0);
  signal latched_wen_lo   : std_logic := '0';
  signal latched_wen_hi   : std_logic := '0';

  signal read_jobs  : unsigned(7 downto 0) := to_unsigned(0, 8);
  signal write_jobs : unsigned(7 downto 0) := to_unsigned(0, 8);

  signal nonram_val : unsigned(7 downto 0);
  signal ps_count   : unsigned(15 downto 0) := to_unsigned(0,16);
  -- Cycles spent in READ_WAIT between READ command and first capture is
  -- read_latency_cfg (+1 implicit), minus one when identical_clocks='1';
  -- a value of 3 reproduces the original fixed 4-cycle wait chain.
  -- Runtime-tunable via $C00000A for capture alignment bring-up.
  -- Default 2: centre of the measured eye on Wukong V3 with the inverted
  -- forwarded clock (2026-09-09 scan, tests/wukong-bringup/).
  signal read_latency_cfg : unsigned(3 downto 0) := to_unsigned(read_latency_init,4);
  signal read_wait_count  : integer range 0 to 15 := 0;

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

  -- Last-read-line cache: rdata_line keeps the most recent 8-byte burst
  -- anyway, so remembering which line it holds lets us serve repeated
  -- reads of that line from IDLE without touching the SDRAM array.
  -- Coherence: any latched write to the cached line invalidates it.
  signal read_line_addr  : unsigned(26 downto 3) := (others => '0');
  signal read_line_valid : std_logic := '0';

  -- Write-combining cache (ported from the openxc7 sdram_controller_wukong):
  -- byte writes merge into a single 8-byte line and complete immediately;
  -- the line is flushed to the array (up to 4 consecutive single-word
  -- WRITE commands, clean words skipped, per-byte DQM masking) only when
  -- a write misses a dirty line or a read needs the line's true content.
  -- A set select bit marks a dirty byte. While a flush is in flight the
  -- triggering request stays latched and is re-dispatched from IDLE
  -- afterwards. write_jobs counts flushes (readable at $C000006).
  signal write_cache_addr  : unsigned(26 downto 3) := (others => '0');
  signal write_cache_data  : unsigned(63 downto 0) := (others => '0');
  signal write_cache_sel   : std_logic_vector(7 downto 0) := (others => '0');
  signal write_cache_dirty : std_logic := '0';
  signal flush_active      : std_logic := '0';

  -- The line-address comparisons against the two caches are precomputed
  -- when a request is latched, so the IDLE dispatch logic tests a single
  -- registered bit instead of a 24-bit comparator (which showed up as
  -- the critical path in the 162MHz domain). Both cache line addresses
  -- are stable between a request's latch and its dispatch.
  signal latched_matches_read_line  : std_logic := '0';
  signal latched_matches_write_line : std_logic := '0';

  signal sdram_dq_out : unsigned(15 downto 0);
  signal sdram_dq_oe_n : std_logic_vector(15 downto 0);

  attribute iob : string;
  attribute iob of sdram_dq_out : signal is "true";
  attribute iob of sdram_dq_oe_n : signal is "true";
  attribute iob of sdram_dq_latched : signal is "true";

begin

  sdram_dq_gen : for i in sdram_dq'range generate
     sdram_dq(i) <= sdram_dq_out(i) when sdram_dq_oe_n(i) = '0' else 'Z';
  end generate sdram_dq_gen;

  process(clock162r) is
  begin

    if rising_edge(clock162r) then
      sdram_dq_latched <= sdram_dq;
    end if;
  end process;

  process(clock162, pixelclock) is
    procedure sdram_emit_command(cmd : sdram_cmd_t) is
    begin
      case cmd is
        when CMD_SET_MODE_REG =>
          sdram_ras_n <= '0';
          sdram_cas_n <= '0';
          sdram_we_n  <= '0';
        when CMD_PRECHARGE =>
          sdram_ras_n <= '0';
          sdram_cas_n <= '1';
          sdram_we_n  <= '0';
          sdram_a(10) <= '1';
        when CMD_AUTO_REFRESH =>
          sdram_ras_n <= '0';
          sdram_cas_n <= '0';
          sdram_we_n  <= '1';
        when CMD_ACTIVATE_ROW =>
          -- sdram_ba=BANK and sdram_a=ROW
          sdram_ras_n <= '0';
          sdram_cas_n <= '1';
          sdram_we_n  <= '1';
        when CMD_READ =>
          sdram_ras_n <= '1';
          sdram_cas_n <= '0';
          sdram_we_n  <= '1';
        when CMD_WRITE =>
          sdram_ras_n <= '1';
          sdram_cas_n <= '0';
          sdram_we_n  <= '0';
        when CMD_STOP =>
          sdram_ras_n <= '1';
          sdram_cas_n <= '1';
          sdram_we_n  <= '0';
        when CMD_NOP =>
          sdram_ras_n <= '1';
          sdram_cas_n <= '1';
          sdram_we_n  <= '1';
        when others =>
          sdram_ras_n <= '1';
          sdram_cas_n <= '1';
          sdram_we_n  <= '1';
      end case;
    end procedure;

    -- Start writing the dirty write-cache line back to the array,
    -- opening or switching to its row first when necessary. The
    -- triggering request stays latched and is re-dispatched from
    -- IDLE once the flush has completed.
    procedure dispatch_flush is
    begin
      report "SDRAMFLUSH: Flushing write cache line $" & to_hexstring(write_cache_addr & "000");
      flush_active <= '1';
      if active_row = '0' then
        sdram_emit_command(CMD_ACTIVATE_ROW);
        sdram_ba    <= write_cache_addr(25 downto 24);
        sdram_a     <= write_cache_addr(23 downto 11);
        sdram_state <= ACTIVATE_WAIT;
      elsif write_cache_addr(25 downto 11) /= active_row_addr(25 downto 11) then
        sdram_emit_command(CMD_PRECHARGE);
        sdram_ba    <= write_cache_addr(25 downto 24);
        sdram_a     <= write_cache_addr(23 downto 11);
        sdram_state <= CLOSE_AND_SWITCH_ROW;
      else
        sdram_emit_command(CMD_NOP);
        sdram_state <= FLUSH_0;
      end if;
    end procedure;

  begin
    if rising_edge(clock162) then

      sdram_dq_oe_n <= (others => '1');
      sdram_dqml <= '1';
      sdram_dqmh <= '1';
      sdram_ps_en <= '0';

      if refresh_due_countdown /= 0 then
        refresh_due_countdown <= refresh_due_countdown - 1;
        refresh_due           <= '0';
      else
        refresh_due <= '1';
      end if;

      if current_cache_line_address(26 downto 3) /= latched_addr(26 downto 3) then
        write_targets_cache_line <= '0';
      else
        write_targets_cache_line <= '1';
      end if;

      cache_line_prev_address <= current_cache_line_address(26 downto 3) - 1;
      cache_line_next_address <= current_cache_line_address(26 downto 3) + 1;

      if reactive_cache_line_if_safe = '1' and write_targets_cache_line = '0' then
        current_cache_line_valid     <= '1';
        current_cache_line_valid_int <= '1';
        reactive_cache_line_if_safe  <= '0';
      end if;

      -- Keep logic flat by pre-extracting read data
      -- report "RDATA_BUF: Reading from offset " & to_string(std_logic_vector(latched_addr(2 downto 0))) &
      -- ", = $" & to_hexstring(rdata_line);
      case latched_addr(2 downto 0) is
        when "000" =>
          rdata_buf    <= rdata_line(7 downto 0);
          rdata_hi_buf <= rdata_line(15 downto 8);
        when "001" =>
          rdata_buf    <= rdata_line(15 downto 8);
          rdata_hi_buf <= rdata_line(23 downto 16);
        when "010" =>
          rdata_buf    <= rdata_line(23 downto 16);
          rdata_hi_buf <= rdata_line(31 downto 24);
        when "011" =>
          rdata_buf    <= rdata_line(31 downto 24);
          rdata_hi_buf <= rdata_line(39 downto 32);
        when "100" =>
          rdata_buf    <= rdata_line(39 downto 32);
          rdata_hi_buf <= rdata_line(47 downto 40);
        when "101" =>
          rdata_buf    <= rdata_line(47 downto 40);
          rdata_hi_buf <= rdata_line(55 downto 48);
        when "110" =>
          rdata_buf    <= rdata_line(55 downto 48);
          rdata_hi_buf <= rdata_line(63 downto 56);
        when others =>                  -- "111" =>
          rdata_buf    <= rdata_line(63 downto 56);
          rdata_hi_buf <= rdata_line(7 downto 0);
      end case;

      case latched_addr(7 downto 0) is
        -- "SDRAM" at $C000000
        when x"00" =>
          nonram_val <= x"53";
        when x"01" =>
          nonram_val <= x"44";
        when x"02" =>
          nonram_val <= x"52";
        when x"03" =>
          nonram_val <= x"41";
        when x"04" =>
          nonram_val <= x"4d";
        -- Number of reads and writes done
        when x"05" =>
          nonram_val <= read_jobs;
        when x"06" =>
          nonram_val <= write_jobs;
        when x"07" =>
          nonram_val <= resets;
        -- Current read-capture phase step count
        when x"08" =>
          nonram_val <= ps_count(7 downto 0);
        when x"09" =>
          nonram_val <= ps_count(15 downto 8);
        -- Read latency configuration
        when x"0A" =>
          nonram_val <= x"0" & read_latency_cfg;
        when others => nonram_val <= x"42";
      end case;


      -- Latch incoming requests (those come in on the 81MHz pixel clock)
      if read_request = '1' and write_request = '0' and write_latched = '0' and read_latched = '0' then
        report "Latching read request for $" & to_hexstring(address);
        report "BUSY: Asserting busy";
        busy         <= '1';
        read_latched <= '1';
        latched_addr <= address;
        silent_read  <= '0';
        if address(26 downto 3) = read_line_addr then
          latched_matches_read_line <= '1';
        else
          latched_matches_read_line <= '0';
        end if;
        if address(26 downto 3) = write_cache_addr then
          latched_matches_write_line <= '1';
        else
          latched_matches_write_line <= '0';
        end if;
      end if;
      if read_request = '0' and write_request = '1' and write_latched = '0' and read_latched = '0' then
        report "Latching write request";
        report "BUSY: Asserting busy";
        busy          <= '1';
        write_latched <= '1';
        latched_addr  <= address;
        wdata_latched <= wdata;
        if address(26 downto 3) = read_line_addr then
          read_line_valid <= '0';
        end if;
        if address(26 downto 3) = write_cache_addr then
          latched_matches_write_line <= '1';
        else
          latched_matches_write_line <= '0';
        end if;
        if rdata_16en = '1' then
          wdata_hi_latched <= wdata_hi;
          -- The latched_wen_* signals carry DQM polarity ('1' = mask the
          -- byte, see the non-16-bit path below). Per the port convention
          -- wen_lo is already inverted (active low) but wen_hi is active
          -- high, so it must be inverted here.
          latched_wen_lo   <= wen_lo;
          latched_wen_hi   <= not wen_hi;
        else
          wdata_hi_latched <= wdata;
          latched_wen_lo   <= address(0);
          latched_wen_hi   <= not address(0);
        end if;
      end if;

      if read_publish_strobe = '1' then
        read_publish_strobe <= '0';
        report "rdata_line = $" & to_hexstring(rdata_line);
        report "latched_addr bits = " & to_string(std_logic_vector(latched_addr(2 downto 0)));
        report "PUBLISH: rdata <= $" & to_hexstring(rdata_hi_buf) & to_hexstring(rdata_buf) & ", silent=" & std_logic'image(silent_read);
        -- When prefetching cache lines, we don't present the output.
        -- I.E., the read is "silent"
        if silent_read = '0' then
          rdata                  <= rdata_buf;
          rdata_hi               <= rdata_hi_buf;
          data_ready_toggle      <= not last_data_ready_toggle;
          last_data_ready_toggle <= not last_data_ready_toggle;
          report "BUSY: Clearing busy via read_publish_strobe";
          busy                   <= '0';
        end if;
      end if;
      if read_complete_strobe = '1' then
        read_complete_strobe <= '0';
        report "READCOMPLETE: Publishing cache line $" & to_hexstring(rdata_line);
        -- We also update the read cache line here
        for b in 0 to 7 loop
          current_cache_line(b) <= rdata_line((b*8+7) downto (b*8));
        end loop;
        current_cache_line_address(26 downto 3) <= latched_addr(26 downto 3);
        current_cache_line_valid                <= '1';
        current_cache_line_valid_int            <= '1';

        read_publish_strobe <= '1';
      end if;

      next_toggle_drive <= expansionram_current_cache_line_next_toggle;
      prev_toggle_drive <= expansionram_current_cache_line_prev_toggle;

      if read_request = '0' and write_request = '0' and write_latched = '0' and read_latched = '0' and
        (prev_toggle_drive /= prev_current_cache_line_prev_toggle) then
        -- Read previous cache line
        report "Latching read or write request for previous cache line";
        report "prev_toggle_drive = " & std_logic'image(prev_toggle_drive) & ", "
          & "prev_current_cache_line_prev_toggle = " & std_logic'image(prev_current_cache_line_prev_toggle);
        report "BUSY: Asserting busy";
        busy                                <= '1';
        read_latched                        <= '1';
        latched_addr(26 downto 3)           <= cache_line_prev_address;
        latched_addr(2 downto 0)            <= "000";
        silent_read                         <= '1';
        prev_current_cache_line_prev_toggle <= prev_toggle_drive;
        if cache_line_prev_address = read_line_addr then
          latched_matches_read_line <= '1';
        else
          latched_matches_read_line <= '0';
        end if;
        if cache_line_prev_address = write_cache_addr then
          latched_matches_write_line <= '1';
        else
          latched_matches_write_line <= '0';
        end if;
      end if;

      if read_request = '0' and write_request = '0' and write_latched = '0' and read_latched = '0' and
        (next_toggle_drive /= prev_current_cache_line_next_toggle) then
        -- Read next cache line
        report "Latching read or write request for next cache line";
        report "BUSY: Asserting busy";
        busy                                <= '1';
        read_latched                        <= '1';
        latched_addr(26 downto 3)           <= cache_line_next_address;
        latched_addr(2 downto 0)            <= "000";
        silent_read                         <= '1';
        prev_current_cache_line_next_toggle <= next_toggle_drive;
        if cache_line_next_address = read_line_addr then
          latched_matches_read_line <= '1';
        else
          latched_matches_read_line <= '0';
        end if;
        if cache_line_next_address = write_cache_addr then
          latched_matches_write_line <= '1';
        else
          latched_matches_write_line <= '0';
        end if;
      end if;

      -- Manage the 100usec SDRAM initialisation delay, if enabled
      if sdram_100us_countdown /= 0 then
        sdram_100us_countdown <= sdram_100us_countdown - 1;
      end if;
      if sdram_100us_countdown = 1 then
        report "SDRAM: Starting init sequence after 100usec delay";
        sdram_do_init <= not sdram_prepped;
      end if;
      if enforce_100us_delay = false then
        if sdram_prepped = '0' then
          report "SDRAM: Skipping 100usec init delay";
        end if;
        sdram_do_init <= not sdram_prepped;
      end if;
      -- And the complete SDRAM initialisation sequence
      if sdram_init_phase = 0 and sdram_do_init = '1' then
        report "SDRAM: Starting SDRAM initialisation sequence";
        sdram_init_phase <= 1;
        resets <= resets + 1;
      end if;
      if sdram_prepped = '0' then
        if sdram_init_phase /= 0 then
          report "EMIT init phase " & integer'image(sdram_init_phase) & " command "
            & sdram_cmd_t'image(init_cmds(sdram_init_phase));
        end if;

        -- Clear reserved bits for mode register
        sdram_ba              <= (others => '0');
        sdram_a(12 downto 10) <= (others => '0');
        -- write burst length = 1
        sdram_a(9)            <= '1';
        -- Normal mode of operation
        sdram_a(8 downto 7)   <= (others => '0');
        -- CAS latency = 3, for 167MHz operation (what we do)
        sdram_a(6 downto 4)   <= to_unsigned(3, 3);
        -- Non-interleaved burst order
        sdram_a(3)            <= '0';
        -- Read burst length = 4 x 16 bit words = 8 bytes
        sdram_a(2 downto 0)   <= to_unsigned(2, 3);
        -- XXX DEBUG: read 8 x words so that we can check if missing bits is
        -- due to first word of burst or not.
--        sdram_a(2 downto 0)   <= to_unsigned(3, 3);

        -- Emit the sequence of commands
        -- MUST BE DONE AFTER SETTING sdram_a
        -- (so that A10 can be set for the PRECHARGE_ALL command,
        --  but stay clear for all the rest)
        sdram_emit_command(init_cmds(sdram_init_phase));

        if sdram_init_phase = 31 then
          sdram_prepped <= '1';
          report "BUSY: Clearing busy";
          busy          <= '0';
          report "SDRAM: Clearing BUSY at end of initialisation sequence";
        elsif sdram_init_phase /= 0 then
          sdram_init_phase <= sdram_init_phase + 1;
        end if;
      else
        -- SDRAM is ready
        report "SDRAMSTATE: " & sdram_state_t'image(sdram_state);
        if sdram_state /= IDLE then
          sdram_state <= sdram_state_t'succ(sdram_state);
        end if;
        case sdram_state is
          when IDLE =>
            if refresh_due = '1' and active_row = '0' then
              report "REFRESH is DUE (and no row was open, so triggering immediately)";
              sdram_emit_command(CMD_AUTO_REFRESH);
              sdram_state <= REFRESH_1;
              report "BUSY: Asserting busy";
              busy        <= '1';
            elsif refresh_due = '1' and active_row = '1' then
              report "REFRESH is DUE (a row is open, so precharging first)";
              sdram_emit_command(CMD_PRECHARGE);
              sdram_state <= CLOSE_FOR_REFRESH;
              report "BUSY: Asserting busy";
              busy        <= '1';
            elsif read_latched = '1' or write_latched = '1' then
              if latched_addr(26) = '1' then
                report "NONRAMACCESS: Non-RAM access detected";
                if write_latched = '1' then
                  if latched_addr(7 downto 0) = x"08" then
                    -- Step the read capture clock phase by ~22ps;
                    -- bit 0 of the written value selects the direction.
                    -- (MMCM wants 12 PSCLK cycles between steps; writes
                    -- arrive orders of magnitude further apart than that.)
                    sdram_ps_en     <= '1';
                    sdram_ps_incdec <= wdata_latched(0);
                    if wdata_latched(0) = '1' then
                      ps_count <= ps_count + 1;
                    else
                      ps_count <= ps_count - 1;
                    end if;
                    report "BUSY: Clearing after phase-step write";
                    busy <= '0';
                  elsif latched_addr(7 downto 0) = x"0A" then
                    -- Set the READ command to capture latency in cycles
                    read_latency_cfg <= wdata_latched(3 downto 0);
                    report "BUSY: Clearing after read-latency write";
                    busy <= '0';
                  else
                    -- Repeat SDRAM initialisation sequence whenever any other
                    -- non-RAM address is written.
                    -- XXX Used to debug whether SDRAM initialisation is sometimes
                    -- failing.
                    sdram_prepped <= '0';
                    sdram_init_phase <= 0;
                    sdram_do_init <= '1';
                  end if;
                  write_latched <= '0';
                else
                  -- Read non-RAM address
                  sdram_state <= NON_RAM_READ;
                  sdram_emit_command(CMD_NOP);
                end if;
              elsif read_latched = '1' then
                report "SDRAMREAD: Starting read from $" & to_hexstring(latched_addr);
                if read_line_valid = '1' and latched_matches_read_line = '1' then
                  -- Read-line cache hit: rdata_line already holds this line,
                  -- so publish it without an SDRAM transaction.
                  report "SDRAMREAD: Read-line cache hit for $" & to_hexstring(latched_addr);
                  sdram_emit_command(CMD_NOP);
                  read_complete_strobe <= '1';
                  read_latched         <= '0';
                  report "BUSY: Clearing after read-line cache hit";
                  busy                 <= '0';
                elsif write_cache_dirty = '1'
                  and latched_matches_write_line = '1' then
                  -- The line's newest bytes are still in the write cache:
                  -- flush it first, then re-dispatch this read from IDLE.
                  dispatch_flush;
                elsif active_row = '0' then
                  report "ACTIVATEROW: No row open yet, so opening before read for row $" & to_hexstring(latched_addr)
                    & " = %" & to_string(std_logic_vector(latched_addr));
                  -- If no active row, then activate one
                  sdram_emit_command(CMD_ACTIVATE_ROW);
                  sdram_ba    <= latched_addr(25 downto 24);
                  sdram_a     <= latched_addr(23 downto 11);
                  sdram_state <= ACTIVATE_WAIT;
                elsif latched_addr(25 downto 11) /= active_row_addr(25 downto 11) then
                  report "ACTIVATEROW: Closing old row before opening new one required for read";
                  -- Different row activated
                  -- Precharge row, then activate the correct row
                  sdram_emit_command(CMD_PRECHARGE);
                  sdram_ba    <= latched_addr(25 downto 24);
                  sdram_a     <= latched_addr(23 downto 11);
                  sdram_state <= CLOSE_AND_SWITCH_ROW;
                else
                  -- Correct row already activated
                  report "SDRAM: Issuing READ command against already-active row";
                  sdram_emit_command(CMD_READ);
                  -- Select address of start of 8-byte block
                  -- Each word is 2 bytes, which takes one bit
                  -- off, and then the bottom two bits must be zero.
                  sdram_a(12)         <= '0';
                  sdram_a(11)         <= '0';
                  sdram_a(10)         <= '0';  -- Disable auto precharge
                  sdram_a(9 downto 2) <= latched_addr(10 downto 3);
                  sdram_a(1 downto 0) <= "00";
                  sdram_state         <= READ_WAIT;
                  if identical_clocks = '1' and read_latency_cfg /= 0 then
                    read_wait_count <= to_integer(read_latency_cfg) - 1;
                  else
                    read_wait_count <= to_integer(read_latency_cfg);
                  end if;
                  sdram_dqml          <= '0'; sdram_dqmh <= '0';
                end if;
              else
                -- Write request: writes complete by merging into the
                -- write-combining cache; only a miss on a dirty line costs
                -- an SDRAM transaction (the flush of the old line).
                report "SDRAMWRITE: Starting write: $" & to_hexstring(latched_addr) & " <= $" & to_hexstring(wdata_latched);

                -- XXX For now we invalidate the cache line on _any_ write
                -- For the common case of DMA copy to or from slow RAM, this
                -- will be ok. Copying slow to slow will, however be bad.
                -- So to remedy that, we set a signal to check if the cache
                -- line can be re-instated. This prevents use of the cache while
                -- we are figuring out if the line is still valid.
                current_cache_line_valid     <= '0';
                current_cache_line_valid_int <= '0';
                if current_cache_line_valid_int = '1' then
                  reactive_cache_line_if_safe <= '1';
                end if;

                if write_cache_dirty = '1'
                  and latched_matches_write_line = '0' then
                  -- Miss on a dirty line: flush it, then re-dispatch this
                  -- write from IDLE (the cache is clean by then).
                  dispatch_flush;
                else
                  -- Merge into the cache (adopting the line first if it
                  -- differs from the last flushed one). The latched_wen_*
                  -- signals carry DQM polarity: '0' means write the byte.
                  sdram_emit_command(CMD_NOP);
                  if latched_matches_write_line = '0' then
                    write_cache_addr <= latched_addr(26 downto 3);
                    write_cache_sel  <= (others => '0');
                  end if;
                  case latched_addr(2 downto 1) is
                    when "00" =>
                      if latched_wen_lo = '0' then
                        write_cache_data(7 downto 0) <= wdata_latched;
                        write_cache_sel(0) <= '1';
                      end if;
                      if latched_wen_hi = '0' then
                        write_cache_data(15 downto 8) <= wdata_hi_latched;
                        write_cache_sel(1) <= '1';
                      end if;
                    when "01" =>
                      if latched_wen_lo = '0' then
                        write_cache_data(23 downto 16) <= wdata_latched;
                        write_cache_sel(2) <= '1';
                      end if;
                      if latched_wen_hi = '0' then
                        write_cache_data(31 downto 24) <= wdata_hi_latched;
                        write_cache_sel(3) <= '1';
                      end if;
                    when "10" =>
                      if latched_wen_lo = '0' then
                        write_cache_data(39 downto 32) <= wdata_latched;
                        write_cache_sel(4) <= '1';
                      end if;
                      if latched_wen_hi = '0' then
                        write_cache_data(47 downto 40) <= wdata_hi_latched;
                        write_cache_sel(5) <= '1';
                      end if;
                    when others =>
                      if latched_wen_lo = '0' then
                        write_cache_data(55 downto 48) <= wdata_latched;
                        write_cache_sel(6) <= '1';
                      end if;
                      if latched_wen_hi = '0' then
                        write_cache_data(63 downto 56) <= wdata_hi_latched;
                        write_cache_sel(7) <= '1';
                      end if;
                  end case;
                  write_cache_dirty <= '1';
                  write_latched     <= '0';
                  report "BUSY: Clearing after write-cache merge";
                  busy              <= '0';
                end if;
              end if;
            else
              sdram_emit_command(CMD_NOP);
            end if;
          when NON_RAM_READ =>
            read_latched              <= '0';
            report "PUBLISH: non-RAM read";
            data_ready_toggle       <= not last_data_ready_toggle;
            last_data_ready_toggle       <= not last_data_ready_toggle;
            report "BUSY: Clearing after non-ram read";
            busy <= '0';
            rdata                     <= nonram_val;
            rdata_hi                  <= nonram_val;
            sdram_state               <= IDLE;
            report "NONRAMACCESS: Presenting value $" & to_hexstring(nonram_val);
          when CLOSE_AND_SWITCH_ROW =>
            -- PRECHARGE has already been issued, so just NOP until precharge
            -- time expired
            sdram_emit_command(CMD_NOP);
          when CLOSE_AND_SWITCH_ROW_2 => sdram_emit_command(CMD_NOP);
          when CLOSE_AND_SWITCH_ROW_3 => sdram_emit_command(CMD_NOP);
          when CLOSE_AND_SWITCH_ROW_4 =>
            -- Now open the new row (of the flush line when flushing)
            sdram_emit_command(CMD_ACTIVATE_ROW);
            if flush_active = '1' then
              sdram_ba <= write_cache_addr(25 downto 24);
              sdram_a  <= write_cache_addr(23 downto 11);
            else
              sdram_ba <= latched_addr(25 downto 24);
              sdram_a  <= latched_addr(23 downto 11);
            end if;
          when ACTIVATE_WAIT =>
            sdram_emit_command(CMD_NOP);
          when ACTIVATE_WAIT_1 =>
            sdram_emit_command(CMD_NOP);
          when ACTIVATE_WAIT_2 =>
            sdram_emit_command(CMD_NOP);
            active_row <= '1';
            if flush_active = '1' then
              -- This activate was for the write-cache flush, not for the
              -- (possibly still latched) triggering request.
              active_row_addr(25 downto 11) <= write_cache_addr(25 downto 11);
              sdram_state <= FLUSH_0;
            elsif read_latched = '1' then
              active_row_addr(25 downto 11) <= latched_addr(25 downto 11);
              report "SDRAM: Issuing READ command after ROW_ACTIVATE";
              sdram_emit_command(CMD_READ);
              -- Select address of start of 8-byte block
              -- Each word is 2 bytes, which takes one bit
              -- off, and then the bottom two bits must be zero.
              sdram_a(12)         <= '0';
              sdram_a(11)         <= '0';
              sdram_a(10)         <= '0';  -- Disable auto precharge
              sdram_a(9 downto 2) <= latched_addr(10 downto 3);
              sdram_a(1 downto 0) <= "00";
              sdram_state         <= READ_WAIT;
              if identical_clocks = '1' and read_latency_cfg /= 0 then
                read_wait_count <= to_integer(read_latency_cfg) - 1;
              else
                read_wait_count <= to_integer(read_latency_cfg);
              end if;
              sdram_dqml          <= '0'; sdram_dqmh <= '0';
            end if;
          when READ_WAIT =>
            -- Wait a configurable number of cycles between the READ
            -- command and the first capture, so the CAS-latency /
            -- capture-register alignment can be tuned at runtime via
            -- $C00000A during board bring-up (hardware showed the fixed
            -- 4-cycle chain sampling two burst words late on Wukong V3).
            sdram_dqml <= '0'; sdram_dqmh <= '0';
            sdram_emit_command(CMD_NOP);
            -- The default auto-progression (sdram_state'succ) advances to
            -- READ_0; hold here instead while the wait counter runs down.
            if read_wait_count /= 0 then
              sdram_state     <= READ_WAIT;
              read_wait_count <= read_wait_count - 1;
            end if;
          when READ_0 =>
            read_jobs  <= read_jobs + 1;
            sdram_dqml <= '0'; sdram_dqmh <= '0';
            sdram_emit_command(CMD_NOP);
            -- Data is latched on opposite phase clock, so it isn't available yet
            -- but rather in the next cycle in READ_1
          when READ_1 =>
            rdata_line(15 downto 0) <= sdram_dq_latched;
            sdram_dqml <= '0'; sdram_dqmh <= '0';
            sdram_emit_command(CMD_NOP);
          when READ_2 =>
            sdram_dqml <= '0'; sdram_dqmh <= '0';
            rdata_line(31 downto 16) <= sdram_dq_latched;
            sdram_emit_command(CMD_NOP);
          when READ_3 =>
            sdram_emit_command(CMD_NOP);
            sdram_dqml <= '0'; sdram_dqmh <= '0';
            rdata_line(47 downto 32) <= sdram_dq_latched;
          when READ_4 =>
            report "READ4: sdram_dq_latched = $" & to_hexstring(sdram_dq_latched);
            rdata_line(63 downto 48) <= sdram_dq_latched;
            read_line_addr           <= latched_addr(26 downto 3);
            read_line_valid          <= '1';
            read_complete_strobe     <= '1';
            read_latched             <= '0';
            report "BUSY: Clearing after read";
            busy                     <= '0';
            sdram_state              <= IDLE;
          -- Write the dirty words of the write-cache line back with up to
          -- four consecutive single-word WRITE commands (clean words are
          -- skipped with a NOP). DQM lines are high to ignore a byte, and
          -- low to accept one; for writes DQM masks the same-cycle word.
          when FLUSH_0 =>
            if write_cache_sel(1 downto 0) /= "00" then
              sdram_emit_command(CMD_WRITE);
              sdram_a(12 downto 10) <= "000";  -- Disable auto precharge
              sdram_a(9 downto 2)   <= write_cache_addr(10 downto 3);
              sdram_a(1 downto 0)   <= "00";
              sdram_dq_out          <= write_cache_data(15 downto 0);
              sdram_dq_oe_n         <= (others => '0');
              sdram_dqml            <= not write_cache_sel(0);
              sdram_dqmh            <= not write_cache_sel(1);
            else
              sdram_emit_command(CMD_NOP);
            end if;
          when FLUSH_1 =>
            if write_cache_sel(3 downto 2) /= "00" then
              sdram_emit_command(CMD_WRITE);
              sdram_a(12 downto 10) <= "000";
              sdram_a(9 downto 2)   <= write_cache_addr(10 downto 3);
              sdram_a(1 downto 0)   <= "01";
              sdram_dq_out          <= write_cache_data(31 downto 16);
              sdram_dq_oe_n         <= (others => '0');
              sdram_dqml            <= not write_cache_sel(2);
              sdram_dqmh            <= not write_cache_sel(3);
            else
              sdram_emit_command(CMD_NOP);
            end if;
          when FLUSH_2 =>
            if write_cache_sel(5 downto 4) /= "00" then
              sdram_emit_command(CMD_WRITE);
              sdram_a(12 downto 10) <= "000";
              sdram_a(9 downto 2)   <= write_cache_addr(10 downto 3);
              sdram_a(1 downto 0)   <= "10";
              sdram_dq_out          <= write_cache_data(47 downto 32);
              sdram_dq_oe_n         <= (others => '0');
              sdram_dqml            <= not write_cache_sel(4);
              sdram_dqmh            <= not write_cache_sel(5);
            else
              sdram_emit_command(CMD_NOP);
            end if;
          when FLUSH_3 =>
            if write_cache_sel(7 downto 6) /= "00" then
              sdram_emit_command(CMD_WRITE);
              sdram_a(12 downto 10) <= "000";
              sdram_a(9 downto 2)   <= write_cache_addr(10 downto 3);
              sdram_a(1 downto 0)   <= "11";
              sdram_dq_out          <= write_cache_data(63 downto 48);
              sdram_dq_oe_n         <= (others => '0');
              sdram_dqml            <= not write_cache_sel(6);
              sdram_dqmh            <= not write_cache_sel(7);
            else
              sdram_emit_command(CMD_NOP);
            end if;
          when FLUSH_RECOVER =>
            -- One write-recovery (tWR) cycle before IDLE can issue a
            -- PRECHARGE. The triggering request is still latched and gets
            -- re-dispatched from IDLE; keep busy asserted for it.
            sdram_emit_command(CMD_NOP);
            flush_active      <= '0';
            write_cache_dirty <= '0';
            write_cache_sel   <= (others => '0');
            write_jobs        <= write_jobs + 1;
            if read_latched = '0' and write_latched = '0' then
              report "BUSY: Clearing after flush";
              busy <= '0';
            end if;
            sdram_state <= IDLE;
          when CLOSE_FOR_REFRESH   => sdram_emit_command(CMD_NOP);
          when CLOSE_FOR_REFRESH_2 => sdram_emit_command(CMD_NOP);
          when CLOSE_FOR_REFRESH_3 => sdram_emit_command(CMD_NOP);
          when CLOSE_FOR_REFRESH_4 => sdram_emit_command(CMD_NOP);
          when REFRESH_1 =>
            active_row            <= '0';
            refresh_due_countdown <= refresh_interval - 1;
          when REFRESH_2 => sdram_emit_command(CMD_NOP);
          when REFRESH_3 => sdram_emit_command(CMD_NOP);
          when REFRESH_4 => sdram_emit_command(CMD_NOP);
          when REFRESH_5 => sdram_emit_command(CMD_NOP);
          when REFRESH_6 => sdram_emit_command(CMD_NOP);
          when REFRESH_7 => sdram_emit_command(CMD_NOP);
          when REFRESH_8 => sdram_emit_command(CMD_NOP);
          when REFRESH_9 =>
            sdram_emit_command(CMD_NOP);
            report "BUSY: Clearing BUSY after refresh";
            busy        <= '0';
            sdram_state <= IDLE;
          when others =>
            sdram_emit_command(CMD_NOP);
        end case;
      end if;

    end if;
  end process;

end tacoma_narrows;
