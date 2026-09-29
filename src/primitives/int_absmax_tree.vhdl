library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic combinational absolute-maximum tree (syseng_docs/04-vhdl-
-- module-list.md's L1 'int_absmax_tree'): returns the largest magnitude
-- among N signed WIDTH-bit values -- used by the activation quantizer's
-- per-256-element abs-max step (04 S2.3/S4's act_quantizer: "abs-max ->
-- recip -> multiply -> round -> clamp +-127").
--
-- A WIDTH-bit signed value's magnitude always fits in WIDTH bits
-- unsigned without growing a bit: the most negative value, -2**(WIDTH-1),
-- has magnitude 2**(WIDTH-1), which is representable in WIDTH-bit
-- unsigned (max representable there is 2**WIDTH-1). So unlike
-- int_sum_tree, this tree's width never grows going up the tree -- each
-- level just keeps the larger of its two children's magnitudes.
--
-- The leaf's magnitude step (unsigned(-v) when negative) looks like it
-- should overflow for that same most-negative value -- negating it in
-- WIDTH-bit signed arithmetic doesn't fit in the signed range -- but
-- two's-complement negation is modulo 2**WIDTH, and 2**(WIDTH-1) mod
-- 2**WIDTH has the exact same bit pattern as -2**(WIDTH-1) itself
-- (1000...0). Reinterpreting that bit pattern as unsigned immediately
-- afterward recovers the correct positive magnitude, so no separate
-- guard bit or saturation is needed here. This is genuinely arithmetic
-- (like generic_round_sat's rounding step), not topological, so it's
-- written directly with numeric_std's unary "-" rather than built from
-- muxes/adders as separate primitives.
--
-- int_absmax_tree_core (below) is the recursive binary-tree engine and
-- only accepts a power-of-two N; int_absmax_tree is the public entity,
-- which pads up to the next power of two with zero-valued elements (0
-- is the smallest possible magnitude, so a pad element can never win
-- the max unless every real element is also 0, in which case 0 is the
-- correct answer anyway) and instantiates the core. Same pad-then-
-- recurse shape as generic_mux.vhdl/generic_lzc.vhdl.
entity int_absmax_tree_core is
  generic (
    WIDTH : positive := 8;
    N     : positive := 4 -- must be a power of two
  );
  port (
    d      : in  std_logic_vector(N * WIDTH - 1 downto 0);
    absmax : out unsigned(WIDTH - 1 downto 0)
  );
end entity int_absmax_tree_core;

architecture recursive of int_absmax_tree_core is
begin

  base : if N = 1 generate
    signal v : signed(WIDTH - 1 downto 0);
  begin
    v <= signed(d);
    absmax <= unsigned(-v) when v(WIDTH - 1) = '1' else unsigned(v);
  end generate base;

  step : if N > 1 generate
    constant HALF : positive := N / 2;
    signal absmax_lo, absmax_hi : unsigned(WIDTH - 1 downto 0);
    signal hi_wins : std_logic;
    signal winner  : std_logic_vector(WIDTH - 1 downto 0);
  begin
    lo_half : entity work.int_absmax_tree_core
      generic map (WIDTH => WIDTH, N => HALF)
      port map (d => d(HALF * WIDTH - 1 downto 0), absmax => absmax_lo);

    hi_half : entity work.int_absmax_tree_core
      generic map (WIDTH => WIDTH, N => HALF)
      port map (d => d(N * WIDTH - 1 downto HALF * WIDTH), absmax => absmax_hi);

    hi_wins <= '1' when absmax_hi > absmax_lo else '0';

    combine : entity work.generic_mux2
      generic map (WIDTH => WIDTH)
      port map (
        sel => hi_wins,
        d0  => std_logic_vector(absmax_lo),
        d1  => std_logic_vector(absmax_hi),
        y   => winner
      );

    absmax <= unsigned(winner);
  end generate step;

end architecture recursive;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity int_absmax_tree is
  generic (
    WIDTH : positive := 8;
    N     : positive := 4
  );
  port (
    d      : in  std_logic_vector(N * WIDTH - 1 downto 0);
    absmax : out unsigned(WIDTH - 1 downto 0)
  );
end entity int_absmax_tree;

architecture structural of int_absmax_tree is
  constant PN : positive := 2 ** clog2(N);
  signal d_padded : std_logic_vector(PN * WIDTH - 1 downto 0);
begin

  d_padded(N * WIDTH - 1 downto 0) <= d;

  pad_gen : if PN > N generate
    d_padded(PN * WIDTH - 1 downto N * WIDTH) <= (others => '0');
  end generate pad_gen;

  core : entity work.int_absmax_tree_core
    generic map (WIDTH => WIDTH, N => PN)
    port map (d => d_padded, absmax => absmax);

end architecture structural;
