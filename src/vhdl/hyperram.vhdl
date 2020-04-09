library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;
use work.cputypes.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity hyperram is
  Port ( pixelclock : in STD_LOGIC; -- For slow devices bus interface is
                                    -- actually on pixelclock to reduce latencies
         clock163 : in std_logic; -- Used for fast clock for HyperRAM

         -- Simple counter for number of requests received
         request_counter : out std_logic := '0';
         
         read_request : in std_logic;
         write_request : in std_logic;
         address : in unsigned(26 downto 0);
         wdata : in unsigned(7 downto 0);
         
         rdata : out unsigned(7 downto 0);
         data_ready_strobe : out std_logic := '0';
         busy : out std_logic := '0';

         -- Export current cache line for speeding up reads from slow_devices controller
         -- by skipping the need to hand us the request and get the response back.
         current_cache_line : out cache_row_t := (others => (others => '0'));
         current_cache_line_address : inout unsigned(26 downto 3) := (others => '0');
         current_cache_line_valid : out std_logic := '0';
         
         hr_d : inout unsigned(7 downto 0) := (others => 'Z'); -- Data/Address
         hr_rwds : inout std_logic := 'Z'; -- RW Data strobe
--         hr_rsto : in std_logic; -- Unknown PIN
         hr_reset : out std_logic := '1'; -- Active low RESET line to HyperRAM
--         hr_int : in std_logic; -- Interrupt?
         hr_clk_n : out std_logic := '0';
         hr_clk_p : out std_logic := '1';
         hr_cs0 : out std_logic := '1';
         hr_cs1 : out std_logic := '1'
         );
end hyperram;

architecture gothic of hyperram is

  type state_t is (
    Debug,
    Idle2,
    Idle,
    ReadSetup,
    WriteSetup,
    HyperRAMCSStrobe,
    HyperRAMOutputCommand,
    HyperRAMLatencyWait,
    HyperRAMFinishWriting1,
    HyperRAMFinishWriting,
    HyperRAMReadWait
    );

  -- How many clock ticks need to expire between transactions to satisfy T_RWR
  -- of hyperrram?
  signal rwr_delay : unsigned(7 downto 0) := to_unsigned(1+40*163/1000,8);
  signal rwr_counter : unsigned(7 downto 0) := (others => '0');

  -- We prime the HyperRAM controller to set the value of CR0 initially on
  -- power up to minimise latency.
  
  
  signal state : state_t := WriteSetup;
  signal busy_internal : std_logic := '1';
  signal hr_command : unsigned(47 downto 0);

  signal ram_address : unsigned(26 downto 0) :=
    "001000000000001000000000000"; -- = bottom 27 bits of x"9001000";
  signal ram_wdata : unsigned(7 downto 0) := x"00";
  signal ram_reading : std_logic := '0';
  signal ram_reading_held : std_logic := '0';

  -- We want to set config register 0 to $8fe6, to enable variable latency
  -- and 3 cycles instead of 6 for latency. This speeds up writing almost 2x.
  
  signal conf_buf0 : unsigned(7 downto 0) := x"8f";
  signal conf_buf1 : unsigned(7 downto 0) := x"e6";
  signal conf_buf0_in : unsigned(7 downto 0) := x"8f";
  signal conf_buf1_in : unsigned(7 downto 0) := x"e6";
  signal conf_buf0_set : std_logic := '0';
  signal conf_buf1_set : std_logic := '0';
  signal last_conf_buf0_set : std_logic := '0';
  signal last_conf_buf1_set : std_logic := '0';

  -- Delay sending of the initial configuration write command
  -- to give the HyperRAM chip time to start up
  -- Datasheet says 150usec is required, we do that, plus a bit.
  signal start_delay_counter : integer := 150*(1000/162)+20;  
  
  signal countdown : integer := 0;
  signal extra_latency : std_logic := '0';

  signal next_is_data : std_logic := '1';
  signal hr_clock : std_logic := '0';

  signal data_ready_toggle : std_logic := '0';
  signal last_data_ready_toggle : std_logic := '0';
  signal data_ready_strobe_hold : std_logic := '0';

  signal request_toggle : std_logic := '0';
  signal last_request_toggle : std_logic := '0';

  signal byte_phase : unsigned(3 downto 0) := to_unsigned(0,4);
  signal write_byte_phase : std_logic := '0';
  signal byte_written : std_logic := '0';

  signal debug_mode : std_logic := '0';

  signal hr_ddr : std_logic := '0';
  signal hr_rwds_ddr : std_logic := '0';
  signal hr_reset_int : std_logic := '0';
  signal hr_rwds_int : std_logic := '0';
  signal hr_cs0_int : std_logic := '0';
  signal hr_cs1_int : std_logic := '0';
  signal hr_clk_p_int : std_logic := '0';
  signal hr_clk_n_int : std_logic := '0';

  signal cycle_count : integer := 0;

  -- Have a tiny little cache to reduce latency
  -- 8 byte cache rows, where we indicate the validity of
  -- each byte.
  signal cache_row0_valids : std_logic_vector(0 to 7) := (others => '0');
  signal cache_row0_address : unsigned(23 downto 0) := (others => '1');  
  signal cache_row0_data : cache_row_t := ( others => x"00" );

  signal cache_row1_valids : std_logic_vector(0 to 7) := (others => '0');
  signal cache_row1_address : unsigned(23 downto 0) := (others => '1');  
  signal cache_row1_data : cache_row_t := ( others => x"00" );

  -- Collect writes together to hide write latency
  signal write_collect0_dispatchable : std_logic := '0';
  signal write_collect0_address : unsigned(26 downto 3) := (others => '0');  
  signal write_collect0_valids : std_logic_vector(0 to 7) := (others => '0');
  signal write_collect0_data : cache_row_t := ( others => x"00" );
  signal write_collect0_toolate : std_logic := '0'; -- Set when its too late to
                                                    -- add more bytes to the write.
  signal write_collect0_flushed : std_logic := '1';

  signal write_collect1_dispatchable : std_logic := '0';
  signal write_collect1_address : unsigned(26 downto 3) := (others => '0');  
  signal write_collect1_valids : std_logic_vector(0 to 7) := (others => '0');
  signal write_collect1_data : cache_row_t := ( others => x"00" );
  signal write_collect1_toolate : std_logic := '0'; -- Set when its too late to
                                                    -- add more bytes to the write.
  signal write_collect1_flushed : std_logic := '1';
  
  
  signal last_rwds : std_logic := '0';

  signal fake_data_ready_strobe : std_logic := '0';
  signal fake_rdata : unsigned(7 downto 0) := x"00";

  signal request_counter_int : std_logic := '0';

  -- 3 is correct for the part we have in the MEGA65, after we have set the
  -- config register to minimise latency.
  signal write_latency : unsigned(7 downto 0) := to_unsigned(3,8);
  -- And the matching extra latency is 5
  signal extra_write_latency : unsigned(7 downto 0) := to_unsigned(5,8);
  -- 8 - 4 is required, however, for the s27k0641.vhd test model that we have
  -- found for testing.
--   signal write_latency : unsigned(7 downto 0) := to_unsigned((8 - 5)*2,8);

  signal cache_enabled : boolean := true;

  signal hr_d_pending : std_logic := '0';
  signal hr_flags_pending : std_logic := '0';
  signal hr_d_newval : unsigned(7 downto 0);
  signal hr_flags_newval : unsigned(7 downto 0);
  signal hr_rwds_high_seen : std_logic := '0';

  signal hr_d_last : unsigned(7 downto 0);
  signal skip_data_phase : std_logic := '0';

  signal random_bits : unsigned(7 downto 0) := x"00";

  signal odd_byte_fix_flags : unsigned(7 downto 0) := "00011111";

  signal write_blocked : std_logic := '0';

  signal background_write : std_logic := '0';
  signal background_write_source : std_logic := '0';
  signal background_write_valids : std_logic_vector(0 to 7) := x"00";
  signal background_write_data : cache_row_t := (others => (others => '0'));
  signal background_write_count : integer range 0 to 15 := 0;

  -- If we get too many writes in short succession, we may need to queue up one
  -- of the writes, while waiting for slow_devices to notice
  signal queued_write : std_logic := '0';
  signal queued_wdata : unsigned(7 downto 0) := x"00";
  signal queued_waddr : unsigned(26 downto 0) := to_unsigned(0,27);

  signal background_writing : std_logic := '0';
  signal hr_rwds_last : std_logic := '0';
  
begin
  process (pixelclock,clock163) is
  begin
    if rising_edge(pixelclock) then
      report "read_request=" & std_logic'image(read_request) & ", busy_internal=" & std_logic'image(busy_internal)
        & ", write_request=" & std_logic'image(write_request);

      -- Pseudo random bits so that we can do randomised cache row replacement
      if random_bits /= to_unsigned(251,8) then
        random_bits <= random_bits + 1;
      else
        random_bits <= x"00";
      end if;
      
      hr_d_pending <= '0';
      hr_flags_pending <= '0';
      
      busy <= busy_internal or write_blocked or queued_write;

      -- Clear write block as soon as either write buffer clears
      if (write_collect0_dispatchable='0' and write_collect0_toolate='0' and write_collect0_flushed='0')
        or (write_collect1_dispatchable='0' and write_collect1_toolate='0' and write_collect1_flushed='0')
      then
        write_blocked <= queued_write;
      else
        write_blocked <= '1';
        busy <= '1';
      end if;

      fake_data_ready_strobe <= '0';

      if read_request = '1' or write_request = '1' then
        request_counter_int <= not request_counter_int;
        request_counter <= request_counter_int;
      end if;
      
      report "cache0: address=$" & to_hstring(cache_row0_address&"000") & ", valids=" & to_string(cache_row0_valids)
        & ", data = "
        & to_hstring(cache_row0_data(0)) & " "
        & to_hstring(cache_row0_data(1)) & " "
        & to_hstring(cache_row0_data(2)) & " "
        & to_hstring(cache_row0_data(3)) & " "
        & to_hstring(cache_row0_data(4)) & " "
        & to_hstring(cache_row0_data(5)) & " "
        & to_hstring(cache_row0_data(6)) & " "
        & to_hstring(cache_row0_data(7)) & " ";
      report "cache1: address=$" & to_hstring(cache_row1_address&"000") & ", valids=" & to_string(cache_row1_valids)
        & ", data = "
        & to_hstring(cache_row1_data(0)) & " "
        & to_hstring(cache_row1_data(1)) & " "
        & to_hstring(cache_row1_data(2)) & " "
        & to_hstring(cache_row1_data(3)) & " "
        & to_hstring(cache_row1_data(4)) & " "
        & to_hstring(cache_row1_data(5)) & " "
        & to_hstring(cache_row1_data(6)) & " "
        & to_hstring(cache_row1_data(7)) & " ";
      report "write0: $" & to_hstring(write_collect0_address&"000") & ", v=" & to_string(write_collect0_valids)
        & ", d=" & std_logic'image(write_collect0_dispatchable)
        & ", late=" & std_logic'image(write_collect0_toolate)
        & ", fl=" & std_logic'image(write_collect0_flushed)
        & ", data = "
        & to_hstring(write_collect0_data(0)) & " "
        & to_hstring(write_collect0_data(1)) & " "
        & to_hstring(write_collect0_data(2)) & " "
        & to_hstring(write_collect0_data(3)) & " "
        & to_hstring(write_collect0_data(4)) & " "
        & to_hstring(write_collect0_data(5)) & " "
        & to_hstring(write_collect0_data(6)) & " "
        & to_hstring(write_collect0_data(7)) & " ";
      report "write1: $" & to_hstring(write_collect1_address&"000") & ", v=" & to_string(write_collect1_valids)
        & ", d=" & std_logic'image(write_collect1_dispatchable)
        & ", late=" & std_logic'image(write_collect1_toolate)
        & ", fl=" & std_logic'image(write_collect1_flushed)
        & ", data = "
        & to_hstring(write_collect1_data(0)) & " "
        & to_hstring(write_collect1_data(1)) & " "
        & to_hstring(write_collect1_data(2)) & " "
        & to_hstring(write_collect1_data(3)) & " "
        & to_hstring(write_collect1_data(4)) & " "
        & to_hstring(write_collect1_data(5)) & " "
        & to_hstring(write_collect1_data(6)) & " "
        & to_hstring(write_collect1_data(7)) & " ";


      if write_collect0_dispatchable = '1' and write_collect0_toolate <= '1' and write_collect0_flushed = '1' then
        write_collect0_dispatchable <= '0';
      end if;
      if write_collect1_dispatchable = '1' and write_collect1_toolate <= '1' and write_collect1_flushed = '1' then
        write_collect1_dispatchable <= '0';
      end if;
              

      
      if read_request='1' and busy_internal='0' then
        report "Making read request";
        -- Begin read request
        -- Latch address
        ram_address <= address;
        ram_reading <= '1';

        -- Check for cache read
        -- We check the write buffers first, as any contents that they have
        -- must take priority over everything else
        if cache_enabled and (address(26 downto 3 ) = write_collect0_address and write_collect0_valids(to_integer(address(2 downto 0))) = '1') then
          -- Write cache read-back
          fake_data_ready_strobe <= '1';
          fake_rdata <= write_collect0_data(to_integer(address(2 downto 0)));
          report "DISPATCH: Returning data $"& to_hstring(write_collect0_data(to_integer(address(2 downto 0))))&" from write collect0";
        elsif cache_enabled and (address(26 downto 3 ) = write_collect1_address and write_collect1_valids(to_integer(address(2 downto 0))) = '1') then
          -- Write cache read-back
          fake_data_ready_strobe <= '1';
          fake_rdata <= write_collect1_data(to_integer(address(2 downto 0)));
          report "DISPATCH: Returning data $"& to_hstring(write_collect1_data(to_integer(address(2 downto 0))))&" from write collect1";
        elsif cache_enabled and (address(26 downto 3 ) = cache_row0_address and cache_row0_valids(to_integer(address(2 downto 0))) = '1') then
          -- Cache read
          fake_data_ready_strobe <= '1';
          fake_rdata <= cache_row0_data(to_integer(address(2 downto 0)));
          report "DISPATCH: Returning data $"& to_hstring(cache_row0_data(to_integer(address(2 downto 0))))&" from cache row0";
        elsif cache_enabled and (address(26 downto 3 ) = cache_row1_address and cache_row1_valids(to_integer(address(2 downto 0))) = '1') then
          -- Cache read
          fake_data_ready_strobe <= '1';
          fake_rdata <= cache_row1_data(to_integer(address(2 downto 0)));
          report "DISPATCH: Returning data $"& to_hstring(cache_row1_data(to_integer(address(2 downto 0))))&" from cache row1";
        elsif address(23 downto 4) = x"FFFFF" and address(25 downto 24) = "11" then
        -- Allow reading from dummy debug bitbash registers at $BFFFFFx
          case address(3 downto 0) is
            when x"0" =>
              fake_rdata <= unsigned(cache_row1_valids);
--              fake_rdata <= (others => debug_mode);
            when x"1" =>
              fake_rdata <= hr_d;
            when x"2" =>
              fake_rdata(0) <= hr_rwds;
              fake_rdata(1) <= hr_reset_int;
              fake_rdata(2) <= hr_rwds_ddr;
              fake_rdata(3) <= hr_clk_p_int;
              fake_rdata(4) <= hr_cs0_int;
              fake_rdata(5) <= hr_cs1_int;
              fake_rdata(6) <= hr_ddr;
              if cache_enabled then
                fake_rdata(7) <= '1';
              else
                fake_rdata(7) <= '0';
              end if;
            when x"3" =>
              fake_rdata <= write_latency;
            when x"4" =>
              fake_rdata <= extra_write_latency;
            when x"5" =>
              fake_rdata <= odd_byte_fix_flags;
            when x"6" =>
              fake_rdata <= rwr_delay;
            when x"7" =>
              fake_rdata <= unsigned(cache_row0_valids);
            when x"8" =>
              fake_rdata <= conf_buf0;
            when x"9" =>
              fake_rdata <= conf_buf1;

            when x"a" =>
              fake_rdata <= cache_row0_address(7 downto 0);
            when x"b" =>
              fake_rdata <= cache_row0_address(15 downto 8);
            when x"c" =>
              fake_rdata <= cache_row0_address(23 downto 16);

            when x"d" =>
              fake_rdata <= cache_row1_address(7 downto 0);
            when x"e" =>
              fake_rdata <= cache_row1_address(15 downto 8);
            when x"f" =>
              fake_rdata <= cache_row1_address(23 downto 16);
              
              
            when others =>
              -- This seems to be what gets returned all the time
              fake_rdata <= x"42";
          end case;
          fake_data_ready_strobe <= '1';
          report "asserting data_ready_strobe for fake read";
        else
          report "request_toggle flipped";

          ram_reading <= '1';
          request_toggle <= not request_toggle;          
        end if;
      elsif queued_write='1' and write_collect0_dispatchable='0' and write_collect0_flushed='0'
        and write_collect0_toolate='0' then

        report "DISPATCH: Executing queued write to $" & to_hstring(queued_waddr);
        
        -- Push it out as a normal batched write, that can collect others if they
        -- come soon enough.
      
        write_collect0_valids <= (others => '0');
        write_collect0_valids(to_integer(queued_waddr(2 downto 0))) <= '1';
        write_collect0_data(to_integer(queued_waddr(2 downto 0))) <= queued_wdata;
        write_collect0_address <= queued_waddr(26 downto 3);
        write_collect0_dispatchable <= '1';

        queued_write <= '0';
        
      elsif write_request='1' and busy_internal='0' then
        report "Making write request: addr $" & to_hstring(address) & " <= " & to_hstring(wdata);
        -- Begin write request
        -- Latch address and data

        ram_address <= address;
        ram_wdata <= wdata;
        ram_reading <= '0';
        
        if address(23 downto 4) = x"FFFFF" and address(25 downto 24) = "11" then
          case address(3 downto 0) is
            when x"0" =>
              if wdata = x"de" then
                debug_mode <= '1';
              elsif wdata = x"1d" then
                debug_mode <= '0';
              end if;
            when x"1" =>
              hr_d_pending <= '1';
              hr_d_newval <= wdata;
--              if hr_ddr='1' then
--                hr_d <= wdata;
--              else
--                hr_d <= (others => 'Z');
--              end if;
            when x"2" =>
              hr_flags_pending <= '1';
              hr_flags_newval <= wdata;
              if wdata(7)='1' then
                cache_enabled <= true;
              else
                cache_enabled <= false;
              end if;
--              hr_rwds_int <= wdata(0);
--              hr_reset_int <= wdata(1);
--              hr_clk_n_int <= wdata(2);
--              hr_clk_p_int <= wdata(3);
--              hr_cs0_int <= wdata(4);
--              hr_cs1_int <= wdata(5);
--
--              hr_reset <= wdata(1);
--              hr_clk_n <= wdata(2);
--              hr_clk_p <= wdata(3);
--              hr_cs0 <= wdata(4);
--              hr_cs1 <= wdata(5);
--
--              hr_ddr <= wdata(6);
--              if wdata(6)='0' then
--                hr_d <= (others => '0');
--              end if;
            when x"3" =>
              write_latency <= wdata;
            when x"4" =>
              extra_write_latency <= wdata;
            when x"5" =>
              odd_byte_fix_flags <= wdata;
            when x"6" =>
              rwr_delay <= wdata;
            when x"8" =>
              conf_buf0_in <= wdata;
              conf_buf0_set <= not conf_buf0_set;
            when x"9" =>
              conf_buf1_in <= wdata;              
              conf_buf1_set <= not conf_buf1_set;
            when others =>
              null;
          end case;
          fake_data_ready_strobe <= '1';
        else
          if cache_enabled = false then
            -- Do normal  write request
          report "request_toggle flipped";
            request_toggle <= not request_toggle;
          else
            -- Collect writes together for dispatch

            -- Can we add the write to an existing collected write?
            if write_collect0_toolate = '0' and write_collect0_address = address(26 downto 3)
              and write_collect0_dispatchable = '1' and write_collect0_toolate='0' then
              write_collect0_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect0_data(to_integer(address(2 downto 0))) <= wdata;
            elsif write_collect1_toolate = '0' and write_collect1_address = address(26 downto 3)
              and write_collect1_dispatchable = '1' and write_collect1_toolate='0' then
              write_collect1_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect1_data(to_integer(address(2 downto 0))) <= wdata;
            elsif write_collect0_dispatchable = '0' and write_collect0_toolate='0' then
              write_collect0_valids <= (others => '0');
              write_collect0_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect0_data(to_integer(address(2 downto 0))) <= wdata;
              write_collect0_address <= address(26 downto 3);
              write_collect0_dispatchable <= '1';
              -- Block further writes if we already have one busy write buffer
              write_blocked <= '1';
            elsif write_collect1_dispatchable = '0' and write_collect1_toolate='0' then
              write_collect1_valids <= (others => '0');
              write_collect1_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect1_data(to_integer(address(2 downto 0))) <= wdata;
              write_collect1_address <= address(26 downto 3);
              write_collect1_dispatchable <= '1';
              -- Block further writes if we already have one busy write buffer
              write_blocked <= '1';
            else
              -- No write collection point that we can use, so just block until
              -- one becomes available
              report "DISPATCH: Write blocked due to busy write buffers: " &
                " addr $" & to_hstring(address) & " <= " & to_hstring(wdata);
              queued_waddr <= address;
              queued_wdata <= wdata;
              queued_write <= '1';
            end if;
          end if;
        end if;        
      else
        -- Nothing new to do
        if data_ready_toggle /= last_data_ready_toggle then
          last_data_ready_toggle <= data_ready_toggle;
          fake_data_ready_strobe <= '1';
        end if;
      end if;

    end if;
    if rising_edge(clock163) then

      cycle_count <= cycle_count + 1;

      -- Bitbashing interface to write values
      if hr_d_pending='1' then
        if hr_ddr='1' then
          hr_d <= hr_d_newval;
        end if;
      end if;
      if hr_flags_pending='1' then
        hr_rwds_int <= hr_flags_newval(0);
        hr_reset_int <= hr_flags_newval(1);
        hr_clk_n_int <= not hr_flags_newval(3);
        hr_clk_p_int <= hr_flags_newval(3);
        hr_cs0_int <= hr_flags_newval(4);
        hr_cs1_int <= hr_flags_newval(5);
        
        hr_reset <= hr_flags_newval(1);
        hr_clk_n <= not hr_flags_newval(3);
        hr_clk_p <= hr_flags_newval(3);
        hr_cs0 <= hr_flags_newval(4);
        hr_cs1 <= hr_flags_newval(5);
        
        hr_rwds_ddr <= hr_flags_newval(2);
        if hr_flags_newval(2)='0' then
          hr_rwds <= 'Z';
        end if;
        
        hr_ddr <= hr_flags_newval(6);
        if hr_flags_newval(6)='0' then
          hr_d <= (others => 'Z');
        end if;
      end if;        
      
      if data_ready_strobe_hold = '0' then      
        data_ready_strobe <= fake_data_ready_strobe;
        if fake_data_ready_strobe='1' then
          report "holding data_ready_strobe via fake data = $" & to_hstring(fake_rdata);
          rdata <= fake_rdata;
        end if;
      else
        report "holding data_ready_strobe for an extra cycle";
        data_ready_strobe <= '1';
      end if;
      data_ready_strobe_hold <= '0';
      
      -- HyperRAM state machine
      report "State = " & state_t'image(state) & " @ Cycle " & integer'image(cycle_count);

      if conf_buf0_set /= last_conf_buf0_set then
        last_conf_buf0_set <= conf_buf0_set;
        conf_buf0 <= conf_buf0_in;
      end if;
      if conf_buf1_set /= last_conf_buf1_set then
        last_conf_buf1_set <= conf_buf1_set;
        conf_buf1 <= conf_buf1_in;
      end if;
      
      if (state /= Idle) and ( start_delay_counter /= 0) then
        start_delay_counter <= start_delay_counter - 1;
      else
        start_delay_counter <= 0;
        
        case state is
          when Debug =>
            if debug_mode='0' then
              rwr_counter <= rwr_delay;
              state <= Idle;
            end if;

            if hr_rwds_ddr='1' then
              hr_rwds <= hr_rwds_int;
            else
              hr_rwds <= 'Z';
            end if;
            hr_reset <= hr_reset_int;

          when Idle2 =>
            report "Releasing hyperram CS lines";
            hr_cs0 <= '1';
            hr_cs1 <= '1';

            -- Clock must be low when idle, so that it is in correct phase
            -- when CS0 is pulled low to trigger a transaction
            hr_clk_p <= '0';
            hr_clock <= '0';
            
            -- Put recogniseable patter on data lines for debugging
            report "Presenting hr_d with $A5";
            hr_d_last <= x"A5";
            hr_d <= x"A5";

            rwr_counter <= rwr_delay;
            state <= Idle;
            
          when Idle =>
            -- Invalidate cache if disabled
            if cache_enabled = false then
              cache_row0_valids <= (others => '0');
              cache_row1_valids <= (others => '0');
            end if;

            -- Clear write buffer flags when they are empty
            if write_collect0_dispatchable = '0' then
              write_collect0_toolate <= '0';
              write_collect0_flushed <= '0';
            end if;
            if write_collect1_dispatchable = '0' then
              write_collect1_toolate <= '0';
              write_collect1_flushed <= '0';
            end if;
            
            -- Mark us ready for a new job, or pick up a new job
            next_is_data <= '1';
            if debug_mode='1' then
              state <= Debug;
            end if;
            if rwr_counter /= to_unsigned(0,8) then
              rwr_counter <= rwr_counter - 1;
            end if;
            if request_toggle /= last_request_toggle and rwr_counter = to_unsigned(0,8) then
              last_request_toggle <= request_toggle;
              ram_reading_held <= ram_reading;
              if ram_reading = '1' then
                state <= ReadSetup;
              else
                report "Setting state to WriteSetup. random_bits=" & to_hstring(random_bits);
                state <= WriteSetup;

                -- Update short-circuit cache line
                -- (We don't change validity, since we don't know if it is
                -- valid or not).
                if ram_address(26 downto 3) = current_cache_line_address(26 downto 3) then
                  current_cache_line(to_integer(ram_address(2 downto 0))) <= ram_wdata;
                end if;

                -- Update cache
                if cache_row0_address = ram_address(26 downto 3) then
                  cache_row0_valids(to_integer(ram_address(2 downto 0))) <= '1';
                  cache_row0_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                elsif cache_row1_address = ram_address(26 downto 3) then
                  cache_row1_valids(to_integer(ram_address(2 downto 0))) <= '1';
                  cache_row1_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                else
                  if random_bits(1)='0' then
                    cache_row0_valids <= (others => '0');
                    cache_row0_address <= ram_address(26 downto 3);
                    cache_row0_valids(to_integer(ram_address(2 downto 0))) <= '1';
                    cache_row0_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                  else
                    cache_row1_valids <= (others => '0');
                    cache_row1_address <= ram_address(26 downto 3);
                    cache_row1_valids(to_integer(ram_address(2 downto 0))) <= '1';
                    cache_row1_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                  end if;
                end if;
                
              end if;
              report "Accepting job";
              busy_internal <= '1';
            elsif write_collect0_dispatchable = '1' then
              -- Do background write.
              busy_internal <= '0';

              report "DISPATCH: Writing out collect0 @ $" & to_hstring(write_collect0_address&"000");
              
              -- Mark the write buffer as being processed.              
              write_collect0_flushed <= '0';
              -- And that it is not (yet) too late to add extra bytes to the write.
              write_collect0_toolate <= '0';

              background_write <= '1';
              background_write_source <= '0'; -- collect 0
              
              -- Prepare command vector
              hr_command(47) <= '0'; -- WRITE
              hr_command(46) <= write_collect0_address(24); -- Memory, not register space
              hr_command(45) <= '1'; -- linear
              hr_command(44 downto 35) <= (others => '0'); -- unused upper address bits
              hr_command(15 downto 3) <= (others => '0'); -- reserved bits
              hr_command(34 downto 16) <= write_collect0_address(22 downto 4);
              hr_command(2) <= write_collect0_address(3);
              hr_command(1 downto 0) <= "00";
              hr_reset <= '1'; -- active low reset

              ram_reading_held <= '0';

              -- This is the delay before we assert CS
              countdown <= 0;
            
              state <= HyperRAMCSStrobe;
              
            elsif write_collect1_dispatchable = '1' then
              busy_internal <= '0';              

              report "DISPATCH: Writing out collect1 @ $" & to_hstring(write_collect1_address&"000");
              
              -- Mark the write buffer as being processed.              
              write_collect1_flushed <= '0';
              -- And that it is not (yet) too late to add extra bytes to the write.
              write_collect1_toolate <= '0';

              background_write <= '1';
              background_write_source <= '1'; -- collect 0
              
              -- Prepare command vector
              hr_command(47) <= '0'; -- WRITE
              hr_command(46) <= write_collect1_address(24); -- Memory, not register space
              hr_command(45) <= '1'; -- linear
              hr_command(44 downto 35) <= (others => '0'); -- unused upper address bits
              hr_command(15 downto 3) <= (others => '0'); -- reserved bits
              hr_command(34 downto 16) <= write_collect1_address(22 downto 4);
              hr_command(2) <= write_collect1_address(3);
              hr_command(1 downto 0) <= "00";

              ram_reading_held <= '0';
              
              hr_reset <= '1'; -- active low reset

              -- This is the delay before we assert CS
              countdown <= 0;
            
              state <= HyperRAMCSStrobe;

            else
              report "Clearing busy_internal";
              busy_internal <= '0';
            end IF;
            -- Release CS line between transactions
            report "Releasing hyperram CS lines";
            hr_cs0 <= '1';
            hr_cs1 <= '1';

            -- Clock must be low when idle, so that it is in correct phase
            -- when CS0 is pulled low to trigger a transaction
            hr_clk_p <= '0';
            hr_clock <= '0';
            
            report "Tristating hr_d";
            hr_d_last <= (others => '1');
            hr_d <= (others => 'Z');
          when ReadSetup =>
            report "Setting up to read $" & to_hstring(ram_address) & " ( address = $" & to_hstring(address) & ")";
            -- Prepare command vector
            hr_command(47) <= '1'; -- READ
            -- Map actual RAM to bottom 32MB of 64MB space (repeated 4x)
            -- and registers to upper 32MB
--            hr_command(46) <= '1'; -- Memory address space (1) / Register
            hr_command(46) <= ram_address(24); -- Memory address space (1) / Register
                                               -- address space select (0) ?
            hr_command(45) <= '1'; -- Linear access (not wrapped)
            hr_command(44 downto 37) <= (others => '0'); -- unused upper address bits
            hr_command(34 downto 16) <= ram_address(22 downto 4);
            hr_command(15 downto 3) <= (others => '0'); -- reserved bits
            if ram_address(24) = '0' then
              -- Always read on 8 byte boundaries, and read a full cache line
              hr_command(2) <= ram_address(3);
              hr_command(1 downto 0) <= "00";
            else
              -- Except that register reads are weird: They read the same 2 bytes
              -- over and over again, so we have to make it set bit 0 of the CA
              -- for the "odd" registers"
              hr_command(2 downto 1) <= "00";
              hr_command(0) <= ram_address(3);
            end if;

            hr_reset <= '1'; -- active low reset
            countdown <= 0;

            state <= HyperRAMCSStrobe;
            
          when WriteSetup =>

            report "Preparing hr_command etc";
            
            -- Prepare command vector
            -- As HyperRAM addresses on 16bit boundaries, we shift the address
            -- down one bit.
            hr_command(47) <= '0'; -- WRITE
            hr_command(46) <= ram_address(24); -- Memory, not register space
            hr_command(45) <= '1'; -- linear
            
            hr_command(44 downto 35) <= (others => '0'); -- unused upper address bits
            hr_command(15 downto 3) <= (others => '0'); -- reserved bits
            
            hr_command(34 downto 16) <= ram_address(22 downto 4);
            hr_command(2 downto 0) <= ram_address(3 downto 1);

            hr_reset <= '1'; -- active low reset

            -- This is the delay before we assert CS
            countdown <= 0;
            
            state <= HyperRAMCSStrobe;

          when HyperRAMCSStrobe =>

            state <= HyperRAMOutputCommand;
            if ram_address(24)='1' and ram_reading_held='0' then
              -- 48 bits of CA followed by 16 bit register value
              -- (we shift the buffered config register values out automatically)
              countdown <= 8;
            else
              countdown <= 6; -- 48 bits = 6 x 8 bits
            end if;

            report "Presenting hr_command byte 0 on hr_d = $" & to_hstring(hr_command(47 downto 40))
              & " (irrespective of skip setting)";
            hr_d_last <= hr_command(47 downto 40);
            hr_d <= hr_command(47 downto 40);

            -- We can always skip the first data phase, because we have just
            -- presented the byte here.
            skip_data_phase <= '1';
            
            next_is_data <= '0';
            hr_clk_n <= '1'; 
            hr_clk_p <= '0';
            hr_clock <= '0';
            
          when HyperRAMOutputCommand =>
            report "Writing command : $" & to_hstring(hr_command);

            report "Presenting hr_command byte on hr_d = $" & to_hstring(hr_command(47 downto 40))
              & ", clock = " & std_logic'image(hr_clock)
              & ", next_is_data = " & std_logic'image(next_is_data)
              & ", countdown = " & integer'image(countdown)
              & ", skip_data_phase = " & std_logic'image(skip_data_phase)
              & ", skip compare: $"
              & to_hstring(hr_command(47 downto 40))
              & " vs $" & to_hstring(hr_d_last);

-- Call HyperRAM to attention
            hr_cs0 <= ram_address(23);
            hr_cs1 <= not ram_address(23);
            
            hr_rwds <= 'Z';
            hr_rwds_last <= '1';

            -- Latch extra latency status
            if countdown = 3 and (ram_address(24)='0' or ram_reading_held='1') then
              extra_latency <= hr_rwds;
              if hr_rwds='1' then
                report "Applying extra latency";
              end if;                    
            end if;

            skip_data_phase <= '0';
            
            if skip_data_phase = '0' then
              next_is_data <= not next_is_data;
            elsif next_is_data='0' then
              -- If the bytes we need to present are identical,
              -- we can skip the data setting phase of the clock, which
              -- speeds up dispatch of the command a little.

              next_is_data <= '0';

              hr_command(47 downto 8) <= hr_command(39 downto 0);

              -- Also shift out config register values, if required
              if ram_address(24)='1' and ram_reading_held='0' then
                report "shifting in conf value $" & to_hstring(conf_buf0);
                hr_command(7 downto 0) <= conf_buf0;
                conf_buf0 <= conf_buf1;
                conf_buf1 <= conf_buf0;
              else
                hr_command(7 downto 0) <= x"00";
              end if;

              countdown <= countdown - 1;

            end if;
            if next_is_data = '0' and countdown /= 0 then
              -- Toggle clock while data steady
              hr_clk_n <= not hr_clock;
              hr_clk_p <= hr_clock;
              hr_clock <= not hr_clock;

              if hr_d_last = hr_command(47 downto 39) then
                report "Ticking clock and skip_data_phase <= 1 because hr_d_last=$"
                  & to_hstring(hr_d_last) & ", hr_cmd=$" & to_hstring(hr_command);
                
                skip_data_phase <= '1';
                hr_d_last <= hr_command(47 downto 40);
                hr_d <= hr_command(47 downto 40);

                hr_command(47 downto 8) <= hr_command(39 downto 0);
                countdown <= countdown - 1;
                
                next_is_data <= '0';
              else
                report "Ticking clock and skip_data_phase <= 0 because hr_d_last=$"
                  & to_hstring(hr_d_last) & ", hr_cmd=$" & to_hstring(hr_command);
                skip_data_phase <= '0';
              end if;              
            else
              -- Toggle data while clock steady
              report "next_is_data='1' or countdown=0";

              if countdown /= 0 then
                hr_d_last <= hr_command(47 downto 40);
                hr_d <= hr_command(47 downto 40);
                hr_command(47 downto 8) <= hr_command(39 downto 0);
              else
                hr_clk_p <= '0';
                hr_clk_n <= '1';
                hr_clock <= '0';
              end if;

              -- Also shift out config register values, if required
              if ram_address(24)='1' and ram_reading_held='0' then
                report "shifting in conf value $" & to_hstring(conf_buf0);
                hr_command(7 downto 0) <= conf_buf0;
                conf_buf0 <= conf_buf1;
                conf_buf1 <= conf_buf0;
              else
                hr_command(7 downto 0) <= x"00";
              end if;
              
              report "Writing command byte $" & to_hstring(hr_command(47 downto 40));

              if countdown /= 0 then
                countdown <= countdown - 1;
              else
                -- Finished shifting out
                if ram_reading_held = '1' then
                  -- Reading: We can just wait until hr_rwds has gone low, and then
                  -- goes high again to indicate the first data byte
                  countdown <= 99;
                  hr_rwds_high_seen <= '0';
                  next_is_data <= '0';
                  state <= HyperRAMReadWait;
                elsif ram_address(24)='1' and ram_reading_held='0' then
                  -- Config register write.
                  -- These are a bit weird, as they have no latency, and all 16
                  -- bits have to get written at once.  So we will have 2 buffer
                  -- registers that get setup, and then ANY write to the register
                  -- area will write those values, which we have done by shifting
                  -- those through and sending 48+16 bits instead of the usual
                  -- 48.
                  state <= HyperRAMFinishWriting1;
                else
                  -- Writing to memory, so count down the correct number of cycles;
                  -- Initial latency is reduced by 2 cycles for the last bytes
                  -- of the access command, and by 1 more to cover state
                  -- machine latency                  
--                  countdown <= 8 - 2 - 1;
                  countdown <= to_integer(write_latency);

                  -- We are not just about ready to start writing, so mark the
                  -- write buffer as too late to be added to, because we will
                  -- snap-shot it in a moment.
                  if background_write = '1' then
                    report "WRITE: Asserting toolate signal";
                    -- 4 words + 3 extra counts?
                    background_write_count <= 7;
                    if background_write_source = '0' then
                      write_collect0_toolate <= '1';
                      write_collect0_flushed <= '0';
                    else
                      write_collect1_toolate <= '1';
                      write_collect1_flushed <= '0';
                    end if;
                  end if;

                  background_writing <= '0';
                  state <= HyperRAMLatencyWait;
                end if;
              end if;
            end if;
            byte_phase <= to_unsigned(0,4);
            write_byte_phase <= '0';
            byte_written <= '0';
          when HyperRAMLatencyWait =>
            report "WRITE: LatencyWait state, bg_wr=" & std_logic'image(background_write)
              & ", count=" & integer'image(background_write_count)
              & ", countdown=" & integer'image(countdown)
              & ", next_is_data=" & std_logic'image(next_is_data)
              & ", skip_data_phase=" &std_logic'image(skip_data_phase);

            -- Now snap-shot the write buffer data, and mark the slot as flushed
            if background_write = '1' then
              if background_write_source = '0' and write_collect0_toolate='1' and write_collect0_flushed = '0' then
                write_collect0_flushed <= '1';
                report "WRITE: background_write_data copied from write_collect0. Valids = " & to_string(write_collect0_valids);
                background_write_data <= write_collect0_data;
                background_write_valids <= write_collect0_valids;
              elsif background_write_source = '1' and write_collect1_toolate='1' and write_collect1_flushed = '0' then
                write_collect1_flushed <= '1';
                report "WRITE: background_write_data copied from write_collect1";
                background_write_data <= write_collect1_data;
                background_write_valids <= write_collect1_valids;
              end if;
            end if;

            -- Do countdown until we are able to write
            if countdown = 1 and extra_latency = '0' then
              background_writing <= '1';
              -- And schedule first piece of data immediately after the count
              -- down is done.
              if background_writing = '0' then
                report "Setting next_is_data <= 0 at end of count down";
                next_is_data <= '0';
              end if;
            end if;

            -- Count down and tick clock while we wait for the latency to
            -- run out. Clock ticks fast.
            if background_writing='0' then
              if hr_clock='0' then
                report "latency countdown = " & integer'image(countdown);
                if countdown /= 0 then
                  countdown <= countdown - 1;
                else
                  if extra_latency='1' then
                    report "Waiting 6 more cycles for extra latency";
                    -- If we were asked to wait for extra latency,
                    -- then wait another 6 cycles.
                    extra_latency <= '0';
                    countdown <= to_integer(extra_write_latency);
                  end if;
                end if;
              end if;

              hr_d <= background_write_data(0);
              hr_d_last <= background_write_data(0);
              
              -- Toggle clock while counting down
              report  "Tick clock (count down)";
              hr_clock <= not hr_clock;
              hr_clk_p <= not hr_clock;
              hr_clk_n <= hr_clock;

            end if;

            -- Begin write mask preamble
            if ram_reading_held = '0' and countdown = 2 and extra_latency='0' and hr_clock='0' then
              hr_rwds <= '0';
              hr_rwds_last <= '0';
              -- And hold clock for 1/2 a tick
              report "DONT Tick clock (1/2 cycle hold for write preamble)";
              hr_clock <= hr_clock;
              hr_clk_p <= hr_clock;
              hr_clk_n <= not hr_clock;
            end if;              
                        
            if background_write='1' and background_writing = '1' then
              -- Background writes, we try to put the next byte out early

              if next_is_data='1' then
                report "WRITE: Writing background byte $" & to_hstring(background_write_data(0))
                  & ", valids= " & to_string(background_write_valids)
                & ", background words left = " & integer'image(background_write_count);

                hr_rwds <= not background_write_valids(0);
                hr_rwds_last <= not background_write_valids(0);
                
                if ((hr_d_last = background_write_data(0)) or (background_write_valids(0)='0'))
                  and (hr_rwds_last = not background_write_valids(0)) then
                  -- Data is already there, so tick immediately
                  
                  report "Tick clock (background writing, next_is_data=1, data already available)";
                  report "hr_rwds_last = " & std_logic'image(hr_rwds_last)
                    & ", valids=" & to_string(background_write_valids(0 to 7));
                  -- Toggle clock while data steady
                  hr_clk_n <= hr_clock;
                  hr_clk_p <= not hr_clock;
                  hr_clock <= not hr_clock;                    
                  next_is_data <= '1';

--                  hr_d <= x"aa"; -- AA for already available
                  
                else
                  -- Data not already correct, so set the data before ticking
                  hr_d_last <= background_write_data(0);
                  hr_d <= background_write_data(0);
                  next_is_data <= '0';

--                  hr_d <= x"48";  -- H for hold
                end if;

                if background_write_count /= 0 then
                  background_write_count <= background_write_count - 1;
                else
                  byte_written <= '1';
                end if;

                if background_write_count < 8 then
                  report "WRITE: Shifting data to write. new next byte will be $"
                    & to_hstring(background_write_data(1));
                  background_write_data(0) <= background_write_data(1);
                  background_write_data(1) <= background_write_data(2);
                  background_write_data(2) <= background_write_data(3);
                  background_write_data(3) <= background_write_data(4);
                  background_write_data(4) <= background_write_data(5);
                  background_write_data(5) <= background_write_data(6);
                  background_write_data(6) <= background_write_data(7);
                  background_write_data(7) <= x"00";
                
                  background_write_valids(0 to 6) <= background_write_valids(1 to 7);
                  background_write_valids(7) <= '0';
                end if;
                
              end if;

              if next_is_data = '0' and background_writing='1' then

                report "Tick clock (background writing, next_is_data=0)";
                next_is_data <= '1';
                
                -- Toggle clock while data steady
                hr_clk_n <= hr_clock;
                hr_clk_p <= not hr_clock;
                hr_clock <= not hr_clock;                                        
                
              end if;
                
            end if;
            
            if byte_written = '1' then
              report "Advancing to HyperRAMFinishWriting";
              state <= HyperRAMFinishWriting1;
            end if;
          when Hyperramfinishwriting1 =>
            -- Mask writing from here on.
            hr_cs0 <= '1';
            hr_cs1 <= '1';
            hr_rwds <= '1';
            hr_d_last <= x"FA"; -- "after" data byte
            hr_d <= x"FA"; -- "after" data byte
            state <= Hyperramfinishwriting;
          when HyperRAMFinishWriting =>
            -- Last cycle was data, so next cycle is clock.

            -- Indicate no more bytes to write
            hr_rwds <= 'Z';

--            -- Toggle clock
--            hr_clk_n <= not hr_clock;
--            hr_clk_p <= hr_clock;
--            hr_clock <= not hr_clock;

            -- Go back to waiting
            rwr_counter <= rwr_delay;
            state <= Idle;
          when HyperRAMReadWait =>
            hr_rwds <= 'Z';
            report "Presenting tri-state on hr_d";
            hr_d_last <= (others => '1');                       
            hr_d <= (others => 'Z');                       
            if (hr_rwds='1') then
              hr_rwds_high_seen <= '1';
              -- Stop fast-ticking once we see hr_rwds go high
              if hr_rwds_high_seen = '0' then
                skip_data_phase <= '0';
              end if;
              if hr_rwds_high_seen = '0' then
                report "DISPATCH saw hr_rwds go high at start of data stream";
              end if;
            end if;                
            if countdown = 0 then
              -- Timed out waiting for read -- so return anyway, rather
              -- than locking the machine hard forever.
              rdata <= x"DD";
              rdata(0) <= data_ready_toggle;
              rdata(1) <= busy_internal;
              data_ready_strobe <= '1';
              data_ready_strobe_hold <= '1';
              rwr_counter <= rwr_delay;
              state <= Idle;
              next_is_data <= not next_is_data;
            else
              countdown <= countdown - 1;
              if hr_rwds_high_seen='0' and hr_rwds='0' then
                next_is_data <= '0';
              else
                next_is_data <= not next_is_data;
              end if;
            end if;
            -- We don't tick clock on the first cycle that data arrives
            -- (so that we stop fast-ticking the clock and don't miss the first
            -- byte, but at the same time, that we don't have to have the hyperram
            -- clock ticking at 40 instead of 80mhz while waiting for data to arrive).
            if next_is_data = '0' and (hr_rwds_high_seen='1' or hr_rwds='0')  then
              -- Toggle clock while data steady
              hr_clk_n <= not hr_clock;
              hr_clk_p <= hr_clock;
              hr_clock <= not hr_clock;
            else
              next_is_data <= '0';
              last_rwds <= hr_rwds;
              -- HyperRAM drives RWDS basically to follow the clock.
              -- But first valid data is when RWDS goes high, so we have to
              -- wait until we see it go high.
--              report "DISPATCH watching for data: rwds=" & std_logic'image(hr_rwds) & ", clock=" & std_logic'image(hr_clock)
--                & ", rwds seen=" & std_logic'image(hr_rwds_high_seen);

              if (hr_rwds_high_seen='1') or (hr_rwds='1') then
                -- Data has arrived: Latch either odd or even byte
                -- as required.
--                report "DISPATCH Saw read data = $" & to_hstring(hr_d);

                -- Update cache
                if byte_phase < 8 then
                  -- Store the bytes in the cache row
                  if cache_row0_address = ram_address(26 downto 3) then          
                    cache_row0_valids(to_integer(byte_phase)) <= '1';
                    cache_row0_data(to_integer(byte_phase)) <= hr_d;
                  elsif cache_row1_address = ram_address(26 downto 3) then          
                    cache_row1_valids(to_integer(byte_phase)) <= '1';
                    cache_row1_data(to_integer(byte_phase)) <= hr_d;
                  elsif random_bits(1) = '0' then
                    cache_row0_valids <= (others => '0');
                    cache_row0_address <= ram_address(26 downto 3);
                    cache_row0_valids(to_integer(byte_phase)) <= '1';
                    cache_row0_data(to_integer(byte_phase)) <= hr_d;
                  else
                    cache_row1_valids <= (others => '0');
                    cache_row1_address <= ram_address(26 downto 3);
                    cache_row1_valids(to_integer(byte_phase)) <= '1';
                    cache_row1_data(to_integer(byte_phase)) <= hr_d;
                  end if;
                else
                  -- Export the appropriate cache line to slow_devices
                  if cache_row0_address = ram_address(26 downto 3) and cache_enabled then          
                    if cache_row0_valids = x"FF" then
                      current_cache_line <= cache_row0_data;
                      current_cache_line_address(26 downto 3) <= ram_address(26 downto 3);
                      current_cache_line_valid <= '1';
                    end if;
                  elsif cache_row1_address = ram_address(26 downto 3) and cache_enabled then          
                    if cache_row1_valids = x"FF" then
                      current_cache_line <= cache_row1_data;
                      current_cache_line_address(26 downto 3) <= ram_address(26 downto 3);
                      current_cache_line_valid <= '1';
                    end if;
                  end if;
                end if;
                
                -- Quickly return the correct byte
                if to_integer(byte_phase) = (to_integer(ram_address(2 downto 0))+0) then
                  report "DISPATCH: Returning freshly read data = $" & to_hstring(hr_d);
                  rdata <= hr_d;
                  data_ready_strobe <= '1';
                  data_ready_strobe_hold <= '1';
                end if;
                report "byte_phase = " & integer'image(to_integer(byte_phase));
                if byte_phase = 7 then
                  rwr_counter <= rwr_delay;
                  state <= Idle2;
                  hr_cs0 <= '1';
                  hr_cs1 <= '1';
                else
                  byte_phase <= byte_phase + 1;
                end if;
                
              end if;
            end if;
          when others =>
            rwr_counter <= rwr_delay;
            state <= Idle;
        end case;      
      end if;
    end if;
    
  end process;
end gothic;


