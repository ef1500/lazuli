library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for group_scale_acc.vhdl. Two DUTs, run
-- sequentially on the same clock: one with HAS_MIN_TERM=false (Q3_K/
-- Q6_K shape -- plain scale*lane_sum accumulation, min_acc must stay 0)
-- and one with HAS_MIN_TERM=true (Q4_K shape -- exercises BOTH the
-- spec-documented m*Sigma(x) subtraction term AND this session's
-- resolved practice #15/#16 weight-offset add-back, 8*sc*Sigma(x)).
-- 4 hand-computed groups per DUT (small enough to verify by hand in the
-- header comment below, not by an independent script -- this is plain
-- integer arithmetic, not a recalled bit-layout, so there's no
-- transcription-bug risk an independent reimplementation would catch
-- that hand computation wouldn't).
--
-- Also checks the entity's own header-documented one-cycle pipeline
-- stagger (int_mul_scale's registered product -> int_acc's registered
-- accumulate, chained for the first time here): with 'ce' held high
-- continuously across all 4 groups (the realistic drive pattern, not
-- isolated pulses), the two stages overlap -- group g's term is
-- consumed by int_acc one edge AFTER the edge that presented it, so
-- immediately after the 4th group's own edge, the accumulator has only
-- caught groups 0..2; it takes exactly one more clock edge (not zero,
-- and not two) for group 3's term to land. Checked by comparing against
-- a hand-computed 3-group PARTIAL sum right after the loop, then the
-- full 4-group sum one edge later.
entity tb_group_scale_acc is
end entity;

architecture sim of tb_group_scale_acc is
  constant LW  : positive := 17;
  constant SW  : positive := 8;
  constant SXW : positive := 13;
  constant AW  : positive := 32;

  signal clk  : std_logic := '0';
  signal done : boolean := false;

  -- DUT 1: HAS_MIN_TERM = false
  signal rst1, ce1 : std_logic := '0';
  signal lane1 : signed(LW - 1 downto 0) := (others => '0');
  signal scale1 : signed(SW - 1 downto 0) := (others => '0');
  signal minv1  : signed(SW - 1 downto 0) := (others => '0');
  signal sumx1  : signed(SXW - 1 downto 0) := (others => '0');
  signal sc_acc1, min_acc1 : signed(AW - 1 downto 0);

  -- DUT 2: HAS_MIN_TERM = true
  signal rst2, ce2 : std_logic := '0';
  signal lane2 : signed(LW - 1 downto 0) := (others => '0');
  signal scale2 : signed(SW - 1 downto 0) := (others => '0');
  signal minv2  : signed(SW - 1 downto 0) := (others => '0');
  signal sumx2  : signed(SXW - 1 downto 0) := (others => '0');
  signal sc_acc2, min_acc2 : signed(AW - 1 downto 0);
begin

  dut_no_min : entity work.group_scale_acc
    generic map (LANE_WIDTH => LW, SCALE_WIDTH => SW, SUM_X_WIDTH => SXW,
                 ACC_WIDTH => AW, HAS_MIN_TERM => false)
    port map (clk => clk, rst => rst1, ce => ce1,
              lane_sum => lane1, scale => scale1, min_val => minv1, sum_x => sumx1,
              sc_acc => sc_acc1, min_acc => min_acc1);

  dut_min : entity work.group_scale_acc
    generic map (LANE_WIDTH => LW, SCALE_WIDTH => SW, SUM_X_WIDTH => SXW,
                 ACC_WIDTH => AW, HAS_MIN_TERM => true, WEIGHT_OFFSET => 8)
    port map (clk => clk, rst => rst2, ce => ce2,
              lane_sum => lane2, scale => scale2, min_val => minv2, sum_x => sumx2,
              sc_acc => sc_acc2, min_acc => min_acc2);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;

    type int_arr_t is array (0 to 3) of integer;
    -- DUT 1 (no min term): expect sc_acc = Sigma(lane*scale)
    --   100*5 + (-50)*10 + 30*(-3) + 9*7 = 500 - 500 - 90 + 63 = -27
    --   partial (groups 0..2 only) = 500 - 500 - 90 = -90
    constant lane_v1  : int_arr_t := (100, -50, 30, 9);
    constant scale_v1 : int_arr_t := (5, 10, -3, 7);
    constant partial1 : integer := -90;
    constant expect1  : integer := -27;

    -- DUT 2 (Q4_K shape): expect sc_acc = Sigma(sc*lane + 8*sc*sum_x),
    -- min_acc = Sigma(m*sum_x) -- worked by hand in this file's header:
    --   g0: 5*100 + 8*5*10    =  500 +  400 =  900 ; min: 2*10  =  20
    --   g1: 10*-50 + 8*10*-20 = -500 -1600 = -2100 ; min: 4*-20 = -80
    --   g2: 3*30 + 8*3*5      =   90 +  120 =  210 ; min: 1*5   =   5
    --   g3: 7*20 + 8*7*3      =  140 +  168 =  308 ; min: 6*3   =  18
    --   sc_acc total  = 900 - 2100 + 210 + 308 = -682 ; partial (0..2) = -990
    --   min_acc total = 20 - 80 + 5 + 18 = -37 ; partial (0..2) = -55
    constant lane_v2  : int_arr_t := (100, -50, 30, 20);
    constant scale_v2 : int_arr_t := (5, 10, 3, 7);
    constant minv_v2  : int_arr_t := (2, 4, 1, 6);
    constant sumx_v2  : int_arr_t := (10, -20, 5, 3);
    constant partial_sc2  : integer := -990;
    constant partial_min2 : integer := -55;
    constant expect_sc2  : integer := -682;
    constant expect_min2 : integer := -37;
  begin
    -- === DUT 1: HAS_MIN_TERM = false ===
    rst1 <= '1'; ce1 <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    rst1 <= '0';
    if to_integer(sc_acc1) /= 0 or to_integer(min_acc1) /= 0 then
      fails := fails + 1;
      report "FAIL dut1: not zero after reset" severity error;
    end if;

    ce1 <= '1';
    for g in 0 to 3 loop
      lane1 <= to_signed(lane_v1(g), LW);
      scale1 <= to_signed(scale_v1(g), SW);
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    ce1 <= '0';

    -- immediately after the loop: group 3's term hasn't landed yet
    if to_integer(sc_acc1) /= partial1 then
      fails := fails + 1;
      report "FAIL dut1: sc_acc right after the loop should be the 0..2 partial=" &
             integer'image(partial1) & " got=" & integer'image(to_integer(sc_acc1)) &
             " -- pipeline stagger missing or wrong?" severity error;
    end if;

    -- one drain cycle: now it must be settled
    wait until rising_edge(clk); wait for 1 ns;
    if to_integer(sc_acc1) /= expect1 then
      fails := fails + 1;
      report "FAIL dut1: sc_acc expect=" & integer'image(expect1) & " got=" & integer'image(to_integer(sc_acc1)) severity error;
    end if;
    if to_integer(min_acc1) /= 0 then
      fails := fails + 1;
      report "FAIL dut1: min_acc must stay 0 when HAS_MIN_TERM=false, got=" & integer'image(to_integer(min_acc1)) severity error;
    end if;

    -- === DUT 2: HAS_MIN_TERM = true ===
    rst2 <= '1'; ce2 <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    rst2 <= '0';
    if to_integer(sc_acc2) /= 0 or to_integer(min_acc2) /= 0 then
      fails := fails + 1;
      report "FAIL dut2: not zero after reset" severity error;
    end if;

    ce2 <= '1';
    for g in 0 to 3 loop
      lane2 <= to_signed(lane_v2(g), LW);
      scale2 <= to_signed(scale_v2(g), SW);
      minv2 <= to_signed(minv_v2(g), SW);
      sumx2 <= to_signed(sumx_v2(g), SXW);
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    ce2 <= '0';

    if to_integer(sc_acc2) /= partial_sc2 or to_integer(min_acc2) /= partial_min2 then
      fails := fails + 1;
      report "FAIL dut2: right after the loop should be the 0..2 partial sc=" &
             integer'image(partial_sc2) & " min=" & integer'image(partial_min2) &
             " got sc=" & integer'image(to_integer(sc_acc2)) & " min=" & integer'image(to_integer(min_acc2))
             severity error;
    end if;

    wait until rising_edge(clk); wait for 1 ns; -- drain: group 3 lands

    if to_integer(sc_acc2) /= expect_sc2 then
      fails := fails + 1;
      report "FAIL dut2: sc_acc expect=" & integer'image(expect_sc2) & " got=" & integer'image(to_integer(sc_acc2)) severity error;
    end if;
    if to_integer(min_acc2) /= expect_min2 then
      fails := fails + 1;
      report "FAIL dut2: min_acc expect=" & integer'image(expect_min2) & " got=" & integer'image(to_integer(min_acc2)) severity error;
    end if;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
