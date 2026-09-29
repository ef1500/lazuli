library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Generic round-to-nearest-even and saturate (syseng_docs/04-vhdl-
-- module-list.md's L0 utility 'round_sat'): takes a fixed-point value
-- wider than the output and produces the nearest representable
-- OUT_WIDTH-bit value, clamped to the output's range on overflow. Used
-- wherever a wide accumulator/product needs to land in a narrower
-- field (the rescaler's group-scale multiplies, a future fixed-point
-- accumulate-and-store step, etc.) -- generic_fpu.vhdl's own round_pack
-- does the equivalent job for fp32 specifically, inline, since it needs
-- float-specific exponent handling round_sat doesn't; this is the
-- plain fixed-point version for everything else.
--
-- d's bottom (IN_WIDTH - OUT_WIDTH) bits are the fractional/guard bits
-- being rounded away; d's top OUT_WIDTH bits are the kept value. This
-- is genuinely an arithmetic block (an adder and comparators), not a
-- topological one like the shifters/muxes elsewhere in this directory,
-- so it's written directly with VHDL's arithmetic/relational operators
-- rather than composed from smaller structural pieces.
entity generic_round_sat is
  generic (
    IN_WIDTH  : positive := 32;
    OUT_WIDTH : positive := 16;
    IS_SIGNED : boolean  := true
  );
  port (
    d   : in  std_logic_vector(IN_WIDTH - 1 downto 0);
    y   : out std_logic_vector(OUT_WIDTH - 1 downto 0);
    sat : out std_logic
  );
end entity generic_round_sat;

architecture behavioral of generic_round_sat is
  constant FRAC_BITS : natural := IN_WIDTH - OUT_WIDTH;
begin

  -- OUT_WIDTH = IN_WIDTH: nothing to round or saturate.
  passthrough_gen : if FRAC_BITS = 0 generate
    y   <= d;
    sat <= '0';
  end generate passthrough_gen;

  round_gen : if FRAC_BITS > 0 generate
    signal round_bit, sticky, lsb, round_up : std_logic;
    signal head_s : signed(OUT_WIDTH downto 0);   -- one extra bit to catch a rounding carry-out
    signal head_u : unsigned(OUT_WIDTH downto 0);
    signal rounded_s : signed(OUT_WIDTH downto 0);
    signal rounded_u : unsigned(OUT_WIDTH downto 0);
    constant MAX_S : signed(OUT_WIDTH downto 0) := shift_left(to_signed(1, OUT_WIDTH + 1), OUT_WIDTH - 1) - 1;
    constant MIN_S : signed(OUT_WIDTH downto 0) := -shift_left(to_signed(1, OUT_WIDTH + 1), OUT_WIDTH - 1);
    constant MAX_U : unsigned(OUT_WIDTH downto 0) := shift_left(to_unsigned(1, OUT_WIDTH + 1), OUT_WIDTH) - 1;
  begin

    round_bit <= d(FRAC_BITS - 1);
    sticky_gen : if FRAC_BITS >= 2 generate
      sticky <= (or d(FRAC_BITS - 2 downto 0));
    end generate sticky_gen;
    no_sticky_gen : if FRAC_BITS < 2 generate
      sticky <= '0';
    end generate no_sticky_gen;

    lsb <= d(FRAC_BITS);
    round_up <= round_bit and (sticky or lsb);

    signed_gen : if IS_SIGNED generate
      head_s <= resize(signed(d(IN_WIDTH - 1 downto FRAC_BITS)), OUT_WIDTH + 1);
      rounded_s <= head_s + 1 when round_up = '1' else head_s;

      y <= std_logic_vector(MAX_S(OUT_WIDTH - 1 downto 0)) when rounded_s > MAX_S else
           std_logic_vector(MIN_S(OUT_WIDTH - 1 downto 0)) when rounded_s < MIN_S else
           std_logic_vector(rounded_s(OUT_WIDTH - 1 downto 0));
      sat <= '1' when (rounded_s > MAX_S) or (rounded_s < MIN_S) else '0';
    end generate signed_gen;

    unsigned_gen : if not IS_SIGNED generate
      head_u <= resize(unsigned(d(IN_WIDTH - 1 downto FRAC_BITS)), OUT_WIDTH + 1);
      rounded_u <= head_u + 1 when round_up = '1' else head_u;

      y <= std_logic_vector(MAX_U(OUT_WIDTH - 1 downto 0)) when rounded_u > MAX_U else
           std_logic_vector(rounded_u(OUT_WIDTH - 1 downto 0));
      sat <= '1' when rounded_u > MAX_U else '0';
    end generate unsigned_gen;

  end generate round_gen;

end architecture behavioral;
