library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U11 entity 6/6 (claude_docs/04-vhdl-module-list.md's `attn_seq` row:
-- "Loops over heads, chunks, sequences") -- the control sequencer tying
-- kv_reader/qk_lanes/softmax_online/pv_lanes/attn_finish together, same
-- role for the attention engine that array_seq.vhdl plays for the
-- matrix array: those five entities each own their OWN internal
-- sequencing (kv_reader walks its own tokens, softmax_online/pv_lanes
-- run their own per-token micro-step loops, attn_finish its own
-- normalize-then-quantize steps) -- this entity owns only the TOP-level
-- loop over one chunk's K-phase-then-V-phase, then chunk-to-chunk, then
-- (once every chunk of this run is done) NUM_Q resident queries'
-- attn_finish calls, exactly mirroring array_seq's own "the other
-- entities are self-contained, this one just sequences calling them."
--
-- SCOPE, ONE KV-HEAD GROUP PER RUN [D]: like vec_seq.vhdl's own
-- resolution of the same gap, "loops over heads... sequences" would need
-- kv_page_mgr/cmd_link (L3/L4, not built) to walk a real multi-sequence,
-- multi-head command stream. This entity resolves the testable part:
-- ONE run = one resident KV-head group (the NUM_Q queries sharing it,
-- loaded into qk_lanes' q_vec by the caller and held stable for the
-- whole run -- same CALLER CONTRACT as vec_seq's own op/sub/cvt) over
-- 'num_chunks' chunks of ONE sequence. Looping over multiple KV heads or
-- multiple sequences is the CALLER's job (re-pulse 'start' with a new
-- q_vec/num_chunks/backing memory), same resolution vec_seq used for
-- "loops over descriptors."
--
-- PORTS ARE CONTROL ONLY -- every DATA bus between the five sub-entities
-- (kv_reader.tok_data -> qk_lanes.k_vec/pv_lanes.v_vec, qk_lanes.score ->
-- softmax_online.k_score, softmax_online.p_valid/query/p_q15 ->
-- pv_lanes.acc_valid/query/p_q15, softmax_online.rescale_out ->
-- pv_lanes.rescale_in, kv_reader's own memory port) is a DIRECT wire
-- between those entities at the integration level (tb_attn_seq.vhdl),
-- NOT relayed through this entity -- this entity never needs to inspect
-- or transform any of that data, only sequence WHEN each producer/
-- consumer acts on it, so routing it through here would just be
-- unnecessary plumbing (vec_seq.vhdl's own a_rdata->lz_a_data relay is
-- NOT the precedent to follow here: vec_seq computes the read ADDRESS
-- itself, a real dependency; attn_seq has no equivalent claim on any of
-- these buses). The one exception is attn_finish's per-query l_in/
-- o_acc_in, which need to select ONE query's slice out of softmax_
-- online's/pv_lanes' NUM_Q-wide outputs -- this entity exposes 'q_idx'
-- (which query is current) for an external mux to use, rather than
-- carrying the NUM_Q*DIM*32-bit o_acc bus through its own ports.
--
-- 'out_valid' (pulses when 'af_done' fires, tagged with 'q_idx') is safe
-- for an external, decoupled consumer (a testbench polling "after a
-- clock edge") to catch even though it's built from a same-cycle AND,
-- unlike this session's earlier softmax_online.vhdl k_done/v_done bug:
-- 'af_done' is ITSELF already a full-clock-cycle-stable flag (attn_
-- finish.vhdl's own dedicated PH_DONE state), and this entity's own
-- 'state' does NOT change on the same edge 'af_done' first asserts (it
-- only reacts to it on the FOLLOWING edge) -- so their AND is stable for
-- one whole checkable cycle, not a same-edge transient. Every 'done'
-- flag this entity itself waits on (kv_done, sm_k_done/sm_v_done,
-- pv_chunk_done, af_done) is the same kind of dedicated-terminal-state
-- or explicitly-registered flag, for the same reason.
entity attn_seq is
  generic (
    CHUNK : positive := 16; -- tokens per KV chunk (must match kv_reader/softmax_online)
    NUM_Q : positive := 4;  -- resident queries (must match qk_lanes/softmax_online/pv_lanes)
    CNT_W : positive := 16  -- width for num_chunks/chunk_cnt
  );
  port (
    clk, rst : in std_logic;

    start      : in  std_logic; -- pulse: begin a run (q_vec/backing memory already loaded by the caller)
    num_chunks : in  std_logic_vector(CNT_W - 1 downto 0);
    busy, done : out std_logic;

    -- kv_reader
    kv_start     : out std_logic;
    kv_done      : in  std_logic;
    kv_tok_valid : in  std_logic;
    kv_tok_is_v  : in  std_logic;
    kv_tok_idx   : in  unsigned(clog2(CHUNK) - 1 downto 0);
    kv_tok_last  : in  std_logic;
    kv_tok_ack   : out std_logic;

    -- qk_lanes
    qk_ce : out std_logic;

    -- softmax_online
    sm_seq_first  : out std_logic;
    sm_k_start    : out std_logic;
    sm_k_tok_idx  : out unsigned(clog2(CHUNK) - 1 downto 0);
    sm_k_last_tok : out std_logic;
    sm_k_done     : in  std_logic;
    sm_v_start    : out std_logic;
    sm_v_tok_idx  : out unsigned(clog2(CHUNK) - 1 downto 0);
    sm_v_done     : in  std_logic;

    -- pv_lanes
    pv_seq_first  : out std_logic;
    pv_chunk_end  : out std_logic;
    pv_chunk_done : in  std_logic;

    -- attn_finish (looped NUM_Q times once every chunk is done)
    af_start : out std_logic;
    af_done  : in  std_logic;

    q_idx     : out unsigned(clog2(NUM_Q) - 1 downto 0); -- selects the active query's external slice
    out_valid : out std_logic -- pulses (for one full cycle) when af_done fires, tagged with q_idx
  );
end entity attn_seq;

architecture behav of attn_seq is
  constant S_IDLE          : std_logic_vector(3 downto 0) := x"0";
  constant S_CHUNK_START   : std_logic_vector(3 downto 0) := x"1";
  constant S_TOK_WAIT      : std_logic_vector(3 downto 0) := x"2";
  constant S_K_CE          : std_logic_vector(3 downto 0) := x"3";
  constant S_K_WAIT_SCORE  : std_logic_vector(3 downto 0) := x"4";
  constant S_K_START_SM    : std_logic_vector(3 downto 0) := x"5";
  constant S_K_WAIT_DONE   : std_logic_vector(3 downto 0) := x"6";
  constant S_V_START_SM    : std_logic_vector(3 downto 0) := x"7";
  constant S_V_WAIT_DONE   : std_logic_vector(3 downto 0) := x"8";
  constant S_TOK_ACK       : std_logic_vector(3 downto 0) := x"9";
  constant S_WAIT_KV_DONE  : std_logic_vector(3 downto 0) := x"A";
  constant S_FOLD_START    : std_logic_vector(3 downto 0) := x"B";
  constant S_FOLD_WAIT     : std_logic_vector(3 downto 0) := x"C";
  constant S_QUERY_START   : std_logic_vector(3 downto 0) := x"D";
  constant S_QUERY_WAIT    : std_logic_vector(3 downto 0) := x"E";
  constant S_DONE          : std_logic_vector(3 downto 0) := x"F";

  signal state, state_next : std_logic_vector(3 downto 0);

  signal num_chunks_reg, num_chunks_next : std_logic_vector(CNT_W - 1 downto 0);
  signal chunk_cnt_slv, chunk_cnt_next   : std_logic_vector(CNT_W - 1 downto 0);
  signal chunk_cnt : unsigned(CNT_W - 1 downto 0);

  constant Q_W : positive := clog2(NUM_Q);
  signal q_idx_slv, q_idx_next : std_logic_vector(Q_W - 1 downto 0);
  signal q_idx_i : unsigned(Q_W - 1 downto 0);

  signal en_run_params, en_chunk_cnt, en_q_idx : std_logic;
  signal last_chunk, last_query : boolean;
begin

  chunk_cnt <= unsigned(chunk_cnt_slv);
  q_idx_i   <= unsigned(q_idx_slv);
  q_idx     <= q_idx_i;

  last_chunk <= (chunk_cnt = unsigned(num_chunks_reg) - 1);
  last_query <= (to_integer(q_idx_i) = NUM_Q - 1);

  ----------------------------------------------------------------
  -- state sequencing
  ----------------------------------------------------------------
  state_next <=
    S_CHUNK_START  when (state = S_IDLE and start = '1') else
    S_TOK_WAIT     when (state = S_CHUNK_START) else
    S_K_CE         when (state = S_TOK_WAIT and kv_tok_valid = '1' and kv_tok_is_v = '0') else
    S_V_START_SM   when (state = S_TOK_WAIT and kv_tok_valid = '1' and kv_tok_is_v = '1') else
    S_TOK_WAIT     when (state = S_TOK_WAIT) else
    S_K_WAIT_SCORE when (state = S_K_CE) else
    S_K_START_SM   when (state = S_K_WAIT_SCORE) else
    S_K_WAIT_DONE  when (state = S_K_START_SM) else
    S_TOK_ACK      when (state = S_K_WAIT_DONE and sm_k_done = '1') else
    S_K_WAIT_DONE  when (state = S_K_WAIT_DONE) else
    S_V_WAIT_DONE  when (state = S_V_START_SM) else
    S_TOK_ACK      when (state = S_V_WAIT_DONE and sm_v_done = '1') else
    S_V_WAIT_DONE  when (state = S_V_WAIT_DONE) else
    S_WAIT_KV_DONE when (state = S_TOK_ACK and kv_tok_is_v = '1' and kv_tok_last = '1') else
    S_TOK_WAIT     when (state = S_TOK_ACK) else
    S_FOLD_START   when (state = S_WAIT_KV_DONE and kv_done = '1') else
    S_WAIT_KV_DONE when (state = S_WAIT_KV_DONE) else
    S_FOLD_WAIT    when (state = S_FOLD_START) else
    S_QUERY_START  when (state = S_FOLD_WAIT and pv_chunk_done = '1' and last_chunk) else
    S_CHUNK_START  when (state = S_FOLD_WAIT and pv_chunk_done = '1') else
    S_FOLD_WAIT    when (state = S_FOLD_WAIT) else
    S_QUERY_WAIT   when (state = S_QUERY_START) else
    S_DONE         when (state = S_QUERY_WAIT and af_done = '1' and last_query) else
    S_QUERY_START  when (state = S_QUERY_WAIT and af_done = '1') else
    S_QUERY_WAIT   when (state = S_QUERY_WAIT) else
    S_IDLE         when (state = S_DONE) else
    S_IDLE;

  state_reg : entity work.generic_register
    generic map (WIDTH => 4)
    port map (clk => clk, rst => rst, en => '1', d => state_next, q => state);

  ----------------------------------------------------------------
  -- run parameters and counters
  ----------------------------------------------------------------
  en_run_params    <= '1' when (state = S_IDLE and start = '1') else '0';
  num_chunks_next  <= num_chunks;

  num_chunks_reg_i : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_run_params, d => num_chunks_next, q => num_chunks_reg);

  en_chunk_cnt <= '1' when (state = S_IDLE and start = '1') else
                  '1' when (state = S_FOLD_WAIT and pv_chunk_done = '1') else
                  '0';
  chunk_cnt_next <=
    (others => '0') when (state = S_IDLE and start = '1') else
    std_logic_vector(chunk_cnt + 1);

  chunk_cnt_reg : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_chunk_cnt, d => chunk_cnt_next, q => chunk_cnt_slv);

  en_q_idx <= '1' when (state = S_FOLD_WAIT and pv_chunk_done = '1' and last_chunk) else
              '1' when (state = S_QUERY_WAIT and af_done = '1') else
              '0';
  q_idx_next <=
    std_logic_vector(to_unsigned(0, Q_W)) when (state = S_FOLD_WAIT and pv_chunk_done = '1' and last_chunk) else
    std_logic_vector(to_unsigned(0, Q_W)) when (state = S_QUERY_WAIT and af_done = '1' and last_query) else
    std_logic_vector(q_idx_i + 1)         when (state = S_QUERY_WAIT and af_done = '1') else
    q_idx_slv;

  q_idx_reg : entity work.generic_register
    generic map (WIDTH => Q_W)
    port map (clk => clk, rst => rst, en => en_q_idx, d => q_idx_next, q => q_idx_slv);

  ----------------------------------------------------------------
  -- outputs
  ----------------------------------------------------------------
  busy <= '0' when state = S_IDLE else '1';
  done <= '1' when state = S_DONE else '0';

  kv_start   <= '1' when state = S_CHUNK_START else '0';
  kv_tok_ack <= '1' when state = S_TOK_ACK else '0';

  qk_ce <= '1' when state = S_K_CE else '0';

  sm_seq_first  <= '1' when chunk_cnt = 0 else '0';
  sm_k_start    <= '1' when state = S_K_START_SM else '0';
  sm_k_tok_idx  <= kv_tok_idx;
  sm_k_last_tok <= kv_tok_last;
  sm_v_start    <= '1' when state = S_V_START_SM else '0';
  sm_v_tok_idx  <= kv_tok_idx;

  pv_seq_first  <= '1' when chunk_cnt = 0 else '0';
  pv_chunk_end  <= '1' when state = S_FOLD_START else '0';

  af_start  <= '1' when state = S_QUERY_START else '0';
  out_valid <= '1' when (state = S_QUERY_WAIT and af_done = '1') else '0';

  assert_num_chunks : assert not (start = '1' and unsigned(num_chunks) = 0)
    report "attn_seq: num_chunks must be >= 1" severity error;

end architecture behav;
