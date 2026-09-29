library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Integration test for array_seq.vhdl -- the first testbench in this
-- repo to wire array_seq + weight_loader + sys_array together, which
-- is also the ONLY configuration that can exercise two bugs no smaller
-- testbench could: the same-clock-edge weight-swap race (tb_weight_
-- loader tests weight_loader alone; tb_sys_array holds weights steady
-- for a single tile and never swaps mid-run) and the SYSTOLIC per-
-- column weight-bus timing / pipeline-drain requirements documented in
-- array_seq.vhdl's header (MIN_TILE_AGENTS and the DRAIN state) -- both
-- were found BY this testbench (wrong per-column sums, then stuck/
-- duplicated first_out/last_out pulses at the tail of the run), not
-- derived up front and merely confirmed by it.
--
-- Activation is held constant (x_r = r+1) across every agent and every
-- tile -- this testbench's job is proving array_seq's tile-chaining and
-- weight-swap timing, not re-proving per-agent dot products (tb_sys_
-- array already sweeps that). Weights vary PER TILE (and per row/
-- column, like tb_sys_array's w1_of) so a stale or premature swap shows
-- up as a wrong sum, not an accidental pass. tile_agents is set to the
-- tightest legal spacing for THIS DSP_COLUMNS/ACT_DIST combination --
-- ROWS+DSP_COLUMNS under SYSTOLIC, not the flat ROWS=16 the naive
-- reading of 08 S3.3 suggests -- see array_seq.vhdl's header for why.
--
-- Weight preloading (standing in for the not-yet-built wt_reader/
-- unpackers): a process waits for array_seq's own first_in to pulse
-- (the observable "a new tile just started" event) and immediately
-- loads the FOLLOWING tile's weights into weight_loader's now-inactive
-- buffer -- this ties preload timing to array_seq's actual behavior
-- instead of a hand-counted cycle number (CLAUDE.md practice #9's
-- spirit: let the DUT's own signals drive the testbench rather than
-- re-deriving its internal timing by hand).
entity tb_array_seq is
end entity;

architecture sim of tb_array_seq is
  constant A_PORT_W : positive := 27;
  constant ACC_W     : positive := 48;
  constant WEIGHT_W  : positive := 4;
  constant SPACING   : positive := 17;
  constant DSP_COLUMNS : positive := 2;
  constant CNT_W     : positive := 16;
  constant NUM_TILES : positive := 3;
  -- NOT 16 (R): under SYSTOLIC with DSP_COLUMNS>1, column c's row r
  -- latches 'first' at (T0 + r + c) -- r from act_skew's row skew, c
  -- from one extra pe_cell register hop per column-to-column hand-off
  -- (sys_array.vhdl's chain_gen -- col_first_in(c) <= col_first_out(c-1),
  -- and pe_cell's own fl_reg is what adds the +1 per hop). weight_loader
  -- drives one GLOBAL, undelayed w1_next/w2_next bus to every column, so
  -- it must stay stable until the LAST row of the LAST column has
  -- latched. See array_seq.vhdl's header for the full derivation
  -- (MIN_TILE_AGENTS = ROWS + DSP_COLUMNS for SYSTOLIC); this is a real
  -- correction to 08 S3.3's literal "B >= R = 16" claim for THIS
  -- repo's SYSTOLIC+direct-write implementation specifically.
  constant TILE_AGENTS : positive := 16 + DSP_COLUMNS; -- ROWS + DSP_COLUMNS

  constant WBUS_W : positive := DSP_COLUMNS * 16 * WEIGHT_W;

  signal clk : std_logic := '0';
  signal rst : std_logic := '0';
  signal done : boolean := false;

  -- array_seq
  signal start : std_logic := '0';
  signal num_tiles_sig   : std_logic_vector(CNT_W - 1 downto 0);
  signal tile_agents_sig : std_logic_vector(CNT_W - 1 downto 0);
  signal weight_ready : std_logic := '0';
  signal swap : std_logic;
  signal ce, first_in, last_in : std_logic;
  signal busy, seq_done : std_logic;

  -- weight_loader
  signal load_en : std_logic := '0';
  signal w1_load, w2_load : std_logic_vector(WBUS_W - 1 downto 0) := (others => '0');
  signal w1_next, w2_next : std_logic_vector(WBUS_W - 1 downto 0);

  -- sys_array
  signal x_in : std_logic_vector(16 * 8 - 1 downto 0) := (others => '0');
  signal p_out : std_logic_vector(DSP_COLUMNS * ACC_W - 1 downto 0);
  signal col_first_out, col_last_out : std_logic_vector(DSP_COLUMNS - 1 downto 0);

  function w1_of(tile, r, c : integer) return integer is
  begin
    return ((r + 3 * c + 5 * tile) mod 16) - 8; -- WEIGHT_W=4 range
  end function;

  -- shared between the checker process and a function that needs no
  -- process context: precompute expected(tile, c) as a pure function.
  function expected(tile, c : integer) return integer is
    variable acc : integer := 0;
  begin
    for r in 0 to 15 loop
      acc := acc + w1_of(tile, r, c) * (r + 1);
    end loop;
    return acc;
  end function;

begin

  seq : entity work.array_seq
    generic map (CNT_W => CNT_W, MIN_TILE_AGENTS => TILE_AGENTS)
    port map (
      clk => clk, rst => rst,
      start => start, num_tiles => num_tiles_sig, tile_agents => tile_agents_sig,
      weight_ready => weight_ready,
      swap => swap,
      ce => ce, first_in => first_in, last_in => last_in,
      busy => busy, done => seq_done
    );

  wl : entity work.weight_loader
    generic map (DSP_COLUMNS => DSP_COLUMNS, WEIGHT_W => WEIGHT_W)
    port map (
      clk => clk, rst => rst,
      load_en => load_en, w1_load => w1_load, w2_load => w2_load,
      swap => swap,
      w1_next => w1_next, w2_next => w2_next
    );

  arr : entity work.sys_array
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING,
                 DSP_COLUMNS => DSP_COLUMNS, ACT_DIST => "SYSTOLIC")
    port map (
      clk => clk, ce => ce, x_in => x_in, first_in => first_in, last_in => last_in,
      w1_next => w1_next, w2_next => w2_next,
      p_out => p_out, first_out => col_first_out, last_out => col_last_out
    );

  clk <= not clk after 5 ns when not done else '0';

  num_tiles_sig   <= std_logic_vector(to_unsigned(NUM_TILES, CNT_W));
  tile_agents_sig <= std_logic_vector(to_unsigned(TILE_AGENTS, CNT_W));

  -- constant activation vector, x_r = r+1, for every agent of every tile
  gen_x : for r in 0 to 15 generate
    x_in((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(to_signed(r + 1, 8));
  end generate gen_x;

  -- weight preload stimulus: tile 0 before start, tiles 1..NUM_TILES-1
  -- each triggered off the PREVIOUS tile's own first_in pulse.
  stim : process
    procedure preload(tile : in integer) is
    begin
      for c in 0 to DSP_COLUMNS - 1 loop
        for r in 0 to 15 loop
          w1_load(c * 16 * WEIGHT_W + (r + 1) * WEIGHT_W - 1 downto c * 16 * WEIGHT_W + r * WEIGHT_W)
            <= std_logic_vector(to_signed(w1_of(tile, r, c), WEIGHT_W));
        end loop;
      end loop;
      w2_load <= (others => '0');
      load_en <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      load_en <= '0';
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    preload(0);
    weight_ready <= '1';

    start <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    start <= '0';

    for tile in 0 to NUM_TILES - 2 loop
      wait until first_in = '1';
      wait for 1 ns;
      preload(tile + 1);
    end loop;

    wait;
  end process;

  -- checker: watches col_first_out/col_last_out every cycle, tracks a
  -- per-column pulse count, and checks p_out against expected(tile, c)
  -- where tile = pulses_seen/2 (2 pulses -- first then last -- per tile
  -- per column, since x doesn't vary by agent here).
  chk : process
    variable fails : integer := 0;
    variable pulses_seen : integer_vector(0 to DSP_COLUMNS - 1) := (others => 0);
    variable tile_idx : integer;
    variable got : integer;
    variable all_seen : boolean;
  begin
    wait until rising_edge(clk); wait for 1 ns; -- align past reset

    for cyc in 1 to 300 loop
      wait until rising_edge(clk); wait for 1 ns;

      for c in 0 to DSP_COLUMNS - 1 loop
        if (col_first_out(c) = '1' or col_last_out(c) = '1') and pulses_seen(c) < 2 * NUM_TILES then
          tile_idx := pulses_seen(c) / 2;
          got := to_integer(signed(p_out((c + 1) * ACC_W - 1 downto c * ACC_W)));
          if got /= expected(tile_idx, c) then
            fails := fails + 1;
            report "FAIL col=" & integer'image(c) & " tile=" & integer'image(tile_idx) &
                   " pulse#=" & integer'image(pulses_seen(c)) &
                   " expect=" & integer'image(expected(tile_idx, c)) & " got=" & integer'image(got)
                   severity error;
          end if;
          pulses_seen(c) := pulses_seen(c) + 1;
        end if;
      end loop;
    end loop;

    all_seen := true;
    for c in 0 to DSP_COLUMNS - 1 loop
      if pulses_seen(c) /= 2 * NUM_TILES then
        all_seen := false;
        fails := fails + 1;
        report "FAIL col=" & integer'image(c) & ": saw " & integer'image(pulses_seen(c)) &
               " pulses, expected " & integer'image(2 * NUM_TILES) severity error;
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
