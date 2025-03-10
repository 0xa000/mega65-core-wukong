library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use IEEE.numeric_std.ALL;

library unisim;
use unisim.vcomponents.all;

entity clocking50mhz is
   port (
      reset       : in  std_logic;
      locked      : out std_logic;

      -- Clock in ports
      clk_in      : in  std_logic;

      -- Clock out ports
      clock27     : out std_logic;
      clock40_5   : out std_logic;
      clock81     : out std_logic;
      clock270    : out std_logic;
      clock324    : out std_logic;
      clock324p90 : out std_logic;
      clock50     : out std_logic;
      clock100    : out std_logic;
      clock200    : out std_logic
   );
end entity;


architecture RTL of clocking50mhz is

  signal clk_fb_clock54 : std_logic := '0';
  signal clock54        : std_logic := '0';
  signal clk_fb_cpu     : std_logic := '0';
  signal clk_fb_eth     : std_logic := '0';
  
  signal clock27_u     : std_logic;
  signal clock40_5_u   : std_logic;
  signal clock81_u     : std_logic;
  signal clock270_u    : std_logic;
  signal clock324_u    : std_logic;
  signal clock324p90_u : std_logic;
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
  -- 54 MHz x 30 = 1620 MHz
  --     /  5 = 324.0 MHz
  --     /  6 = 270.0 MHz
  --     / 10 = 162.0 MHz (not used)
  --     / 20 =  81.0 MHz
  --     / 40 =  40.5 MHz
  --     / 60 =  27.0 MHz


  MMCME2_BASE_clock54 : MMCME2_BASE
  generic map (
     BANDWIDTH => "OPTIMIZED",  -- Jitter programming (OPTIMIZED, HIGH, LOW)
     CLKFBOUT_MULT_F => 27.0,    -- Multiply value for all CLKOUT (2.000-64.000).
     CLKFBOUT_PHASE => 0.0,     -- Phase offset in degrees of CLKFB (-360.000-360.000).
     CLKIN1_PERIOD => 20.0,      -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).
     -- CLKOUT0_DIVIDE - CLKOUT6_DIVIDE: Divide amount for each CLKOUT (1-128)
     CLKOUT1_DIVIDE => 1,
     CLKOUT2_DIVIDE => 1,
     CLKOUT3_DIVIDE => 1,
     CLKOUT4_DIVIDE => 1,
     CLKOUT5_DIVIDE => 1,
     CLKOUT6_DIVIDE => 1,
     CLKOUT0_DIVIDE_F => 25.0,   -- Divide amount for CLKOUT0 (1.000-128.000).
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
     CLKFBOUT_MULT => 30,       -- Multiply value for all CLKOUT, (2-64)
     CLKFBOUT_PHASE => 0.0,     -- Phase offset in degrees of CLKFB, (-360.000-360.000).
     CLKIN1_PERIOD => 18.519,   -- Input clock period in ns to ps resolution (i.e. 33.333 is 30 MHz).
     -- CLKOUT0_DIVIDE - CLKOUT5_DIVIDE: Divide amount for each CLKOUT (1-128)
     CLKOUT0_DIVIDE => 5,
     CLKOUT1_DIVIDE => 5,
     CLKOUT2_DIVIDE => 6,
     CLKOUT3_DIVIDE => 20,
     CLKOUT4_DIVIDE => 40,
     CLKOUT5_DIVIDE => 60,
     -- CLKOUT0_DUTY_CYCLE - CLKOUT5_DUTY_CYCLE: Duty cycle for each CLKOUT (0.001-0.999).
     CLKOUT0_DUTY_CYCLE => 0.5,
     CLKOUT1_DUTY_CYCLE => 0.5,
     CLKOUT2_DUTY_CYCLE => 0.5,
     CLKOUT3_DUTY_CYCLE => 0.5,
     CLKOUT4_DUTY_CYCLE => 0.5,
     CLKOUT5_DUTY_CYCLE => 0.5,
     -- CLKOUT0_PHASE - CLKOUT5_PHASE: Phase offset for each CLKOUT (-360.000-360.000).
     CLKOUT0_PHASE => 0.0,
     CLKOUT1_PHASE => 90.0,
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
     CLKOUT0 => clock324_u,    -- 1-bit output: CLKOUT0
     CLKOUT1 => clock324p90_u, -- 1-bit output: CLKOUT1
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
  bufg_clock270    : BUFG port map ( I => clock270_u   , O => clock270    );
  bufg_clock324    : BUFG port map ( I => clock324_u   , O => clock324    );
  bufg_clock324p90 : BUFG port map ( I => clock324p90_u, O => clock324p90 );
  bufg_clock50     : BUFG port map ( I => clock50_u    , O => clock50     );
  bufg_clock100    : BUFG port map ( I => clock100_u   , O => clock100    );
  bufg_clock200    : BUFG port map ( I => clock200_u   , O => clock200    );

  locked <= locked_mmce_clock54 and locked_pll_cpu and locked_pll_eth;

end rtl;
