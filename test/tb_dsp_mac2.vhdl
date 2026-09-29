library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for dsp_mac2.vhdl, architecture "behav" (the
-- one actually elaborated -- "xilinx" has no UNISIM library in this
-- repo, so it's analyzed for syntax only by test/run_tests.sh, never
-- bound here). Generics match the Q6_K corner (WEIGHT_W=6, the widest
-- of the three formats this project reads) with SPACING=17, the value
-- syseng_docs/04-vhdl-module-list.md S2.1 verified works for all three
-- K-quant formats.
--
-- Main pass: exhaustive over every (w1, w2) weight pair in -32..31 (the
-- full WEIGHT_W=6 signed range) times five activation values including
-- both +-127 extremes -- 20,480 cases -- each loaded via 'first' one
-- cycle and multiplied the next, checked against A = w1 + w2*2**SPACING,
-- p_out = p_in + A*x computed directly in plain VHDL integers (headroom
-- checked: |A|*|x| never exceeds about 5.2e8, comfortably inside
-- integer's 32-bit range).
--
-- Then spot-checks: weight-load timing (the new pair must NOT be used
-- until the cycle after 'first'), p_in chaining with a nonzero partial
-- sum, ce=0 hold, the x_in->x_out combinational passthrough, and lane0_
-- valid/lane1_valid's documented timing (pulse together, aligned with
-- when p_out reflects a freshly issued MAC).
entity tb_dsp_mac2 is
end entity;

architecture sim of tb_dsp_mac2 is
  constant A_PORT_W : positive := 27;
  constant ACC_W     : positive := 48;
  constant WEIGHT_W  : positive := 6;
  constant SPACING   : positive := 17;

  signal clk     : std_logic := '0';
  signal ce      : std_logic := '0';
  signal first   : std_logic := '0';
  signal w1_next : signed(WEIGHT_W - 1 downto 0) := (others => '0');
  signal w2_next : signed(WEIGHT_W - 1 downto 0) := (others => '0');
  signal x_in    : signed(7 downto 0) := (others => '0');
  signal p_in    : signed(ACC_W - 1 downto 0) := (others => '0');
  signal x_out   : signed(7 downto 0);
  signal p_out   : signed(ACC_W - 1 downto 0);
  signal lane0_valid, lane1_valid : std_logic;

  signal done : boolean := false;
begin

  dut : entity work.dsp_mac2(behav)
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
    port map (
      clk => clk, ce => ce, first => first,
      w1_next => w1_next, w2_next => w2_next,
      x_in => x_in, p_in => p_in, x_out => x_out, p_out => p_out,
      lane0_valid => lane0_valid, lane1_valid => lane1_valid
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails   : integer := 0;
    variable a_word  : integer;
    variable expect  : integer;

    -- Loads (w1,w2) via 'first' for one cycle, then multiplies against x
    -- with the given p_in for the next cycle, checking p_out.
    procedure check_mac(w1, w2, x, pin : integer; tag : string) is
    begin
      w1_next <= to_signed(w1, WEIGHT_W);
      w2_next <= to_signed(w2, WEIGHT_W);
      first   <= '1';
      ce      <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;

      first <= '0';
      ce    <= '1';
      x_in  <= to_signed(x, 8);
      p_in  <= to_signed(pin, ACC_W);
      wait until rising_edge(clk);
      wait for 1 ns;

      a_word := w1 + w2 * (2 ** SPACING);
      expect := pin + a_word * x;
      if to_integer(p_out) /= expect then
        fails := fails + 1;
        report "FAIL " & tag & " w1=" & integer'image(w1) & " w2=" & integer'image(w2) &
               " x=" & integer'image(x) & " pin=" & integer'image(pin) &
               " expect=" & integer'image(expect) & " got=" & integer'image(to_integer(p_out))
               severity error;
      end if;

      ce <= '0';
    end procedure;

  begin
    -- exhaustive: every (w1,w2) in -32..31, x in {-127,-1,0,1,127}, p_in=0
    for w1 in -32 to 31 loop
      for w2 in -32 to 31 loop
        for xi in 0 to 4 loop
          case xi is
            when 0 => check_mac(w1, w2, -127, 0, "exhaustive");
            when 1 => check_mac(w1, w2, -1,   0, "exhaustive");
            when 2 => check_mac(w1, w2,  0,   0, "exhaustive");
            when 3 => check_mac(w1, w2,  1,   0, "exhaustive");
            when others => check_mac(w1, w2, 127, 0, "exhaustive");
          end case;
        end loop;
      end loop;
    end loop;

    -- p_in chaining, nonzero partial sum from "the row above"
    check_mac(31, -32, 127, 1_000_000, "p_in-chain");
    check_mac(-32, 31, -127, -1_000_000, "p_in-chain");
    check_mac(3, -4, 100, 42, "p_in-chain");

    -- weight-load timing: loading a new pair via 'first' must not affect
    -- p_out until the FOLLOWING cycle -- pulsing 'ce' in the very same
    -- cycle as 'first' must still use whatever weight was active before.
    w1_next <= to_signed(5, WEIGHT_W);
    w2_next <= to_signed(5, WEIGHT_W);
    first   <= '1';
    ce      <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    first <= '0';

    -- active weight is now (5,5); load a different pair but pulse ce
    -- in the SAME cycle as first -- p_out must reflect the OLD (5,5)
    -- pair, not the new one being loaded this same cycle.
    w1_next <= to_signed(-10, WEIGHT_W);
    w2_next <= to_signed(-10, WEIGHT_W);
    first   <= '1';
    ce      <= '1';
    x_in    <= to_signed(10, 8);
    p_in    <= to_signed(0, ACC_W);
    wait until rising_edge(clk); wait for 1 ns;
    a_word := 5 + 5 * (2 ** SPACING);
    expect := a_word * 10;
    if to_integer(p_out) /= expect then
      fails := fails + 1;
      report "FAIL weight-load-timing: expected old (5,5) pair to still be active, expect=" &
             integer'image(expect) & " got=" & integer'image(to_integer(p_out)) severity error;
    end if;
    first <= '0';
    ce    <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    -- now the (-10,-10) pair should be active
    ce   <= '1';
    x_in <= to_signed(10, 8);
    p_in <= to_signed(0, ACC_W);
    wait until rising_edge(clk); wait for 1 ns;
    a_word := -10 + (-10) * (2 ** SPACING);
    expect := a_word * 10;
    if to_integer(p_out) /= expect then
      fails := fails + 1;
      report "FAIL weight-load-timing: expected new (-10,-10) pair active one cycle later, expect=" &
             integer'image(expect) & " got=" & integer'image(to_integer(p_out)) severity error;
    end if;
    ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    -- ce=0 hold: p_out must not change even as x_in/p_in vary
    x_in <= to_signed(99, 8);
    p_in <= to_signed(555, ACC_W);
    wait until rising_edge(clk); wait for 1 ns;
    if to_integer(p_out) /= expect then
      fails := fails + 1;
      report "FAIL: p_out changed while ce=0" severity error;
    end if;

    -- x_in -> x_out combinational passthrough, no clock needed
    x_in <= to_signed(-42, 8);
    wait for 1 ns;
    if x_out /= to_signed(-42, 8) then
      fails := fails + 1;
      report "FAIL: x_out did not pass through x_in combinationally" severity error;
    end if;

    -- lane0_valid/lane1_valid: settle at ce=0, then confirm both pulse
    -- together on the same cycle p_out picks up a fresh ce=1 MAC, and
    -- drop again the cycle after.
    ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    wait until rising_edge(clk); wait for 1 ns;
    if lane0_valid /= '0' or lane1_valid /= '0' then
      fails := fails + 1;
      report "FAIL: lane valid should be 0 while ce has been 0" severity error;
    end if;

    ce <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    if lane0_valid /= '1' or lane1_valid /= '1' then
      fails := fails + 1;
      report "FAIL: lane valid should pulse the same cycle p_out updates from ce=1" severity error;
    end if;

    ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    if lane0_valid /= '0' or lane1_valid /= '0' then
      fails := fails + 1;
      report "FAIL: lane valid should drop the cycle after ce returns to 0" severity error;
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
