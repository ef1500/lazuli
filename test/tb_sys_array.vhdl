library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for sys_array.vhdl, both ACT_DIST values
-- (instantiated side by side, driven by the same stimulus, checked
-- independently -- they finish at different cycles, which is exactly
-- the thing under test).
--
-- Strategy: rather than hand-deriving each mode's exact fill latency
-- (SYSTOLIC's R+DSP_COLUMNS-ish vs TREE's R+TREE_DEPTH-ish -- see
-- sys_array.vhdl's header), drive ONE agent's worth of activation and
-- weights, held steady, pulse first_in/last_in for exactly one cycle
-- (act_skew staggers that pulse out to each row itself), then run for
-- many more cycles than either mode could plausibly need and watch
-- every column's own first_out for when it pulses -- that IS "this
-- column's result is ready," so check p_out(c) at exactly that cycle
-- rather than guessing when to look. Every column must fire exactly
-- once within the run; last_out(c) must pulse on the identical cycle
-- (single-agent test, so first and last are the same agent).
--
-- Weights: w1(r,c) = ((r + 3*c) mod 64) - 32 (sweeps WEIGHT_W=6's full
-- signed range, different per row AND per column so a row/column mixup
-- in sys_array's packing or chaining shows up as a wrong sum, not an
-- accidental pass); w2=0 throughout, since dsp_mac2/pe_cell/pe_column's
-- own testbenches already cover the second packed lane -- this
-- testbench's job is the skew/chain/packing wiring, not re-proving
-- per-cell arithmetic. x_r = r+1.
entity tb_sys_array is
end entity;

architecture sim of tb_sys_array is
  constant A_PORT_W : positive := 27;
  constant ACC_W     : positive := 48;
  constant WEIGHT_W  : positive := 6;
  constant SPACING   : positive := 17;
  constant DSP_COLUMNS : positive := 4;
  constant RUN_CYCLES : positive := 60;

  signal clk, ce : std_logic := '0';
  signal x_in : std_logic_vector(16 * 8 - 1 downto 0) := (others => '0');
  signal first_in, last_in : std_logic := '0';
  signal w1_next, w2_next : std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0) := (others => '0');

  signal sys_p_first, tree_p_first : std_logic_vector(DSP_COLUMNS * ACC_W - 1 downto 0);
  signal sys_first_out, sys_last_out : std_logic_vector(DSP_COLUMNS - 1 downto 0);
  signal tree_first_out, tree_last_out : std_logic_vector(DSP_COLUMNS - 1 downto 0);

  signal done : boolean := false;

  function w1_of(r, c : integer) return integer is
  begin
    return ((r + 3 * c) mod 64) - 32;
  end function;
begin

  dut_systolic : entity work.sys_array
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING,
                 DSP_COLUMNS => DSP_COLUMNS, ACT_DIST => "SYSTOLIC")
    port map (
      clk => clk, ce => ce, x_in => x_in, first_in => first_in, last_in => last_in,
      w1_next => w1_next, w2_next => w2_next,
      p_out => sys_p_first, first_out => sys_first_out, last_out => sys_last_out
    );

  dut_tree : entity work.sys_array
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING,
                 DSP_COLUMNS => DSP_COLUMNS, ACT_DIST => "TREE")
    port map (
      clk => clk, ce => ce, x_in => x_in, first_in => first_in, last_in => last_in,
      w1_next => w1_next, w2_next => w2_next,
      p_out => tree_p_first, first_out => tree_first_out, last_out => tree_last_out
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails  : integer := 0;
    variable expect : integer_vector(0 to DSP_COLUMNS - 1);
    variable sys_seen, tree_seen : std_logic_vector(DSP_COLUMNS - 1 downto 0) := (others => '0');
  begin
    -- weight bus: column c, row r
    for c in 0 to DSP_COLUMNS - 1 loop
      for r in 0 to 15 loop
        w1_next(c * 16 * WEIGHT_W + (r + 1) * WEIGHT_W - 1 downto c * 16 * WEIGHT_W + r * WEIGHT_W)
          <= std_logic_vector(to_signed(w1_of(r, c), WEIGHT_W));
      end loop;
    end loop;
    w2_next <= (others => '0');

    -- activation vector: x_r = r+1
    for r in 0 to 15 loop
      x_in((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(to_signed(r + 1, 8));
    end loop;

    for c in 0 to DSP_COLUMNS - 1 loop
      expect(c) := 0;
      for r in 0 to 15 loop
        expect(c) := expect(c) + w1_of(r, c) * (r + 1);
      end loop;
    end loop;

    first_in <= '1'; last_in <= '1'; ce <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    first_in <= '0'; last_in <= '0';

    for cyc in 1 to RUN_CYCLES loop
      wait until rising_edge(clk); wait for 1 ns;

      for c in 0 to DSP_COLUMNS - 1 loop
        if sys_first_out(c) = '1' and sys_seen(c) = '0' then
          sys_seen(c) := '1';
          if sys_last_out(c) /= '1' then
            fails := fails + 1;
            report "FAIL SYSTOLIC col=" & integer'image(c) & ": first_out fired without last_out" severity error;
          end if;
          if to_integer(signed(sys_p_first((c + 1) * ACC_W - 1 downto c * ACC_W))) /= expect(c) then
            fails := fails + 1;
            report "FAIL SYSTOLIC col=" & integer'image(c) & " cyc=" & integer'image(cyc) &
                   " expect=" & integer'image(expect(c)) &
                   " got=" & integer'image(to_integer(signed(sys_p_first((c + 1) * ACC_W - 1 downto c * ACC_W))))
                   severity error;
          end if;
        end if;

        if tree_first_out(c) = '1' and tree_seen(c) = '0' then
          tree_seen(c) := '1';
          if tree_last_out(c) /= '1' then
            fails := fails + 1;
            report "FAIL TREE col=" & integer'image(c) & ": first_out fired without last_out" severity error;
          end if;
          if to_integer(signed(tree_p_first((c + 1) * ACC_W - 1 downto c * ACC_W))) /= expect(c) then
            fails := fails + 1;
            report "FAIL TREE col=" & integer'image(c) & " cyc=" & integer'image(cyc) &
                   " expect=" & integer'image(expect(c)) &
                   " got=" & integer'image(to_integer(signed(tree_p_first((c + 1) * ACC_W - 1 downto c * ACC_W))))
                   severity error;
          end if;
        end if;
      end loop;
    end loop;

    for c in 0 to DSP_COLUMNS - 1 loop
      if sys_seen(c) = '0' then
        fails := fails + 1;
        report "FAIL SYSTOLIC col=" & integer'image(c) & ": first_out never fired within " &
               integer'image(RUN_CYCLES) & " cycles" severity error;
      end if;
      if tree_seen(c) = '0' then
        fails := fails + 1;
        report "FAIL TREE col=" & integer'image(c) & ": first_out never fired within " &
               integer'image(RUN_CYCLES) & " cycles" severity error;
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
