library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use work.project_types.all;
use work.fpu_vectors.all;

-- Self-checking testbench for generic_fpu.vhdl: drives every case in
-- fpu_vectors.vhdl (bit-exact IEEE-754 reference values computed in
-- Python -- see test/gen/gen_fpu_vectors.py) and checks the result bit
-- for bit. Covers ADD/SUB (via the sub flags), MUL, MAX, and all four
-- CVT conversions, including overflow/saturation and round-to-nearest-
-- even tie cases.
entity tb_generic_fpu is
end entity;

architecture sim of tb_generic_fpu is
  signal clk  : std_logic := '0';
  signal ce   : std_logic := '1';
  signal op   : alu_op_t;
  signal sub  : std_logic_vector(2 downto 0) := "000";
  signal cvt  : cvt_op_t;
  signal a, b : std_logic_vector(31 downto 0);
  signal y    : std_logic_vector(31 downto 0);
  signal flag : std_logic_vector(1 downto 0);
  signal done : boolean := false;
begin

  dut: entity work.generic_fpu
    port map (clk => clk, ce => ce, op => op, sub => sub, cvt => cvt,
               a => a, b => b, y => y, flag => flag);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
  begin
    wait until clk = '1';
    for i in VECTORS'range loop
      op  <= VECTORS(i).op;
      cvt <= VECTORS(i).cvt;
      a   <= VECTORS(i).a;
      b   <= VECTORS(i).b;
      wait until rising_edge(clk);
      wait for 1 ns; -- let the registered output settle
      if y /= VECTORS(i).expect then
        fails := fails + 1;
        report "FAIL case " & integer'image(i) &
               " op=" & alu_op_t'image(VECTORS(i).op) &
               " cvt=" & cvt_op_t'image(VECTORS(i).cvt) &
               " a=" & to_hstring(VECTORS(i).a) &
               " b=" & to_hstring(VECTORS(i).b) &
               " expect=" & to_hstring(VECTORS(i).expect) &
               " got=" & to_hstring(y)
          severity error;
      end if;
    end loop;
    report "generic_fpu: " & integer'image(VECTORS'length - fails) & " / " &
           integer'image(VECTORS'length) & " passed";
    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
