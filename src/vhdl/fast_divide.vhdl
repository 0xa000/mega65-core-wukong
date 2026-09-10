
use WORK.ALL;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;


entity fast_divide is
  port (
    -- Must be the 4x CPU clock (clock162), phase-aligned with cpuclock.
    -- n, d and start_over are cpuclock-domain registers; q and busy must be
    -- re-registered on cpuclock by the instantiating entity before feeding
    -- any wider logic (e.g. the fastio read mux), so that the only
    -- cross-domain paths are direct register-to-register hops.
    clock : in std_logic;
    n : in unsigned(31 downto 0);
    d : in unsigned(31 downto 0);
    q : out unsigned(63 downto 0);
    start_over : in std_logic;
    busy : out std_logic := '0'
    );
end entity;

architecture wattle_and_daub of fast_divide is
  -- A single-cycle Goldschmidt iteration needs ~26ns on an xc7a100t-1,
  -- which does not fit the 24.7ns cpuclock period.  Instead of stretching
  -- the iteration over multiple CPU cycles (which breaks software that
  -- relies on the result being ready 7 cycles after triggering), the whole
  -- divider runs at 4x the CPU clock with the iteration spread over four
  -- fast cycles: DSP48 partial products (mul1), the per-column ternary
  -- combines (mul2), the pairwise top sums and low window (mul3), and an
  -- update stage that rounds the product and derives f for the next
  -- iteration.  One iteration thus takes exactly one CPU cycle, and after
  -- re-registering q and busy on cpuclock the result is readable 9 CPU
  -- cycles after the trigger write, identical to the upstream single-clock
  -- version.  The multiplier is decomposed by hand (see the signal
  -- comments below) because every inferred variant left either a
  -- two-level fabric adder tree or an unregistered DSP cascade hop on a
  -- fast-cycle path.
  type state_t is (idle, prime, mul1, mul2, mul3, update, output);
  signal state : state_t := idle;
  signal steps_remaining : integer range 0 to 5 := 0;

  signal dd : unsigned(67 downto 0) := to_unsigned(0,68);
  signal nn : unsigned(67 downto 0) := to_unsigned(0,68);
  -- Goldschmidt factor f = 2 - dd.  Because dd is always normalised to
  -- [0.5, 1), f lies in (1, 1.5] and its top two bits are constant "01",
  -- so only the low 68 bits g = f - 2^68 are stored.  That keeps the
  -- multipliers at 68x68 (exactly four 17-bit DSP slices; a 70-bit factor
  -- needs a fifth 2-bit slice whose fabric partial products push the
  -- final combining adder to two chained levels, which does not fit a
  -- fast cycle); the implicit f(68)='1' becomes an aligned addend.
  signal g_r : unsigned(67 downto 0) := to_unsigned(0,68);
  -- Registered dd = all-ones compare (see the free-running compare in the
  -- process) so the loop control does not need a wide compare of its own.
  signal dd_ones : std_logic := '0';
  -- Normalised d, kept so prime can compute the initial f with a 38-bit
  -- subtract (the lower 32 bits of the initial dd are constant zero).
  signal d_hi : unsigned(35 downto 0) := to_unsigned(0,36);

  -- The update stage must not get merged into the DSP input registers:
  -- that would put the rounding carry chain, cross-fabric routing and the
  -- DSP input setup into a single fast cycle.
  attribute dont_touch : string;
  attribute dont_touch of dd : signal is "true";
  attribute dont_touch of nn : signal is "true";
  attribute dont_touch of g_r : signal is "true";

  -- Free-running multiplier pipelines.  Each 68x68 multiply is split
  -- manually as nn*g = nn*g(67:34)*2^34 + nn*g(33:0): a monolithic 68x68
  -- with three pipeline stages leaves Vivado a two-level fabric adder
  -- tree in the last stage, which does not fit a fast cycle.  The 68x34
  -- halves fit the DSP48 pipeline with a single-level ternary combine,
  -- and the final stage is then one plain two-input add.
  -- Stage 1: 24 individual 24x17 partial products, one DSP48 each with
  -- its own pipeline register -- single-DSP multiplies cannot be PCIN-
  -- cascaded, which otherwise leaves unregistered DSP-to-DSP hops.
  -- Stage 2: each 68x17 column q_i = pp(i,0) + pp(i,1)<<24 + pp(i,2)<<48
  -- as one ternary add.
  type pp_array_t is array(0 to 3, 0 to 2) of unsigned(40 downto 0);
  signal pp_nn : pp_array_t := (others => (others => to_unsigned(0,41)));
  signal pp_dd : pp_array_t := (others => (others => to_unsigned(0,41)));
  signal q_nn_0_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_nn_1_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_nn_2_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_nn_3_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_dd_0_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_dd_1_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_dd_2_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  signal q_dd_3_2 : unsigned(84 downto 0) := to_unsigned(0,85);
  -- Stage 3: the product top p(135:68) equals q0(84:68) + q1(84:51) +
  -- q2(84:34) + q3(84:17) + carry of the low window, so pre-add the top
  -- parts pairwise (exact, in parallel) and separately sum the complete
  -- low window p(67:0), whose bits 69:68 are that carry and bit 67 the
  -- round bit.  The product bits below 67 are consumed nowhere, so the
  -- full 136-bit sum never needs to materialise anywhere.
  -- v_lo also folds in the operand itself (the (op << 68) addend of the
  -- full product), so the update stage is left with only two wide terms.
  signal v_nn_hi : unsigned(68 downto 0) := to_unsigned(0,69);
  signal v_nn_lo : unsigned(68 downto 0) := to_unsigned(0,69);
  signal v_dd_hi : unsigned(68 downto 0) := to_unsigned(0,69);
  signal v_dd_lo : unsigned(68 downto 0) := to_unsigned(0,69);
  signal low_nn : unsigned(69 downto 0) := to_unsigned(0,70);
  signal low_dd : unsigned(69 downto 0) := to_unsigned(0,70);

  attribute use_dsp : string;
  attribute use_dsp of pp_nn : signal is "yes";
  attribute use_dsp of pp_dd : signal is "yes";

  -- Input capture registers: the only logic on the cpuclock -> clock162
  -- crossing paths.  start_over is one cpuclock = four fast cycles wide
  -- and would otherwise retrigger the division four times, so trigger
  -- once per pulse via the armed flag.
  signal n_r : unsigned(31 downto 0) := to_unsigned(0,32);
  signal d_r : unsigned(31 downto 0) := to_unsigned(0,32);
  signal so_r : std_logic := '0';
  signal so_r2 : std_logic := '0';
  signal so_r3 : std_logic := '0';
  signal armed : std_logic := '1';

  -- Free-running normalisation of the sampled operands, spread over two
  -- cycles (leading-zero count, then the barrel shifts) ahead of the
  -- trigger, so the trigger cycle itself is a plain register copy.  The
  -- cpuclock-side re-registration of q and busy quantises completion to
  -- CPU cycles, so these extra fast cycles do not change any CPU-visible
  -- timing.
  signal lz_r : integer range 0 to 31 := 0;
  signal n_r2 : unsigned(31 downto 0) := to_unsigned(0,32);
  signal d_r2 : unsigned(31 downto 0) := to_unsigned(0,32);
  signal norm_dd_r : unsigned(35 downto 0) := to_unsigned(0,36);
  signal norm_nn_r : unsigned(67 downto 0) := to_unsigned(0,68);

  pure function count_leading_zeros(arg : unsigned(31 downto 0)) return natural is
  begin
    for i in 0 to 31 loop
      if arg(31-i) = '1' then
        return i;
      end if;
    end loop;
    return 0;
  end function count_leading_zeros;

begin

  process (clock) is
    variable temp64 : unsigned(73 downto 0) := to_unsigned(0,74);
    variable two69 : unsigned(68 downto 0) := to_unsigned(0,69);
    variable sum_dd : unsigned(68 downto 0);
    variable g_raw : unsigned(67 downto 0);
    variable satmask : unsigned(67 downto 0);
    variable leading_zeros : natural range 0 to 31;
    variable new_dd : unsigned( 35 downto 0);
    variable new_nn : unsigned( 67 downto 0);
    variable padded_d : unsigned(63 downto 0);
  begin
    if rising_edge(clock) then
      report "state is " & state_t'image(state);

      -- The full products are nn * f = (nn << 68) + nn * g (and likewise
      -- for dd), but only the plain nn * g multiplies are pipelined here;
      -- the (nn << 68) addend is folded into the update stage's adders
      -- instead (nn and dd hold their values from mul1 through update, so
      -- the operands are still available there).  Adding it here would
      -- break the clean pipelined DSP inference of the multiplies.
      for i in 0 to 3 loop
        pp_nn(i,0) <= nn(23 downto 0) * g_r(16+17*i downto 17*i);
        pp_nn(i,1) <= nn(47 downto 24) * g_r(16+17*i downto 17*i);
        pp_nn(i,2) <= resize(nn(67 downto 48),24) * g_r(16+17*i downto 17*i);
        pp_dd(i,0) <= dd(23 downto 0) * g_r(16+17*i downto 17*i);
        pp_dd(i,1) <= dd(47 downto 24) * g_r(16+17*i downto 17*i);
        pp_dd(i,2) <= resize(dd(67 downto 48),24) * g_r(16+17*i downto 17*i);
      end loop;
      q_nn_0_2 <= resize(pp_nn(0,0),85) + (pp_nn(0,1) & to_unsigned(0,24))
                  + (pp_nn(0,2)(36 downto 0) & to_unsigned(0,48));
      q_nn_1_2 <= resize(pp_nn(1,0),85) + (pp_nn(1,1) & to_unsigned(0,24))
                  + (pp_nn(1,2)(36 downto 0) & to_unsigned(0,48));
      q_nn_2_2 <= resize(pp_nn(2,0),85) + (pp_nn(2,1) & to_unsigned(0,24))
                  + (pp_nn(2,2)(36 downto 0) & to_unsigned(0,48));
      q_nn_3_2 <= resize(pp_nn(3,0),85) + (pp_nn(3,1) & to_unsigned(0,24))
                  + (pp_nn(3,2)(36 downto 0) & to_unsigned(0,48));
      v_nn_hi <= ('0' & q_nn_3_2(84 downto 17)) + q_nn_2_2(84 downto 34);
      v_nn_lo <= ('0' & nn) + q_nn_1_2(84 downto 51) + q_nn_0_2(84 downto 68);
      low_nn <= ("00" & q_nn_0_2(67 downto 0))
                + (q_nn_1_2(50 downto 0) & to_unsigned(0,17))
                + (q_nn_2_2(33 downto 0) & to_unsigned(0,34))
                + (q_nn_3_2(16 downto 0) & to_unsigned(0,51));
      q_dd_0_2 <= resize(pp_dd(0,0),85) + (pp_dd(0,1) & to_unsigned(0,24))
                  + (pp_dd(0,2)(36 downto 0) & to_unsigned(0,48));
      q_dd_1_2 <= resize(pp_dd(1,0),85) + (pp_dd(1,1) & to_unsigned(0,24))
                  + (pp_dd(1,2)(36 downto 0) & to_unsigned(0,48));
      q_dd_2_2 <= resize(pp_dd(2,0),85) + (pp_dd(2,1) & to_unsigned(0,24))
                  + (pp_dd(2,2)(36 downto 0) & to_unsigned(0,48));
      q_dd_3_2 <= resize(pp_dd(3,0),85) + (pp_dd(3,1) & to_unsigned(0,24))
                  + (pp_dd(3,2)(36 downto 0) & to_unsigned(0,48));
      v_dd_hi <= ('0' & q_dd_3_2(84 downto 17)) + q_dd_2_2(84 downto 34);
      v_dd_lo <= ('0' & dd) + q_dd_1_2(84 downto 51) + q_dd_0_2(84 downto 68);
      low_dd <= ("00" & q_dd_0_2(67 downto 0))
                + (q_dd_1_2(50 downto 0) & to_unsigned(0,17))
                + (q_dd_2_2(33 downto 0) & to_unsigned(0,34))
                + (q_dd_3_2(16 downto 0) & to_unsigned(0,51));

      n_r <= n;
      d_r <= d;
      so_r <= start_over;
      so_r2 <= so_r;
      so_r3 <= so_r2;
      if so_r3 = '0' then
        armed <= '1';
      end if;

      -- Free-running operand normalisation (see signal declaration)
      lz_r <= count_leading_zeros(d_r);
      n_r2 <= n_r;
      d_r2 <= d_r;

      leading_zeros := lz_r;
      padded_d := d_r2 & X"00000000";
      new_dd := (others => '0');
      new_dd(35 downto 4) := padded_d(63-leading_zeros downto 32-leading_zeros);
      new_nn := (others => '0');
      new_nn(35+leading_zeros downto 4+leading_zeros) := n_r2;
      norm_dd_r <= new_dd;
      norm_nn_r <= new_nn;

      -- Free-running early-exit compare: consumed by the update state,
      -- where dd was last written four cycles earlier, so this registered
      -- compare is always up to date there and off every critical path.
      if dd = X"FFFFFFFFFFFFFFFFF" then
        dd_ones <= '1';
      else
        dd_ones <= '0';
      end if;

      case state is
        when idle =>
          null;
        when prime =>
          report "nn=$" & to_hstring(nn(67 downto 36)) & "." & to_hstring(nn(35 downto 4)) & "." & to_hstring(nn(3 downto 0))
            & " / dd=$" & to_hstring(dd(67 downto 36)) & "." & to_hstring(dd(35 downto 4)) & "." & to_hstring(dd(3 downto 0));

          -- g = f - 2^68 = 2^68 - dd; the lower 32 bits of the freshly
          -- loaded dd are zero, so subtracting the saved d_hi folds to a
          -- 37-bit chain
          two69 := to_unsigned(0,69);
          two69(68) := '1';
          g_r <= resize(two69 - (d_hi & X"00000000"), 68);
          state <= mul1;
        when mul1 =>
          state <= mul2;
        when mul2 =>
          state <= mul3;
        when mul3 =>
          state <= update;
        when update =>
          -- The full product top p(135:68) is v_hi + v_lo + the low
          -- window carry; the folded (op << 68) addend and the round bit
          -- p(67) = low(67) join in, so each result here is one
          -- compressed carry chain starting directly at registers,
          -- followed by at most one mux level.

          -- Round nn up on p(67); overflow wraps, same as upstream
          nn <= resize(v_nn_hi,68) + resize(v_nn_lo,68)
                + low_nn(69 downto 68) + ("" & low_nn(67));

          -- Round dd up on p(67), but avoid overflow: the guarded round
          -- of upstream (only round if the product top is not all-ones)
          -- is equivalent to rounding unguarded and saturating on
          -- carry-out.  When the sum carries out it is exactly 2^68 (the
          -- product top is at most 2^68 - 1 and the round bit adds one),
          -- so the low bits are all zero and saturation reduces to OR-ing
          -- the carry into every bit -- no mux behind the carry chain.
          sum_dd := resize(v_dd_hi,69) + resize(v_dd_lo,69)
                    + low_dd(69 downto 68) + ("" & low_dd(67));
          satmask := (others => sum_dd(68));
          dd <= sum_dd(67 downto 0) or satmask;
          -- g = 2^68 - new dd, computed modulo 2^68 as 0 - (all the terms
          -- of new dd); Vivado compresses the multi-operand subtract into
          -- one chain via complements rather than chaining a subtractor
          -- behind the rounding adder.  In the saturated case the raw
          -- value is 0 and the true g is 2^68 - (2^68-1) = 1, so the
          -- carry again just ORs into bit 0.
          g_raw := to_unsigned(0,68) - resize(v_dd_hi,68) - resize(v_dd_lo,68)
                   - low_dd(69 downto 68) - ("" & low_dd(67));
          g_r <= g_raw(67 downto 1) & (g_raw(0) or sum_dd(68));
          report "p_dd top=$" & to_hstring(sum_dd);

          -- Perform number of required steps, or abort early if we can
          -- (dd_ones tracks dd = all-ones from the previous update)
          if steps_remaining /= 0 and dd_ones = '0' then
            steps_remaining <= steps_remaining - 1;
            state <= mul1;
          else
            state <= output;
          end if;
        when output =>
          -- No idea why we need to add one, but we do to stop things like 4/2
          -- giving a result of 1.999999999
          temp64(67 downto 0) := nn;
          temp64(73 downto 68) := (others => '0');
          temp64 := temp64 + 8;
          report "temp64=$" & to_hstring(temp64);
          busy <= '0';
          q <= temp64(67 downto 4);
          state <= idle;
      end case;

      if so_r3='1' and armed='1' then
        armed <= '0';
        -- norm_dd_r is zero exactly when d was zero (a non-zero d always
        -- normalises with its leading one at bit 35)
        if norm_dd_r /= to_unsigned(0,36) then
          report "Calculating $" & to_hstring(n_r2) & " / $" & to_hstring(d_r2);
          report "Normalised to $" & to_hstring(norm_nn_r(67 downto 36)) & "." &
            to_hstring(norm_nn_r(35 downto 4)) & "." & to_hstring(norm_nn_r(3 downto 0))
            & " / $" & to_hstring(norm_dd_r(35 downto 4)) & "." & to_hstring(norm_dd_r(3 downto 0));
          dd <= norm_dd_r & X"00000000";
          nn <= norm_nn_r;
          d_hi <= norm_dd_r;
          state <= prime;
          steps_remaining <= 5;
          busy <= '1';
        else
          report "Ignoring divide by zero";
        end if;
      end if;

    end if;
  end process;
end wattle_and_daub;
