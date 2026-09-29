library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- One systolic-array cell (claude_docs/08-vhdl-implementation-spec.md
-- S3.1): a dsp_mac2 plus the activation/control pass-through pe_column
-- chains cell to cell. Registers x_in -> x_out and first_in/last_in ->
-- first_out/last_out one clock -- gated by the same 'ce' that gates
-- dsp_mac2's own p_out register, so the whole cell advances together --
-- and feeds dsp_mac2 with first <= first_in.
--
-- x_in/x_out here run HORIZONTALLY, column to column (same row index,
-- next column), not vertically within a column: pe_column (S3.2) only
-- chains p_in/p_out row to row, so x_in/x_out are exposed per row for
-- sys_array to wire between adjacent columns under ACT_DIST=SYSTOLIC.
-- Concretely: dot-product depth-16 accumulation flows DOWN a column
-- (row r's p_out feeds row r+1's p_in), while one activation element
-- flows RIGHT across a row's 16 columns, one column-hop per clock, so
-- that every column eventually sees the same 16-element activation
-- vector against its own weight column -- a classic weight-stationary
-- systolic array. See act_skew.vhdl for how the 16 rows' worth of one
-- vector, which arrives simultaneously on sys_array's input bus, gets
-- pre-staggered by row before entering column 0 so that row r+1's x_in
-- and its p_in cascade (arriving one cycle later than row r's) carry
-- matching activation/partial-sum pairs for the same agent.
--
-- No generic ARCH here, unlike dsp_mac2's ARCH generic: like dsp_mac2
-- itself, "behav" vs "xilinx" is selected by which ARCHITECTURE of this
-- entity you elaborate/bind to, not by a generic string -- each
-- architecture below simply binds to the matching dsp_mac2 architecture.
-- Matches 08 S3.1's literal generic list (A_PORT_W, ACC_W, WEIGHT_W,
-- SPACING only, no ARCH).
--
-- No reset port, for the same reason dsp_mac2 has none (see its header):
-- an idle cell simply never pulses 'ce'.
entity pe_cell is
  generic (
    A_PORT_W : positive := 27;
    ACC_W    : positive := 48;
    WEIGHT_W : positive := 6;
    SPACING  : positive := 17
  );
  port (
    clk, ce              : in  std_logic;
    x_in                 : in  signed(7 downto 0);
    w1_next, w2_next     : in  signed(WEIGHT_W - 1 downto 0);
    first_in, last_in    : in  std_logic;
    p_in                 : in  signed(ACC_W - 1 downto 0);
    x_out                : out signed(7 downto 0);
    first_out, last_out  : out std_logic;
    p_out                : out signed(ACC_W - 1 downto 0)
  );
end entity pe_cell;

architecture behav of pe_cell is
  signal x_out_slv          : std_logic_vector(7 downto 0);
  signal fl_d, fl_q         : std_logic_vector(1 downto 0);
  signal dsp_x_out          : signed(7 downto 0);
  signal dsp_lane0, dsp_lane1 : std_logic;
begin

  mac : entity work.dsp_mac2(behav)
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
    port map (
      clk => clk, ce => ce, first => first_in,
      w1_next => w1_next, w2_next => w2_next,
      x_in => x_in, p_in => p_in,
      x_out => dsp_x_out, p_out => p_out,
      lane0_valid => dsp_lane0, lane1_valid => dsp_lane1
    );

  x_reg : entity work.generic_register
    generic map (WIDTH => 8)
    port map (clk => clk, rst => '0', en => ce, d => std_logic_vector(x_in), q => x_out_slv);

  fl_d <= first_in & last_in;

  fl_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => '0', en => ce, d => fl_d, q => fl_q);

  x_out     <= signed(x_out_slv);
  first_out <= fl_q(1);
  last_out  <= fl_q(0);

end architecture behav;

architecture xilinx of pe_cell is
  signal x_out_slv          : std_logic_vector(7 downto 0);
  signal fl_d, fl_q         : std_logic_vector(1 downto 0);
  signal dsp_x_out          : signed(7 downto 0);
  signal dsp_lane0, dsp_lane1 : std_logic;
begin

  mac : entity work.dsp_mac2(xilinx)
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
    port map (
      clk => clk, ce => ce, first => first_in,
      w1_next => w1_next, w2_next => w2_next,
      x_in => x_in, p_in => p_in,
      x_out => dsp_x_out, p_out => p_out,
      lane0_valid => dsp_lane0, lane1_valid => dsp_lane1
    );

  x_reg : entity work.generic_register
    generic map (WIDTH => 8)
    port map (clk => clk, rst => '0', en => ce, d => std_logic_vector(x_in), q => x_out_slv);

  fl_d <= first_in & last_in;

  fl_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => '0', en => ce, d => fl_d, q => fl_q);

  x_out     <= signed(x_out_slv);
  first_out <= fl_q(1);
  last_out  <= fl_q(0);

end architecture xilinx;
