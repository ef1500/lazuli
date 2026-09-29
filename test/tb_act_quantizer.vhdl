library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for act_quantizer.vhdl.
--
-- The recip table loaded here is DELIBERATELY DEGENERATE (both entries
-- {value=1.0, slope=0}, bits=1) rather than an accurate reciprocal
-- table: generic_lookup.vhdl's own interpolation accuracy already has
-- its own dedicated testbench (tb_generic_lookup.vhdl), so re-testing
-- it here would just add tolerance-based fuzz without checking anything
-- new about act_quantizer.vhdl itself. With slope=0, generic_lookup's
-- TAB_MANT math collapses to a pure "negate the exponent" function
-- (tval = entry_val + slope*frac = 1.0 + 0 = 1.0 always, regardless of
-- idx/frac), which happens to equal the TRUE reciprocal whenever the
-- exponent alone determines it and is otherwise still an exact,
-- hand-computable function of the input -- letting every value in this
-- testbench, including the SECOND recip call (on 15.875, not a power of
-- two -- see below), be checked bit-exactly instead of by tolerance.
--
-- Hand-worked expected values (BLOCK_SIZE=256, SUBGROUP=32):
--   elements 0..5 = {8.0, -8.0, 4.0, 0.0, 1.0, -0.5}, elements 6..255 = 0.0
--   amax = 8.0 (element 0)
--   recip(8.0) [degenerate table] = exp_shift(1.0, 127-130) = 0.125  -- exact, matches true math too
--   inv_scale = 0.125 * 127.0 = 15.875                                -- exact fp32 product
--   recip(15.875) [degenerate table] = exp_shift(1.0, 127-130) = 0.125
--     (15.875 also has biased exponent 130, so this is 0.125 again --
--     NOT the true 1/15.875~=0.063, because the mock table is
--     degenerate; see header above for why that's fine here)
--   scale = 0.125 (0x3E000000)
--   q_i = clamp(round(x_i * 15.875), -127, 127):
--     q_0 = round(8.0  * 15.875) = round(127.0)   = 127
--     q_1 = round(-8.0 * 15.875) = round(-127.0)  = -127
--     q_2 = round(4.0  * 15.875) = round(63.5)    = 64   (tie, round-half-to-even: 64 is even)
--     q_3 = round(0.0  * 15.875) = 0
--     q_4 = round(1.0  * 15.875) = round(15.875)  = 16
--     q_5 = round(-0.5 * 15.875) = round(-7.9375) = -8
--     q_6..q_255 = 0
--   Sigma(q) subgroup 0 (elements 0..31) = 127-127+64+0+16-8 = 72
--   Sigma(q) subgroups 1..7 = 0
entity tb_act_quantizer is
end entity;

architecture sim of tb_act_quantizer is
  constant BLOCK_SIZE : positive := 256;
  constant SUBGROUP   : positive := 32;
  constant NSUB       : positive := BLOCK_SIZE / SUBGROUP;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  signal start, in_valid : std_logic := '0';
  signal in_data : std_logic_vector(31 downto 0) := (others => '0');
  signal busy, done : std_logic;

  signal q_out : std_logic_vector(BLOCK_SIZE * 8 - 1 downto 0);
  signal scale_out : std_logic_vector(31 downto 0);
  signal sum_out : std_logic_vector(NSUB * 13 - 1 downto 0);

  signal ld_en, ld_we : std_logic := '0';
  signal ld_slot : unsigned(2 downto 0) := (others => '0');
  signal ld_mode : tab_mode_t := TAB_MANT;
  signal ld_lo, ld_hi : std_logic_vector(31 downto 0) := (others => '0');
  signal ld_left, ld_right : tab_edge_t := EDGE_CLAMP;
  signal ld_bits : unsigned(3 downto 0) := (others => '0');
  signal ld_addr : unsigned(9 downto 0) := (others => '0');
  signal ld_value, ld_slope : std_logic_vector(31 downto 0) := (others => '0');

  constant ONE_FP32 : std_logic_vector(31 downto 0) := x"3F800000";
begin

  dut : entity work.act_quantizer
    generic map (BLOCK_SIZE => BLOCK_SIZE, SUBGROUP => SUBGROUP, RECIP_SLOT => 0)
    port map (
      clk => clk, rst => rst,
      start => start, in_valid => in_valid, in_data => in_data,
      busy => busy, done => done,
      q_out => q_out, scale_out => scale_out, sum_out => sum_out,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;
    variable iters : integer;

    variable elem : std_logic_vector(31 downto 0);

    procedure check_q(i : integer; expect : integer) is
      variable got : integer;
    begin
      got := to_integer(signed(q_out((i + 1) * 8 - 1 downto i * 8)));
      if got /= expect then
        fails := fails + 1;
        report "FAIL q_out(" & integer'image(i) & ") expect=" & integer'image(expect) &
               " got=" & integer'image(got) severity error;
      end if;
    end procedure;

    procedure check_sum(g : integer; expect : integer) is
      variable got : integer;
    begin
      got := to_integer(signed(sum_out((g + 1) * 13 - 1 downto g * 13)));
      if got /= expect then
        fails := fails + 1;
        report "FAIL sum_out(" & integer'image(g) & ") expect=" & integer'image(expect) &
               " got=" & integer'image(got) severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- load the degenerate 2-entry recip table into slot 0 (see header)
    ld_slot <= to_unsigned(0, 3);
    ld_mode <= TAB_MANT;
    ld_bits <= to_unsigned(1, 4);
    ld_en <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ld_en <= '0';

    ld_slot <= to_unsigned(0, 3);
    ld_addr <= to_unsigned(0, 10);
    ld_value <= ONE_FP32; ld_slope <= (others => '0'); ld_we <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ld_addr <= to_unsigned(1, 10);
    wait until rising_edge(clk); wait for 1 ns;
    ld_we <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    -- start a block and stream in 256 fp32 values. 'in_valid' is raised
    -- in the SAME delta region as 'start' drops (before any settle
    -- wait), so it's already high by the time 'phase' becomes PH_INGEST
    -- at this same clock edge -- staggering the two (dropping 'start'
    -- with a settle wait, then raising 'in_valid' afterward) leaves a
    -- ~1ns window where phase=PH_INGEST but in_valid is still '0' and
    -- trips act_quantizer.vhdl's own contract-check assertion, a
    -- testbench-timing artifact rather than a DUT bug.
    start <= '1';
    wait until rising_edge(clk);
    start <= '0';
    in_valid <= '1';
    wait for 1 ns;

    for i in 0 to BLOCK_SIZE - 1 loop
      case i is
        when 0 => elem := x"41000000"; -- 8.0
        when 1 => elem := x"C1000000"; -- -8.0
        when 2 => elem := x"40800000"; -- 4.0
        when 3 => elem := x"00000000"; -- 0.0
        when 4 => elem := x"3F800000"; -- 1.0
        when 5 => elem := x"BF000000"; -- -0.5
        when others => elem := x"00000000";
      end case;
      in_data <= elem;
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    in_valid <= '0';

    iters := 0;
    while done /= '1' and iters < 2000 loop
      wait until rising_edge(clk); wait for 1 ns;
      iters := iters + 1;
    end loop;

    if done /= '1' then
      fails := fails + 1;
      report "FAIL: done never pulsed within 2000 cycles" severity error;
    else
      if scale_out /= x"3E000000" then
        fails := fails + 1;
        report "FAIL: scale_out expect=0x3E000000 (0.125) got=" & to_hstring(scale_out) severity error;
      end if;

      check_q(0, 127);
      check_q(1, -127);
      check_q(2, 64);
      check_q(3, 0);
      check_q(4, 16);
      check_q(5, -8);
      check_q(6, 0);
      check_q(31, 0);
      check_q(100, 0);
      check_q(255, 0);

      check_sum(0, 72);
      check_sum(1, 0);
      check_sum(7, 0);
    end if;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
