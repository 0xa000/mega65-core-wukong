library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use IEEE.numeric_std.ALL;

library unisim;
use unisim.vcomponents.all;

entity clocking_wukongv3 is
   port (
      reset       : in  std_logic;
      locked      : out std_logic;

      -- Clock in ports
      clk_in      : in  std_logic;

      -- Clock out ports
      clock27     : out std_logic;
      clock40_5   : out std_logic;
      clock81     : out std_logic;
      clock162    : out std_logic;
      clock162m   : out std_logic;
      clock270    : out std_logic;
      clock50     : out std_logic;
      clock100    : out std_logic;
      clock200    : out std_logic;

      -- Fine phase-shift control for the SDRAM read capture clock
      -- (clock162m), synchronous to clock162.  Each sdram_ps_en pulse
      -- moves clock162m by 1/56 of the 810MHz VCO period (~22ps);
      -- sdram_ps_incdec selects the direction.
      sdram_ps_en     : in  std_logic := '0';
      sdram_ps_incdec : in  std_logic := '0'
   );
end entity;


architecture RTL of clocking_wukongv3 is

  signal clk_fb_clock54 : std_logic := '0';
  signal clock54        : std_logic := '0';
  signal clk_fb_cpu     : std_logic := '0';
  signal clk_fb_eth     : std_logic := '0';
  signal clk_fb_sdram_ps : std_logic := '0';
  signal clock162_buf   : std_logic := '0';
  
  signal clock27_u     : std_logic;
  signal clock40_5_u   : std_logic;
  signal clock81_u     : std_logic;
  signal clock162_u    : std_logic;
  signal clock162m_u   : std_logic;
  signal clock270_u    : std_logic;
  signal clock50_u     : std_logic;
  signal clock100_u    : std_logic;
  signal clock200_u    : std_logic;

  signal locked_mmce_clock54 : std_logic;
  signal locked_pll_cpu      : std_logic;
  signal locked_pll_eth      : std_logic;

begin

  -- We want a 27 MHz true pixel clock and various multiples from our 50 MHz or
  -- 100 MHz input clock. We can use the MMCME2_ADV improved clock fiddling
  -- factors to easily get this.
  --
  -- 50 MHz x 27 / 25 = 54 MHz
  --
  -- 54 MHz x 15 = 810 MHz (VCO: legal on -1 parts, 800-1600 MHz)
  --     /  3 = 270.0 MHz
  --     / 10 =  81.0 MHz
  --     / 20 =  40.5 MHz
  --     / 30 =  27.0 MHz
  --     /  5 = 162.0 MHz (SDRAM clock pair, phase 0 and -207 degrees)


  MMCME2_BASE_clock54 : MMCME2_BASE
  generic map (
     BANDWIDTH => "OPTIMIZED",  -- Jitter programming (OPTIMIZED, HIGH, LOW)
     CLKFBOUT_MULT_F => 13.5,    -- Multiply value for all CLKOUT (2.000-64.000). VCO 675MHz: legal on -1 parts (600-1200MHz).
     CLKFBOUT_PHASE => 0.0,     -- Phase offset in degrees of CLKFB (-360.000-360.000).
     CLKIN1_PERIOD => 20.0,      -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).
     -- CLKOUT0_DIVIDE - CLKOUT6_DIVIDE: Divide amount for each CLKOUT (1-128)
     CLKOUT1_DIVIDE => 1,
     CLKOUT2_DIVIDE => 1,
     CLKOUT3_DIVIDE => 1,
     CLKOUT4_DIVIDE => 1,
     CLKOUT5_DIVIDE => 1,
     CLKOUT6_DIVIDE => 1,
     CLKOUT0_DIVIDE_F => 12.5,   -- Divide amount for CLKOUT0 (1.000-128.000). 675/12.5 = 54MHz.
     -- CLKOUT0_DUTY_CYCLE - CLKOUT6_DUTY_CYCLE: Duty cycle for each CLKOUT (0.01-0.99).
     CLKOUT0_DUTY_CYCLE => 0.5,
     CLKOUT1_DUTY_CYCLE => 0.5,
     CLKOUT2_DUTY_CYCLE => 0.5,
     CLKOUT3_DUTY_CYCLE => 0.5,
     CLKOUT4_DUTY_CYCLE => 0.5,
     CLKOUT5_DUTY_CYCLE => 0.5,
     CLKOUT6_DUTY_CYCLE => 0.5,
     -- CLKOUT0_PHASE - CLKOUT6_PHASE: Phase offset for each CLKOUT (-360.000-360.000).
     CLKOUT0_PHASE => 0.0,
     CLKOUT1_PHASE => 0.0,
     CLKOUT2_PHASE => 0.0,
     CLKOUT3_PHASE => 0.0,
     CLKOUT4_PHASE => 0.0,
     CLKOUT5_PHASE => 0.0,
     CLKOUT6_PHASE => 0.0,
     CLKOUT4_CASCADE => FALSE,  -- Cascade CLKOUT4 counter with CLKOUT6 (FALSE, TRUE)
     DIVCLK_DIVIDE => 1,        -- Master division value (1-106)
     REF_JITTER1 => 0.0,        -- Reference input jitter in UI (0.000-0.999).
     STARTUP_WAIT => FALSE      -- Delays DONE until MMCM is locked (FALSE, TRUE)
  )
  port map (
     -- Clock Outputs: 1-bit (each) output: User configurable clock outputs
     CLKOUT0 => clock54,     -- 1-bit output: CLKOUT0
     -- Feedback Clocks: 1-bit (each) output: Clock feedback ports
     CLKFBOUT => clk_fb_clock54,   -- 1-bit output: Feedback clock
     CLKFBOUTB => open,      -- 1-bit output: Inverted CLKFBOUT
     -- Status Ports: 1-bit (each) output: MMCM status ports
     LOCKED => locked_mmce_clock54,         -- 1-bit output: LOCK
     -- Clock Inputs: 1-bit (each) input: Clock input
     CLKIN1 => clk_in,       -- 1-bit input: Clock
     -- Control Ports: 1-bit (each) input: MMCM control ports
     PWRDWN => '0',          -- 1-bit input: Power-down
     RST => reset,             -- 1-bit input: Reset
     -- Feedback Clocks: 1-bit (each) input: Clock feedback ports
     CLKFBIN => clk_fb_clock54      -- 1-bit input: Feedback clock
  );

  --PLLE2_BASE_clock54 : PLLE2_BASE
  --generic map (
  --   BANDWIDTH => "OPTIMIZED",  -- OPTIMIZED, HIGH, LOW
  --   CLKFBOUT_MULT => 27,       -- Multiply value for all CLKOUT, (2-64)
  --   CLKFBOUT_PHASE => 0.0,     -- Phase offset in degrees of CLKFB, (-360.000-360.000).
  --   CLKIN1_PERIOD => 20.000,   -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).
  --   -- CLKOUT0_DIVIDE - CLKOUT5_DIVIDE: Divide amount for each CLKOUT (1-128)
  --   CLKOUT0_DIVIDE => 25,
  --   CLKOUT1_DIVIDE => 1,
  --   CLKOUT2_DIVIDE => 1,
  --   CLKOUT3_DIVIDE => 1,
  --   CLKOUT4_DIVIDE => 1,
  --   CLKOUT5_DIVIDE => 1,
  --   -- CLKOUT0_DUTY_CYCLE - CLKOUT5_DUTY_CYCLE: Duty cycle for each CLKOUT (0.001-0.999).
  --   CLKOUT0_DUTY_CYCLE => 0.5,
  --   CLKOUT1_DUTY_CYCLE => 0.5,
  --   CLKOUT2_DUTY_CYCLE => 0.5,
  --   CLKOUT3_DUTY_CYCLE => 0.5,
  --   CLKOUT4_DUTY_CYCLE => 0.5,
  --   CLKOUT5_DUTY_CYCLE => 0.5,
  --   -- CLKOUT0_PHASE - CLKOUT5_PHASE: Phase offset for each CLKOUT (-360.000-360.000).
  --   CLKOUT0_PHASE => 0.0,
  --   CLKOUT1_PHASE => 0.0,
  --   CLKOUT2_PHASE => 0.0,
  --   CLKOUT3_PHASE => 0.0,
  --   CLKOUT4_PHASE => 0.0,
  --   CLKOUT5_PHASE => 0.0,
  --   DIVCLK_DIVIDE => 1,        -- Master division value, (1-56)
  --   REF_JITTER1 => 0.0,        -- Reference input jitter in UI, (0.000-0.999).
  --   STARTUP_WAIT => "FALSE"    -- Delay DONE until PLL Locks, ("TRUE"/"FALSE")
  --)
  --port map (
  --   -- Clock Outputs: 1-bit (each) output: User configurable clock outputs
  --   CLKOUT0 => clock54,   -- 1-bit output: CLKOUT0
  --   -- Feedback Clocks: 1-bit (each) output: Clock feedback ports
  --   CLKFBOUT => clk_fb_clock54, -- 1-bit output: Feedback clock
  --   LOCKED => open,     -- 1-bit output: LOCK
  --   CLKIN1 => clk_in,     -- 1-bit input: Input clock
  --   -- Control Ports: 1-bit (each) input: PLL control ports
  --   PWRDWN => '0',     -- 1-bit input: Power-down
  --   RST => '0',           -- 1-bit input: Reset
  --   -- Feedback Clocks: 1-bit (each) input: Clock feedback ports
  --   CLKFBIN => clk_fb_clock54    -- 1-bit input: Feedback clock
  --);

  PLLE2_BASE_cpu : PLLE2_BASE
  generic map (
     BANDWIDTH => "OPTIMIZED",  -- OPTIMIZED, HIGH, LOW
     CLKFBOUT_MULT => 15,       -- Multiply value for all CLKOUT, (2-64)
     CLKFBOUT_PHASE => 0.0,     -- Phase offset in degrees of CLKFB, (-360.000-360.000).
     CLKIN1_PERIOD => 18.519,   -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).
     -- CLKOUT0_DIVIDE - CLKOUT5_DIVIDE: Divide amount for each CLKOUT (1-128)
     CLKOUT0_DIVIDE => 5,
     CLKOUT1_DIVIDE => 5,
     CLKOUT2_DIVIDE => 3,
     CLKOUT3_DIVIDE => 10,
     CLKOUT4_DIVIDE => 20,
     CLKOUT5_DIVIDE => 30,
     -- CLKOUT0_DUTY_CYCLE - CLKOUT5_DUTY_CYCLE: Duty cycle for each CLKOUT (0.001-0.999).
     CLKOUT0_DUTY_CYCLE => 0.5,
     CLKOUT1_DUTY_CYCLE => 0.5,
     CLKOUT2_DUTY_CYCLE => 0.5,
     CLKOUT3_DUTY_CYCLE => 0.5,
     CLKOUT4_DUTY_CYCLE => 0.5,
     CLKOUT5_DUTY_CYCLE => 0.5,
     -- CLKOUT0_PHASE - CLKOUT5_PHASE: Phase offset for each CLKOUT (-360.000-360.000).
     CLKOUT0_PHASE => 0.0,
     CLKOUT1_PHASE => -207.0,   -- SDRAM read register clock, phase shifted for read timing (as on mega65r4+)
     CLKOUT2_PHASE => 0.0,
     CLKOUT3_PHASE => 0.0,
     CLKOUT4_PHASE => 0.0,
     CLKOUT5_PHASE => 0.0,
     DIVCLK_DIVIDE => 1,        -- Master division value, (1-56)
     REF_JITTER1 => 0.0,        -- Reference input jitter in UI, (0.000-0.999).
     STARTUP_WAIT => "FALSE"    -- Delay DONE until PLL Locks, ("TRUE"/"FALSE")
  )
  port map (
     -- Clock Outputs: 1-bit (each) output: User configurable clock outputs
     CLKOUT0 => clock162_u,    -- 1-bit output: 162 MHz for SDRAM
     CLKOUT1 => open,          -- (SDRAM read clock now comes from MMCME2_sdram_ps below)
     CLKOUT2 => clock270_u,    -- 1-bit output: CLKOUT2
     CLKOUT3 => clock81_u,     -- 1-bit output: CLKOUT3
     CLKOUT4 => clock40_5_u,   -- 1-bit output: CLKOUT4
     CLKOUT5 => clock27_u,     -- 1-bit output: CLKOUT5
     -- Feedback Clocks: 1-bit (each) output: Clock feedback ports
     CLKFBOUT => clk_fb_cpu, -- 1-bit output: Feedback clock
     LOCKED => locked_pll_cpu,     -- 1-bit output: LOCK
     CLKIN1 => clock54,     -- 1-bit input: Input clock
     -- Control Ports: 1-bit (each) input: PLL control ports
     PWRDWN => '0',     -- 1-bit input: Power-down
     RST => reset,           -- 1-bit input: Reset
     -- Feedback Clocks: 1-bit (each) input: Clock feedback ports
     CLKFBIN => clk_fb_cpu    -- 1-bit input: Feedback clock
  );


  PLLE2_BASE_eth : PLLE2_BASE
  generic map (
     BANDWIDTH => "OPTIMIZED",  -- OPTIMIZED, HIGH, LOW
     CLKFBOUT_MULT => 20,       -- Multiply value for all CLKOUT, (2-64)
     CLKFBOUT_PHASE => 0.0,     -- Phase offset in degrees of CLKFB, (-360.000-360.000).
     CLKIN1_PERIOD => 20.000,   -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).
     -- CLKOUT0_DIVIDE - CLKOUT5_DIVIDE: Divide amount for each CLKOUT (1-128)
     CLKOUT0_DIVIDE => 20,
     CLKOUT1_DIVIDE => 10,
     CLKOUT2_DIVIDE => 5,
     CLKOUT3_DIVIDE => 1,
     CLKOUT4_DIVIDE => 1,
     CLKOUT5_DIVIDE => 1,
     -- CLKOUT0_DUTY_CYCLE - CLKOUT5_DUTY_CYCLE: Duty cycle for each CLKOUT (0.001-0.999).
     CLKOUT0_DUTY_CYCLE => 0.5,
     CLKOUT1_DUTY_CYCLE => 0.5,
     CLKOUT2_DUTY_CYCLE => 0.5,
     CLKOUT3_DUTY_CYCLE => 0.5,
     CLKOUT4_DUTY_CYCLE => 0.5,
     CLKOUT5_DUTY_CYCLE => 0.5,
     -- CLKOUT0_PHASE - CLKOUT5_PHASE: Phase offset for each CLKOUT (-360.000-360.000).
     CLKOUT0_PHASE => 0.0,
     CLKOUT1_PHASE => 0.0,
     CLKOUT2_PHASE => 0.0,
     CLKOUT3_PHASE => 0.0,
     CLKOUT4_PHASE => 0.0,
     CLKOUT5_PHASE => 0.0,
     DIVCLK_DIVIDE => 1,        -- Master division value, (1-56)
     REF_JITTER1 => 0.0,        -- Reference input jitter in UI, (0.000-0.999).
     STARTUP_WAIT => "FALSE"    -- Delay DONE until PLL Locks, ("TRUE"/"FALSE")
  )
  port map (
     -- Clock Outputs: 1-bit (each) output: User configurable clock outputs
     CLKOUT0 => clock50_u,   -- 1-bit output: CLKOUT0
     CLKOUT1 => clock100_u,  -- 1-bit output: CLKOUT1
     CLKOUT2 => clock200_u,  -- 1-bit output: CLKOUT2
     -- Feedback Clocks: 1-bit (each) output: Clock feedback ports
     CLKFBOUT => clk_fb_eth, -- 1-bit output: Feedback clock
     LOCKED => locked_pll_eth,     -- 1-bit output: LOCK
     CLKIN1 => clk_in,     -- 1-bit input: Input clock
     -- Control Ports: 1-bit (each) input: PLL control ports
     PWRDWN => '0',     -- 1-bit input: Power-down
     RST => reset,           -- 1-bit input: Reset
     -- Feedback Clocks: 1-bit (each) input: Clock feedback ports
     CLKFBIN => clk_fb_eth    -- 1-bit input: Feedback clock
  );
  
  bufg_clock27     : BUFG port map ( I => clock27_u    , O => clock27     );
  bufg_clock40_5   : BUFG port map ( I => clock40_5_u  , O => clock40_5   );
  bufg_clock81     : BUFG port map ( I => clock81_u    , O => clock81     );
  bufg_clock162    : BUFG port map ( I => clock162_u   , O => clock162_buf );
  clock162 <= clock162_buf;
  bufg_clock162m   : BUFG port map ( I => clock162m_u  , O => clock162m   );

  -- Dedicated MMCM for the SDRAM read capture clock (the PLLE2 that
  -- generates the other CPU-family clocks has no phase-shift feature, and
  -- its static -207 degree setting copied from mega65r4 does not match
  -- this board).  Same clock54 input and x15 VCO (810 MHz, legal on -1),
  -- so clock162m stays frequency-locked to clock162.
  -- The static 51.4 degree phase is the centre of the data eye measured
  -- on hardware (2026-09-09 scan, tests/wukong-bringup/scan-*.log: eye
  -- spans ~200 of 280 fine-PS steps with the inverted forwarded
  -- sdram_clk and read latency 2).  Fine phase shift stays enabled on
  -- top of it, so the capture phase remains runtime tunable via
  -- $C000008; the controller's step counter then reads as a RELATIVE
  -- offset from this calibrated centre (0 = calibrated).  (Note: the
  -- Clocking Wizard refuses this combination, but the MMCME2 primitive
  -- accepts a static phase together with USE_FINE_PS.)
  MMCME2_sdram_ps : MMCME2_ADV
  generic map (
     BANDWIDTH => "OPTIMIZED",
     CLKIN1_PERIOD => 18.519,   -- 54 MHz
     CLKFBOUT_MULT_F => 15.0,   -- VCO 810 MHz
     DIVCLK_DIVIDE => 1,
     CLKOUT0_DIVIDE_F => 5.0,   -- 162 MHz
     CLKOUT0_PHASE => 51.429,
     CLKOUT0_USE_FINE_PS => TRUE
  )
  port map (
     CLKOUT0 => clock162m_u,
     CLKFBOUT => clk_fb_sdram_ps,
     CLKFBIN => clk_fb_sdram_ps,
     CLKIN1 => clock54,
     CLKIN2 => '0',
     CLKINSEL => '1',
     LOCKED => open,
     PWRDWN => '0',
     RST => reset,
     PSCLK => clock162_buf,
     PSEN => sdram_ps_en,
     PSINCDEC => sdram_ps_incdec,
     PSDONE => open,
     DADDR => (others => '0'),
     DCLK => '0',
     DEN => '0',
     DI => (others => '0'),
     DWE => '0',
     DO => open,
     DRDY => open
  );
  bufg_clock270    : BUFG port map ( I => clock270_u   , O => clock270    );
  bufg_clock50     : BUFG port map ( I => clock50_u    , O => clock50     );
  bufg_clock100    : BUFG port map ( I => clock100_u   , O => clock100    );
  bufg_clock200    : BUFG port map ( I => clock200_u   , O => clock200    );

  locked <= locked_mmce_clock54 and locked_pll_cpu and locked_pll_eth;

end rtl;
