library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Integration testbench: group_scale_acc.vhdl -> sb_finish.vhdl ->
-- generic_sdp_ram.vhdl, chained exactly as U10's three entities are
-- meant to be wired together, exercising the FULL Q4_K path this
-- session's practice #15/#16 resolved -- proving the end-to-end result
-- matches ggml's true `d*sc*q - dmin*m` formula even though the array's
-- own hardware only ever computes on the packed (q-8) weight. Each
-- individual entity already has its own unit testbench (tb_group_
-- scale_acc.vhdl, tb_sb_finish.vhdl); this is the "does wiring them
-- together actually work" check practice #11/#12's lesson calls for.
--
-- 2 groups, 2 weights each, hand-computed independently of any VHDL or
-- script (this file's comments show the arithmetic):
--   group 0: sc=2, m=1, RAW q=[8,8],  x=[3,5]   -> packed q-8=[0,0]
--     lane_sum = 0*3+0*5 = 0 ; sum_x = 3+5 = 8
--     true Sigma(q*x) = 8*3+8*5 = 64  (check: lane_sum+8*sum_x = 0+64 = 64, OK)
--   group 1: sc=3, m=2, RAW q=[10,6], x=[2,-4]  -> packed q-8=[2,-2]
--     lane_sum = 2*2+(-2)*(-4) = 12 ; sum_x = 2+(-4) = -2
--     true Sigma(q*x) = 10*2+6*(-4) = -4  (check: lane_sum+8*sum_x = 12-16 = -4, OK)
--
-- group_scale_acc must therefore produce:
--   sc_acc  = Sigma(sc * true_Sigma_qx) = 2*64 + 3*(-4) = 128 - 12 = 116
--   min_acc = Sigma(m * sum_x)          = 1*8  + 2*(-2) = 8 - 4   = 4
--
-- With d=dmin=act_scale=1.0 (all fp32/fp16 identity, chosen so the fp32
-- pipeline doesn't obscure the integer-stage result being checked):
--   delta = sc_acc - min_acc = 116 - 4 = 112.0 exactly
--   which is also directly d*sc*q*x - dmin*m*x summed over both groups:
--   g0: 2*64 - 1*8 = 120 ; g1: 3*(-4) - 2*(-2) = -8 ; total = 112 -- matches.
--   112.0 in fp32 = 1.75 x 2^6 -> 0x42E00000.
entity tb_rescaler_q4k is
end entity;

architecture sim of tb_rescaler_q4k is
  constant LW  : positive := 17;
  constant SW  : positive := 8;
  constant SXW : positive := 13;
  constant AW_ACC : positive := 32;
  constant ADDR_W  : positive := 4;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  -- group_scale_acc
  signal gce, grst : std_logic := '0';
  signal lane : signed(LW - 1 downto 0) := (others => '0');
  signal scale, minv : signed(SW - 1 downto 0) := (others => '0');
  signal sumx : signed(SXW - 1 downto 0) := (others => '0');
  signal sc_acc_s, min_acc_s : signed(AW_ACC - 1 downto 0);

  -- sb_finish
  signal start : std_logic := '0';
  signal addr  : unsigned(ADDR_W - 1 downto 0) := (others => '0');
  signal first : std_logic := '0';
  signal d_f16, dmin_f16 : std_logic_vector(15 downto 0) := (others => '0');
  signal act_scale : std_logic_vector(31 downto 0) := (others => '0');
  signal busy, done : std_logic;

  signal ram_we : std_logic;
  signal ram_waddr : unsigned(ADDR_W - 1 downto 0);
  signal ram_wdata : std_logic_vector(31 downto 0);
  signal ram_re : std_logic;
  signal ram_raddr : unsigned(ADDR_W - 1 downto 0);
  signal ram_rdata : std_logic_vector(31 downto 0);
begin

  gsa : entity work.group_scale_acc
    generic map (LANE_WIDTH => LW, SCALE_WIDTH => SW, SUM_X_WIDTH => SXW,
                 ACC_WIDTH => AW_ACC, HAS_MIN_TERM => true, WEIGHT_OFFSET => 8)
    port map (clk => clk, rst => grst, ce => gce,
              lane_sum => lane, scale => scale, min_val => minv, sum_x => sumx,
              sc_acc => sc_acc_s, min_acc => min_acc_s);

  sbf : entity work.sb_finish
    generic map (ADDR_WIDTH => ADDR_W)
    port map (
      clk => clk, rst => rst,
      start => start, addr => addr, first => first,
      sc_acc => sc_acc_s, min_acc => min_acc_s,
      d_f16 => d_f16, dmin_f16 => dmin_f16, act_scale => act_scale,
      busy => busy, done => done,
      ram_we => ram_we, ram_waddr => ram_waddr, ram_wdata => ram_wdata,
      ram_re => ram_re, ram_raddr => ram_raddr, ram_rdata => ram_rdata
    );

  ram : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => 2 ** ADDR_W)
    port map (clk => clk, we => ram_we, waddr => ram_waddr, wdata => ram_wdata,
              re => ram_re, raddr => ram_raddr, rdata => ram_rdata);

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;
    variable iters : integer;
  begin
    rst <= '1'; grst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0'; grst <= '0';

    -- drive the 2 groups into group_scale_acc
    gce <= '1';
    lane <= to_signed(0, LW); scale <= to_signed(2, SW); minv <= to_signed(1, SW); sumx <= to_signed(8, SXW);
    wait until rising_edge(clk); wait for 1 ns;
    lane <= to_signed(12, LW); scale <= to_signed(3, SW); minv <= to_signed(2, SW); sumx <= to_signed(-2, SXW);
    wait until rising_edge(clk); wait for 1 ns;
    gce <= '0';

    wait until rising_edge(clk); wait for 1 ns; -- drain: group 1's term lands

    if to_integer(sc_acc_s) /= 116 then
      fails := fails + 1;
      report "FAIL: sc_acc expect=116 got=" & integer'image(to_integer(sc_acc_s)) severity error;
    end if;
    if to_integer(min_acc_s) /= 4 then
      fails := fails + 1;
      report "FAIL: min_acc expect=4 got=" & integer'image(to_integer(min_acc_s)) severity error;
    end if;

    -- feed sb_finish (sc_acc_s/min_acc_s are now stable) with d=dmin=act_scale=1.0
    addr <= to_unsigned(0, ADDR_W);
    first <= '1';
    d_f16 <= x"3C00";
    dmin_f16 <= x"3C00";
    act_scale <= x"3F800000";
    start <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    start <= '0';

    iters := 0;
    while done /= '1' and iters < 20 loop
      wait until rising_edge(clk); wait for 1 ns;
      iters := iters + 1;
    end loop;

    if done /= '1' then
      fails := fails + 1;
      report "FAIL: sb_finish done never pulsed" severity error;
    elsif ram_wdata /= x"42E00000" then
      fails := fails + 1;
      report "FAIL: final acc_ram value expect=0x42E00000 (112.0) got=" & to_hstring(ram_wdata) severity error;
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
