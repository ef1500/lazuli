library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic N-to-1, WIDTH-bit multiplexer, built as a binary tree of
-- generic_mux2 instances rather than a 'with sel select' or a function
-- that computes the answer procedurally. 'd' packs the N inputs
-- concatenated (entry i at d((i+1)*WIDTH-1 downto i*WIDTH), matching
-- how lazuli.vhdl already packs per-lane data).
--
-- generic_mux_core (below) is the recursive binary-tree engine and only
-- accepts a power-of-two N; generic_mux is the public entity, which
-- pads up to the next power of two (zero-filling the unused inputs --
-- never selected, since 'sel' only ever carries values 0..N-1) and
-- instantiates the core. This is the same pad-then-recurse shape as
-- generic_lzc.vhdl.
entity generic_mux_core is
  generic (
    WIDTH : positive := 8;
    N     : positive := 4 -- must be a power of two
  );
  port (
    sel : in  unsigned(clog2(N) - 1 downto 0);
    d   : in  std_logic_vector(N * WIDTH - 1 downto 0);
    y   : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_mux_core;

architecture recursive of generic_mux_core is
begin

  base : if N = 1 generate
    y <= d;
  end generate base;

  step : if N > 1 generate
    constant HALF : positive := N / 2;
    signal y_lo, y_hi : std_logic_vector(WIDTH - 1 downto 0);
  begin
    lo_half : entity work.generic_mux_core
      generic map (WIDTH => WIDTH, N => HALF)
      port map (sel => sel(clog2(HALF) - 1 downto 0), d => d(HALF * WIDTH - 1 downto 0), y => y_lo);

    hi_half : entity work.generic_mux_core
      generic map (WIDTH => WIDTH, N => HALF)
      port map (sel => sel(clog2(HALF) - 1 downto 0), d => d(N * WIDTH - 1 downto HALF * WIDTH), y => y_hi);

    top_mux : entity work.generic_mux2
      generic map (WIDTH => WIDTH)
      port map (sel => sel(clog2(N) - 1), d0 => y_lo, d1 => y_hi, y => y);
  end generate step;

end architecture recursive;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity generic_mux is
  generic (
    WIDTH : positive := 8;
    N     : positive := 4
  );
  port (
    sel : in  unsigned(clog2(N) - 1 downto 0);
    d   : in  std_logic_vector(N * WIDTH - 1 downto 0);
    y   : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_mux;

architecture structural of generic_mux is
  -- 2**clog2(N) always equals N when N is already a power of two, and
  -- clog2(2**clog2(N)) always equals clog2(N) -- so sel and the padded
  -- core's sel port are always the same width, pad or not.
  constant PN : positive := 2 ** clog2(N);
  signal d_padded : std_logic_vector(PN * WIDTH - 1 downto 0);
begin

  d_padded(N * WIDTH - 1 downto 0) <= d;

  pad_gen : if PN > N generate
    d_padded(PN * WIDTH - 1 downto N * WIDTH) <= (others => '0');
  end generate pad_gen;

  core : entity work.generic_mux_core
    generic map (WIDTH => WIDTH, N => PN)
    port map (sel => sel, d => d_padded, y => y);

end architecture structural;
