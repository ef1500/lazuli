library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic combinational adder tree (syseng_docs/04-vhdl-module-list.md's
-- L1 'int_sum_tree'): sums N signed WIDTH-bit values, widening by
-- clog2(N) bits so the sum can never overflow regardless of input
-- values (worst case: every element at the same-sign extreme). Used by
-- the activation quantizer's per-32 group sum (Sigma x, needed for
-- Q4_K's asymmetric min_term, 04 S1) and anywhere else a fixed-size
-- combinational reduction is needed.
--
-- int_sum_tree_core (below) is the recursive binary-tree engine and
-- only accepts a power-of-two N; int_sum_tree is the public entity,
-- which pads up to the next power of two with zero-valued elements (the
-- identity for addition -- they never change the sum) and instantiates
-- the core. Same pad-then-recurse shape as generic_mux.vhdl/generic_lzc
-- .vhdl.
entity int_sum_tree_core is
  generic (
    WIDTH : positive := 8;
    N     : positive := 4 -- must be a power of two
  );
  port (
    d   : in  std_logic_vector(N * WIDTH - 1 downto 0);
    sum : out signed(WIDTH + clog2(N) - 1 downto 0)
  );
end entity int_sum_tree_core;

architecture recursive of int_sum_tree_core is
begin

  base : if N = 1 generate
    sum <= signed(d);
  end generate base;

  step : if N > 1 generate
    constant HALF : positive := N / 2;
    signal sum_lo, sum_hi : signed(WIDTH + clog2(HALF) - 1 downto 0);
  begin
    lo_half : entity work.int_sum_tree_core
      generic map (WIDTH => WIDTH, N => HALF)
      port map (d => d(HALF * WIDTH - 1 downto 0), sum => sum_lo);

    hi_half : entity work.int_sum_tree_core
      generic map (WIDTH => WIDTH, N => HALF)
      port map (d => d(N * WIDTH - 1 downto HALF * WIDTH), sum => sum_hi);

    sum <= resize(sum_lo, WIDTH + clog2(N)) + resize(sum_hi, WIDTH + clog2(N));
  end generate step;

end architecture recursive;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity int_sum_tree is
  generic (
    WIDTH : positive := 8;
    N     : positive := 4
  );
  port (
    d   : in  std_logic_vector(N * WIDTH - 1 downto 0);
    sum : out signed(WIDTH + clog2(N) - 1 downto 0)
  );
end entity int_sum_tree;

architecture structural of int_sum_tree is
  -- 2**clog2(N) always equals N when N is already a power of two, and
  -- clog2(2**clog2(N)) always equals clog2(N) -- so sum and the padded
  -- core's sum port are always the same width, pad or not (see
  -- generic_mux.vhdl's PN comment for the same invariant).
  constant PN : positive := 2 ** clog2(N);
  signal d_padded : std_logic_vector(PN * WIDTH - 1 downto 0);
  signal core_sum : signed(WIDTH + clog2(PN) - 1 downto 0);
begin

  d_padded(N * WIDTH - 1 downto 0) <= d;

  pad_gen : if PN > N generate
    d_padded(PN * WIDTH - 1 downto N * WIDTH) <= (others => '0');
  end generate pad_gen;

  core : entity work.int_sum_tree_core
    generic map (WIDTH => WIDTH, N => PN)
    port map (d => d_padded, sum => core_sum);

  sum <= core_sum;

end architecture structural;
