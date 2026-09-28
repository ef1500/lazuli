-- The Tensor Processing Unit
-- Generic so the number of lanes can be chosen, as well as other details.
-- Author: Christopher J. Cole.
--
-- This wires together every primitive that currently has a real VHDL
-- implementation (src/primitives/*.vhdl) into one block: LANES copies of
-- generic_vector_unit (claude_docs/08-vhdl-implementation-spec.md S6.1's
-- 'vec_lane', 8 per tile there) run in lockstep SIMD, fed and drained
-- through generic_fifo operand/result queues. It is the vector-unit tile
-- (U12 in claude_docs/03-architecture-units.md), not the full chip --
-- the systolic array (U9), weight path (U7), attention engine (U11) and
-- memory system (L3) are still plans in claude_docs, not code, so this
-- entity doesn't (and can't yet) instantiate them.
--
-- Every lane executes the SAME op/sub/cvt/lut_slot each cycle -- this
-- is a SIMD lane array, matching S6.1's description of vec_lane as one
-- bundle selected by one opcode field. Each lane gets its own (a,b)
-- operand pair, packed LANES-wide into a_data/b_data. There is no
-- vec_seq here: claude_docs/08 describes it as walking a tpu_vop
-- command's stream descriptors, and that command format (ref/tpu.h)
-- doesn't exist in this repo, so operand sequencing is the caller's job.
--
-- Flow control: like generic_fifo itself, this entity does not stall
-- the caller. Operands are consumed whenever both input queues are
-- non-empty; results are produced exactly LATENCY cycles later (LATENCY
-- = generic_vector_unit's fixed 2-cycle pipeline depth) and pushed into
-- the output queues, which -- per generic_fifo's own documented
-- contract -- silently overwrite the oldest unread entry if the
-- consumer falls behind. Keep 'out_ren' serviced at least as fast as
-- 'in_wen' retires, or size QDEPTH generously, if every result matters.
--
-- Every result is also mirrored into result_ram (generic_sdp_ram.vhdl,
-- claude_docs/04's L0 utility 'sdp_ram'), a circular buffer of the last
-- RDEPTH results addressable by result_addr/result_data -- a second,
-- random-access way to read a result besides draining y_fifo/flag_fifo
-- in order, independent of out_ren (this is the memory-controller
-- integration point; the flag word isn't mirrored, since flag_fifo
-- already gives ordered access to it and doubling the RAM width for a
-- 2-bit-per-lane field wasn't worth it).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity lazuli is
  generic (
    LANES  : positive := 8;
    QDEPTH : positive := 16;
    RDEPTH : positive := 256 -- depth of the result-history RAM
  );
  port (
    clk, rst : in std_logic;

    -- SIMD control, applied to every lane this cycle
    op       : in alu_op_t;
    sub      : in std_logic_vector(2 downto 0) := (others => '0');
    cvt      : in cvt_op_t                     := CVT_I2F;
    lut_slot : in unsigned(2 downto 0)         := (others => '0');

    -- operand queues: one LANES*32-bit word = one operand for every lane
    a_data  : in  std_logic_vector(LANES * 32 - 1 downto 0);
    b_data  : in  std_logic_vector(LANES * 32 - 1 downto 0);
    in_wen  : in  std_logic;
    in_full : out std_logic;

    -- result queue: pop with out_ren, one LANES*32-bit word of y plus
    -- one LANES*2-bit word of per-lane flags per pop
    y_data    : out std_logic_vector(LANES * 32 - 1 downto 0);
    flag_data : out std_logic_vector(LANES * 2 - 1 downto 0);
    out_ren   : in  std_logic;
    out_empty : out std_logic;

    -- random-access readback of the last RDEPTH results (see header
    -- comment); address 0 is the oldest entry still held, wrapping as
    -- new results arrive -- read result_wraddr (below) to find the
    -- most-recently-written slot
    result_addr   : in  unsigned(clog2(RDEPTH) - 1 downto 0);
    result_data   : out std_logic_vector(LANES * 32 - 1 downto 0);
    result_wraddr : out unsigned(clog2(RDEPTH) - 1 downto 0);

    -- table/slot-config load bus, broadcast to every lane's generic_lookup
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
end entity lazuli;

architecture structural of lazuli is

  signal a_rdata, b_rdata : std_logic_vector(LANES * 32 - 1 downto 0);
  signal a_empty, b_empty : std_logic;
  signal lane_ce           : std_logic;

  signal lane_y    : std_logic_vector(LANES * 32 - 1 downto 0);
  signal lane_flag : std_logic_vector(LANES * 2 - 1 downto 0);

  -- Tracks occupancy of generic_vector_unit's own 2-stage pipeline
  -- (stage 1 = each sub-unit's internal register, stage 2 = the
  -- op-selecting mux register) so a write into y_fifo/flag_fifo fires on
  -- exactly the cycle a result actually lands in lane_y/lane_flag.
  --
  -- 'issuing' (a genuine new operand pair available) and 'lane_ce' (the
  -- pipeline should advance this cycle) are deliberately different
  -- signals. A pipeline only moves an item from stage 1 to stage 2 when
  -- its ce is asserted -- if lane_ce dropped the instant a_fifo/b_fifo
  -- ran dry, an item already latched into stage 1 on the last real issue
  -- would never get the second ce pulse it needs to reach stage 2 and
  -- retire, and would sit there indefinitely (or worse, get silently
  -- overwritten by a later real issue). So lane_ce stays asserted for
  -- one extra ("drain") cycle after 'issuing' drops, as long as
  -- something is still in stage 1 (occ1). On a drain cycle a_fifo/
  -- b_fifo aren't popped (ren = issuing, not lane_ce), so the sub-units
  -- just recompute stage 1's already-latched operands -- a harmless,
  -- idempotent no-op that exists purely to shift the real result already
  -- sitting in stage 1 onward into stage 2.
  signal issuing            : std_logic;
  signal occ1, occ2, wen_r : std_logic := '0';

  signal result_wraddr_i : unsigned(clog2(RDEPTH) - 1 downto 0) := (others => '0');

begin

  result_wraddr <= result_wraddr_i;

  issuing <= (not a_empty) and (not b_empty);
  lane_ce <= issuing or occ1;

  a_fifo : entity work.generic_FIFO
    generic map (bits => LANES * 32, depth => QDEPTH)
    port map (clk => clk, rst => rst, wdata => a_data, wen => in_wen, ren => issuing,
              rdata => a_rdata, empty => a_empty, full => in_full);

  b_fifo : entity work.generic_FIFO
    generic map (bits => LANES * 32, depth => QDEPTH)
    port map (clk => clk, rst => rst, wdata => b_data, wen => in_wen, ren => issuing,
              rdata => b_rdata, empty => b_empty, full => open);

  lane_array : for i in 0 to LANES - 1 generate
    lane_inst : entity work.generic_vector_unit
      port map (
        clk => clk, ce => lane_ce, op => op, sub => sub, cvt => cvt, lut_slot => lut_slot,
        a => a_rdata((i + 1) * 32 - 1 downto i * 32),
        b => b_rdata((i + 1) * 32 - 1 downto i * 32),
        y => lane_y((i + 1) * 32 - 1 downto i * 32),
        flag => lane_flag((i + 1) * 2 - 1 downto i * 2),
        ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
        ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right,
        ld_bits => ld_bits, ld_addr => ld_addr, ld_value => ld_value,
        ld_slope => ld_slope, ld_we => ld_we
      );
  end generate lane_array;

  pipe_track : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        occ1  <= '0';
        occ2  <= '0';
        wen_r <= '0';
      elsif lane_ce = '1' then
        wen_r <= occ1;   -- whatever was already in stage 1 retires (into y) this edge
        occ2  <= occ1;
        occ1  <= issuing; -- stage 1 gets a real new item only if we're actually issuing
      else
        wen_r <= '0';  -- no advance this cycle: nothing new lands, so no write
      end if;
    end if;
  end process pipe_track;

  y_fifo : entity work.generic_FIFO
    generic map (bits => LANES * 32, depth => QDEPTH)
    port map (clk => clk, rst => rst, wdata => lane_y, wen => wen_r,
              ren => out_ren, rdata => y_data, empty => out_empty, full => open);

  flag_fifo : entity work.generic_FIFO
    generic map (bits => LANES * 2, depth => QDEPTH)
    port map (clk => clk, rst => rst, wdata => lane_flag, wen => wen_r,
              ren => out_ren, rdata => flag_data, empty => open, full => open);

  wraddr_ctr : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        result_wraddr_i <= (others => '0');
      elsif wen_r = '1' then
        if result_wraddr_i = RDEPTH - 1 then
          result_wraddr_i <= (others => '0');
        else
          result_wraddr_i <= result_wraddr_i + 1;
        end if;
      end if;
    end if;
  end process wraddr_ctr;

  result_ram : entity work.generic_sdp_ram
    generic map (WIDTH => LANES * 32, DEPTH => RDEPTH)
    port map (clk => clk, we => wen_r, waddr => result_wraddr_i, wdata => lane_y,
              re => '1', raddr => result_addr, rdata => result_data);

end architecture structural;
