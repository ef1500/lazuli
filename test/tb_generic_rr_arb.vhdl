library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity tb_generic_rr_arb is
end entity;

architecture sim of tb_generic_rr_arb is
  constant N : positive := 4;
  signal clk, rst : std_logic := '0';
  signal req : std_logic_vector(N-1 downto 0) := (others=>'0');
  signal advance : std_logic := '1';
  signal grant : std_logic_vector(N-1 downto 0);
  signal grant_idx : unsigned(clog2(N)-1 downto 0);
  signal valid : std_logic;
  signal done : boolean := false;
begin
  dut: entity work.generic_rr_arb generic map (N=>N)
    port map (clk=>clk, rst=>rst, req=>req, advance=>advance, grant=>grant, grant_idx=>grant_idx, valid=>valid);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    procedure check(exp_idx : integer; exp_valid : std_logic) is
    begin
      wait for 1 ns;
      if valid /= exp_valid or (exp_valid='1' and to_integer(grant_idx) /= exp_idx) then
        fails := fails + 1;
        report "FAIL expect idx=" & integer'image(exp_idx) & " valid=" & std_logic'image(exp_valid) &
               " got idx=" & integer'image(to_integer(grant_idx)) & " valid=" & std_logic'image(valid) severity error;
      end if;
    end procedure;
  begin
    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk); rst <= '0';
    wait until rising_edge(clk);

    -- all four requesting: last_grant resets to 0 (read as "0 was
    -- already serviced" -- see generic_rr_arb.vhdl's header), so the
    -- first grant is 1, then round-robin 2,3,0,1,...
    req <= "1111";
    check(1, '1');
    wait until rising_edge(clk); check(2, '1');
    wait until rising_edge(clk); check(3, '1');
    wait until rising_edge(clk); check(0, '1');
    wait until rising_edge(clk); check(1, '1'); -- wrapped back around

    -- no requests: valid should drop
    wait until rising_edge(clk);
    req <= "0000";
    check(0, '0'); -- idx don't-care when invalid, but function signature needs an exp

    -- only requester 2 asking now: should always grant 2 regardless of last_grant
    wait until rising_edge(clk);
    req <= "0100";
    check(2, '1');
    wait until rising_edge(clk); check(2, '1');

    -- now 0 and 3 both request; last_grant is 2, so priority order after
    -- 2 is 3,0,1,2 -- expect 3 granted first, then (after advancing) 0
    wait until rising_edge(clk);
    req <= "1001";
    check(3, '1');
    wait until rising_edge(clk); check(0, '1');

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
