library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for wt_pack.vhdl. Exhaustive over every
-- (q1, q2) pair at WEIGHT_W=4 -- small enough to cover the full signed
-- range of both lanes, checking the packed word against the same
-- formula dsp_mac2.vhdl's a_word uses.
entity tb_wt_pack is
end entity;

architecture sim of tb_wt_pack is
  constant WEIGHT_W : positive := 4;
  constant SPACING  : positive := 6;
  constant OUT_W    : positive := 12;

  signal q1, q2 : signed(WEIGHT_W - 1 downto 0);
  signal y      : signed(OUT_W - 1 downto 0);
begin

  dut : entity work.wt_pack
    generic map (WEIGHT_W => WEIGHT_W, SPACING => SPACING, OUT_W => OUT_W)
    port map (q1 => q1, q2 => q2, y => y);

  process
    variable fails  : integer := 0;
    variable expect : integer;
  begin
    for a in -8 to 7 loop
      for b in -8 to 7 loop
        q1 <= to_signed(a, WEIGHT_W);
        q2 <= to_signed(b, WEIGHT_W);
        wait for 1 ns;
        expect := a + b * (2 ** SPACING);
        if to_integer(y) /= expect then
          fails := fails + 1;
          report "FAIL q1=" & integer'image(a) & " q2=" & integer'image(b) &
                 " expect=" & integer'image(expect) & " got=" & integer'image(to_integer(y)) severity error;
        end if;
      end loop;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;

end architecture sim;
