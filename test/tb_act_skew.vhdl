library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for act_skew.vhdl. ROWS=4 (small, so the
-- whole skew depth is exercised quickly): drives a distinct, counting
-- value into every row's lane each cycle (all ROWS lanes get the SAME
-- value that cycle, matching how sys_array's activation bus actually
-- presents one full vector simultaneously) along with a toggling first/
-- last pattern, and checks that row r's output correctly reflects
-- exactly r real clocks of delay.
--
-- The naive per-iteration comparison ("row r's output at iteration i
-- should equal what was presented at iteration i-r") is off by one for
-- every row with STAGES>=1, NOT a DUT bug: this loop sets a new input
-- value, then waits for exactly one edge before checking, every
-- iteration -- so a fresh value is already stable well before "its"
-- edge, and row r's FIRST register captures it at that very edge (same
-- iteration), with each additional stage adding one more edge of lag
-- relative to that. Net effect: a row with STAGES=S>=1 shows an
-- apparent lag of (S-1) iterations at this loop's own per-edge check
-- points, not S (S=0 -- the row-0 combinational passthrough -- is the
-- one case with no extra register to introduce that off-by-one, hence
-- 0). Verified by hand against generic_register's capture semantics
-- before trusting it here, not just curve-fit to make the numbers work.
entity tb_act_skew is
end entity;

architecture sim of tb_act_skew is
  -- Effective observed lag, in this testbench's own iterations, for a
  -- row with the given STAGES count -- see the header comment above.
  function obs_lag(stages : natural) return natural is
  begin
    if stages = 0 then
      return 0;
    else
      return stages - 1;
    end if;
  end function;

  constant ROWS : positive := 4;
  constant NCYC : positive := 20;

  signal clk, ce : std_logic := '0';
  signal x_in    : std_logic_vector(ROWS * 8 - 1 downto 0) := (others => '0');
  signal first_in, last_in : std_logic := '0';
  signal x_out      : std_logic_vector(ROWS * 8 - 1 downto 0);
  signal first_out, last_out : std_logic_vector(ROWS - 1 downto 0);
  signal done : boolean := false;

  type hist_int_t is array (0 to NCYC - 1) of integer;
  type hist_bit_t is array (0 to NCYC - 1) of std_logic;
begin

  dut : entity work.act_skew
    generic map (ROWS => ROWS)
    port map (
      clk => clk, ce => ce, x_in => x_in, first_in => first_in, last_in => last_in,
      x_out => x_out, first_out => first_out, last_out => last_out
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    variable xhist : hist_int_t;
    variable fhist, lhist : hist_bit_t;
    variable lag : natural;
  begin
    for i in 0 to NCYC - 1 loop
      for r in 0 to ROWS - 1 loop
        x_in((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(to_signed(i, 8));
      end loop;
      if i mod 2 = 0 then first_in <= '1'; else first_in <= '0'; end if;
      if (i + 1) mod 2 = 0 then last_in <= '1'; else last_in <= '0'; end if;
      ce <= '1';

      xhist(i) := i;
      if i mod 2 = 0 then fhist(i) := '1'; else fhist(i) := '0'; end if;
      if (i + 1) mod 2 = 0 then lhist(i) := '1'; else lhist(i) := '0'; end if;

      wait until rising_edge(clk); wait for 1 ns;

      for r in 0 to ROWS - 1 loop
        lag := obs_lag(r);
        if i >= lag then
          if to_integer(signed(x_out((r + 1) * 8 - 1 downto r * 8))) /= xhist(i - lag) then
            fails := fails + 1;
            report "FAIL x row=" & integer'image(r) & " cyc=" & integer'image(i) &
                   " expect=" & integer'image(xhist(i - lag)) &
                   " got=" & integer'image(to_integer(signed(x_out((r + 1) * 8 - 1 downto r * 8))))
                   severity error;
          end if;
          if first_out(r) /= fhist(i - lag) or last_out(r) /= lhist(i - lag) then
            fails := fails + 1;
            report "FAIL flags row=" & integer'image(r) & " cyc=" & integer'image(i) severity error;
          end if;
        end if;
      end loop;
    end loop;

    -- ce=0: rows 1..ROWS-1 (the ones with a real register, STAGES>=1)
    -- must hold, even as x_in/first_in/last_in change. Row 0 has
    -- STAGES=0 -- a pure combinational passthrough with no register to
    -- gate -- so it is NOT expected to hold; it must track the new
    -- input immediately regardless of ce.
    for r in 0 to ROWS - 1 loop
      x_in((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(to_signed(99, 8));
    end loop;
    first_in <= '1'; last_in <= '1'; ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    if to_integer(signed(x_out(7 downto 0))) /= 99 or first_out(0) /= '1' or last_out(0) /= '1' then
      fails := fails + 1;
      report "FAIL: row 0 (STAGES=0) did not track x_in combinationally despite ce=0" severity error;
    end if;
    for r in 1 to ROWS - 1 loop
      lag := obs_lag(r);
      if to_integer(signed(x_out((r + 1) * 8 - 1 downto r * 8))) /= xhist(NCYC - 1 - lag) then
        fails := fails + 1;
        report "FAIL: row " & integer'image(r) & " changed while ce=0" severity error;
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
