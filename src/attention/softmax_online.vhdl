library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U11 entity 3/6 (syseng_docs/04-vhdl-module-list.md's `softmax_online`
-- row: "Running max, exp, running sum, chunk-boundary rescale"; 08-vhdl-
-- implementation-spec.md S5.1: "running max and sum per query, updated
-- per 16-token chunk").
--
-- BASE-2, NOT NATURAL-e [D]: this entity computes the whole online-
-- softmax recurrence using 2^x (generic_lookup's native TAB_FRAC mode)
-- instead of e^x. Softmax's normalized OUTPUT is invariant to which
-- exponential base is used consistently for both the numerator and the
-- denominator -- Softmax_b(x)_i = b^x_i / Sum_j(b^x_j) gives the exact
-- same result for any base b > 1, since a change of base is just a
-- constant rescale of every x_i (x -> x*ln(b)) that cancels in the
-- ratio. Using exp2 directly, rather than converting through a
-- multiply-by-log2(e) first, avoids an extra fp32 multiply (and its
-- rounding) per score with zero effect on the final normalized result.
--
-- ALGORITHM (standard online/"flash attention" softmax, chunked):
-- per query q, per chunk: K-phase computes each token's raw int score,
-- converts it to fp32, remembers it (this chunk's score RAM, revisited
-- in the V-phase), and tracks this chunk's local max. At the chunk's
-- last K token (K-phase end, "K_FINAL" below): m_new = max(m_old,
-- chunk_max_local); rescale = 2^(m_old - m_new); l is immediately
-- rescaled (l <= l_old * rescale) so the V-phase can just accumulate
-- new terms onto it. V-phase then revisits each of this chunk's scores:
-- p_i = 2^(score_i - m_new), l += p_i, and p_i is quantized to unsigned
-- Q0.15 (round-to-nearest via generic_fpu's own CVT_F2I, then taking the
-- low 16 bits -- p_i in [0,1] means p_i*32768 in [0,32768], which always
-- fits 16 unsigned bits without needing a separate saturate step) and
-- handed to the caller (pv_lanes, via p_valid/p_query/p_q15) for the P.V
-- accumulate. `rescale_out` is what pv_lanes uses to fold its own
-- accumulator at the chunk boundary (see pv_lanes.vhdl's header).
--
-- FIRST-CHUNK HANDLING (`seq_first`, CALLER-HELD, mirrors sb_finish.
-- vhdl's own `first` convention): on a sequence's first chunk there is
-- no valid m_old/l_old to compare against or rescale, so the K_FINAL and
-- V-phase math is computed UNCONDITIONALLY every chunk (same step count,
-- same fpu/lookup calls) and only the four REGISTER CAPTURES that would
-- otherwise use a stale m_old/l_old are muxed by `seq_first` -- m <=
-- chunk_max_local directly (skipping the max-with-garbage compare) and
-- l <= 0 (skipping the rescale-with-garbage multiply). Computing the
-- otherwise-unused intermediate values anyway, rather than branching the
-- FSM around them, keeps the step count uniform and the sequencer simple
-- (same style as sb_finish's own `first`-gated 'old_or_zero' mux).
--
-- SHARED RESOURCES: one internal generic_fpu and one internal
-- generic_lookup (TAB_FRAC/exp2, host-preloaded at LUT_SLOT -- this
-- entity only broadcasts the ld_* load port through, same convention as
-- act_quantizer.vhdl) serve all NUM_Q queries, serially, per token --
-- the same "dedicated-but-shared, correctness first" call already made
-- for sb_finish/act_quantizer's own fpu/lookup instances (04 S2.2's
-- "8 shared multipliers per tile" TDM optimization is NOT implemented
-- here either, same [D] as rescaling/group_scale_acc.vhdl's header).
--
-- HANDSHAKE: k_start/v_start are one-cycle PULSES; this entity LATCHES
-- k_tok_idx/k_score/k_last_tok (or v_tok_idx) on that same cycle, then
-- runs its own internal NUM_Q-query loop (3 steps/query for a K token,
-- +5 steps/query more on the chunk's last K token, 7 steps/query for a V
-- token) before pulsing k_done/v_done -- the caller (attn_seq) must wait
-- for that pulse before presenting the next token (this entity has no
-- input buffering beyond the one just-latched token).
entity softmax_online is
  generic (
    CHUNK    : positive := 16;  -- tokens per KV chunk
    NUM_Q    : positive := 4;   -- GQA reuse factor (resident queries)
    SCORE_W  : positive := 23;  -- must match the caller's qk_lanes SCORE_W (16 + clog2(DIM))
    LUT_SLOT : natural range 0 to 7 := 0
  );
  port (
    clk, rst : in std_logic;

    seq_first : in std_logic; -- CALLER-HELD: '1' while processing a new sequence's first chunk

    k_start    : in  std_logic;
    k_tok_idx  : in  unsigned(clog2(CHUNK) - 1 downto 0);
    k_score    : in  std_logic_vector(NUM_Q * SCORE_W - 1 downto 0); -- [q], signed, from qk_lanes
    k_last_tok : in  std_logic; -- this is token CHUNK-1 of the K-phase
    k_done     : out std_logic;

    v_start   : in  std_logic;
    v_tok_idx : in  unsigned(clog2(CHUNK) - 1 downto 0);
    v_done    : out std_logic;

    p_valid : out std_logic;
    p_query : out unsigned(clog2(NUM_Q) - 1 downto 0);
    p_q15   : out std_logic_vector(15 downto 0); -- unsigned Q0.15

    rescale_out : out std_logic_vector(NUM_Q * 32 - 1 downto 0); -- [q], fp32, stable from k_done(last) through the V-phase
    l_out       : out std_logic_vector(NUM_Q * 32 - 1 downto 0); -- [q], fp32, running sum

    ld_en    : in std_logic;
    ld_slot  : in unsigned(2 downto 0);
    ld_mode  : in tab_mode_t;
    ld_lo    : in std_logic_vector(31 downto 0);
    ld_hi    : in std_logic_vector(31 downto 0);
    ld_left  : in tab_edge_t;
    ld_right : in tab_edge_t;
    ld_bits  : in unsigned(3 downto 0);
    ld_addr  : in unsigned(9 downto 0);
    ld_value : in std_logic_vector(31 downto 0);
    ld_slope : in std_logic_vector(31 downto 0);
    ld_we    : in std_logic
  );
end entity softmax_online;

architecture behav of softmax_online is
  constant TOK_W      : positive := clog2(CHUNK);
  constant Q_W         : positive := clog2(NUM_Q);
  constant RAM_ADDR_W  : positive := clog2(NUM_Q * CHUNK);
  constant CONST_32768 : std_logic_vector(31 downto 0) := x"47000000"; -- 32768.0 exactly

  constant MODE_IDLE : std_logic_vector(1 downto 0) := "00";
  constant MODE_K     : std_logic_vector(1 downto 0) := "01";
  constant MODE_KFIN  : std_logic_vector(1 downto 0) := "10";
  constant MODE_V      : std_logic_vector(1 downto 0) := "11";

  signal mode, mode_next : std_logic_vector(1 downto 0);
  signal step_slv, step_next_slv : std_logic_vector(2 downto 0);
  signal step : unsigned(2 downto 0);
  signal q_idx_slv, q_idx_next_slv : std_logic_vector(Q_W - 1 downto 0);
  signal q_idx : unsigned(Q_W - 1 downto 0);

  signal step_last, q_idx_last : boolean;

  signal tok_idx_hold_slv, tok_idx_hold_next : std_logic_vector(TOK_W - 1 downto 0);
  signal tok_idx_hold : unsigned(TOK_W - 1 downto 0);
  signal last_hold_slv : std_logic_vector(0 downto 0);
  signal last_hold : std_logic;
  signal last_hold_next : std_logic_vector(0 downto 0);

  signal k_done_i_vec, v_done_i_vec : std_logic_vector(0 downto 0);
  signal k_done_slv, v_done_slv : std_logic_vector(0 downto 0);
  signal raw_score_hold, raw_score_hold_next : std_logic_vector(NUM_Q * SCORE_W - 1 downto 0);
  signal hold_en : std_logic;

  signal fpu_op  : alu_op_t;
  signal fpu_sub : std_logic_vector(2 downto 0);
  signal fpu_cvt : cvt_op_t;
  signal fpu_a, fpu_b : std_logic_vector(31 downto 0);
  signal fpu_ce  : std_logic;
  signal fpu_y   : std_logic_vector(31 downto 0);

  signal lut_ce : std_logic;
  signal lut_x, lut_y : std_logic_vector(31 downto 0);

  signal ram_we, ram_re : std_logic;
  signal ram_waddr, ram_raddr : unsigned(RAM_ADDR_W - 1 downto 0);
  signal ram_wdata, ram_rdata : std_logic_vector(31 downto 0);

  signal m_wr, l_wr, chunk_max_wr, rescale_wr : std_logic;
  signal m_next, l_next, chunk_max_next, rescale_next : std_logic_vector(31 downto 0);

  type fp_arr_t is array (0 to NUM_Q - 1) of std_logic_vector(31 downto 0);
  signal m_arr, l_arr, chunk_max_arr, rescale_arr : fp_arr_t;
begin

  step  <= unsigned(step_slv);
  q_idx <= unsigned(q_idx_slv);
  tok_idx_hold <= unsigned(tok_idx_hold_slv);

  step_last  <= (mode = MODE_K and step = 2) or (mode = MODE_KFIN and step = 4) or (mode = MODE_V and step = 6);
  q_idx_last <= (to_integer(q_idx) = NUM_Q - 1);

  ----------------------------------------------------------------
  -- mode / step / q_idx sequencing (Moore, act_quantizer.vhdl's style:
  -- concurrent conditional assignments for next-state, a separate
  -- combinational 'issue' process below for what each step actually does)
  ----------------------------------------------------------------
  mode_next <=
    MODE_K    when (mode = MODE_IDLE and k_start = '1') else
    MODE_V    when (mode = MODE_IDLE and v_start = '1') else
    MODE_KFIN when (mode = MODE_K and step_last and q_idx_last and last_hold = '1') else
    MODE_IDLE when (mode = MODE_K and step_last and q_idx_last and last_hold = '0') else
    MODE_K    when (mode = MODE_K) else
    MODE_IDLE when (mode = MODE_KFIN and step_last and q_idx_last) else
    MODE_KFIN when (mode = MODE_KFIN) else
    MODE_IDLE when (mode = MODE_V and step_last and q_idx_last) else
    MODE_V    when (mode = MODE_V) else
    MODE_IDLE;

  mode_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => rst, en => '1', d => mode_next, q => mode);

  step_next_slv <=
    std_logic_vector(to_unsigned(0, 3)) when (mode = MODE_IDLE) else
    std_logic_vector(to_unsigned(0, 3)) when step_last else
    std_logic_vector(step + 1);

  step_reg : entity work.generic_register
    generic map (WIDTH => 3)
    port map (clk => clk, rst => rst, en => '1', d => step_next_slv, q => step_slv);

  q_idx_next_slv <=
    std_logic_vector(to_unsigned(0, Q_W)) when (mode = MODE_IDLE) else
    std_logic_vector(to_unsigned(0, Q_W)) when (step_last and q_idx_last) else
    std_logic_vector(q_idx + 1)           when step_last else
    q_idx_slv;

  q_idx_reg : entity work.generic_register
    generic map (WIDTH => Q_W)
    port map (clk => clk, rst => rst, en => '1', d => q_idx_next_slv, q => q_idx_slv);

  -- k_done_i/v_done_i are true DURING the last cycle of MODE_K/MODE_KFIN/
  -- MODE_V (combinationally, off the CURRENT mode/step/q_idx) -- but that
  -- state is gone the instant the SAME edge moves mode back to MODE_IDLE,
  -- so no synchronous consumer sampling "after a clock edge" (a
  -- testbench's own wait-until-edge-then-check, or attn_seq itself) could
  -- ever actually catch it: by the time anything checks, mode has already
  -- moved on and the combinational condition has already gone false
  -- again. Registering it one more cycle makes it visible for a full,
  -- checkable clock period starting the cycle AFTER that transition --
  -- same role as act_quantizer.vhdl's dedicated PH_DONE state, just via
  -- an explicit register instead of an extra phase value.
  k_done_i_vec(0) <= '1' when (mode = MODE_K and step_last and q_idx_last and last_hold = '0') else
                     '1' when (mode = MODE_KFIN and step_last and q_idx_last) else
                     '0';
  v_done_i_vec(0) <= '1' when (mode = MODE_V and step_last and q_idx_last) else '0';

  k_done_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => '1', d => k_done_i_vec, q => k_done_slv);

  v_done_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => '1', d => v_done_i_vec, q => v_done_slv);

  k_done <= k_done_slv(0);
  v_done <= v_done_slv(0);

  ----------------------------------------------------------------
  -- token latches: grab the caller's inputs on the one-cycle start
  -- pulse, since the multi-step loop that follows takes many cycles and
  -- the caller is free to change k_score/k_tok_idx as soon as k_start
  -- has been accepted.
  ----------------------------------------------------------------
  hold_en <= '1' when (mode = MODE_IDLE and (k_start = '1' or v_start = '1')) else '0';
  tok_idx_hold_next <= std_logic_vector(k_tok_idx) when k_start = '1' else std_logic_vector(v_tok_idx);
  last_hold_next(0) <= k_last_tok;
  raw_score_hold_next <= k_score;

  tok_idx_hold_reg : entity work.generic_register
    generic map (WIDTH => TOK_W)
    port map (clk => clk, rst => rst, en => hold_en, d => tok_idx_hold_next, q => tok_idx_hold_slv);

  last_hold_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => hold_en, d => last_hold_next, q => last_hold_slv);

  last_hold <= last_hold_slv(0);

  raw_score_hold_reg : entity work.generic_register
    generic map (WIDTH => NUM_Q * SCORE_W)
    port map (clk => clk, rst => rst, en => hold_en, d => raw_score_hold_next, q => raw_score_hold);

  ----------------------------------------------------------------
  -- issue: combinational routing of this cycle's fpu/lookup/RAM inputs
  -- and per-query register writes, from (mode, step, q_idx). Same role
  -- as act_quantizer.vhdl's/sb_finish.vhdl's own 'issue' process.
  ----------------------------------------------------------------
  issue : process (mode, step, q_idx, last_hold, tok_idx_hold, raw_score_hold, seq_first,
                    fpu_y, lut_y, ram_rdata, m_arr, l_arr, chunk_max_arr)
    variable qi : integer;
  begin
    qi := to_integer(q_idx);

    fpu_op  <= ALU_MAX;
    fpu_cvt <= CVT_I2F;
    fpu_sub <= (others => '0');
    fpu_a   <= (others => '0');
    fpu_b   <= (others => '0');
    fpu_ce  <= '0';

    lut_ce <= '0';
    lut_x  <= (others => '0');

    ram_we    <= '0';
    ram_re    <= '0';
    ram_waddr <= (others => '0');
    ram_raddr <= (others => '0');
    ram_wdata <= (others => '0');

    m_wr <= '0'; m_next <= (others => '0');
    l_wr <= '0'; l_next <= (others => '0');
    chunk_max_wr <= '0'; chunk_max_next <= (others => '0');
    rescale_wr   <= '0'; rescale_next   <= (others => '0');

    p_valid <= '0';
    p_query <= (others => '0');
    p_q15   <= (others => '0');

    case mode is

      ----------------------------------------------------------------
      when MODE_K =>
        case to_integer(step) is
          when 0 =>
            fpu_op  <= ALU_CVT; fpu_cvt <= CVT_I2F;
            fpu_a   <= std_logic_vector(resize(signed(raw_score_hold((qi + 1) * SCORE_W - 1 downto qi * SCORE_W)), 32));
            fpu_ce  <= '1';
          when 1 =>
            -- fpu_y = this token's score, converted to fp32 (step 0, zero-slack)
            ram_we    <= '1';
            ram_waddr <= to_unsigned(qi * CHUNK + to_integer(tok_idx_hold), RAM_ADDR_W);
            ram_wdata <= fpu_y;
            fpu_op <= ALU_MAX;
            fpu_a  <= fpu_y when to_integer(tok_idx_hold) = 0 else chunk_max_arr(qi);
            fpu_b  <= fpu_y;
            fpu_ce <= '1';
          when others => -- 2
            -- fpu_y = running max(chunk_max, this score) (step 1, zero-slack)
            chunk_max_wr   <= '1';
            chunk_max_next <= fpu_y;
        end case;

      ----------------------------------------------------------------
      when MODE_KFIN =>
        case to_integer(step) is
          when 0 =>
            fpu_op <= ALU_MAX; fpu_a <= m_arr(qi); fpu_b <= chunk_max_arr(qi); fpu_ce <= '1';
          when 1 =>
            -- fpu_y = max(m_old, chunk_max_local) (step 0, zero-slack)
            m_wr   <= '1';
            m_next <= chunk_max_arr(qi) when seq_first = '1' else fpu_y;
            fpu_op <= ALU_ADD; fpu_a <= m_arr(qi); fpu_b <= fpu_y;
            fpu_sub(NEG_B) <= '1';
            fpu_ce <= '1';
          when 2 =>
            -- fpu_y = delta = m_old - m_new (step 1, zero-slack)
            lut_x <= fpu_y; lut_ce <= '1';
          when 3 =>
            -- lut_y = rescale = 2^delta (step 2, zero-slack)
            rescale_wr   <= '1';
            rescale_next <= lut_y;
            fpu_op <= ALU_MUL; fpu_a <= l_arr(qi); fpu_b <= lut_y; fpu_ce <= '1';
          when others => -- 4
            -- fpu_y = l_old * rescale (step 3, zero-slack)
            l_wr   <= '1';
            l_next <= x"00000000" when seq_first = '1' else fpu_y;
        end case;

      ----------------------------------------------------------------
      when MODE_V =>
        case to_integer(step) is
          when 0 =>
            ram_re    <= '1';
            ram_raddr <= to_unsigned(qi * CHUNK + to_integer(tok_idx_hold), RAM_ADDR_W);
          when 1 =>
            -- ram_rdata = this token's stored fp32 score (issued step 0)
            fpu_op <= ALU_ADD; fpu_a <= ram_rdata; fpu_b <= m_arr(qi);
            fpu_sub(NEG_B) <= '1';
            fpu_ce <= '1';
          when 2 =>
            -- fpu_y = delta = score - m (step 1, zero-slack)
            lut_x <= fpu_y; lut_ce <= '1';
          when 3 =>
            -- lut_y = p_fp = 2^delta (step 2, zero-slack)
            fpu_op <= ALU_ADD; fpu_a <= l_arr(qi); fpu_b <= lut_y; fpu_ce <= '1';
          when 4 =>
            -- fpu_y = l_new = l_old + p_fp (step 3, zero-slack); lut_y
            -- still holds p_fp unchanged (no lookup issued at step 3)
            l_wr   <= '1';
            l_next <= fpu_y;
            fpu_op <= ALU_MUL; fpu_a <= lut_y; fpu_b <= CONST_32768; fpu_ce <= '1';
          when 5 =>
            -- fpu_y = p_fp * 32768.0 (step 4, zero-slack)
            fpu_op <= ALU_CVT; fpu_cvt <= CVT_F2I; fpu_a <= fpu_y; fpu_ce <= '1';
          when others => -- 6
            -- fpu_y = round(p_fp * 32768.0) as int32, in [0,32768] (step 5, zero-slack)
            p_valid <= '1';
            p_query <= q_idx;
            p_q15   <= fpu_y(15 downto 0);
        end case;

      when others => null; -- MODE_IDLE

    end case;
  end process issue;

  fpu : entity work.generic_fpu
    port map (clk => clk, ce => fpu_ce, op => fpu_op, sub => fpu_sub, cvt => fpu_cvt,
              a => fpu_a, b => fpu_b, y => fpu_y, flag => open);

  lut : entity work.generic_lookup
    port map (
      clk => clk, ce => lut_ce, slot => to_unsigned(LUT_SLOT, 3), x => lut_x, y => lut_y, flag => open,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  score_ram : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => NUM_Q * CHUNK)
    port map (clk => clk, we => ram_we, waddr => ram_waddr, wdata => ram_wdata,
              re => ram_re, raddr => ram_raddr, rdata => ram_rdata);

  ----------------------------------------------------------------
  -- per-query state: one shared 'next value' bus per register kind,
  -- decoded to whichever lane q_idx currently selects (same broadcast-
  -- bus-plus-decoded-enable shape as act_quantizer.vhdl's q_gen).
  ----------------------------------------------------------------
  reg_gen : for i in 0 to NUM_Q - 1 generate
    signal en_m, en_l, en_cmax, en_rescale : std_logic;
  begin
    en_m       <= m_wr         when to_integer(q_idx) = i else '0';
    en_l       <= l_wr         when to_integer(q_idx) = i else '0';
    en_cmax    <= chunk_max_wr when to_integer(q_idx) = i else '0';
    en_rescale <= rescale_wr   when to_integer(q_idx) = i else '0';

    m_reg_i : entity work.generic_register
      generic map (WIDTH => 32)
      port map (clk => clk, rst => rst, en => en_m, d => m_next, q => m_arr(i));

    l_reg_i : entity work.generic_register
      generic map (WIDTH => 32)
      port map (clk => clk, rst => rst, en => en_l, d => l_next, q => l_arr(i));

    cmax_reg_i : entity work.generic_register
      generic map (WIDTH => 32)
      port map (clk => clk, rst => rst, en => en_cmax, d => chunk_max_next, q => chunk_max_arr(i));

    rescale_reg_i : entity work.generic_register
      generic map (WIDTH => 32)
      port map (clk => clk, rst => rst, en => en_rescale, d => rescale_next, q => rescale_arr(i));

    rescale_out((i + 1) * 32 - 1 downto i * 32) <= rescale_arr(i);
    l_out((i + 1) * 32 - 1 downto i * 32)       <= l_arr(i);
  end generate reg_gen;

end architecture behav;
