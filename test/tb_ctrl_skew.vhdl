library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for ctrl_skew.vhdl. N=4 channels with
-- STAGE_LIST=(0,1,2,3) (matching how sys_array would drive it under
-- ACT_DIST=TREE: channel c delayed by c clocks). Each channel gets its
-- OWN distinct first/last pattern (phase-shifted by channel index) so a
-- channel-to-channel wiring mixup would show up as a mismatch, not
-- accidentally pass.
--
-- Same per-iteration timing subtlety as tb_act_skew.vhdl (see its
-- header for the full derivation): this loop presents a new value and
-- checks one edge later, every iteration, so a channel with STAGES=S>=1
-- shows an apparent lag of (S-1) iterations at these check points, not
-- S -- verified against generic_register's capture semantics, not
-- curve-fit. Then checks ce=0 holds every channel with STAGES>=1, and
-- that channel 0 (STAGES=0) is a pure combinational passthrough, same
-- as act_skew's row 0.
entity tb_ctrl_skew is
end entity;

architecture sim of tb_ctrl_skew is
  function obs_lag(stages : natural) return natural is
  begin
    if stages = 0 then
      return 0;
    else
      return stages - 1;
    end if;
  end function;

  constant N : positive := 4;
  constant STAGE_LIST : integer_vector(0 to N - 1) := (0, 1, 2, 3);
  constant NCYC : positive := 16;

  signal clk, ce : std_logic := '0';
  signal first_in, last_in   : std_logic_vector(N - 1 downto 0) := (others => '0');
  signal first_out, last_out : std_logic_vector(N - 1 downto 0);
  signal done : boolean := false;

  type hist_t is array (0 to NCYC - 1, 0 to N - 1) of std_logic;
begin

  dut : entity work.ctrl_skew
    generic map (N => N, STAGE_LIST => STAGE_LIST)
    port map (
      clk => clk, ce => ce,
      first_in => first_in, last_in => last_in,
      first_out => first_out, last_out => last_out
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    variable fhist, lhist : hist_t;
    variable lag : natural;
  begin
    for i in 0 to NCYC - 1 loop
      for c in 0 to N - 1 loop
        if (i + c) mod 2 = 0 then
          first_in(c) <= '1'; fhist(i, c) := '1';
        else
          first_in(c) <= '0'; fhist(i, c) := '0';
        end if;
        if (i + c + 1) mod 2 = 0 then
          last_in(c) <= '1'; lhist(i, c) := '1';
        else
          last_in(c) <= '0'; lhist(i, c) := '0';
        end if;
      end loop;
      ce <= '1';

      wait until rising_edge(clk); wait for 1 ns;

      for c in 0 to N - 1 loop
        lag := obs_lag(STAGE_LIST(c));
        if i >= lag then
          if first_out(c) /= fhist(i - lag, c) or last_out(c) /= lhist(i - lag, c) then
            fails := fails + 1;
            report "FAIL channel=" & integer'image(c) & " cyc=" & integer'image(i) severity error;
          end if;
        end if;
      end loop;
    end loop;

    -- ce=0: channels with STAGES>=1 must hold; channel 0 (STAGES=0) is
    -- combinational and tracks the new input regardless of ce.
    for c in 0 to N - 1 loop
      first_in(c) <= '1'; last_in(c) <= '0';
    end loop;
    ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    if first_out(0) /= '1' or last_out(0) /= '0' then
      fails := fails + 1;
      report "FAIL: channel 0 (STAGES=0) did not track inputs combinationally despite ce=0" severity error;
    end if;
    for c in 1 to N - 1 loop
      lag := obs_lag(STAGE_LIST(c));
      if first_out(c) /= fhist(NCYC - 1 - lag, c) or last_out(c) /= lhist(NCYC - 1 - lag, c) then
        fails := fails + 1;
        report "FAIL: channel " & integer'image(c) & " changed while ce=0" severity error;
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
