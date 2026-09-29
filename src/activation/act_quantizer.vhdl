library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U8 entity 1/2 (syseng_docs/03-architecture-units.md's U8, syseng_docs/
-- 04-vhdl-module-list.md's `act_quantizer` row): per BLOCK_SIZE-element
-- (QK_K=256) block, "abs-max -> recip -> multiply -> round -> clamp
-- +-127", plus the per-32 Sigma(q) group sums Q4_K's asymmetric rescale
-- needs (this session's group_scale_acc.vhdl's `sum_x` input -- see its
-- header; `q` there IS this entity's own `q_out`, confirming the naming
-- match is not a coincidence).
--
-- ALGORITHM, worked out from "abs-max -> recip -> multiply -> round ->
-- clamp" (03 S/U8, 04 S2.2's activation-quantizer note) since neither
-- doc spells out the exact op sequence: there is no on-chip divider
-- anywhere in this design (04 S2's "three arithmetic blocks" have none),
-- so `x_i / scale` is computed as `x_i * (1/scale)` via ONE `generic_
-- lookup` TAB_MANT (recip) call, not 256 divisions. Getting BOTH the
-- per-element multiplier (1/scale) and the value actually stored for
-- later dequant (`scale` itself, S2.2's `act_scale`) needs the
-- reciprocal taken TWICE -- once on `amax` (giving `127/amax` after a
-- multiply by the exact constant 127.0), once on THAT result (giving
-- back `amax/127 = scale`) -- rather than needing a second constant
-- (`1/127`, awkward to encode/verify by hand) alongside the first:
--   amax      = max(|x_i|) over the block                         (streaming abs-max, see below)
--   inv_scale = recip(amax) * 127.0                                (2 lookups/multiplies total,
--   scale     = recip(inv_scale)   [[= amax/127 exactly, in real math]]   both reusing ONE shared
--   q_i       = clamp(round(x_i * inv_scale), -127, 127)                  generic_lookup instance)
-- `clamp to +-127`, not the full signed-8-bit +-128, is deliberate and
-- already load-bearing elsewhere in this repo: `04` S2.1 found INT8
-- activation value -128 breaks `dsp_mac2`'s packed-lane arithmetic at
-- Q4_K's depth-32 spacing, which is why the quantizer -- not the array
-- -- is the place this gets enforced.
--
-- STREAMING ABS-MAX: taking the sign bit off an IEEE-754 float and
-- reading the rest as a plain unsigned magnitude preserves ordering for
-- any non-negative float (larger exponent, or equal-exponent-larger-
-- mantissa, is always the larger value) -- so `abs(x)` is a wire
-- operation (clear bit 31), not an arithmetic one, and doesn't need
-- int_absmax_tree.vhdl's two's-complement-negation trick (that one's
-- for signed INTEGER magnitudes, not float bit patterns). The actual
-- max-of-256 reduction is done SEQUENTIALLY through `generic_fpu`'s
-- ALU_MAX (IEEE-ordering-aware, via f32_key), one comparison per
-- incoming element, rather than a 255-comparator combinational tree --
-- this task runs once per 256-element block ahead of a matmul, not on
-- the array's own per-clock critical path (`03`'s own characterization
-- of U8/U12: "latency matters more than throughput here"), so trading
-- tree parallelism for one shared, reused ALU is the right call, not a
-- shortcut.
--
-- TWO-PASS, RAM-BUFFERED: abs-max needs to see every element before
-- `scale` is known, and quantizing needs to revisit every element
-- afterward -- so this entity owns a local scratch `generic_sdp_ram`
-- (BLOCK_SIZE x 32-bit) holding the raw fp32 block during ingest, read
-- back during requantize. This buffer is local/transient (this entity's
-- own two-pass working set), NOT act_ram/act_scale_ram -- those are
-- act_store.vhdl's persistent, ping-ponged storage for the QUANTIZED
-- result this entity produces.
--
-- INTERFACE, [D] (no producer exists yet to match against): 'start'
-- begins a block; the caller must then hold 'in_valid'='1' for exactly
-- BLOCK_SIZE consecutive cycles, presenting one fp32 element per cycle
-- -- no backpressure/ready port, the simplest streaming convention
-- already used for a fixed-length accumulate in this repo (group_scale_
-- acc.vhdl's own 'ce' train), rather than wt_reader.vhdl's ready/valid
-- handshake (that one exists because ITS caller can't be assumed to
-- always have data ready every cycle; U12's vector-unit output, at only
-- ~18% ALU utilisation per `03`, plausibly can, but this is a documented
-- assumption, not a fact -- add backpressure here if it turns out wrong).
--
-- generic_lookup's TAB_MANT/recip table itself is NOT configured here --
-- like lazuli.vhdl's own vector-unit tile, this entity only broadcasts
-- the ld_* load port through to its internal generic_lookup instance,
-- and RECIP_SLOT (which of the 8 slots the host has pre-loaded with
-- TAB_MANT/recip, at boot, before any quantize runs) is a caller-set
-- generic, not a fixed convention -- nothing in this repo hardcodes a
-- slot number for any function yet.
entity act_quantizer is
  generic (
    BLOCK_SIZE : positive := 256; -- QK_K
    SUBGROUP   : positive := 32;  -- Q4_K's activation group-sum granularity
    RECIP_SLOT : natural range 0 to 7 := 0
  );
  port (
    clk, rst : in std_logic;

    start    : in std_logic;
    in_valid : in std_logic;
    in_data  : in std_logic_vector(31 downto 0); -- fp32 activation, one per cycle

    busy : out std_logic;
    done : out std_logic; -- pulses one cycle, q_out/scale_out/sum_out all valid

    q_out     : out std_logic_vector(BLOCK_SIZE * 8 - 1 downto 0);           -- [i], signed int8, clamped +-127
    scale_out : out std_logic_vector(31 downto 0);                          -- fp32, ~= amax/127
    sum_out   : out std_logic_vector((BLOCK_SIZE / SUBGROUP) * 13 - 1 downto 0); -- [g], signed Sigma(q) per SUBGROUP

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
end entity act_quantizer;

architecture behav of act_quantizer is
  constant NUM_SUBGROUPS : positive := BLOCK_SIZE / SUBGROUP;
  constant EIDX_W : positive := clog2(BLOCK_SIZE);
  constant CONST_127 : std_logic_vector(31 downto 0) := x"42FE0000"; -- 127.0 exactly

  constant PH_IDLE          : std_logic_vector(3 downto 0) := "0000";
  constant PH_INGEST        : std_logic_vector(3 downto 0) := "0001";
  constant PH_INGEST_DRAIN  : std_logic_vector(3 downto 0) := "0010";
  constant PH_RECIP1        : std_logic_vector(3 downto 0) := "0011";
  constant PH_MUL127        : std_logic_vector(3 downto 0) := "0100";
  constant PH_RECIP2        : std_logic_vector(3 downto 0) := "0101";
  constant PH_CAPTURE_SCALE : std_logic_vector(3 downto 0) := "0110";
  constant PH_REQUANT       : std_logic_vector(3 downto 0) := "0111";
  constant PH_CAPTURE_LAST  : std_logic_vector(3 downto 0) := "1000";
  constant PH_DONE          : std_logic_vector(3 downto 0) := "1001";

  signal phase, phase_next : std_logic_vector(3 downto 0);

  signal elem_idx_slv, elem_idx_next_slv : std_logic_vector(EIDX_W - 1 downto 0);
  signal elem_idx : unsigned(EIDX_W - 1 downto 0);

  signal sub_step_slv, sub_step_next_slv : std_logic_vector(1 downto 0);
  signal sub_step : unsigned(1 downto 0);

  signal amax_r, inv_scale_r, scale_r : std_logic_vector(31 downto 0);

  signal fpu_op  : alu_op_t;
  signal fpu_sub : std_logic_vector(2 downto 0);
  signal fpu_cvt : cvt_op_t;
  signal fpu_a, fpu_b : std_logic_vector(31 downto 0);
  signal fpu_ce  : std_logic;
  signal fpu_y   : std_logic_vector(31 downto 0);

  signal lut_ce   : std_logic;
  signal lut_slot : unsigned(2 downto 0);
  signal lut_x    : std_logic_vector(31 downto 0);
  signal lut_y    : std_logic_vector(31 downto 0);

  signal ram_we, ram_re : std_logic;
  signal ram_waddr, ram_raddr : unsigned(EIDX_W - 1 downto 0);
  signal ram_wdata, ram_rdata : std_logic_vector(31 downto 0);

  signal f2i_result : signed(31 downto 0);
  signal clamped_q  : signed(7 downto 0);

  signal acc_rst, acc_ce : std_logic;
  signal acc_val : signed(12 downto 0);

  signal amax_en, inv_scale_en, scale_en : std_logic;
begin

  assert (BLOCK_SIZE mod SUBGROUP) = 0
    report "act_quantizer: BLOCK_SIZE must be an exact multiple of SUBGROUP"
    severity failure;

  assert not (phase = PH_INGEST and in_valid = '0')
    report "act_quantizer: in_valid must stay high for all BLOCK_SIZE ingest cycles (no backpressure, see header)"
    severity warning;

  elem_idx <= unsigned(elem_idx_slv);
  sub_step <= unsigned(sub_step_slv);

  ----------------------------------------------------------------
  -- phase / counters: a Moore-style sequencer (phase_reg) plus two
  -- counters that mean different things in different phases (elem_idx
  -- counts ingest position 0..BLOCK_SIZE-1 during PH_INGEST, then
  -- requant element position during PH_REQUANT; sub_step only moves
  -- during PH_REQUANT, one of 4 sub-cycles per element -- see header).
  ----------------------------------------------------------------
  phase_next <=
    PH_INGEST        when (phase = PH_IDLE and start = '1') else
    PH_INGEST_DRAIN  when (phase = PH_INGEST and elem_idx = BLOCK_SIZE - 1) else
    PH_INGEST        when (phase = PH_INGEST) else
    PH_RECIP1        when (phase = PH_INGEST_DRAIN) else
    PH_MUL127        when (phase = PH_RECIP1) else
    PH_RECIP2        when (phase = PH_MUL127) else
    PH_CAPTURE_SCALE when (phase = PH_RECIP2) else
    PH_REQUANT       when (phase = PH_CAPTURE_SCALE) else
    PH_CAPTURE_LAST  when (phase = PH_REQUANT and elem_idx = BLOCK_SIZE - 1 and sub_step = 3) else
    PH_REQUANT       when (phase = PH_REQUANT) else
    PH_DONE          when (phase = PH_CAPTURE_LAST) else
    PH_IDLE          when (phase = PH_DONE) else
    PH_IDLE;

  phase_reg : entity work.generic_register
    generic map (WIDTH => 4)
    port map (clk => clk, rst => rst, en => '1', d => phase_next, q => phase);

  elem_idx_next_slv <=
    std_logic_vector(to_unsigned(0, EIDX_W)) when (phase = PH_IDLE and start = '1') else
    std_logic_vector(elem_idx + 1)           when (phase = PH_INGEST and elem_idx /= BLOCK_SIZE - 1) else
    std_logic_vector(to_unsigned(0, EIDX_W)) when (phase = PH_CAPTURE_SCALE) else
    std_logic_vector(elem_idx + 1)           when (phase = PH_REQUANT and sub_step = 3 and elem_idx /= BLOCK_SIZE - 1) else
    elem_idx_slv;

  elem_idx_reg : entity work.generic_register
    generic map (WIDTH => EIDX_W)
    port map (clk => clk, rst => rst, en => '1', d => elem_idx_next_slv, q => elem_idx_slv);

  sub_step_next_slv <=
    "00"                                  when (phase = PH_CAPTURE_SCALE) else
    std_logic_vector(sub_step + 1)        when (phase = PH_REQUANT) else
    sub_step_slv;

  sub_step_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => rst, en => '1', d => sub_step_next_slv, q => sub_step_slv);

  busy <= '0' when phase = PH_IDLE else '1';
  done <= '1' when phase = PH_DONE else '0';

  ----------------------------------------------------------------
  -- op issue: combinational selection of this cycle's generic_fpu /
  -- generic_lookup / RAM inputs from 'phase'/'sub_step' -- plain data
  -- routing over registered state, same role as sb_finish.vhdl's own
  -- 'issue' process.
  ----------------------------------------------------------------
  issue : process (phase, sub_step, elem_idx, in_data, fpu_y, lut_y, amax_r, inv_scale_r, ram_rdata)
  begin
    fpu_op  <= ALU_MAX;
    fpu_cvt <= CVT_I2F;
    fpu_sub <= (others => '0');
    fpu_a   <= (others => '0');
    fpu_b   <= (others => '0');
    fpu_ce  <= '0';

    lut_ce   <= '0';
    lut_slot <= to_unsigned(RECIP_SLOT, 3);
    lut_x    <= (others => '0');

    ram_re    <= '0';
    ram_raddr <= elem_idx;

    case phase is
      when PH_INGEST =>
        fpu_op <= ALU_MAX;
        fpu_a  <= (others => '0') when elem_idx = 0 else fpu_y;
        fpu_b  <= '0' & in_data(30 downto 0); -- |in_data|: clear the sign bit (see header)
        fpu_ce <= '1';

      when PH_RECIP1 =>
        lut_x  <= amax_r;
        lut_ce <= '1';

      when PH_MUL127 =>
        fpu_op <= ALU_MUL;
        fpu_a  <= lut_y; -- = recip(amax), from PH_RECIP1
        fpu_b  <= CONST_127;
        fpu_ce <= '1';

      when PH_RECIP2 =>
        lut_x  <= fpu_y; -- = inv_scale, from PH_MUL127 (zero-slack: see CLAUDE.md practice #16)
        lut_ce <= '1';

      when PH_REQUANT =>
        case sub_step is
          when "00" =>
            ram_re    <= '1';
            ram_raddr <= elem_idx;
          when "01" =>
            fpu_op <= ALU_MUL;
            fpu_a  <= ram_rdata;
            fpu_b  <= inv_scale_r;
            fpu_ce <= '1';
          when "10" =>
            fpu_op  <= ALU_CVT;
            fpu_cvt <= CVT_F2I;
            fpu_a   <= fpu_y; -- = x_i * inv_scale, from sub_step "01" (zero-slack)
            fpu_ce  <= '1';
          when others => null; -- "11": nothing issued, this cycle clamps/stores/accumulates instead
        end case;

      when others => null;
    end case;
  end process issue;

  fpu : entity work.generic_fpu
    port map (clk => clk, ce => fpu_ce, op => fpu_op, sub => fpu_sub, cvt => fpu_cvt,
              a => fpu_a, b => fpu_b, y => fpu_y, flag => open);

  lut : entity work.generic_lookup
    port map (
      clk => clk, ce => lut_ce, slot => lut_slot, x => lut_x, y => lut_y, flag => open,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  ram_we    <= '1' when phase = PH_INGEST else '0';
  ram_waddr <= elem_idx;
  ram_wdata <= in_data;

  ram : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => BLOCK_SIZE)
    port map (clk => clk, we => ram_we, waddr => ram_waddr, wdata => ram_wdata,
              re => ram_re, raddr => ram_raddr, rdata => ram_rdata);

  ----------------------------------------------------------------
  -- scalar latches
  ----------------------------------------------------------------
  amax_en      <= '1' when phase = PH_INGEST_DRAIN  else '0';
  inv_scale_en <= '1' when phase = PH_RECIP2         else '0';
  scale_en     <= '1' when phase = PH_CAPTURE_SCALE  else '0';

  amax_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => amax_en, d => fpu_y, q => amax_r);

  inv_scale_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => inv_scale_en, d => fpu_y, q => inv_scale_r);

  scale_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => scale_en, d => lut_y, q => scale_r);

  scale_out <= scale_r;

  ----------------------------------------------------------------
  -- per-element clamp, storage, and per-subgroup Sigma(q)
  ----------------------------------------------------------------
  f2i_result <= signed(fpu_y);
  clamped_q  <= to_signed(127, 8)  when f2i_result > 127  else
                to_signed(-127, 8) when f2i_result < -127 else
                resize(f2i_result, 8);

  acc_rst <= '1' when (phase = PH_REQUANT and sub_step = 0 and (elem_idx mod SUBGROUP) = 0) else '0';
  acc_ce  <= '1' when (phase = PH_REQUANT and sub_step = 3) else '0';

  int_acc_inst : entity work.int_acc
    generic map (IN_WIDTH => 8, ACC_WIDTH => 13)
    port map (clk => clk, rst => acc_rst, ce => acc_ce, d => clamped_q, acc => acc_val);

  q_gen : for i in 0 to BLOCK_SIZE - 1 generate
    signal q_en : std_logic;
  begin
    q_en <= '1' when (phase = PH_REQUANT and sub_step = 3 and elem_idx = i) else '0';

    q_reg_i : entity work.generic_register
      generic map (WIDTH => 8)
      port map (clk => clk, rst => '0', en => q_en, d => std_logic_vector(clamped_q), q => q_out((i + 1) * 8 - 1 downto i * 8));
  end generate q_gen;

  sum_gen : for g in 0 to NUM_SUBGROUPS - 1 generate
    signal en_sig : std_logic;
  begin
    last_g_gen : if g = NUM_SUBGROUPS - 1 generate
      en_sig <= '1' when phase = PH_CAPTURE_LAST else '0';
    end generate last_g_gen;

    other_g_gen : if g /= NUM_SUBGROUPS - 1 generate
      en_sig <= '1' when (phase = PH_REQUANT and sub_step = 0 and elem_idx = (g + 1) * SUBGROUP) else '0';
    end generate other_g_gen;

    sum_reg_g : entity work.generic_register
      generic map (WIDTH => 13)
      port map (clk => clk, rst => '0', en => en_sig, d => std_logic_vector(acc_val), q => sum_out((g + 1) * 13 - 1 downto g * 13));
  end generate sum_gen;

end architecture behav;
