library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Rescaler U10 entity 1/3 (claude_docs/04-vhdl-module-list.md's U10 table,
-- claude_docs/08-vhdl-implementation-spec.md S2.2): "Per column: scale
-- multiply, sum 16 groups (2 tiles for Q4_K), optional min_term." One
-- instance per (output column, DSP lane) -- the caller sequences 16 'ce'
-- pulses per super-block, one per group, presenting that group's already-
-- lane-extracted 'lane_sum' (int_mul_scale.vhdl's header: "lane0 =
-- sext(P, SPACING), lane1 = (P - lane0) >> SPACING ... a plain signed
-- slice/subtract the caller does inline" -- group_scale_acc is that
-- caller for one lane) plus that group's scale/min/sum_x.
--
-- RESOLVES practice #15's flagged gap (this file's header carries the
-- derivation; CLAUDE.md's practice #16 below points back here). Q4_K's
-- true ggml formula is `d*sc*q - dmin*m` using the RAW unsigned nibble
-- q (0..15); this project's array packs the weight as `q-8` (matching
-- Q3_K's/Q6_K's own native-formula offsets, but NOT Q4_K's, which has no
-- per-weight centering of its own -- see q4k_unpack.vhdl's header for the
-- full background). The array's hardware therefore computes
-- `lane_sum = Sigma(q_packed*x) = Sigma(q*x) - 8*Sigma(x)`, so recovering
-- the true `sc*Sigma(q*x)` term (the one that gets scaled by `d` in
-- sb_finish) needs `sc*lane_sum + 8*sc*Sigma(x)` added back -- an extra
-- term neither 08 S2.2's rescaler-ops table nor int_acc.vhdl's header
-- lists. This entity computes that add-back with the SAME multiplier
-- shape already needed for Q4_K's existing, spec-documented `m * Sigma(x)`
-- subtraction (module list S2.2's `min_term`) -- both are "6-bit scale-
-- like value times 13-bit Sigma(x)" -- just added instead of subtracted,
-- and pre-shifted left by log2(WEIGHT_OFFSET) (a free wire shift, since
-- WEIGHT_OFFSET=8 is a power of two, not a real multiply). Q3_K/Q6_K
-- never set HAS_MIN_TERM, so they never pay for or need this path: their
-- packed offset (`q-4`, `q-32`) already IS ggml's true per-weight formula.
--
-- HAS_MIN_TERM gates BOTH the dmin*m subtraction path AND this add-back,
-- since ggml only defines Q4_K as asymmetric -- the two are the same
-- generic's worth of "does this format need a second, Sigma(x)-driven
-- term" and always travel together in this design.
--
-- ONE-CYCLE PIPELINE STAGGER [D, new instance of the same class of bug as
-- practice #10/#11/#12]: int_mul_scale.vhdl registers its product on 'ce'
-- (1-cycle latency: the product for group g's inputs becomes visible one
-- cycle after the 'ce' pulse that presented them, not the same cycle).
-- int_acc.vhdl's own 'ce' captures whatever 'd' reads *at the time of
-- ITS OWN ce pulse* into the accumulator. Feeding int_acc the SAME raw
-- 'ce' train int_mul_scale consumes would make int_acc sample the
-- upstream product's PRE-edge (i.e. previous group's, or garbage on the
-- first pulse) value every time -- the textbook same-edge peer-register
-- race, here between two DIFFERENT primitives chained together for the
-- first time rather than within one entity. Fixed by registering 'ce'
-- through one extra generic_register stage (the same "ce_d" pattern
-- dsp_mac2.vhdl already uses for lane0_valid/lane1_valid) before it
-- reaches either int_acc instance -- 'rst' needs no such delay, since it
-- clears int_acc's own register directly and never passes through
-- int_mul_scale at all.
entity group_scale_acc is
  generic (
    LANE_WIDTH    : positive := 17; -- extracted per-group lane sum width (int_mul_scale.vhdl)
    SCALE_WIDTH   : positive := 8;  -- signed width fed to int_mul_scale; caller zero-extends Q3_K/Q4_K's
                                     -- unsigned 6-bit sc/m into this many bits (top bits 0) so they read
                                     -- as non-negative signed -- NOT the raw 6-bit width, which would
                                     -- misread sc/m values 32..63 as negative (see int_mul_scale.vhdl's
                                     -- own practice #14 note on group_scale's sign)
    SUM_X_WIDTH   : positive := 13; -- Sigma(x) per group, signed (04 S2.2's "13-bit Sigma x"); ignored
                                     -- when HAS_MIN_TERM = false
    ACC_WIDTH     : positive := 32; -- must match sb_finish.vhdl's fixed 32-bit CVT_I2F input if paired
                                     -- with it directly (sb_finish has no ACC_WIDTH generic of its own)
    HAS_MIN_TERM  : boolean  := false; -- true selects Q4_K's dmin*m subtraction + weight-offset add-back
    WEIGHT_OFFSET : positive := 8      -- the per-weight packing offset needing compensation (Q4_K's q-8);
                                        -- must be a power of two, asserted below
  );
  port (
    clk, rst : in std_logic; -- rst: synchronous clear, pulse at super-block start (see int_acc.vhdl)
    ce       : in std_logic; -- accumulate this group's inputs (pulse once per group, 16x per super-block)

    lane_sum : in signed(LANE_WIDTH - 1 downto 0);
    scale    : in signed(SCALE_WIDTH - 1 downto 0); -- this group's sc
    min_val  : in signed(SCALE_WIDTH - 1 downto 0); -- this group's m (ignored unless HAS_MIN_TERM)
    sum_x    : in signed(SUM_X_WIDTH - 1 downto 0); -- this group's Sigma(x) (ignored unless HAS_MIN_TERM;
                                                      -- ties back to act_quantizer, U8, not yet built --
                                                      -- caller-supplied dependency, same treatment as
                                                      -- wt_pack.vhdl's undetermined consumer)

    sc_acc  : out signed(ACC_WIDTH - 1 downto 0); -- accumulated term to be scaled by 'd' in sb_finish
    min_acc : out signed(ACC_WIDTH - 1 downto 0)  -- accumulated term to be scaled by 'dmin' and
                                                    -- SUBTRACTED in sb_finish; all-zero when not HAS_MIN_TERM
  );
end entity group_scale_acc;

architecture behav of group_scale_acc is
  constant SHIFT_AMT  : natural  := clog2(WEIGHT_OFFSET);
  constant TERM_WIDTH : positive := LANE_WIDTH + SCALE_WIDTH + 1; -- +1: headroom for the bias add-back

  signal ce_d_slv : std_logic_vector(0 downto 0);
  signal ce_d     : std_logic; -- 'ce' delayed one cycle -- see header's pipeline-stagger note

  signal sc_product : signed(LANE_WIDTH + SCALE_WIDTH - 1 downto 0);
  signal sc_term     : signed(TERM_WIDTH - 1 downto 0);

  signal bias_raw    : signed(SUM_X_WIDTH + SCALE_WIDTH - 1 downto 0);
  signal min_product  : signed(SUM_X_WIDTH + SCALE_WIDTH - 1 downto 0);
begin

  assert WEIGHT_OFFSET = 2 ** SHIFT_AMT
    report "group_scale_acc: WEIGHT_OFFSET must be a power of two (it becomes a wire shift, not a real multiply)"
    severity failure;

  assert (SUM_X_WIDTH + SHIFT_AMT) <= LANE_WIDTH
    report "group_scale_acc: sum_x<<log2(WEIGHT_OFFSET) doesn't fit under sc_product's headroom -- widen LANE_WIDTH"
    severity failure;

  ce_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => '0', en => '1', d(0) => ce, q => ce_d_slv);
  ce_d <= ce_d_slv(0);

  sc_mul : entity work.int_mul_scale
    generic map (LANE_WIDTH => LANE_WIDTH, SCALE_WIDTH => SCALE_WIDTH)
    port map (clk => clk, ce => ce, lane_sum => lane_sum, group_scale => scale, p => sc_product);

  no_min_gen : if not HAS_MIN_TERM generate
    sc_term <= resize(sc_product, TERM_WIDTH);
    min_acc <= (others => '0');
  end generate no_min_gen;

  min_gen : if HAS_MIN_TERM generate
    bias_mul : entity work.int_mul_scale
      generic map (LANE_WIDTH => SUM_X_WIDTH, SCALE_WIDTH => SCALE_WIDTH)
      port map (clk => clk, ce => ce, lane_sum => sum_x, group_scale => scale, p => bias_raw);

    min_mul : entity work.int_mul_scale
      generic map (LANE_WIDTH => SUM_X_WIDTH, SCALE_WIDTH => SCALE_WIDTH)
      port map (clk => clk, ce => ce, lane_sum => sum_x, group_scale => min_val, p => min_product);

    sc_term <= resize(sc_product, TERM_WIDTH) +
               resize(shift_left(resize(bias_raw, TERM_WIDTH), SHIFT_AMT), TERM_WIDTH);

    min_acc_inst : entity work.int_acc
      generic map (IN_WIDTH => SUM_X_WIDTH + SCALE_WIDTH, ACC_WIDTH => ACC_WIDTH)
      port map (clk => clk, rst => rst, ce => ce_d, d => min_product, acc => min_acc);
  end generate min_gen;

  sc_acc_inst : entity work.int_acc
    generic map (IN_WIDTH => TERM_WIDTH, ACC_WIDTH => ACC_WIDTH)
    port map (clk => clk, rst => rst, ce => ce_d, d => sc_term, acc => sc_acc);

end architecture behav;
