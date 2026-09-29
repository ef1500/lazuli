library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U12 entity (claude_docs/08-vhdl-implementation-spec.md S6.1's
-- `vec_seq`, claude_docs/04-vhdl-module-list.md's row of the same name):
-- "Not microcode: each tpu_vop command already names one fully-specified
-- op and its three stream descriptors (source A, source B, destination
-- -- base + up to 3 nested loop counts/strides); vec_seq just walks
-- that descriptor and feeds vec_lane." `lazuli.vhdl` IS that lane array
-- (S6.1's `vec_lane`, `LANES`-wide SIMD) -- its own header says exactly
-- this: "There is no vec_seq here... operand sequencing is the caller's
-- job." This entity is that caller.
--
-- BLOCKED-ON-ref/tpu.h, RESOLVED THE SAME WAY AS THE WEIGHT PATH'S OWN
-- OPEN INTERFACES: `ref/tpu.h`'s `tpu_cmd` (8x32-bit words, `w[0]`'s low
-- byte = opcode) is not in this repo, so the exact bit-packing of "base
-- + up to 3 nested loop counts/strides x 3 operands" into 256 bits is
-- unknown and NOT reconstructed here -- guessing it would silently
-- commit to an unverifiable ABI. Instead, exactly like `lazuli.vhdl`
-- itself takes a typed `op`/`sub`/`cvt` rather than raw opcode bits,
-- this entity takes the descriptor already DECODED into typed ports
-- (base/stride/count fields below) [D]. Whatever eventually decodes a
-- real `tpu_cmd` (`cmd_link`, `08` S8.1 -- not built) is the thing that
-- should produce these fields; this entity only owns the walk.
--
-- DESCRIPTOR SHAPE [D]: the three operands (A, B, DST) share ONE set of
-- loop counts (count0/1/2 -- the total number of SIMD-width chunks to
-- process is count0*count1*count2) but each has its OWN base address
-- and its OWN three strides -- a stride of 0 on any level lets that
-- operand broadcast across that loop level (e.g. RMSNorm's gain vector
-- read once per group rather than once per element) without needing a
-- second, independent count per operand. `08`'s own phrasing ("base +
-- up to 3 nested loop counts/strides" listed once per operand) could
-- also mean fully independent counts per operand; shared counts is the
-- simpler, still fully general (via zero strides) reading, chosen here.
--
-- ONE STRIDE UNIT = ONE FULL SIMD-WIDE MEMORY WORD [D]: the a_re/
-- a_raddr/a_rdata (and b_*, dst_*) ports below are `generic_sdp_ram`-
-- shaped, `LANES*32` bits wide -- i.e. the backing memory is assumed to
-- already be organised one RAM word per LANES-wide operand chunk
-- (matching how `lazuli.vhdl`'s own a_data/b_data/y_data ports, and
-- act_store.vhdl's q_out, are already LANES/BLOCK_SIZE-wide flat buses,
-- not per-scalar). A stride therefore advances by whole chunks, not
-- individual elements -- no per-lane addressing exists in this entity,
-- since `lazuli` already reads/writes all LANES lanes from/to one word.
--
-- NOT PIPELINED ACROSS ITERATIONS, [D]: this entity issues one operand
-- pair, waits for `lazuli`'s result to retire (draining `lazuli`'s own
-- out_empty), writes it to the destination memory, THEN advances to the
-- next loop point -- it does not prefetch the next operand while a
-- result is in flight, even though `lazuli`'s own operand/result FIFOs
-- (QDEPTH-deep) could support that overlap. `08`'s own characterization
-- of U12 ("latency matters more than throughput here", 8 lanes run only
-- 18% busy) makes this the right first cut, not just an expedient one;
-- overlapping issue and retire is a real, later throughput optimization,
-- not a correctness gap.
--
-- ADDRESS STEPPING: a multiply-free "odometer" walk -- each operand
-- keeps not just its current address but two CHECKPOINT addresses (the
-- value at the start of the current i1 sweep, and at the start of the
-- current i2 sweep), so wrapping i0 back to 0 just re-loads the i1
-- checkpoint (no subtraction needed to "undo" count0-1 steps of
-- stride0), and wrapping i1 similarly re-loads (then advances) the i2
-- checkpoint. Same shape as array_seq.vhdl's counters: plain registers
-- and adds, no primitive needed beyond generic_register.
--
-- CALLER CONTRACT [D], no cmd_link/queue exists yet to define this
-- properly: every descriptor field (op/sub/cvt/lut_slot, all 3 bases,
-- all 9 strides, count0/1/2) must stay stable from the cycle 'start' is
-- asserted until 'done' pulses -- this entity does not latch them (op/
-- sub/cvt/lut_slot are enumerated types, not std_logic_vector, so
-- passing them through generic_register would need a type-conversion
-- step this entity avoids entirely by not latching ANY descriptor field,
-- for one uniform contract instead of latching some fields and not
-- others). 'lz_flag_data' (per-lane status from lazuli) is read but not
-- yet acted on -- no error-aggregation policy exists yet; a future
-- caller wanting that will need to add it.
entity vec_seq is
  generic (
    LANES    : positive := 8;  -- must match the lazuli instance this drives
    ADDR_W   : positive := 16;
    STRIDE_W : positive := 17
  );
  port (
    clk, rst : in std_logic;

    start : in std_logic;

    op       : in alu_op_t;
    sub      : in std_logic_vector(2 downto 0);
    cvt      : in cvt_op_t;
    lut_slot : in unsigned(2 downto 0);

    base_a, base_b, base_dst : in unsigned(ADDR_W - 1 downto 0);
    stride_a0, stride_a1, stride_a2 : in signed(STRIDE_W - 1 downto 0);
    stride_b0, stride_b1, stride_b2 : in signed(STRIDE_W - 1 downto 0);
    stride_d0, stride_d1, stride_d2 : in signed(STRIDE_W - 1 downto 0);
    count0, count1, count2 : in unsigned(15 downto 0); -- shared loop trip counts, >= 1 each

    busy : out std_logic;
    done : out std_logic;

    -- lazuli-facing: mirrors lazuli.vhdl's own operand/result port shape exactly
    lz_op        : out alu_op_t;
    lz_sub       : out std_logic_vector(2 downto 0);
    lz_cvt       : out cvt_op_t;
    lz_lut_slot  : out unsigned(2 downto 0);
    lz_a_data    : out std_logic_vector(LANES * 32 - 1 downto 0);
    lz_b_data    : out std_logic_vector(LANES * 32 - 1 downto 0);
    lz_in_wen    : out std_logic;
    lz_in_full   : in  std_logic;
    lz_y_data    : in  std_logic_vector(LANES * 32 - 1 downto 0);
    lz_flag_data : in  std_logic_vector(LANES * 2 - 1 downto 0);
    lz_out_ren   : out std_logic;
    lz_out_empty : in  std_logic;

    -- operand/destination memory ports, generic_sdp_ram-shaped, one
    -- LANES*32-bit word per address (see header)
    a_re    : out std_logic;
    a_raddr : out unsigned(ADDR_W - 1 downto 0);
    a_rdata : in  std_logic_vector(LANES * 32 - 1 downto 0);

    b_re    : out std_logic;
    b_raddr : out unsigned(ADDR_W - 1 downto 0);
    b_rdata : in  std_logic_vector(LANES * 32 - 1 downto 0);

    dst_we    : out std_logic;
    dst_waddr : out unsigned(ADDR_W - 1 downto 0);
    dst_wdata : out std_logic_vector(LANES * 32 - 1 downto 0)
  );
end entity vec_seq;

architecture behav of vec_seq is
  constant PH_IDLE        : std_logic_vector(2 downto 0) := "000";
  constant PH_MEM_ISSUE   : std_logic_vector(2 downto 0) := "001";
  constant PH_MEM_WAIT    : std_logic_vector(2 downto 0) := "010";
  constant PH_RESULT_WAIT : std_logic_vector(2 downto 0) := "011";
  constant PH_ADVANCE     : std_logic_vector(2 downto 0) := "100";
  constant PH_DONE        : std_logic_vector(2 downto 0) := "101";

  signal phase, phase_next : std_logic_vector(2 downto 0);

  signal i0_slv, i0_next_slv, i1_slv, i1_next_slv, i2_slv, i2_next_slv : std_logic_vector(15 downto 0);
  signal i0, i1, i2 : unsigned(15 downto 0);

  signal advance, i0_wrap, i1_wrap, i2_wrap : std_logic; -- 'advance' pulses at PH_ADVANCE

  type addr_arr_t   is array (0 to 2) of std_logic_vector(ADDR_W - 1 downto 0);
  type stride_arr_t is array (0 to 2) of signed(STRIDE_W - 1 downto 0);

  signal base_arr : addr_arr_t;
  signal s0_arr, s1_arr, s2_arr : stride_arr_t;
  signal addr_arr : addr_arr_t; -- current address per operand (0=A, 1=B, 2=DST)

  signal a_addr_u, b_addr_u, dst_addr_u : unsigned(ADDR_W - 1 downto 0);
begin

  base_arr(0) <= std_logic_vector(base_a);
  base_arr(1) <= std_logic_vector(base_b);
  base_arr(2) <= std_logic_vector(base_dst);
  s0_arr(0) <= stride_a0; s1_arr(0) <= stride_a1; s2_arr(0) <= stride_a2;
  s0_arr(1) <= stride_b0; s1_arr(1) <= stride_b1; s2_arr(1) <= stride_b2;
  s0_arr(2) <= stride_d0; s1_arr(2) <= stride_d1; s2_arr(2) <= stride_d2;

  a_addr_u   <= unsigned(addr_arr(0));
  b_addr_u   <= unsigned(addr_arr(1));
  dst_addr_u <= unsigned(addr_arr(2));

  i0 <= unsigned(i0_slv);
  i1 <= unsigned(i1_slv);
  i2 <= unsigned(i2_slv);

  busy <= '0' when phase = PH_IDLE else '1';
  done <= '1' when phase = PH_DONE else '0';

  ----------------------------------------------------------------
  -- phase sequencer
  ----------------------------------------------------------------
  phase_next <=
    PH_MEM_ISSUE   when (phase = PH_IDLE and start = '1') else
    PH_MEM_WAIT    when (phase = PH_MEM_ISSUE) else
    PH_MEM_WAIT    when (phase = PH_MEM_WAIT and lz_in_full = '1') else
    PH_RESULT_WAIT when (phase = PH_MEM_WAIT and lz_in_full = '0') else
    PH_RESULT_WAIT when (phase = PH_RESULT_WAIT and lz_out_empty = '1') else
    PH_ADVANCE     when (phase = PH_RESULT_WAIT and lz_out_empty = '0') else
    PH_DONE        when (phase = PH_ADVANCE and i2_wrap = '1') else
    PH_MEM_ISSUE   when (phase = PH_ADVANCE) else
    PH_IDLE        when (phase = PH_DONE) else
    PH_IDLE;

  phase_reg : entity work.generic_register
    generic map (WIDTH => 3)
    port map (clk => clk, rst => rst, en => '1', d => phase_next, q => phase);

  advance <= '1' when phase = PH_ADVANCE else '0';

  ----------------------------------------------------------------
  -- op/sub/cvt/lut_slot: pass through directly (see header's CALLER
  -- CONTRACT note -- not latched, along with every other descriptor field)
  ----------------------------------------------------------------
  lz_op       <= op;
  lz_sub      <= sub;
  lz_cvt      <= cvt;
  lz_lut_slot <= lut_slot;

  ----------------------------------------------------------------
  -- i0/i1/i2: the nested loop counters, and the wrap pulses that drive
  -- both the address-stepper generate loop below and the phase sequencer
  -- above (i2_wrap = "this was the very last (i0,i1,i2) triple")
  ----------------------------------------------------------------
  i0_next_slv <= (others => '0')                       when (phase = PH_IDLE and start = '1') else
                 std_logic_vector(to_unsigned(0, 16))   when (advance = '1' and i0 = count0 - 1) else
                 std_logic_vector(i0 + 1)               when (advance = '1') else
                 i0_slv;
  i0_reg : entity work.generic_register
    generic map (WIDTH => 16)
    port map (clk => clk, rst => rst, en => '1', d => i0_next_slv, q => i0_slv);
  i0_wrap <= '1' when (advance = '1' and i0 = count0 - 1) else '0';

  i1_next_slv <= (others => '0')                       when (phase = PH_IDLE and start = '1') else
                 std_logic_vector(to_unsigned(0, 16))   when (i0_wrap = '1' and i1 = count1 - 1) else
                 std_logic_vector(i1 + 1)               when (i0_wrap = '1') else
                 i1_slv;
  i1_reg : entity work.generic_register
    generic map (WIDTH => 16)
    port map (clk => clk, rst => rst, en => '1', d => i1_next_slv, q => i1_slv);
  i1_wrap <= '1' when (i0_wrap = '1' and i1 = count1 - 1) else '0';

  i2_next_slv <= (others => '0')                       when (phase = PH_IDLE and start = '1') else
                 std_logic_vector(to_unsigned(0, 16))   when (i1_wrap = '1' and i2 = count2 - 1) else
                 std_logic_vector(i2 + 1)               when (i1_wrap = '1') else
                 i2_slv;
  i2_reg : entity work.generic_register
    generic map (WIDTH => 16)
    port map (clk => clk, rst => rst, en => '1', d => i2_next_slv, q => i2_slv);
  i2_wrap <= '1' when (i1_wrap = '1' and i2 = count2 - 1) else '0';

  ----------------------------------------------------------------
  -- per-operand address stepper (see header's ADDRESS STEPPING note):
  -- k=0 -> A, k=1 -> B, k=2 -> DST
  ----------------------------------------------------------------
  addr_gen : for k in 0 to 2 generate
    signal base1_r, base2_r : std_logic_vector(ADDR_W - 1 downto 0);
    signal addr_next, base1_next, base2_next : std_logic_vector(ADDR_W - 1 downto 0);
    signal new_addr0, new_base1, new_base2 : signed(STRIDE_W - 1 downto 0);
  begin
    new_addr0 <= resize(signed('0' & addr_arr(k)), STRIDE_W) + s0_arr(k);
    new_base1 <= resize(signed('0' & base1_r), STRIDE_W) + s1_arr(k);
    new_base2 <= resize(signed('0' & base2_r), STRIDE_W) + s2_arr(k);

    addr_next <= base_arr(k)                              when (phase = PH_IDLE and start = '1') else
                 std_logic_vector(new_base2(ADDR_W - 1 downto 0)) when (advance = '1' and i1_wrap = '1') else
                 std_logic_vector(new_base1(ADDR_W - 1 downto 0)) when (advance = '1' and i0_wrap = '1') else
                 std_logic_vector(new_addr0(ADDR_W - 1 downto 0)) when (advance = '1') else
                 addr_arr(k);
    addr_reg_k : entity work.generic_register
      generic map (WIDTH => ADDR_W)
      port map (clk => clk, rst => rst, en => '1', d => addr_next, q => addr_arr(k));

    base1_next <= base_arr(k)                              when (phase = PH_IDLE and start = '1') else
                  std_logic_vector(new_base2(ADDR_W - 1 downto 0)) when (advance = '1' and i1_wrap = '1') else
                  std_logic_vector(new_base1(ADDR_W - 1 downto 0)) when (advance = '1' and i0_wrap = '1') else
                  base1_r;
    base1_reg_k : entity work.generic_register
      generic map (WIDTH => ADDR_W)
      port map (clk => clk, rst => rst, en => '1', d => base1_next, q => base1_r);

    base2_next <= base_arr(k)                              when (phase = PH_IDLE and start = '1') else
                  std_logic_vector(new_base2(ADDR_W - 1 downto 0)) when (advance = '1' and i1_wrap = '1') else
                  base2_r;
    base2_reg_k : entity work.generic_register
      generic map (WIDTH => ADDR_W)
      port map (clk => clk, rst => rst, en => '1', d => base2_next, q => base2_r);
  end generate addr_gen;

  ----------------------------------------------------------------
  -- operand memory reads: issue the cycle we enter PH_MEM_ISSUE
  -- (generic_sdp_ram-style 1-cycle registered read -- valid the
  -- following cycle, PH_MEM_WAIT)
  ----------------------------------------------------------------
  a_re    <= '1' when phase = PH_MEM_ISSUE else '0';
  a_raddr <= a_addr_u;
  b_re    <= '1' when phase = PH_MEM_ISSUE else '0';
  b_raddr <= b_addr_u;

  ----------------------------------------------------------------
  -- lazuli operand issue: a_rdata/b_rdata are stable throughout
  -- PH_MEM_WAIT; fire in_wen the cycle lz_in_full finally reads low
  ----------------------------------------------------------------
  lz_a_data <= a_rdata;
  lz_b_data <= b_rdata;
  lz_in_wen <= '1' when (phase = PH_MEM_WAIT and lz_in_full = '0') else '0';

  ----------------------------------------------------------------
  -- lazuli result retire + destination write, same cycle:
  -- generic_fifo.vhdl's rdata is show-ahead ("latch the data ... and
  -- pull ren" -- valid to read the SAME cycle 'ren' pops it), so no
  -- extra wait state is needed between popping and using the result.
  ----------------------------------------------------------------
  lz_out_ren <= '1' when (phase = PH_RESULT_WAIT and lz_out_empty = '0') else '0';

  dst_we    <= '1' when (phase = PH_RESULT_WAIT and lz_out_empty = '0') else '0';
  dst_waddr <= dst_addr_u;
  dst_wdata <= lz_y_data;

end architecture behav;
