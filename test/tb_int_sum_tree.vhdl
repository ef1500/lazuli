library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for int_sum_tree.vhdl. Exhaustively checks
-- N=4 (a power of two, exercises int_sum_tree_core directly) and N=3
-- (not a power of two, exercises the pad-with-zero wrapper) at WIDTH=4,
-- every possible combination of element values -- including the
-- exact-boundary case (all four elements at the most-negative value,
-- whose sum lands exactly on the output width's minimum representable
-- value). Then spot-checks a wider tree (N=16) with hand-picked extreme
-- patterns, since exhaustive coverage there (16^16 combinations) isn't
-- feasible.
entity tb_int_sum_tree is
end entity;

architecture sim of tb_int_sum_tree is
  constant W4 : positive := 4;

  signal d4   : std_logic_vector(4 * W4 - 1 downto 0);
  signal sum4 : signed(W4 + clog2(4) - 1 downto 0);

  signal d3   : std_logic_vector(3 * W4 - 1 downto 0);
  signal sum3 : signed(W4 + clog2(3) - 1 downto 0);

  constant N16 : positive := 16;
  signal d16    : std_logic_vector(N16 * 8 - 1 downto 0);
  signal sum16  : signed(8 + clog2(N16) - 1 downto 0);
begin

  dut4 : entity work.int_sum_tree
    generic map (WIDTH => W4, N => 4)
    port map (d => d4, sum => sum4);

  dut3 : entity work.int_sum_tree
    generic map (WIDTH => W4, N => 3)
    port map (d => d3, sum => sum3);

  dut16 : entity work.int_sum_tree
    generic map (WIDTH => 8, N => N16)
    port map (d => d16, sum => sum16);

  process
    variable fails  : integer := 0;
    variable expect : integer;
  begin
    -- N=4, WIDTH=4: exhaustive over every (a,b,c,e) in -8..7
    for a in -8 to 7 loop
      for b in -8 to 7 loop
        for c in -8 to 7 loop
          for e in -8 to 7 loop
            d4 <= std_logic_vector(to_signed(e, W4)) & std_logic_vector(to_signed(c, W4)) &
                  std_logic_vector(to_signed(b, W4)) & std_logic_vector(to_signed(a, W4));
            wait for 1 ns;
            expect := a + b + c + e;
            if to_integer(sum4) /= expect then
              fails := fails + 1;
              report "FAIL N=4 a=" & integer'image(a) & " b=" & integer'image(b) &
                     " c=" & integer'image(c) & " e=" & integer'image(e) &
                     " expect=" & integer'image(expect) & " got=" & integer'image(to_integer(sum4))
                     severity error;
            end if;
          end loop;
        end loop;
      end loop;
    end loop;

    -- N=3, WIDTH=4: exhaustive over every (a,b,c) in -8..7
    for a in -8 to 7 loop
      for b in -8 to 7 loop
        for c in -8 to 7 loop
          d3 <= std_logic_vector(to_signed(c, W4)) &
                std_logic_vector(to_signed(b, W4)) & std_logic_vector(to_signed(a, W4));
          wait for 1 ns;
          expect := a + b + c;
          if to_integer(sum3) /= expect then
            fails := fails + 1;
            report "FAIL N=3 a=" & integer'image(a) & " b=" & integer'image(b) &
                   " c=" & integer'image(c) &
                   " expect=" & integer'image(expect) & " got=" & integer'image(to_integer(sum3))
                   severity error;
          end if;
        end loop;
      end loop;
    end loop;

    -- N=16, WIDTH=8: hand-picked extreme patterns
    for pat in 0 to 3 loop
      expect := 0;
      for i in 0 to N16 - 1 loop
        case pat is
          when 0 =>
            d16((i + 1) * 8 - 1 downto i * 8) <= std_logic_vector(to_signed(127, 8));
            expect := expect + 127;
          when 1 =>
            d16((i + 1) * 8 - 1 downto i * 8) <= std_logic_vector(to_signed(-128, 8));
            expect := expect + (-128);
          when 2 =>
            if i mod 2 = 0 then
              d16((i + 1) * 8 - 1 downto i * 8) <= std_logic_vector(to_signed(127, 8));
              expect := expect + 127;
            else
              d16((i + 1) * 8 - 1 downto i * 8) <= std_logic_vector(to_signed(-128, 8));
              expect := expect + (-128);
            end if;
          when others =>
            d16((i + 1) * 8 - 1 downto i * 8) <= std_logic_vector(to_signed(0, 8));
            expect := expect + 0;
        end case;
      end loop;
      wait for 1 ns;
      if to_integer(sum16) /= expect then
        fails := fails + 1;
        report "FAIL N=16 pat=" & integer'image(pat) &
               " expect=" & integer'image(expect) & " got=" & integer'image(to_integer(sum16)) severity error;
      end if;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;

end architecture sim;
