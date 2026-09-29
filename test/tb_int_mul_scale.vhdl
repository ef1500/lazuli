library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for int_mul_scale.vhdl. Exhaustive over every
-- (lane_sum, group_scale) pair at LANE_WIDTH=6 (-32..31), SCALE_WIDTH=4
-- (-8..7) -- small enough to cover every input combination, including
-- both operands' full signed range (group_scale became signed after
-- this entity's header found Q6_K's group scale is genuinely signed,
-- not just non-negative like Q3_K/Q4_K's).
entity tb_int_mul_scale is
end entity;

architecture sim of tb_int_mul_scale is
  constant LW : positive := 6;
  constant SW : positive := 4;

  signal clk         : std_logic := '0';
  signal ce          : std_logic := '0';
  signal lane_sum    : signed(LW - 1 downto 0) := (others => '0');
  signal group_scale : signed(SW - 1 downto 0) := (others => '0');
  signal p           : signed(LW + SW - 1 downto 0);
  signal done        : boolean := false;
begin

  dut : entity work.int_mul_scale
    generic map (LANE_WIDTH => LW, SCALE_WIDTH => SW)
    port map (clk => clk, ce => ce, lane_sum => lane_sum, group_scale => group_scale, p => p);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails  : integer := 0;
    variable expect : integer;
  begin
    ce <= '1';

    for ls in -32 to 31 loop
      for sc in -8 to 7 loop
        lane_sum    <= to_signed(ls, LW);
        group_scale <= to_signed(sc, SW);
        wait until rising_edge(clk);
        wait for 1 ns;
        expect := ls * sc;
        if to_integer(p) /= expect then
          fails := fails + 1;
          report "FAIL ls=" & integer'image(ls) & " sc=" & integer'image(sc) &
                 " expect=" & integer'image(expect) & " got=" & integer'image(to_integer(p)) severity error;
        end if;
      end loop;
    end loop;

    -- ce=0 must hold the last registered value (ls=31, sc=7 from the loop above)
    ce <= '0';
    lane_sum    <= to_signed(5, LW);
    group_scale <= to_signed(-5, SW);
    wait until rising_edge(clk);
    wait for 1 ns;
    if to_integer(p) /= 31 * 7 then
      fails := fails + 1;
      report "FAIL: p changed while ce=0" severity error;
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
