library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Shared types and helper functions used by every primitive in this
-- project (src/primitives/*.vhdl). Compile this package before
-- anything that does 'use work.project_types.all;'.

package project_types is

  -- Ceiling log base 2: the number of bits needed to count 0 .. n-1.
  -- clog2(1) = 0, clog2(2) = 1, clog2(3) = 2, clog2(4) = 2, clog2(5) = 3.
  function clog2(n : natural) return natural;

  -- Convenience wrapper so std_logic can be used directly in
  -- boolean-valued conditions (e.g. 'when' clauses over 'and'/'or'
  -- expressions built from std_logic signals).
  function to_boolean(b : std_logic) return boolean;

  -- Promote a single std_logic bit to a 1-bit std_logic_vector so it
  -- can be concatenated ('&') with other std_logic signals to build a
  -- selector vector for a 'with ... select' statement.
  function to_vector(b : std_logic) return std_logic_vector;

  -- One-hot decoder: returns a std_logic_vector of length 2**sel'length
  -- where bit position to_integer(unsigned(sel)) is 'en' and every other
  -- bit is '0'. Callers that assign the result into a signal narrower
  -- than 2**sel'length (e.g. a non-power-of-two depth) must size sel so
  -- that 2**sel'length equals the target length -- every depth in this
  -- project is a power of two, so this always holds in practice.
  function decode(sel : std_logic_vector; en : std_logic) return std_logic_vector;

  -- ALU op selector for generic_fpu / generic_vector_unit
  -- (08-vhdl-implementation-spec.md S1.1, S2.3).
  type alu_op_t is (ALU_ADD, ALU_MUL, ALU_MAX, ALU_CVT, ALU_LUT);

  -- Which conversion generic_fpu performs when op = ALU_CVT.
  type cvt_op_t is (CVT_I2F, CVT_F2I, CVT_F16_TO_F32, CVT_F32_TO_F16);

  -- ALU_ADD sub-flags: bit positions in generic_fpu's 'sub' input.
  -- NEG_A/NEG_B negate that operand before adding; ABS_A forces a's sign
  -- positive (applied before NEG_A), so (ABS_A, NEG_B) gives |a| - b, etc.
  constant NEG_A : natural := 0;
  constant NEG_B : natural := 1;
  constant ABS_A : natural := 2;

  -- generic_lookup table addressing mode (08-vhdl-implementation-spec.md
  -- S2.4). TAB_MANT and TAB_RSQRT both index by mantissa bits but differ
  -- in how the output exponent is reconstructed (plain negate vs
  -- halve-with-odd/even folding) -- the source spec lumps both under one
  -- "TAB_MANT" mode without a way to select the exponent transform, so
  -- this package splits them into two mode values instead. See
  -- generic_lookup.vhdl's header comment for the reasoning.
  type tab_mode_t is (TAB_MANT, TAB_RSQRT, TAB_FRAC, TAB_RANGE);
  type tab_edge_t is (EDGE_CLAMP, EDGE_ZERO, EDGE_IDENTITY);

  -- Status flags returned by generic_fpu/generic_lookup on their 'flag' port.
  constant FLAG_OK       : std_logic_vector(1 downto 0) := "00";
  constant FLAG_FLUSHED  : std_logic_vector(1 downto 0) := "01"; -- denormal/underflow result flushed to 0
  constant FLAG_OVERFLOW : std_logic_vector(1 downto 0) := "10"; -- result magnitude saturated
  constant FLAG_ERROR    : std_logic_vector(1 downto 0) := "11"; -- NaN/Inf input, not propagated

  -- Reorders an IEEE-754 fp32 bit pattern so an ordinary unsigned compare
  -- gives the correct float ordering (flip the sign bit; if it was
  -- negative, flip everything else too). Used by fp32_max and any
  -- unsigned-compare sorter (e.g. a top-k sampler).
  function f32_key(x : std_logic_vector(31 downto 0)) return std_logic_vector;

end package project_types;

package body project_types is

  function clog2(n : natural) return natural is
    variable bits : natural := 0;
    variable span : natural := 1;
  begin
    while span < n loop
      span := span * 2;
      bits := bits + 1;
    end loop;
    return bits;
  end function clog2;

  function to_boolean(b : std_logic) return boolean is
  begin
    return b = '1';
  end function to_boolean;

  function to_vector(b : std_logic) return std_logic_vector is
    variable result : std_logic_vector(0 downto 0);
  begin
    result(0) := b;
    return result;
  end function to_vector;

  function decode(sel : std_logic_vector; en : std_logic) return std_logic_vector is
    variable result : std_logic_vector(2**sel'length - 1 downto 0) := (others => '0');
  begin
    result(to_integer(unsigned(sel))) := en;
    return result;
  end function decode;

  function f32_key(x : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable key : std_logic_vector(31 downto 0);
  begin
    if x(31) = '1' then
      key := not x;
    else
      key := '1' & x(30 downto 0);
    end if;
    return key;
  end function f32_key;

end package body project_types;
