library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- One systolic-array column: R=16 pe_cell chained vertically through the
-- dot-product cascade (claude_docs/08-vhdl-implementation-spec.md S3.2).
-- p_out of row r feeds p_in of row r+1; row 0's p_in is tied to 0
-- internally (not an external port -- a column always starts its
-- depth-16 sum from zero, there's nothing meaningful to feed it from
-- outside). Only the final row's p_out (the completed 16-deep dot
-- product for this column) is exposed.
--
-- x_in/x_out and first_in/first_out/last_in/last_out, by contrast, are
-- exposed PER ROW (packed 16-wide buses -- entry r at bits
-- ((r+1)*8-1 downto r*8) for the 8-bit signals, bit r for the 1-bit
-- flags -- same packing convention as generic_mux.vhdl) because they
-- run HORIZONTALLY, not vertically (see pe_cell.vhdl's header): row r's
-- activation/first/last come from and go to the SAME row r of the
-- neighboring column, wired by sys_array, not chained within this
-- column. w1_next/w2_next are likewise per-row (weight_loader drives
-- each cell's weight pair independently).
--
-- ROWS is fixed at 16, not a generic (matches Q3_K's group size, per
-- claude_docs/04-vhdl-module-list.md's "R=16, fixed by the Q3_K group
-- size" note) -- everything above this in the design assumes it.
entity pe_column is
  generic (
    A_PORT_W : positive := 27;
    ACC_W    : positive := 48;
    WEIGHT_W : positive := 6;
    SPACING  : positive := 17
  );
  port (
    clk, ce   : in  std_logic;

    x_in      : in  std_logic_vector(16 * 8 - 1 downto 0);
    x_out     : out std_logic_vector(16 * 8 - 1 downto 0);

    w1_next   : in  std_logic_vector(16 * WEIGHT_W - 1 downto 0);
    w2_next   : in  std_logic_vector(16 * WEIGHT_W - 1 downto 0);

    first_in  : in  std_logic_vector(15 downto 0);
    first_out : out std_logic_vector(15 downto 0);
    last_in   : in  std_logic_vector(15 downto 0);
    last_out  : out std_logic_vector(15 downto 0);

    p_out     : out signed(ACC_W - 1 downto 0)
  );
end entity pe_column;

architecture behav of pe_column is
  constant ROWS : positive := 16;
  type p_arr_t is array (0 to ROWS) of signed(ACC_W - 1 downto 0);
  signal p : p_arr_t;
begin

  p(0) <= (others => '0');

  row_gen : for r in 0 to ROWS - 1 generate
    signal x_in_r, x_out_r : signed(7 downto 0);
    signal w1_r, w2_r      : signed(WEIGHT_W - 1 downto 0);
  begin
    x_in_r <= signed(x_in((r + 1) * 8 - 1 downto r * 8));
    w1_r   <= signed(w1_next((r + 1) * WEIGHT_W - 1 downto r * WEIGHT_W));
    w2_r   <= signed(w2_next((r + 1) * WEIGHT_W - 1 downto r * WEIGHT_W));

    cell : entity work.pe_cell(behav)
      generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
      port map (
        clk => clk, ce => ce,
        x_in => x_in_r,
        w1_next => w1_r, w2_next => w2_r,
        first_in => first_in(r), last_in => last_in(r),
        p_in => p(r),
        x_out => x_out_r,
        first_out => first_out(r), last_out => last_out(r),
        p_out => p(r + 1)
      );

    x_out((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(x_out_r);
  end generate row_gen;

  p_out <= p(ROWS);

end architecture behav;

architecture xilinx of pe_column is
  constant ROWS : positive := 16;
  type p_arr_t is array (0 to ROWS) of signed(ACC_W - 1 downto 0);
  signal p : p_arr_t;
begin

  p(0) <= (others => '0');

  row_gen : for r in 0 to ROWS - 1 generate
    signal x_in_r, x_out_r : signed(7 downto 0);
    signal w1_r, w2_r      : signed(WEIGHT_W - 1 downto 0);
  begin
    x_in_r <= signed(x_in((r + 1) * 8 - 1 downto r * 8));
    w1_r   <= signed(w1_next((r + 1) * WEIGHT_W - 1 downto r * WEIGHT_W));
    w2_r   <= signed(w2_next((r + 1) * WEIGHT_W - 1 downto r * WEIGHT_W));

    cell : entity work.pe_cell(xilinx)
      generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
      port map (
        clk => clk, ce => ce,
        x_in => x_in_r,
        w1_next => w1_r, w2_next => w2_r,
        first_in => first_in(r), last_in => last_in(r),
        p_in => p(r),
        x_out => x_out_r,
        first_out => first_out(r), last_out => last_out(r),
        p_out => p(r + 1)
      );

    x_out((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(x_out_r);
  end generate row_gen;

  p_out <= p(ROWS);

end architecture xilinx;
