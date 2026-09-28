library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking smoke test for generic_vector_unit.vhdl: confirms opcode
-- routing (ALU_ADD/ALU_MUL/ALU_MAX go through the embedded generic_fpu,
-- ALU_LUT goes through the embedded generic_lookup) and the unit's fixed
-- 2-cycle latency. The underlying arithmetic is already exhaustively
-- verified by tb_generic_fpu.vhdl/tb_generic_lookup.vhdl, so this only
-- needs to prove the wiring, not re-derive numeric correctness.
entity tb_generic_vector_unit is
end entity;

architecture sim of tb_generic_vector_unit is
  signal clk : std_logic := '0';
  signal ce  : std_logic := '1';
  signal op  : alu_op_t := ALU_ADD;
  signal sub : std_logic_vector(2 downto 0) := "000";
  signal cvt : cvt_op_t := CVT_I2F;
  signal lut_slot : unsigned(2 downto 0) := "000";
  signal a, b : std_logic_vector(31 downto 0) := (others => '0');
  signal y : std_logic_vector(31 downto 0);
  signal flag : std_logic_vector(1 downto 0);

  signal ld_en, ld_we : std_logic := '0';
  signal ld_slot : unsigned(2 downto 0) := "000";
  signal ld_mode : tab_mode_t := TAB_FRAC;
  signal ld_lo, ld_hi : std_logic_vector(31 downto 0) := (others => '0');
  signal ld_left, ld_right : tab_edge_t := EDGE_CLAMP;
  signal ld_bits : unsigned(3 downto 0) := to_unsigned(1, 4);
  signal ld_addr : unsigned(9 downto 0) := (others => '0');
  signal ld_value, ld_slope : std_logic_vector(31 downto 0) := (others => '0');

  signal done : boolean := false;
  constant ONE : std_logic_vector(31 downto 0) := x"3F800000";
  constant TWO : std_logic_vector(31 downto 0) := x"40000000";
  constant THREE : std_logic_vector(31 downto 0) := x"40400000";
  constant SIX : std_logic_vector(31 downto 0) := x"40C00000";
begin

  dut: entity work.generic_vector_unit
    port map (
      clk => clk, ce => ce, op => op, sub => sub, cvt => cvt, lut_slot => lut_slot,
      a => a, b => b, y => y, flag => flag,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode, ld_lo => ld_lo, ld_hi => ld_hi,
      ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    procedure check(got, expect : std_logic_vector(31 downto 0); msg : string) is
    begin
      if got /= expect then
        fails := fails + 1;
        report "FAIL " & msg & " expect=" & to_hstring(expect) & " got=" & to_hstring(got) severity error;
      end if;
    end procedure;
  begin
    wait until clk = '1';

    -- trivial exp2 table (slot 0, 2 entries) for the ALU_LUT check
    ld_slot <= "000"; ld_mode <= TAB_FRAC; ld_bits <= to_unsigned(1,4);
    ld_left <= EDGE_CLAMP; ld_right <= EDGE_CLAMP; ld_lo <= (others=>'0'); ld_hi <= (others=>'0');
    ld_en <= '1';
    wait until rising_edge(clk);
    ld_en <= '0';
    ld_addr <= "0000000000"; ld_value <= x"3F800000"; ld_slope <= x"3F3504F3"; ld_we <= '1'; -- T[0]=1.0
    wait until rising_edge(clk);
    ld_addr <= "0000000001"; ld_value <= x"3FB504F3"; ld_slope <= x"3F3504F3"; ld_we <= '1'; -- T[1]=2^0.5
    wait until rising_edge(clk);
    ld_we <= '0';
    wait until rising_edge(clk);

    -- ALU_ADD: 2 + 3 = 5, 2-cycle latency
    op <= ALU_ADD; a <= TWO; b <= THREE;
    wait until rising_edge(clk); wait until rising_edge(clk); wait for 1 ns;
    check(y, x"40A00000", "add 2+3=5");

    -- ALU_MUL: 2*3 = 6
    op <= ALU_MUL; a <= TWO; b <= THREE;
    wait until rising_edge(clk); wait until rising_edge(clk); wait for 1 ns;
    check(y, SIX, "mul 2*3=6");

    -- ALU_LUT: exp2(0) = 1.0 via slot 0
    op <= ALU_LUT; lut_slot <= "000"; a <= (others=>'0');
    wait until rising_edge(clk); wait until rising_edge(clk); wait for 1 ns;
    check(y, ONE, "lut exp2(0)=1");

    -- back to ALU_MAX: max(2,3)=3
    op <= ALU_MAX; a <= TWO; b <= THREE;
    wait until rising_edge(clk); wait until rising_edge(clk); wait for 1 ns;
    check(y, THREE, "max(2,3)=3");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
