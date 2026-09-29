library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- The full matrix array tile (claude_docs/08-vhdl-implementation-spec.
-- md S3.3, claude_docs/04-vhdl-module-list.md's U9): DSP_COLUMNS
-- pe_column instances, plus the act_skew/ctrl_skew this session found
-- they need (see pe_column.vhdl's header for the dataflow model this is
-- built on). Presents a clean, un-skewed interface to the outside
-- world: a single ROWS(=16)-wide activation vector and one first/last
-- flag pair per clock in, one accumulator + flag pair per DSP column
-- out -- all the internal skewing needed to make pe_column's cascade
-- work is done here, once, rather than pushed onto every caller.
--
-- ACT_DIST generic, built both ways as 08 S3.3 asks ("build both,
-- decide by synthesis" -- timing at 300 MHz on the VU9P is a place-and-
-- route experiment, not a fact this session can settle):
--   SYSTOLIC: column 0 gets the (act_skew'd) vector directly; column c
--     gets column (c-1)'s own x_out/first_out/last_out, via pe_cell's
--     existing horizontal chain (pe_column.vhdl). Column c's result is
--     c clocks behind column 0's for free.
--   TREE: every column gets the SAME vector, broadcast after a fixed
--     TREE_DEPTH=2 clocks of latency (08's "2-level register tree" --
--     modeled here as a flat 2-stage delay before an identical
--     broadcast, not a physically fanned-out tree: the difference is a
--     synthesis/floorplan fanout-buffering concern, not a functional
--     one, same reasoning as ctrl_skew.vhdl's own per-lane-duplication
--     note). Every column's result now lands at the SAME time (no
--     natural stagger), so ctrl_skew is driven with an EXTRA per-column
--     c-clocks-per-column stagger on top of the +1 below, to
--     manufacture the same relative timing SYSTOLIC gives for free --
--     so whatever consumes sys_array's output (the rescaler, not yet
--     built) can stay agnostic to which ACT_DIST this tile was built
--     with. [D]
--
-- ctrl_skew's STAGE_LIST always carries a uniform +1 baseline, on both
-- modes -- found by simulation, not derived up front [see practice #10
-- in CLAUDE.md]: a row's first_in/last_in (act_skew'd, then pe_cell's
-- own fl_reg) become valid ONE CYCLE BEFORE that row's p_out does, even
-- though both are nominally "1 register hop" from the same source. The
-- reason is dsp_mac2's own weight-swap pipeline (dsp_mac2.vhdl S2.1
-- item 1): 'first' loads w1_active/w2_active AT the same edge it also
-- gates p_out's capture, so on THAT edge p_out is still computed from
-- the OLD (pre-swap) weight -- the multiply only reflects the NEW
-- weight starting the following ce cycle. first_out/last_out have no
-- such dependency (pe_cell's fl_reg just registers first_in/last_in
-- directly), so they read "ready" one cycle earlier than p_out actually
-- is. Confirmed by probing pe_column's row-15 pe_cell internals
-- directly (VHDL-2008 external names) rather than re-deriving the
-- 16-deep pipeline by hand a third time. The alternative fix -- adding
-- a matching extra hop inside pe_cell/dsp_mac2 itself -- was rejected:
-- first_out/last_out also drive the NEXT column's horizontal wavefront
-- trigger (SYSTOLIC), and delaying THAT would misalign the weight-swap
-- timing this whole scheme depends on; correcting it only in the
-- flag path sys_array exposes externally is the smaller, localized fix.
--
-- Weight-load bus: direct-write, not chain-load [D]. 08 S3.3 flags
-- "which the vendor DSP hardware supports" as unresolved and the single
-- biggest open unknown in the array's timing -- but dsp_mac2.vhdl (this
-- session) already committed to plain-wire w1_next/w2_next ports with
-- no A-cascade shift mechanism, which only direct-write can drive as
-- built. Direct-write also needs only B>=ROWS=16 for zero bubbles
-- (chain-load needs B>=2*ROWS-1=31), so it's both what's already built
-- and the better-utilization choice absent a confirmed hardware
-- constraint forcing chain-load. Revisit if UG579/UG479 turns out to
-- require it: that would mean extending dsp_mac2's "xilinx" architecture
-- with a real cascade port, not a change here.
--
-- w1_next/w2_next are packed [column][row]: column c's own ROWS*
-- WEIGHT_W-bit slice (bits (c+1)*ROWS*WEIGHT_W-1 downto c*ROWS*
-- WEIGHT_W) is exactly pe_column's own w1_next/w2_next shape, so it's
-- passed straight through with no repacking.
entity sys_array is
  generic (
    A_PORT_W    : positive := 27;
    ACC_W       : positive := 48;
    WEIGHT_W    : positive := 6;
    SPACING     : positive := 17;
    DSP_COLUMNS : positive := 8;         -- 8 (A100T) or 64 (VU9P)
    ACT_DIST    : string   := "SYSTOLIC"; -- "SYSTOLIC" or "TREE"
    TREE_DEPTH  : natural  := 2           -- only used when ACT_DIST = "TREE"
  );
  port (
    clk, ce : in std_logic;

    x_in      : in std_logic_vector(16 * 8 - 1 downto 0); -- one ROWS(=16)-wide vector per clock
    first_in  : in std_logic;
    last_in   : in std_logic;

    w1_next : in std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0);
    w2_next : in std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0);

    p_out     : out std_logic_vector(DSP_COLUMNS * ACC_W - 1 downto 0); -- column c at (c+1)*ACC_W-1 downto c*ACC_W
    first_out : out std_logic_vector(DSP_COLUMNS - 1 downto 0);
    last_out  : out std_logic_vector(DSP_COLUMNS - 1 downto 0)
  );
end entity sys_array;

architecture structural of sys_array is

  -- Compile-time-only helper (like project_types.clog2 -- computing an
  -- elaboration-time generic constant, not describing runtime hardware
  -- logic, so it isn't the kind of function CLAUDE.md's practice #1
  -- warns against): ctrl_skew's per-column delay list, which depends on
  -- ACT_DIST and DSP_COLUMNS, both generics fixed at elaboration.
  function ctrl_skew_stages(dist : string; n : positive) return integer_vector is
    variable result : integer_vector(0 to n - 1);
  begin
    for c in 0 to n - 1 loop
      if dist = "TREE" then
        result(c) := c + 1;
      else
        result(c) := 1;
      end if;
    end loop;
    return result;
  end function;

  -- Separate "what feeds column c" (col_x_in etc.) from "what column c
  -- itself produced" (col_x_out etc.): under ACT_DIST=TREE every
  -- column's INPUT is the same broadcast tree_x regardless of what any
  -- OTHER column produced, so col_x_in and col_x_out must be distinct
  -- signals -- folding them into one array (column c's input AND column
  -- (c-1)'s output sharing a slot) would give TREE mode two drivers on
  -- the same signal.
  type x_bus_arr_t    is array (0 to DSP_COLUMNS - 1) of std_logic_vector(16 * 8 - 1 downto 0);
  type flag_bus_arr_t is array (0 to DSP_COLUMNS - 1) of std_logic_vector(15 downto 0);
  signal col_x_in, col_x_out                 : x_bus_arr_t;
  signal col_first_in, col_first_out         : flag_bus_arr_t;
  signal col_last_in, col_last_out           : flag_bus_arr_t;

  signal skew_x                : std_logic_vector(16 * 8 - 1 downto 0);
  signal skew_first, skew_last : std_logic_vector(15 downto 0);

  signal col_last_row_first, col_last_row_last : std_logic_vector(DSP_COLUMNS - 1 downto 0);
  signal col_p : std_logic_vector(DSP_COLUMNS * ACC_W - 1 downto 0);

begin

  act_skew_inst : entity work.act_skew
    generic map (ROWS => 16)
    port map (
      clk => clk, ce => ce, x_in => x_in, first_in => first_in, last_in => last_in,
      x_out => skew_x, first_out => skew_first, last_out => skew_last
    );

  systolic_gen : if ACT_DIST = "SYSTOLIC" generate
    col_x_in(0) <= skew_x;
    col_first_in(0) <= skew_first;
    col_last_in(0) <= skew_last;

    chain_gen : for c in 1 to DSP_COLUMNS - 1 generate
      col_x_in(c) <= col_x_out(c - 1);
      col_first_in(c) <= col_first_out(c - 1);
      col_last_in(c) <= col_last_out(c - 1);
    end generate chain_gen;
  end generate systolic_gen;

  tree_gen : if ACT_DIST = "TREE" generate
    signal packed_in, packed_out : std_logic_vector(16 * 8 + 16 + 16 - 1 downto 0);
    signal tree_x : std_logic_vector(16 * 8 - 1 downto 0);
    signal tree_first, tree_last : std_logic_vector(15 downto 0);
  begin
    packed_in <= skew_x & skew_first & skew_last;

    dl : entity work.generic_delay_line
      generic map (WIDTH => 16 * 8 + 16 + 16, STAGES => TREE_DEPTH)
      port map (clk => clk, rst => '0', en => ce, d => packed_in, q => packed_out);

    tree_x     <= packed_out(16 * 8 + 16 + 16 - 1 downto 16 + 16);
    tree_first <= packed_out(16 + 16 - 1 downto 16);
    tree_last  <= packed_out(15 downto 0);

    fanout_gen : for c in 0 to DSP_COLUMNS - 1 generate
      col_x_in(c) <= tree_x;
      col_first_in(c) <= tree_first;
      col_last_in(c) <= tree_last;
    end generate fanout_gen;
  end generate tree_gen;

  col_gen : for c in 0 to DSP_COLUMNS - 1 generate
    signal p_c : signed(ACC_W - 1 downto 0);
  begin
    cell : entity work.pe_column(behav)
      generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
      port map (
        clk => clk, ce => ce,
        x_in => col_x_in(c), x_out => col_x_out(c),
        w1_next => w1_next((c + 1) * 16 * WEIGHT_W - 1 downto c * 16 * WEIGHT_W),
        w2_next => w2_next((c + 1) * 16 * WEIGHT_W - 1 downto c * 16 * WEIGHT_W),
        first_in => col_first_in(c), first_out => col_first_out(c),
        last_in => col_last_in(c), last_out => col_last_out(c),
        p_out => p_c
      );

    col_p((c + 1) * ACC_W - 1 downto c * ACC_W) <= std_logic_vector(p_c);

    -- Only row 15 (the column's own completed dot product) is this
    -- column's meaningful first/last -- the other 15 row bits in
    -- col_first_out(c)/col_last_out(c) exist purely for the NEXT
    -- column's horizontal chain (SYSTOLIC) and aren't this column's own
    -- result.
    col_last_row_first(c) <= col_first_out(c)(15);
    col_last_row_last(c)  <= col_last_out(c)(15);
  end generate col_gen;

  bad_act_dist_gen : if ACT_DIST /= "SYSTOLIC" and ACT_DIST /= "TREE" generate
    assert false
      report "sys_array: ACT_DIST must be ""SYSTOLIC"" or ""TREE"""
      severity failure;
  end generate bad_act_dist_gen;

  ctrl_skew_inst : entity work.ctrl_skew
    generic map (N => DSP_COLUMNS, STAGE_LIST => ctrl_skew_stages(ACT_DIST, DSP_COLUMNS))
    port map (
      clk => clk, ce => ce,
      first_in => col_last_row_first, last_in => col_last_row_last,
      first_out => first_out, last_out => last_out
    );

  p_out <= col_p;

end architecture structural;
