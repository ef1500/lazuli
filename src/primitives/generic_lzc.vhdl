library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic leading-zero counter: counts how many zero bits precede the
-- first '1', scanning from the MSB down. Built as a recursive binary
-- tree (not a software-style scan loop in a function): split the input
-- in half, recurse on each half, and combine with one generic_mux2 --
-- if the upper half has a '1' anywhere, the count is the upper half's
-- own count (with a leading 0 prepended, since we never needed to look
-- at the lower half); otherwise it's 1 followed by the lower half's
-- count.
--
-- generic_lzc_core (below) requires a power-of-two WIDTH; generic_lzc
-- is the public entity and pads arbitrary WIDTH up to the next power of
-- two with '1' bits appended at the LSB end -- a '1' there can never be
-- mistaken for a real leading zero (scanning is MSB-first) and
-- guarantees the count never runs past the real WIDTH.
entity generic_lzc_core is
  generic (
    WIDTH : positive := 8 -- must be a power of two
  );
  port (
    d        : in  std_logic_vector(WIDTH - 1 downto 0);
    all_zero : out std_logic;
    count    : out unsigned(clog2(WIDTH) - 1 downto 0) -- null range when WIDTH = 1
  );
end entity generic_lzc_core;

architecture recursive of generic_lzc_core is
begin

  base : if WIDTH = 1 generate
    all_zero <= not d(0);
  end generate base;

  step : if WIDTH > 1 generate
    constant HALF : positive := WIDTH / 2;
    signal upper_zero, lower_zero : std_logic;
    signal upper_count, lower_count : unsigned(clog2(HALF) - 1 downto 0);
    signal hi_result, lo_result : std_logic_vector(clog2(WIDTH) - 1 downto 0);
    signal count_slv : std_logic_vector(clog2(WIDTH) - 1 downto 0);
  begin
    upper : entity work.generic_lzc_core
      generic map (WIDTH => HALF)
      port map (d => d(WIDTH - 1 downto HALF), all_zero => upper_zero, count => upper_count);

    lower : entity work.generic_lzc_core
      generic map (WIDTH => HALF)
      port map (d => d(HALF - 1 downto 0), all_zero => lower_zero, count => lower_count);

    all_zero <= upper_zero and lower_zero;

    -- upper not all zero -> count = 0 & upper_count; upper all zero -> 1 & lower_count
    hi_result <= '0' & std_logic_vector(upper_count);
    lo_result <= '1' & std_logic_vector(lower_count);

    combine : entity work.generic_mux2
      generic map (WIDTH => clog2(WIDTH))
      port map (sel => upper_zero, d0 => hi_result, d1 => lo_result, y => count_slv);

    count <= unsigned(count_slv);
  end generate step;

end architecture recursive;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity generic_lzc is
  generic (
    WIDTH : positive := 32
  );
  port (
    d        : in  std_logic_vector(WIDTH - 1 downto 0);
    all_zero : out std_logic;
    count    : out unsigned(clog2(WIDTH + 1) - 1 downto 0) -- 0 .. WIDTH inclusive
  );
end entity generic_lzc;

architecture structural of generic_lzc is
  constant PWIDTH : positive := 2 ** clog2(WIDTH);
  signal d_padded : std_logic_vector(PWIDTH - 1 downto 0);
  signal core_count : unsigned(clog2(PWIDTH) - 1 downto 0);
  signal core_all_zero : std_logic;
begin

  d_padded(PWIDTH - 1 downto PWIDTH - WIDTH) <= d;

  pad_gen : if PWIDTH > WIDTH generate
    d_padded(PWIDTH - WIDTH - 1 downto 0) <= (others => '1');
  end generate pad_gen;

  core : entity work.generic_lzc_core
    generic map (WIDTH => PWIDTH)
    port map (d => d_padded, all_zero => core_all_zero, count => core_count);

  count <= resize(core_count, count'length);

  -- With padding (PWIDTH > WIDTH), the pad bits are '1's, so the padded
  -- vector is never all-zero even when every real bit is -- core_count
  -- lands on exactly WIDTH in precisely that case instead (the pad
  -- trick's whole point), so derive all_zero from that. With no padding
  -- needed (WIDTH already a power of two), core_all_zero is already
  -- correct as-is (there are no pad-bit artifacts to correct for).
  no_pad_gen : if PWIDTH = WIDTH generate
    all_zero <= core_all_zero;
  end generate no_pad_gen;

  pad_flag_gen : if PWIDTH > WIDTH generate
    all_zero <= '1' when core_count = WIDTH else '0';
  end generate pad_flag_gen;

end architecture structural;
