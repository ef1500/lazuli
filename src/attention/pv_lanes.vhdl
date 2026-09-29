library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U11 entity 4/6 (claude_docs/04-vhdl-module-list.md's `pv_lanes` row:
-- "Q0.15 x int8 multiply-accumulate, 16-token chunks"; 08-vhdl-
-- implementation-spec.md S5.1: "quantize p to unsigned Q0.15, multiply
-- by int8 V, accumulate 16 tokens per chunk in a 27-bit accumulator...
-- at each chunk boundary, one fp32 rescale by exp(m_old-m_new)").
--
-- Two very different halves, matching the "throughput here, TDM there"
-- split already used elsewhere in this codebase:
--
-- 1) PER-TOKEN ACCUMULATE (always live, no sequencer): for every
--    softmax_online.p_valid pulse, the addressed query's DIM parallel
--    `int_acc` lanes ALL accumulate p_q15*v_vec[d] the SAME cycle -- p is
--    a scalar per (token,query), so the DIM dimension is naturally
--    parallel (unlike softmax_online's own per-query serialization, this
--    doesn't need a shared resource at all: DIM int_acc instances per
--    query is exactly `int_acc.vhdl`'s own intended reuse). Caller wires
--    acc_valid/acc_query/acc_p_q15 straight from softmax_online's
--    p_valid/p_query/p_q15, and v_vec from kv_reader's tok_data during
--    the V-phase (see attn_seq.vhdl).
--
-- 2) CHUNK-BOUNDARY FOLD (one shared generic_fpu, TDM, correctness
--    first -- same [D] as group_scale_acc.vhdl/softmax_online.vhdl's own
--    fpu instances): on `chunk_end`, serially over every (query, dim)
--    lane: convert that lane's just-finished int accumulator to fp32,
--    rescale the GLOBAL o_acc[query][dim] by `rescale_in[query]`
--    (softmax_online's own chunk-boundary rescale factor -- by
--    construction it's still stable when chunk_end fires, since
--    attn_seq only fires chunk_end after the V-phase, and rescale_out
--    doesn't change again until the NEXT chunk's K-phase), add the two,
--    write back into o_acc, and clear that lane's int accumulator for
--    the next chunk. `seq_first` (CALLER-HELD, same convention as
--    softmax_online.vhdl's) skips using the stale/garbage global value
--    on a sequence's first chunk, same "compute unconditionally, mux the
--    capture" style as softmax_online's own K_FINAL step.
--
-- WIDTHS: p_q15 is unsigned Q0.15 (max value 32768 exactly, see
-- softmax_online.vhdl's own header -- fits 16 unsigned bits without
-- saturation). Zero-extending it to 17 bits before the signed multiply
-- (not 16) is required: reinterpreting the raw 16-bit pattern as signed
-- would read 32768 (0x8000) as -32768. 17b signed x 8b signed = 25b
-- signed product (IN_WIDTH for int_acc below); 08 S5.1's own "16 x 32767
-- x 127 fits 27 bits" sizes ACC_WIDTH.
entity pv_lanes is
  generic (
    DIM   : positive := 128;
    NUM_Q : positive := 4
  );
  port (
    clk, rst : in std_logic;

    seq_first : in std_logic; -- CALLER-HELD, mirrors softmax_online.vhdl's own convention

    acc_valid : in std_logic;
    acc_query : in unsigned(clog2(NUM_Q) - 1 downto 0);
    acc_p_q15 : in std_logic_vector(15 downto 0); -- unsigned Q0.15
    v_vec     : in std_logic_vector(DIM * 8 - 1 downto 0); -- signed int8 lanes

    chunk_end  : in  std_logic; -- pulse: fold this chunk's int accumulators into o_acc
    rescale_in : in  std_logic_vector(NUM_Q * 32 - 1 downto 0);
    chunk_done : out std_logic; -- pulses (registered) once the fold has finished

    o_acc : out std_logic_vector(NUM_Q * DIM * 32 - 1 downto 0) -- [q][d], fp32
  );
end entity pv_lanes;

architecture behav of pv_lanes is
  constant Q_W : positive := clog2(NUM_Q);
  constant D_W : positive := clog2(DIM);
  constant PROD_W : positive := 25; -- 17b (p, zero-extended) x 8b (v)
  constant ACC_W  : positive := 27;

  signal busy, busy_next : std_logic;
  signal step_slv, step_next_slv : std_logic_vector(1 downto 0);
  signal step : unsigned(1 downto 0);
  signal q_idx_slv, q_idx_next_slv : std_logic_vector(Q_W - 1 downto 0);
  signal q_idx : unsigned(Q_W - 1 downto 0);
  signal d_idx_slv, d_idx_next_slv : std_logic_vector(D_W - 1 downto 0);
  signal d_idx : unsigned(D_W - 1 downto 0);

  signal step_last, d_idx_last, q_idx_last : boolean;

  signal fpu_op  : alu_op_t;
  signal fpu_cvt : cvt_op_t;
  signal fpu_a, fpu_b : std_logic_vector(31 downto 0);
  signal fpu_ce  : std_logic;
  signal fpu_y   : std_logic_vector(31 downto 0);

  signal contrib_f_en : std_logic;
  signal contrib_f    : std_logic_vector(31 downto 0);

  signal o_wr   : std_logic;
  signal o_next : std_logic_vector(31 downto 0);
  signal acc_rst_pulse : std_logic; -- fold has consumed this lane's int accumulator; clear it

  signal chunk_done_i_vec, chunk_done_slv : std_logic_vector(0 downto 0);

  type acc_arr_t is array (0 to NUM_Q * DIM - 1) of signed(ACC_W - 1 downto 0);
  signal acc_arr : acc_arr_t;

  type o_arr_t is array (0 to NUM_Q * DIM - 1) of std_logic_vector(31 downto 0);
  signal o_arr : o_arr_t;
begin

  step  <= unsigned(step_slv);
  q_idx <= unsigned(q_idx_slv);
  d_idx <= unsigned(d_idx_slv);

  step_last  <= (step = 3);
  d_idx_last <= (to_integer(d_idx) = DIM - 1);
  q_idx_last <= (to_integer(q_idx) = NUM_Q - 1);

  ----------------------------------------------------------------
  -- fold sequencer: busy/step/q_idx/d_idx, act_quantizer.vhdl's style
  ----------------------------------------------------------------
  busy_next <= '1' when (busy = '0' and chunk_end = '1') else
               '0' when (busy = '1' and step_last and d_idx_last and q_idx_last) else
               busy;

  busy_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => '1', d(0) => busy_next, q(0) => busy);

  step_next_slv <=
    "00" when (busy = '0') else
    "00" when step_last else
    std_logic_vector(step + 1);

  step_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => rst, en => '1', d => step_next_slv, q => step_slv);

  d_idx_next_slv <=
    std_logic_vector(to_unsigned(0, D_W)) when (busy = '0') else
    std_logic_vector(to_unsigned(0, D_W)) when (step_last and d_idx_last) else
    std_logic_vector(d_idx + 1)           when step_last else
    d_idx_slv;

  d_idx_reg : entity work.generic_register
    generic map (WIDTH => D_W)
    port map (clk => clk, rst => rst, en => '1', d => d_idx_next_slv, q => d_idx_slv);

  q_idx_next_slv <=
    std_logic_vector(to_unsigned(0, Q_W)) when (busy = '0') else
    std_logic_vector(to_unsigned(0, Q_W)) when (step_last and d_idx_last and q_idx_last) else
    std_logic_vector(q_idx + 1)           when (step_last and d_idx_last) else
    q_idx_slv;

  q_idx_reg : entity work.generic_register
    generic map (WIDTH => Q_W)
    port map (clk => clk, rst => rst, en => '1', d => q_idx_next_slv, q => q_idx_slv);

  -- registered, same reasoning as softmax_online.vhdl's k_done/v_done fix:
  -- the combinational "last step" condition is gone the instant the same
  -- edge drops 'busy', so no synchronous consumer could ever catch it
  -- un-registered.
  chunk_done_i_vec(0) <= '1' when (busy = '1' and step_last and d_idx_last and q_idx_last) else '0';

  chunk_done_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => '1', d => chunk_done_i_vec, q => chunk_done_slv);

  chunk_done <= chunk_done_slv(0);

  ----------------------------------------------------------------
  -- issue: fold micro-steps (CVT_I2F -> capture+issue MUL -> issue ADD
  -- -> capture+clear), same 4-step shape act_quantizer.vhdl/sb_finish.
  -- vhdl's own sequencers use, driven from the CURRENT (q_idx,d_idx) lane.
  ----------------------------------------------------------------
  issue : process (busy, step, q_idx, d_idx, seq_first, fpu_y, contrib_f, acc_arr, o_arr, rescale_in)
    variable qi, di, li : integer;
  begin
    qi := to_integer(q_idx);
    di := to_integer(d_idx);
    li := qi * DIM + di;

    fpu_op  <= ALU_CVT;
    fpu_cvt <= CVT_I2F;
    fpu_a   <= (others => '0');
    fpu_b   <= (others => '0');
    fpu_ce  <= '0';

    contrib_f_en <= '0';
    o_wr   <= '0';
    o_next <= (others => '0');
    acc_rst_pulse <= '0';

    if busy = '1' then
      case to_integer(step) is
        when 0 =>
          fpu_op  <= ALU_CVT; fpu_cvt <= CVT_I2F;
          fpu_a   <= std_logic_vector(resize(acc_arr(li), 32));
          fpu_ce  <= '1';
        when 1 =>
          -- fpu_y = this lane's int accumulator, as fp32 (step 0, zero-slack)
          contrib_f_en <= '1';
          fpu_op <= ALU_MUL;
          fpu_a  <= o_arr(li);
          fpu_b  <= rescale_in((qi + 1) * 32 - 1 downto qi * 32);
          fpu_ce <= '1';
        when 2 =>
          -- fpu_y = global_old * rescale (step 1, zero-slack); contrib_f
          -- (captured at step 1) still holds step 0's result
          fpu_op <= ALU_ADD; fpu_a <= contrib_f; fpu_b <= fpu_y; fpu_ce <= '1';
        when others => -- 3
          -- fpu_y = contrib_f + global_rescaled (step 2, zero-slack)
          o_wr   <= '1';
          o_next <= contrib_f when seq_first = '1' else fpu_y;
          acc_rst_pulse <= '1';
      end case;
    end if;
  end process issue;

  fpu : entity work.generic_fpu
    port map (clk => clk, ce => fpu_ce, op => fpu_op, sub => "000", cvt => fpu_cvt,
              a => fpu_a, b => fpu_b, y => fpu_y, flag => open);

  contrib_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => rst, en => contrib_f_en, d => fpu_y, q => contrib_f);

  ----------------------------------------------------------------
  -- per-(query,dim) lanes: DIM*NUM_Q int_acc accumulators (always-live,
  -- per-token) and DIM*NUM_Q fp32 global registers (written only by the
  -- fold sequencer above).
  ----------------------------------------------------------------
  q_gen : for q in 0 to NUM_Q - 1 generate
    signal acc_ce_q : std_logic;
  begin
    acc_ce_q <= acc_valid when to_integer(acc_query) = q else '0';

    d_gen : for d in 0 to DIM - 1 generate
      signal term : signed(PROD_W - 1 downto 0);
      signal acc_rst_lane, o_en_lane : std_logic;
      signal acc_out : signed(ACC_W - 1 downto 0);
    begin
      term <= signed('0' & acc_p_q15) * signed(v_vec((d + 1) * 8 - 1 downto d * 8));

      -- Chip-wide 'rst' must ALSO clear this lane's accumulator, not just
      -- the per-chunk fold-triggered pulse: without it, int_acc's own
      -- internal register starts simulation uninitialized ('X') and its
      -- FIRST-EVER use (this chunk's accumulate, before any fold has run
      -- even once to supply an rst pulse of its own) reads/accumulates
      -- against that undefined state, and X + anything = X in std_logic
      -- arithmetic -- it would stay garbage forever, never resolving,
      -- since nothing else ever forces a clean 0 in. Found via
      -- simulation: acc_arr(0) traced as 'X' through this lane's entire
      -- first fold, only becoming defined once ITS OWN fold's rst pulse
      -- (issued below, once) finally cleared it -- one chunk too late.
      acc_rst_lane <= '1' when rst = '1' else
                      acc_rst_pulse when (to_integer(q_idx) = q and to_integer(d_idx) = d) else '0';

      int_acc_i : entity work.int_acc
        generic map (IN_WIDTH => PROD_W, ACC_WIDTH => ACC_W)
        port map (clk => clk, rst => acc_rst_lane, ce => acc_ce_q, d => term, acc => acc_out);

      acc_arr(q * DIM + d) <= acc_out;

      o_en_lane <= o_wr when (to_integer(q_idx) = q and to_integer(d_idx) = d) else '0';

      o_reg_i : entity work.generic_register
        generic map (WIDTH => 32)
        port map (clk => clk, rst => rst, en => o_en_lane, d => o_next, q => o_arr(q * DIM + d));

      o_acc((q * DIM + d + 1) * 32 - 1 downto (q * DIM + d) * 32) <= o_arr(q * DIM + d);
    end generate d_gen;
  end generate q_gen;

end architecture behav;
