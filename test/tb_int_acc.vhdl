library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for int_acc.vhdl: synchronous clear, a
-- 16-group accumulation (matching the rescaler's Q3_K/Q6_K super-block
-- shape, 04 S2.2), hold-while-ce=0, a second clear at the next
-- super-block boundary, and a negative-heavy accumulation to exercise
-- the sign path.
entity tb_int_acc is
end entity;

architecture sim of tb_int_acc is
  constant INW  : positive := 8;
  constant ACCW : positive := 16;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '0';
  signal ce   : std_logic := '0';
  signal d    : signed(INW - 1 downto 0) := (others => '0');
  signal acc  : signed(ACCW - 1 downto 0);
  signal done : boolean := false;
begin

  dut : entity work.int_acc
    generic map (IN_WIDTH => INW, ACC_WIDTH => ACCW)
    port map (clk => clk, rst => rst, ce => ce, d => d, acc => acc);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails  : integer := 0;
    variable expect : integer;
  begin
    -- sync clear
    rst <= '1'; ce <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;
    if to_integer(acc) /= 0 then
      fails := fails + 1;
      report "FAIL: not zero after reset" severity error;
    end if;
    rst <= '0';

    -- accumulate 16 groups
    expect := 0;
    ce <= '1';
    for g in 0 to 15 loop
      d <= to_signed(100 + g, INW);
      wait until rising_edge(clk);
      wait for 1 ns;
      expect := expect + (100 + g);
      if to_integer(acc) /= expect then
        fails := fails + 1;
        report "FAIL accumulate g=" & integer'image(g) & " expect=" & integer'image(expect) &
               " got=" & integer'image(to_integer(acc)) severity error;
      end if;
    end loop;

    -- ce=0 must hold
    ce <= '0';
    d <= to_signed(-77, INW);
    wait until rising_edge(clk);
    wait for 1 ns;
    if to_integer(acc) /= expect then
      fails := fails + 1;
      report "FAIL: acc changed while ce=0" severity error;
    end if;

    -- clear at the next super-block start
    rst <= '1'; ce <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;
    if to_integer(acc) /= 0 then
      fails := fails + 1;
      report "FAIL: not zero after second reset" severity error;
    end if;
    rst <= '0';

    -- negative-heavy accumulation, to exercise the sign path
    expect := 0;
    ce <= '1';
    for g in 0 to 15 loop
      d <= to_signed(-100 - g, INW);
      wait until rising_edge(clk);
      wait for 1 ns;
      expect := expect + (-100 - g);
      if to_integer(acc) /= expect then
        fails := fails + 1;
        report "FAIL negative accumulate g=" & integer'image(g) & " expect=" & integer'image(expect) &
               " got=" & integer'image(to_integer(acc)) severity error;
      end if;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
