library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Rescaler U10 entity 2/3 (syseng_docs/04-vhdl-module-list.md's U10
-- table: "Convert to fp32, multiply by d x activation scale, add into
-- acc_ram"). One instance per output column, paired with its own
-- group_scale_acc.vhdl (which supplies sc_acc/min_acc) and its own
-- acc_ram_bank.vhdl slice (ram_* ports below). Runs once per super-
-- block, issuing a fixed 10-op sequence through ONE shared generic_fpu
-- instance -- this entity does NOT implement 04 S2.2's "8 shared per
-- tile [D]" fp32_mul time-multiplexing (one generic_fpu per sb_finish
-- instance instead of a shared pool across several columns); that's a
-- synthesis-area optimization left for later, not a correctness
-- requirement -- see this file's own note below, same treatment as
-- group_scale_acc.vhdl's un-time-multiplexed int_mul_scale instances.
--
-- Formula (matches ggml's true per-weight dequant, d*sc*q - dmin*m,
-- recovered from the array's packed-offset accumulation by
-- group_scale_acc.vhdl -- see that entity's header for the derivation):
--   d_contrib   = i2f(sc_acc)  * (f16_to_f32(d)    * act_scale)
--   min_contrib = i2f(min_acc) * (f16_to_f32(dmin) * act_scale)
--   delta       = d_contrib - min_contrib   -- min_contrib is 0 when the
--                                              caller ties min_acc/dmin
--                                              to 0 (Q3_K/Q6_K, which
--                                              never set HAS_MIN_TERM on
--                                              their group_scale_acc)
--   acc_ram[addr] <= (first ? 0 : acc_ram[addr]) + delta
--
-- 'act_scale' (the activation quantizer's fp32 dequant scale, one per
-- 256-activation block) is a caller-supplied input from act_quantizer
-- (U8, not yet built) -- same "interface invented ahead of its real
-- producer" situation as wt_pack.vhdl/wt_reader.vhdl's [D] notes.
--
-- Inputs are LATCHED on 'start' into internal registers and the whole
-- 12-step sequence runs off those latched copies, not the live ports --
-- the caller only needs to hold its signals stable for the one cycle
-- 'start' is asserted, matching array_seq.vhdl's num_tiles_reg/
-- tile_agents_reg latch-on-start convention, rather than needing to hold
-- them for this entity's entire ~12-cycle run.
--
-- sc_acc/min_acc are fixed 32-bit signed (not a generic ACC_WIDTH),
-- because generic_fpu's CVT_I2F port is fixed 32-bit -- a
-- group_scale_acc instance using a narrower ACC_WIDTH must be resized to
-- 32 bits by the caller before reaching this entity.
--
-- RAM read is issued at step 0, far ahead of when 'old_or_zero' is
-- actually consumed (step 9) -- generic_sdp_ram.vhdl's rdata is a
-- registered output that HOLDS its value once loaded (re does not need
-- to stay asserted), so there is no pipeline-stagger risk here of the
-- kind documented in group_scale_acc.vhdl's header: by the time step 9
-- needs ram_rdata, it has been stable for 8 cycles.
entity sb_finish is
  generic (
    ADDR_WIDTH : positive := 8
  );
  port (
    clk, rst : in std_logic;

    start : in std_logic;
    addr  : in unsigned(ADDR_WIDTH - 1 downto 0);
    first : in std_logic; -- this super-block is the first contribution to 'addr': skip the RAM read, use 0

    sc_acc  : in signed(31 downto 0);
    min_acc : in signed(31 downto 0); -- 0 for formats without HAS_MIN_TERM (see group_scale_acc.vhdl)

    d_f16     : in std_logic_vector(15 downto 0);
    dmin_f16  : in std_logic_vector(15 downto 0); -- caller may tie to 0 when min_acc is always 0
    act_scale : in std_logic_vector(31 downto 0); -- fp32, from act_quantizer (not yet built)

    busy : out std_logic;
    done : out std_logic; -- pulses one cycle, the same cycle as the acc_ram write

    ram_we    : out std_logic;
    ram_waddr : out unsigned(ADDR_WIDTH - 1 downto 0);
    ram_wdata : out std_logic_vector(31 downto 0);
    ram_re    : out std_logic;
    ram_raddr : out unsigned(ADDR_WIDTH - 1 downto 0);
    ram_rdata : in  std_logic_vector(31 downto 0)
  );
end entity sb_finish;

architecture behav of sb_finish is
  constant N_STEPS : positive := 12; -- steps 0 .. 11

  signal step_slv, step_next_slv : std_logic_vector(3 downto 0);
  signal step : unsigned(3 downto 0);
  signal busy_slv, busy_next : std_logic_vector(0 downto 0);
  signal busy_i : std_logic;

  -- inputs latched on 'start'
  signal addr_r_slv, addr_r_next : std_logic_vector(ADDR_WIDTH - 1 downto 0);
  signal first_r_slv, first_r_next : std_logic_vector(0 downto 0);
  signal sc_acc_r, min_acc_r : std_logic_vector(31 downto 0);
  signal d_f16_r, dmin_f16_r : std_logic_vector(15 downto 0);
  signal act_scale_r : std_logic_vector(31 downto 0);
  signal start_d : std_logic; -- 'start' latched-write enable for the above (combinational alias, see below)

  -- fpu wiring
  signal fpu_op  : alu_op_t;
  signal fpu_sub : std_logic_vector(2 downto 0);
  signal fpu_cvt : cvt_op_t;
  signal fpu_a, fpu_b : std_logic_vector(31 downto 0);
  signal fpu_ce  : std_logic;
  signal fpu_y   : std_logic_vector(31 downto 0);

  -- result registers, one per intermediate value that's needed MORE than
  -- one step after generic_fpu produces it -- min_contrib (step7's
  -- result) and delta (step8's result) are each consumed the very next
  -- step, with zero slack, so those two are read directly off fpu_y
  -- instead (see the 'issue' process's step8/step9 branches and the
  -- comment below); a register would add a full extra cycle of latency
  -- neither has room for.
  signal d_f32, dmin_f32, sc_f32, min_f32 : std_logic_vector(31 downto 0);
  signal d_scale, dmin_scale               : std_logic_vector(31 downto 0);
  signal d_contrib, new_val                 : std_logic_vector(31 downto 0);

  signal old_or_zero : std_logic_vector(31 downto 0);

  signal done_i : std_logic;

  -- step_hit(i) = '1' for exactly one cycle, when busy and step = i --
  -- used both to gate each result register's latch-this-cycle enable
  -- (see the registers below) and (i=0, i=11) the RAM read/write pulses.
  signal step_hit : std_logic_vector(0 to N_STEPS - 1);
begin

  busy_i <= busy_slv(0);
  busy   <= busy_i;

  step_hit_gen : for i in 0 to N_STEPS - 1 generate
    step_hit(i) <= '1' when (busy_i = '1' and step = to_unsigned(i, step'length)) else '0';
  end generate step_hit_gen;

  -- step counter: holds at 0 while idle, free-runs 0..N_STEPS-1 while busy
  step <= unsigned(step_slv);
  step_next_slv <= std_logic_vector(to_unsigned(0, 4)) when (busy_i = '0') else
                    std_logic_vector(to_unsigned(0, 4)) when (step = N_STEPS - 1) else
                    std_logic_vector(step + 1);

  step_reg : entity work.generic_register
    generic map (WIDTH => 4)
    port map (clk => clk, rst => rst, en => '1', d => step_next_slv, q => step_slv);

  busy_next(0) <= '1' when (start = '1' and busy_i = '0') else
                  '0' when (busy_i = '1' and step = N_STEPS - 1) else
                  busy_i;

  busy_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => '1', d => busy_next, q => busy_slv);

  -- latch inputs on 'start' (only meaningful while idle -- a 'start'
  -- pulse arriving while already busy is out of contract, same as
  -- array_seq.vhdl's own 'start' handling)
  start_d <= start and not busy_i;

  addr_r_next <= std_logic_vector(addr);
  addr_reg : entity work.generic_register
    generic map (WIDTH => ADDR_WIDTH)
    port map (clk => clk, rst => '0', en => start_d, d => addr_r_next, q => addr_r_slv);

  first_r_next(0) <= first;
  first_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => '0', en => start_d, d => first_r_next, q => first_r_slv);

  sc_acc_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => start_d, d => std_logic_vector(sc_acc), q => sc_acc_r);

  min_acc_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => start_d, d => std_logic_vector(min_acc), q => min_acc_r);

  d_f16_reg : entity work.generic_register
    generic map (WIDTH => 16)
    port map (clk => clk, rst => '0', en => start_d, d => d_f16, q => d_f16_r);

  dmin_f16_reg : entity work.generic_register
    generic map (WIDTH => 16)
    port map (clk => clk, rst => '0', en => start_d, d => dmin_f16, q => dmin_f16_r);

  act_scale_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => start_d, d => act_scale, q => act_scale_r);

  -- op issue: combinational selection of this cycle's generic_fpu inputs
  -- from 'step'. A plain multi-way selector over registered state, same
  -- role as array_seq.vhdl's state-driven control signals -- not a
  -- "function on runtime data" in the practice #1 sense, just data
  -- routing.
  issue : process (step, busy_i, d_f16_r, dmin_f16_r, sc_acc_r, min_acc_r, act_scale_r,
                    d_f32, dmin_f32, sc_f32, min_f32, d_scale, dmin_scale,
                    d_contrib, old_or_zero, fpu_y)
  begin
    fpu_op  <= ALU_ADD;
    fpu_cvt <= CVT_I2F;
    fpu_sub <= (others => '0');
    fpu_a   <= (others => '0');
    fpu_b   <= (others => '0');
    fpu_ce  <= '0';

    if busy_i = '1' then
      case to_integer(step) is
        when 0 =>
          fpu_op <= ALU_CVT; fpu_cvt <= CVT_F16_TO_F32;
          fpu_a  <= (31 downto 16 => '0') & d_f16_r;
          fpu_ce <= '1';
        when 1 =>
          fpu_op <= ALU_CVT; fpu_cvt <= CVT_F16_TO_F32;
          fpu_a  <= (31 downto 16 => '0') & dmin_f16_r;
          fpu_ce <= '1';
        when 2 =>
          fpu_op <= ALU_CVT; fpu_cvt <= CVT_I2F;
          fpu_a  <= sc_acc_r;
          fpu_ce <= '1';
        when 3 =>
          fpu_op <= ALU_CVT; fpu_cvt <= CVT_I2F;
          fpu_a  <= min_acc_r;
          fpu_ce <= '1';
        when 4 =>
          fpu_op <= ALU_MUL; fpu_a <= d_f32; fpu_b <= act_scale_r;
          fpu_ce <= '1';
        when 5 =>
          fpu_op <= ALU_MUL; fpu_a <= dmin_f32; fpu_b <= act_scale_r;
          fpu_ce <= '1';
        when 6 =>
          fpu_op <= ALU_MUL; fpu_a <= sc_f32; fpu_b <= d_scale;
          fpu_ce <= '1';
        when 7 =>
          fpu_op <= ALU_MUL; fpu_a <= min_f32; fpu_b <= dmin_scale;
          fpu_ce <= '1';
        when 8 =>
          -- fpu_y here is step7's own result (min_contrib), read directly:
          -- it's needed THIS step, one cycle after being produced, with no
          -- slack for an extra register hop (see the signal declarations above).
          fpu_op <= ALU_ADD; fpu_a <= d_contrib; fpu_b <= fpu_y;
          fpu_sub(NEG_B) <= '1';
          fpu_ce <= '1';
        when 9 =>
          -- fpu_y here is step8's own result (delta), same zero-slack reasoning.
          fpu_op <= ALU_ADD; fpu_a <= old_or_zero; fpu_b <= fpu_y;
          fpu_ce <= '1';
        when others =>
          null; -- 10 (latch new_val), 11 (write) -- no fpu op issued
      end case;
    end if;
  end process issue;

  fpu : entity work.generic_fpu
    port map (clk => clk, ce => fpu_ce, op => fpu_op, sub => fpu_sub, cvt => fpu_cvt,
              a => fpu_a, b => fpu_b, y => fpu_y, flag => open);

  -- each result register latches generic_fpu's 'y' exactly one cycle
  -- after the 'issue' process above issued the op that produced it, i.e.
  -- while 'step' holds the NEXT step number (see this file's header).
  d_f32_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(1), d => fpu_y, q => d_f32);

  dmin_f32_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(2), d => fpu_y, q => dmin_f32);

  sc_f32_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(3), d => fpu_y, q => sc_f32);

  min_f32_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(4), d => fpu_y, q => min_f32);

  d_scale_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(5), d => fpu_y, q => d_scale);

  dmin_scale_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(6), d => fpu_y, q => dmin_scale);

  d_contrib_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(7), d => fpu_y, q => d_contrib);

  new_val_reg : entity work.generic_register
    generic map (WIDTH => 32)
    port map (clk => clk, rst => '0', en => step_hit(10), d => fpu_y, q => new_val);

  ram_re    <= step_hit(0);
  ram_raddr <= unsigned(addr_r_slv);

  old_zero_mux : entity work.generic_mux2
    generic map (WIDTH => 32)
    port map (sel => first_r_slv(0), d0 => ram_rdata, d1 => (31 downto 0 => '0'), y => old_or_zero);

  ram_we    <= step_hit(N_STEPS - 1);
  ram_waddr <= unsigned(addr_r_slv);
  ram_wdata <= new_val;

  done_i <= step_hit(N_STEPS - 1);
  done   <= done_i;

end architecture behav;
