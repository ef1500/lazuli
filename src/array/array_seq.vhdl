library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- The array's control sequencer (syseng_docs/04-vhdl-module-list.md's
-- U9 entry: "counts the clocks per tile, chains one tile into the
-- next, handles matrix edges"; syseng_docs/08-vhdl-implementation-spec.
-- md S3.3's "B" -- activation vectors streamed per tile). Drives
-- weight_loader's 'swap' and sys_array's 'ce'/'first_in'/'last_in' from
-- two counters (which tile, which agent within it) loaded once per run
-- via 'start'.
--
-- Division of labor [D]: weight_loader owns only the weight ping-pong
-- buffer (swap in/w1_next+w2_next out); sys_array owns only the
-- systolic/tree wiring and internal skew. ALL of the sequencing --
-- when to swap, when a tile's activation burst starts/ends, when the
-- whole run is done -- lives here, matching this entity's own job
-- description above and keeping each of the other two entities'
-- responsibilities free of counters they'd otherwise have to duplicate
-- or get wrong (see weight_loader.vhdl's header for the earlier,
-- rejected attempt at putting flag-generation there instead).
--
-- Timing contract with weight_loader -- THE reason this entity exists
-- as a real state machine and not a free-running counter [V by
-- simulation, not just derived by hand -- see tb_array_seq.vhdl and the
-- uncommitted scratch testbench that first caught this]: 'swap' must
-- NOT ride the same clock cycle as 'first_in' for the tile it just
-- swapped in. weight_loader's active-buffer register and dsp_mac2's
-- own w1_active register (which 'first_in' ultimately triggers, via
-- sys_array's act_skew and pe_cell's pass-through) are separate
-- registers on the identical clock edge with only a combinational mux
-- between them -- standard same-edge peer-register semantics mean
-- dsp_mac2 would latch the OUTGOING tile's weight, not the incoming
-- one, if 'first_in' asserted on swap's own cycle. This entity's state
-- machine naturally provides the needed one-cycle gap for free: 'swap'
-- is asserted combinationally DURING the state (WAIT_SWAP, or RUN at a
-- tile boundary) that precedes the state transition, and 'first_in' is
-- asserted combinationally only after that transition has landed (agent
-- _cnt = 0 in RUN) -- i.e. exactly one registered cycle later, with no
-- extra delay logic needed beyond the state register that already has
-- to exist.
--
-- Timeline for one tile boundary (B = tile_agents):
--   cycle T   : RUN, agent_cnt = B-1 (this tile's LAST agent; ce=1,
--               last_in=1). weight_ready=1, so swap=1 THIS cycle too --
--               concurrent with, not conflicting with, the outgoing
--               tile's own last agent (swap and ce/first_in/last_in are
--               independent ports; nothing about presenting the last
--               agent depends on the weight bus).
--   cycle T+1 : RUN, agent_cnt wraps to 0 (the NEW tile's first agent;
--               ce=1, first_in=1). weight_loader's w1_next/w2_next have
--               been stable since right after cycle T's edge -- a full
--               cycle -- so dsp_mac2 safely latches the correct,
--               incoming tile's weight when first_in reaches it.
-- Zero bubble: ce stays high across the boundary (T and T+1 are
-- consecutive activation-vector cycles).
--
-- MIN_TILE_AGENTS -- NOT simply ROWS=16 [D, correcting 08 S3.3's literal
-- "direct-write needs only B >= R" for THIS repo's actual SYSTOLIC
-- implementation]: 08 S3.3's B >= R minimum assumes the weight bus only
-- needs to stay stable across ROW skew. But sys_array's SYSTOLIC chain
-- (chain_gen in sys_array.vhdl) feeds column c's first_in from column
-- (c-1)'s own first_out -- which is pe_cell's REGISTERED fl_reg output,
-- one MORE clock per column hop -- while w1_next/w2_next (weight_loader,
-- direct-write) is ONE GLOBAL, UNDELAYED bus read identically by every
-- column's dsp_mac2 the instant its own 'first' arrives. So column c's
-- row r latches its weight at (source cycle) + r + c, not just + r --
-- confirmed by an integration test (tb_array_seq.vhdl) that failed with
-- far columns reading a STALE, already-swapped-away tile's weight at
-- B=16, and passed once B was widened. The bus must stay stable until
-- the LAST row of the LAST column has latched: + (ROWS-1) + (DSP_
-- COLUMNS-1), plus ctrl_skew's own uniform +1 stage on top of that
-- (needed for the drain requirement below, and harmless slack for the
-- weight-latch requirement, which alone would need one cycle less) --
-- i.e. the caller must pass MIN_TILE_AGENTS = ROWS + DSP_COLUMNS for
-- SYSTOLIC (16 + DSP_COLUMNS), NOT the bare ROWS=16 the spec text alone
-- suggests. TREE mode's own minimum was not derived or tested here
-- (every column gets the same broadcast, so it may not need this
-- correction at all -- see sys_array.vhdl's TREE notes) -- a caller
-- using TREE must work out and pass its own correct value; this
-- entity's default (16) is deliberately just ROWS, matching only the
-- DSP_COLUMNS=1 / no-cross-column-chaining case, so an un-updated
-- caller under SYSTOLIC with DSP_COLUMNS>1 gets a visibly-too-small
-- default rather than a silently-plausible-looking wrong one.
--
-- DRAIN -- the state that exists because of the SAME propagation delay:
-- when this entity presents its LAST agent (finishing), that agent's
-- result is still MIN_TILE_AGENTS-ish cycles from reaching the farthest
-- column's first_out/last_out (through act_skew + the column chain +
-- ctrl_skew's own stage). Dropping 'ce' immediately (as an earlier
-- version of this entity did, going straight RUN -> IDLE on finishing)
-- FREEZES every delay line mid-drain -- generic_delay_line's stages
-- only advance on ce, so whatever value was sitting in each stage at
-- that instant stays there, indefinitely, for as long as ce stays low.
-- Externally this looked like a column's first_out/last_out getting
-- "stuck" high (or showing a stale value) for several extra cycles --
-- caught by tb_array_seq.vhdl the same run that found the MIN_TILE_
-- AGENTS gap above, not derived up front. The fix: an explicit DRAIN
-- state, entered on 'finishing', holding ce=1 (first_in/last_in=0 --
-- no NEW agent is being presented, just letting the last real one
-- finish propagating) for MIN_TILE_AGENTS more cycles before 'done'
-- pulses and the state returns to IDLE.
--
-- weight_ready [D] -- not in 08/04's text, but a real gap this entity
-- has to resolve somehow: weight_loader's buffer must actually be
-- loaded (by the not-yet-built q3k_unpack/wt_reader path, via
-- weight_loader's own load_en/w1_load/w2_load, which this entity does
-- NOT drive) before 'swap' can safely fire. Rather than silently assume
-- the loader always keeps up, this entity STALLS (holds ce=0, holding
-- the outgoing tile's last agent steady) at a tile boundary until
-- weight_ready='1', so a slow loader costs idle cycles instead of
-- corrupting a tile with a half-loaded weight buffer. No bubble occurs
-- if weight_ready is already high by the time it's needed.
entity array_seq is
  generic (
    CNT_W           : positive := 16; -- width for num_tiles/tile_agents/counters
    MIN_TILE_AGENTS : positive := 16  -- caller-computed; see header (16+DSP_COLUMNS for SYSTOLIC)
  );
  port (
    clk, rst : in std_logic;

    start       : in std_logic;                     -- pulse: begin a new matmul run
    num_tiles   : in std_logic_vector(CNT_W - 1 downto 0); -- how many weight tiles (K-dim groups) this run has
    tile_agents : in std_logic_vector(CNT_W - 1 downto 0); -- B: activation vectors streamed per tile

    weight_ready : in std_logic; -- next tile's weights are loaded into weight_loader's inactive buffer and safe to swap in [D]

    swap : out std_logic; -- to weight_loader

    ce       : out std_logic; -- to sys_array (and the activation source, once U8 exists)
    first_in : out std_logic; -- to sys_array
    last_in  : out std_logic; -- to sys_array

    busy : out std_logic;
    done : out std_logic -- pulses one cycle once the final tile's final agent has fully drained through the array
  );
end entity array_seq;

architecture behav of array_seq is
  constant IDLE      : std_logic_vector(1 downto 0) := "00";
  constant WAIT_SWAP  : std_logic_vector(1 downto 0) := "01";
  constant RUN        : std_logic_vector(1 downto 0) := "10";
  constant DRAIN      : std_logic_vector(1 downto 0) := "11";

  signal state, state_next : std_logic_vector(1 downto 0);
  signal num_tiles_reg, num_tiles_next     : std_logic_vector(CNT_W - 1 downto 0);
  signal tile_agents_reg, tile_agents_next : std_logic_vector(CNT_W - 1 downto 0);
  signal tile_cnt, tile_cnt_next           : std_logic_vector(CNT_W - 1 downto 0);
  signal agent_cnt, agent_cnt_next         : std_logic_vector(CNT_W - 1 downto 0);
  signal drain_cnt, drain_cnt_next         : std_logic_vector(CNT_W - 1 downto 0);

  signal en_num_tiles, en_tile_cnt, en_agent_cnt, en_drain_cnt : std_logic;

  signal is_idle, is_wait, is_run, is_drain : std_logic;
  signal last_agent, last_tile    : std_logic;
  signal advance_tile, stalled, finishing, drain_done : std_logic;
  signal ce_i : std_logic;
begin

  is_idle  <= '1' when state = IDLE else '0';
  is_wait  <= '1' when state = WAIT_SWAP else '0';
  is_run   <= '1' when state = RUN else '0';
  is_drain <= '1' when state = DRAIN else '0';

  last_agent <= '1' when unsigned(agent_cnt) = unsigned(tile_agents_reg) - 1 else '0';
  last_tile  <= '1' when unsigned(tile_cnt) = unsigned(num_tiles_reg) - 1 else '0';

  advance_tile <= is_run and last_agent and not last_tile and weight_ready;
  stalled      <= is_run and last_agent and not last_tile and not weight_ready;
  finishing    <= is_run and last_agent and last_tile;
  drain_done   <= '1' when is_drain = '1' and unsigned(drain_cnt) = MIN_TILE_AGENTS - 1 else '0';

  ce_i <= (is_run and not stalled) or is_drain;
  ce   <= ce_i;

  swap     <= (is_wait and weight_ready) or advance_tile;
  first_in <= is_run when unsigned(agent_cnt) = 0 else '0';
  last_in  <= is_run and last_agent;

  busy <= not is_idle;
  done <= drain_done;

  -- state
  state_next <= WAIT_SWAP when (is_idle = '1' and start = '1') else
                RUN        when (is_wait = '1' and weight_ready = '1') else
                DRAIN      when (is_run = '1' and finishing = '1') else
                IDLE       when (is_drain = '1' and drain_done = '1') else
                state;

  state_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => rst, en => '1', d => state_next, q => state);

  -- run parameters, latched once at start
  en_num_tiles    <= is_idle and start;
  num_tiles_next   <= num_tiles;
  tile_agents_next <= tile_agents;

  num_tiles_reg_i : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_num_tiles, d => num_tiles_next, q => num_tiles_reg);

  tile_agents_reg_i : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_num_tiles, d => tile_agents_next, q => tile_agents_reg);

  -- tile_cnt: 0 on start, +1 on advance_tile
  en_tile_cnt   <= (is_idle and start) or advance_tile;
  tile_cnt_next <= (others => '0') when (is_idle = '1' and start = '1') else
                    std_logic_vector(unsigned(tile_cnt) + 1);

  tile_cnt_reg : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_tile_cnt, d => tile_cnt_next, q => tile_cnt);

  -- agent_cnt: 0 when entering RUN fresh for a tile (from WAIT_SWAP or
  -- via advance_tile), +1 on every other active ce cycle
  en_agent_cnt   <= (is_wait and weight_ready) or ce_i;
  agent_cnt_next <= (others => '0') when (is_wait = '1' and weight_ready = '1') or advance_tile = '1' else
                     std_logic_vector(unsigned(agent_cnt) + 1);

  agent_cnt_reg : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_agent_cnt, d => agent_cnt_next, q => agent_cnt);

  -- drain_cnt: 0 on entering DRAIN (finishing), +1 every DRAIN cycle
  en_drain_cnt   <= (is_run and finishing) or is_drain;
  drain_cnt_next <= (others => '0') when (is_run = '1' and finishing = '1') else
                     std_logic_vector(unsigned(drain_cnt) + 1);

  drain_cnt_reg : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_drain_cnt, d => drain_cnt_next, q => drain_cnt);

  assert_num_tiles : assert not (start = '1' and unsigned(num_tiles) = 0)
    report "array_seq: num_tiles must be >= 1" severity error;

  assert_tile_agents : assert not (start = '1' and unsigned(tile_agents) < MIN_TILE_AGENTS)
    report "array_seq: tile_agents (B) must be >= " & integer'image(MIN_TILE_AGENTS) &
           " for this sys_array configuration (see this entity's header -- 08 S3.3's bare B>=R=16 is not enough for SYSTOLIC with DSP_COLUMNS>1)"
    severity error;

end architecture behav;
