library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Output-side skew for the matrix array (syseng_docs/04-vhdl-module-
-- list.md's L2 'ctrl_skew': "delays the valid/first/last flags by
-- column index instead of delaying the data"). Chosen over buffering
-- the wide P data itself to re-align every column's completion time:
-- 68,544 FF/tile for a data-skew vs 8,064 for a flag-skew (04 S3's
-- "Skew choice"), because each column's downstream slice (int_mul_scale
-- eventually) can just run at ITS OWN natural time and write its own
-- acc_ram slice instead of waiting for every column to line up.
--
-- One channel per DSP column (not per output column/lane): both packed
-- lanes of a given DSP column complete on the exact same cycle (they
-- share dsp_mac2's one P register, see dsp_mac2.vhdl), so they need the
-- exact same flag delay -- no reason to skew them separately. 04's
-- 8,064 FF figure is 2 flags x 2 lanes x sum(0..DSP_COLUMNS-1) for
-- DSP_COLUMNS=64 (2016 stages x 4 = 8,064): a real layout likely
-- duplicates the delayed flag register per lane for fanout, which this
-- entity doesn't model (fanout duplication is a synthesis/floorplan
-- concern, not a functional one) -- logically, one flag pair per DSP
-- column is sufficient and this entity's own FF count is half that
-- (sum(0..63)*2 = 4,032).
--
-- Under ACT_DIST=SYSTOLIC (sys_array.vhdl), column c's flags already
-- arrive c clocks after column 0's for free, via pe_cell's own
-- first_out/last_out chain -- so sys_array instantiates this with
-- STAGES=>0 per channel there (a pass-through) rather than double-
-- skewing. Under ACT_DIST=TREE, every column's flags arrive together
-- (no natural stagger from a fan-out network), so sys_array drives this
-- with STAGES=>c per channel to manufacture the same c-clocks-per-
-- column timing SYSTOLIC gives for free -- letting whatever consumes
-- sys_array's output (the rescaler, not yet built) stay agnostic to
-- which ACT_DIST it was built with. [D]
entity ctrl_skew is
  generic (
    N          : positive := 64; -- number of columns
    STAGE_LIST : integer_vector(0 to N - 1) -- channel c's flags delay by STAGE_LIST(c) clocks
  );
  port (
    clk : in std_logic;
    ce  : in std_logic := '1';

    first_in  : in  std_logic_vector(N - 1 downto 0);
    last_in   : in  std_logic_vector(N - 1 downto 0);
    first_out : out std_logic_vector(N - 1 downto 0);
    last_out  : out std_logic_vector(N - 1 downto 0)
  );
end entity ctrl_skew;

architecture structural of ctrl_skew is
begin

  chan_gen : for c in 0 to N - 1 generate
    signal packed_in, packed_out : std_logic_vector(1 downto 0); -- first & last
  begin
    packed_in <= first_in(c) & last_in(c);

    dl : entity work.generic_delay_line
      generic map (WIDTH => 2, STAGES => STAGE_LIST(c))
      port map (clk => clk, rst => '0', en => ce, d => packed_in, q => packed_out);

    first_out(c) <= packed_out(1);
    last_out(c)  <= packed_out(0);
  end generate chan_gen;

end architecture structural;
