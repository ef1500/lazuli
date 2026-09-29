library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for attn_finish.vhdl. DIM=4 -- small enough to
-- hand-run both the normalize (o_acc * recip(l)) and the internal act_
-- quantizer's own abs-max -> recip -> requantize pass. Uses CLAUDE.md
-- practice #17's degenerate mock TAB_MANT table ({value=1.0, slope=0}
-- in every entry, y = 2**-(unbiased exponent) for ANY input) at
-- RECIP_SLOT=0 -- shared by attn_finish's own recip(l) call AND the
-- internal act_quantizer's two recip calls, all from the SAME ld_* load
-- (see attn_finish.vhdl's header on why one shared table load suffices).
--
-- Every value below is chosen as an exact power of two so the
-- degenerate table's "2**-e" collapse happens to equal the TRUE
-- reciprocal too (exact only because of that choice, not in general --
-- see generic_lookup.vhdl's own accuracy tests for the real table).
-- l=2.0 -> recip(l)=0.5 exactly. o_acc=[8,-8,4,2] -> o_norm=[4,-4,2,1].
-- Requantizing [4,-4,2,1]: amax=4.0 -> inv_scale=recip(4.0)*127=31.75 --
-- recip(4.0)=0.25 is exact (4.0 is a power of two) but 31.75 itself is
-- NOT, so scale=recip(31.75) via the degenerate table lands on
-- 2**-4=0.0625 (1/16), not variable 31.75's true reciprocal (~0.0315) --
-- still an EXACT, hand-computable result per practice #17, just not an
-- accurate one (generic_lookup's own accuracy is covered elsewhere).
-- q_i = round(x_i * 31.75), clamped +-127: 4.0->127, -4.0->-127,
-- 2.0->round(63.5)=64 (round-to-even, exactly halfway), 1.0->round(31.75)=32.
entity tb_attn_finish is
end entity;

architecture sim of tb_attn_finish is
  constant DIM : positive := 4;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  signal start : std_logic := '0';
  signal l_in : std_logic_vector(31 downto 0) := (others => '0');
  signal o_acc_in : std_logic_vector(DIM * 32 - 1 downto 0) := (others => '0');

  signal busy, done : std_logic;
  signal q_out : std_logic_vector(DIM * 8 - 1 downto 0);
  signal scale_out : std_logic_vector(31 downto 0);

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

  dut : entity work.attn_finish
    generic map (DIM => DIM, RECIP_SLOT => 0)
    port map (
      clk => clk, rst => rst, start => start, l_in => l_in, o_acc_in => o_acc_in,
      busy => busy, done => done, q_out => q_out, scale_out => scale_out,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        fails := fails + 1;
        report "FAIL: " & msg severity error;
      end if;
    end procedure;

    procedure check_q(d : natural; expect : integer; msg : string) is
      variable got : integer;
    begin
      got := to_integer(signed(q_out((d + 1) * 8 - 1 downto d * 8)));
      check(got = expect, msg & " (got " & integer'image(got) & ", expected " & integer'image(expect) & ")");
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- load the degenerate 2-entry recip table into slot 0
    ld_slot <= to_unsigned(0, 3);
    ld_mode <= TAB_MANT;
    ld_bits <= to_unsigned(1, 4);
    ld_en   <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ld_en <= '0';

    ld_slot  <= to_unsigned(0, 3);
    ld_addr  <= to_unsigned(0, 10);
    ld_value <= ONE_FP32; ld_slope <= (others => '0'); ld_we <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ld_addr <= to_unsigned(1, 10);
    wait until rising_edge(clk); wait for 1 ns;
    ld_we <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    l_in <= x"40000000"; -- 2.0
    o_acc_in <= x"40000000" & x"40800000" & x"C1000000" & x"41000000"; -- [8,-8,4,2] (d0=8.0 lowest)
    start <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    start <= '0';

    loop
      wait until rising_edge(clk); wait for 1 ns;
      exit when done = '1';
    end loop;

    check(scale_out = x"3D800000", "scale_out mismatch (got 0x" & to_hstring(scale_out) & ", expected 0x3D800000)");
    check_q(0, 127,  "q_out[0] (from o_norm=4.0)");
    check_q(1, -127, "q_out[1] (from o_norm=-4.0)");
    check_q(2, 64,   "q_out[2] (from o_norm=2.0, round-to-even at .5)");
    check_q(3, 32,   "q_out[3] (from o_norm=1.0)");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
