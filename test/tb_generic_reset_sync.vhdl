library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_generic_reset_sync is
end entity;

architecture sim of tb_generic_reset_sync is
  signal clk : std_logic := '0';
  signal arst_in : std_logic := '1';
  signal rst_out : std_logic;
  signal done : boolean := false;
begin
  dut: entity work.generic_reset_sync generic map (STAGES=>2) port map (clk=>clk, arst_in=>arst_in, rst_out=>rst_out);
  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
  begin
    -- async assert should be visible almost immediately, no clock needed
    wait for 1 ns;
    if rst_out /= '1' then
      fails := fails + 1;
      report "FAIL: rst_out should assert immediately (async)" severity error;
    end if;

    wait until rising_edge(clk);
    wait until rising_edge(clk);
    wait for 1 ns;
    if rst_out /= '1' then
      fails := fails + 1;
      report "FAIL: rst_out should still be asserted while arst_in='1'" severity error;
    end if;

    -- release arst_in; rst_out must stay asserted for STAGES clean
    -- clock edges before dropping
    wait until falling_edge(clk); -- release mid-cycle, away from any edge
    arst_in <= '0';

    wait until rising_edge(clk); -- 1st clean edge
    wait for 1 ns;
    if rst_out /= '1' then
      fails := fails + 1;
      report "FAIL: rst_out dropped too early (after only 1 clean edge, STAGES=2)" severity error;
    end if;

    wait until rising_edge(clk); -- 2nd clean edge
    wait for 1 ns;
    if rst_out /= '0' then
      fails := fails + 1;
      report "FAIL: rst_out should have released after 2 clean edges" severity error;
    end if;

    -- assert again asynchronously mid-cycle, confirm it's immediate again
    wait until falling_edge(clk);
    arst_in <= '1';
    wait for 1 ns;
    if rst_out /= '1' then
      fails := fails + 1;
      report "FAIL: re-assert should be immediate (async), not wait for a clock edge" severity error;
    end if;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
