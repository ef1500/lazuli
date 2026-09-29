library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Input-side skew bank for the matrix array (syseng_docs/04-vhdl-
-- module-list.md's L2 'act_skew': "delays row r by r clocks"). Mandatory
-- prerequisite for pe_column regardless of sys_array's ACT_DIST choice
-- -- see pe_cell.vhdl/pe_column.vhdl's headers for the full reasoning,
-- summarized here: sys_array's activation port delivers one full
-- ROWS-wide vector simultaneously each clock (one agent's worth of
-- activation, all ROWS elements at once), but pe_column's vertical P
-- cascade needs row r's element to arrive r clocks after row 0's (since
-- that's how long the partial sum takes to ripple down to row r). This
-- entity is what performs that conversion: row r's copy of the incoming
-- vector (and the first/last flags that travel with it) is delayed by
-- exactly r clocks before reaching pe_column's per-row ports.
--
-- Built from generic_delay_line, one instance per row with STAGES=>r
-- (row 0 gets STAGES=>0, a plain passthrough). x/first/last are packed
-- together into one delay_line per row so they stay bit-exact aligned;
-- splitting them into three separate delay lines per row risks them
-- drifting apart under a future edit.
--
-- FF count: sum(0..ROWS-1) * 8 = 120*8 = 960 for ROWS=16, matching 04's
-- own "act_skew: 120x8=960 flip-flops" figure for the activation path
-- alone -- this entity's actual FF count is a bit higher (120*10=1200)
-- since it also skews the 2 flag bits alongside the 8 activation bits,
-- which 04's headline figure doesn't appear to have separately tallied.
--
-- Row 0 gets STAGES=>0, which generic_delay_line implements as a pure
-- combinational passthrough (no register at all) -- so row 0's outputs
-- track x_in/first_in/last_in immediately and are NOT gated by 'ce',
-- unlike every other row. This falls out naturally from wanting a
-- uniform per-row loop rather than special-casing row 0, and is
-- harmless here since row 0 feeding pe_column always has real data
-- exactly when the rest of the array does -- but it's worth knowing if
-- you ever probe row 0 in isolation.
entity act_skew is
  generic (
    ROWS : positive := 16
  );
  port (
    clk   : in  std_logic;
    ce    : in  std_logic := '1';
    x_in  : in  std_logic_vector(ROWS * 8 - 1 downto 0); -- one row's worth per clock, ROWS wide
    first_in, last_in : in std_logic;

    x_out     : out std_logic_vector(ROWS * 8 - 1 downto 0); -- row r skewed by r clocks
    first_out : out std_logic_vector(ROWS - 1 downto 0);
    last_out  : out std_logic_vector(ROWS - 1 downto 0)
  );
end entity act_skew;

architecture structural of act_skew is
begin

  row_gen : for r in 0 to ROWS - 1 generate
    signal packed_in, packed_out : std_logic_vector(9 downto 0); -- x(7:0) & first & last
  begin
    packed_in <= x_in((r + 1) * 8 - 1 downto r * 8) & first_in & last_in;

    dl : entity work.generic_delay_line
      generic map (WIDTH => 10, STAGES => r)
      port map (clk => clk, rst => '0', en => ce, d => packed_in, q => packed_out);

    x_out((r + 1) * 8 - 1 downto r * 8) <= packed_out(9 downto 2);
    first_out(r) <= packed_out(1);
    last_out(r)  <= packed_out(0);
  end generate row_gen;

end architecture structural;
