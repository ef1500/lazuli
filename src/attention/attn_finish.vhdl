library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U11 entity 5/6 (claude_docs/04-vhdl-module-list.md's `attn_finish` row:
-- "Divide by the sum (recip, fmul), quantize back for the o matmul").
--
-- Two steps, run once per resident query, after that query's whole
-- sequence (all chunks) has finished accumulating into pv_lanes.vhdl's
-- o_acc:
--   1) NORMALIZE: o_norm[d] = o_acc[d] * recip(l) for d in 0..DIM-1 --
--      no on-chip divider anywhere in this design (same constraint
--      act_quantizer.vhdl's own header explains), so division-by-l
--      becomes one `generic_lookup` TAB_MANT/recip call plus DIM
--      multiplies through a local, dedicated `generic_fpu`, sequenced
--      like sb_finish.vhdl's/act_quantizer.vhdl's own step machines.
--   2) QUANTIZE: hands the normalized DIM-vector to an internal
--      `act_quantizer` instance (BLOCK_SIZE=>DIM, SUBGROUP=>DIM) to get
--      the abs-max -> reciprocal -> clamp-to-+-127 int8 vector this
--      entity's own job description asks for -- this is EXACTLY act_
--      quantizer.vhdl's own algorithm (the doc's "quantize back" is the
--      same "activation quantization" job, just for attention's output
--      instead of a generic activation block), so this entity reuses
--      that entity wholesale rather than re-deriving its ~250-line FSM.
--      `sum_out` (Q4_K's per-32 Sigma(q), not needed here) is left open.
--
-- SCRATCH RAM + REPLAY, same shape as act_quantizer.vhdl's own two-pass
-- buffer: o_norm[d] is computed once (step 1) and stored, then REPLAYED
-- into the internal act_quantizer as its in_data stream (step 2) --
-- act_quantizer's own contract requires 'in_valid' held for exactly DIM
-- CONSECUTIVE cycles with no gap, so PH_AQ_PRESENT prefetches entry d+1
-- (via 'ram_re'/'ram_raddr', 1-cycle registered read) while presenting
-- entry d, the same one-cycle-ahead overlap kv_reader.vhdl/vec_seq.vhdl
-- already use for their own RAM reads.
--
-- act_quantizer's own 'start' contract (see tb_act_quantizer.vhdl):
-- 'start' pulses one cycle BEFORE in_valid/in_data must already be
-- presenting element 0 -- PH_AQ_ISSUE pulses aq_start while prefetching
-- element 0 (ram_re/raddr=0), so by PH_AQ_PRESENT's first cycle (element
-- 0), act_quantizer has already moved into its own ingest phase and
-- ram_rdata(0) is already valid -- the two line up by construction.
--
-- A harmless act_quantizer.vhdl "in_valid must stay high" WARNING (not
-- error) fires once per run, from PH_AQ_ISSUE/PH_AQ_PRESENT's own edge --
-- same benign multi-delta settling artifact tb_act_quantizer.vhdl's own
-- header already documents for an external caller driving this exact
-- protocol, not a real one-cycle gap (tb_attn_finish.vhdl's q_out/
-- scale_out come out bit-exact despite it).
--
-- ONE SHARED RECIP TABLE [D]: attn_finish owns its own local generic_
-- lookup (for recip(l)) IN ADDITION to the internal act_quantizer's own
-- (for its abs-max reciprocal) -- two physical table instances, same as
-- this codebase's established "dedicated resource, correctness first,
-- TDM deferred" choice elsewhere (group_scale_acc.vhdl/softmax_online.
-- vhdl). Rather than expose two separate ld_* ports, both are loaded
-- from ONE ld_* bus at the SAME RECIP_SLOT, broadcast to both -- the
-- host loads one recip table once per attn_finish instance, not twice.
entity attn_finish is
  generic (
    DIM        : positive := 128;
    RECIP_SLOT : natural range 0 to 7 := 0
  );
  port (
    clk, rst : in std_logic;

    start : in std_logic;
    l_in  : in std_logic_vector(31 downto 0);          -- this query's final running sum (fp32)
    o_acc_in : in std_logic_vector(DIM * 32 - 1 downto 0); -- this query's accumulated o vector (fp32)

    busy : out std_logic;
    done : out std_logic; -- pulses one cycle, q_out/scale_out valid

    q_out     : out std_logic_vector(DIM * 8 - 1 downto 0);
    scale_out : out std_logic_vector(31 downto 0);

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
end entity attn_finish;

architecture behav of attn_finish is
  constant D_W : positive := clog2(DIM);

  constant PH_IDLE         : std_logic_vector(3 downto 0) := "0000";
  constant PH_RECIP        : std_logic_vector(3 downto 0) := "0001";
  constant PH_NORM_ISSUE   : std_logic_vector(3 downto 0) := "0010";
  constant PH_NORM_CAPTURE : std_logic_vector(3 downto 0) := "0011";
  constant PH_AQ_ISSUE     : std_logic_vector(3 downto 0) := "0100";
  constant PH_AQ_PRESENT   : std_logic_vector(3 downto 0) := "0101";
  constant PH_AQ_WAIT      : std_logic_vector(3 downto 0) := "0110";
  constant PH_CAPTURE      : std_logic_vector(3 downto 0) := "0111";
  constant PH_DONE         : std_logic_vector(3 downto 0) := "1000";

  signal phase, phase_next : std_logic_vector(3 downto 0);
  signal d_idx_slv, d_idx_next_slv : std_logic_vector(D_W - 1 downto 0);
  signal d_idx : unsigned(D_W - 1 downto 0);

  signal fpu_op  : alu_op_t;
  signal fpu_a, fpu_b : std_logic_vector(31 downto 0);
  signal fpu_ce  : std_logic;
  signal fpu_y   : std_logic_vector(31 downto 0);

  signal lut_ce : std_logic;
  signal lut_x, lut_y : std_logic_vector(31 downto 0);

  signal ram_we, ram_re : std_logic;
  signal ram_waddr, ram_raddr : unsigned(D_W - 1 downto 0);
  signal ram_wdata, ram_rdata : std_logic_vector(31 downto 0);

  signal aq_start, aq_busy, aq_done : std_logic;
  signal aq_in_valid : std_logic;
  signal aq_in_data  : std_logic_vector(31 downto 0);
  signal aq_q_out    : std_logic_vector(DIM * 8 - 1 downto 0);
  signal aq_scale_out : std_logic_vector(31 downto 0);

  signal q_out_en, scale_out_en : std_logic;
begin

  d_idx <= unsigned(d_idx_slv);

  ----------------------------------------------------------------
  -- phase / d_idx sequencing (act_quantizer.vhdl's style)
  ----------------------------------------------------------------
  phase_next <=
    PH_RECIP        when (phase = PH_IDLE and start = '1') else
    PH_NORM_ISSUE   when (phase = PH_RECIP) else
    PH_NORM_CAPTURE when (phase = PH_NORM_ISSUE) else
    PH_AQ_ISSUE     when (phase = PH_NORM_CAPTURE and d_idx = DIM - 1) else
    PH_NORM_ISSUE   when (phase = PH_NORM_CAPTURE) else
    PH_AQ_PRESENT   when (phase = PH_AQ_ISSUE) else
    PH_AQ_WAIT      when (phase = PH_AQ_PRESENT and d_idx = DIM - 1) else
    PH_AQ_PRESENT   when (phase = PH_AQ_PRESENT) else
    PH_CAPTURE      when (phase = PH_AQ_WAIT and aq_done = '1') else
    PH_AQ_WAIT      when (phase = PH_AQ_WAIT) else
    PH_DONE         when (phase = PH_CAPTURE) else
    PH_IDLE         when (phase = PH_DONE) else
    PH_IDLE;

  phase_reg : entity work.generic_register
    generic map (WIDTH => 4)
    port map (clk => clk, rst => rst, en => '1', d => phase_next, q => phase);

  d_idx_next_slv <=
    std_logic_vector(to_unsigned(0, D_W)) when (phase = PH_IDLE) else
    std_logic_vector(to_unsigned(0, D_W)) when (phase = PH_NORM_CAPTURE and d_idx = DIM - 1) else
    std_logic_vector(d_idx + 1)           when (phase = PH_NORM_CAPTURE) else
    std_logic_vector(to_unsigned(0, D_W)) when (phase = PH_AQ_ISSUE) else
    std_logic_vector(d_idx + 1)           when (phase = PH_AQ_PRESENT and d_idx /= DIM - 1) else
    d_idx_slv;

  d_idx_reg : entity work.generic_register
    generic map (WIDTH => D_W)
    port map (clk => clk, rst => rst, en => '1', d => d_idx_next_slv, q => d_idx_slv);

  busy <= '0' when phase = PH_IDLE else '1';
  done <= '1' when phase = PH_DONE else '0';

  ----------------------------------------------------------------
  -- issue: combinational routing, sb_finish.vhdl's/act_quantizer.vhdl's
  -- own 'issue' process shape.
  ----------------------------------------------------------------
  issue : process (phase, d_idx, l_in, o_acc_in, lut_y, fpu_y, ram_rdata)
    variable di : integer;
  begin
    di := to_integer(d_idx);

    fpu_op <= ALU_MUL;
    fpu_a  <= (others => '0');
    fpu_b  <= (others => '0');
    fpu_ce <= '0';

    lut_ce <= '0';
    lut_x  <= (others => '0');

    ram_we    <= '0';
    ram_re    <= '0';
    ram_waddr <= (others => '0');
    ram_raddr <= (others => '0');
    ram_wdata <= (others => '0');

    aq_start    <= '0';
    aq_in_valid <= '0';
    aq_in_data  <= (others => '0');

    case phase is
      when PH_RECIP =>
        lut_x <= l_in; lut_ce <= '1';

      when PH_NORM_ISSUE =>
        fpu_op <= ALU_MUL;
        fpu_a  <= o_acc_in((di + 1) * 32 - 1 downto di * 32);
        fpu_b  <= lut_y; -- = recip(l), from PH_RECIP (stable, only computed once)
        fpu_ce <= '1';

      when PH_NORM_CAPTURE =>
        -- fpu_y = o_acc[d] * recip(l) (PH_NORM_ISSUE, zero-slack)
        ram_we    <= '1';
        ram_waddr <= d_idx;
        ram_wdata <= fpu_y;

      when PH_AQ_ISSUE =>
        aq_start  <= '1';
        ram_re    <= '1';
        ram_raddr <= to_unsigned(0, D_W);

      when PH_AQ_PRESENT =>
        aq_in_valid <= '1';
        aq_in_data  <= ram_rdata; -- prefetched by the PREVIOUS cycle's ram_re
        if di /= DIM - 1 then
          ram_re    <= '1';
          ram_raddr <= to_unsigned(di + 1, D_W);
        end if;

      when others => null;
    end case;
  end process issue;

  fpu : entity work.generic_fpu
    port map (clk => clk, ce => fpu_ce, op => fpu_op, sub => "000", cvt => CVT_I2F,
              a => fpu_a, b => fpu_b, y => fpu_y, flag => open);

  lut : entity work.generic_lookup
    port map (
      clk => clk, ce => lut_ce, slot => to_unsigned(RECIP_SLOT, 3), x => lut_x, y => lut_y, flag => open,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  norm_ram : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => DIM)
    port map (clk => clk, we => ram_we, waddr => ram_waddr, wdata => ram_wdata,
              re => ram_re, raddr => ram_raddr, rdata => ram_rdata);

  aq : entity work.act_quantizer
    generic map (BLOCK_SIZE => DIM, SUBGROUP => DIM, RECIP_SLOT => RECIP_SLOT)
    port map (
      clk => clk, rst => rst, start => aq_start, in_valid => aq_in_valid, in_data => aq_in_data,
      busy => aq_busy, done => aq_done, q_out => aq_q_out, scale_out => aq_scale_out, sum_out => open,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  q_out_en     <= '1' when phase = PH_CAPTURE else '0';
  scale_out_en <= '1' when phase = PH_CAPTURE else '0';

  q_out_reg : entity work.generic_register
    generic map (WIDTH => DIM * 8)
    port map (clk => clk, rst => rst, en => q_out_en, d => aq_q_out, q => q_out);

  scale_out_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => rst, en => scale_out_en, d => aq_scale_out, q => scale_out);

end architecture behav;
