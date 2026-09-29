library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic table-driven fp32 function unit (syseng_docs/08-vhdl-
-- implementation-spec.md S2.4's 'lut_unit'). y = T[i] + slope[i]*frac,
-- where i/frac come from x per the loaded slot's mode:
--   TAB_MANT  (recip, domain [1,2))   : i/frac from x's mantissa bits directly
--   TAB_RSQRT (rsqrt, domain [1,4))   : as TAB_MANT, plus odd/even exponent folding
--   TAB_FRAC  (exp2, x = ipart+frac)  : i/frac from floor(x)'s fractional remainder
--   TAB_RANGE (sigmoid/silu/gelu)     : clamp x to [lo,hi], i/frac linear over the span
--
-- Two deliberate deviations from the doc's lut_unit sketch, both needed
-- to make the interface buildable, documented here rather than silently:
--  1. TAB_MANT and TAB_RSQRT are separate modes. The doc lumps recip and
--     rsqrt under one "TAB_MANT" name but they need different output-
--     exponent reconstructions (plain negate vs halve-with-parity-fold);
--     there is no other port that could select between the two, so this
--     package splits them (project_types.vhdl).
--  2. Added 'ld_bits' (log2 of this slot's table depth) to the load port.
--     The doc's ld_addr is sized for up to 1024 entries, but individual
--     tables are smaller (128 for recip, 256 for rsqrt, 1024 for the
--     RANGE functions per S2.4's own accuracy table) and nothing else in
--     the port list carries that per-slot depth.
--  3. TAB_RANGE requires (ld_hi - ld_lo) to be an exact power of two.
--     Every function in S2.4's accuracy table satisfies this (32, 32, 16),
--     and it lets indexing be done with a pure exponent shift instead of
--     an on-chip divider -- which would be circular, since division is
--     exactly what this unit exists to avoid.
--  4. TAB_FRAC (exp2) additionally requires |x| < 256 (flagged
--     FLAG_OVERFLOW otherwise). Every real use range-reduces first (see
--     syseng_docs/04-vhdl-module-list.md S2.3's exp_unit note: "reduce
--     x = k*ln2+r ... e^r from a 128-entry table"), so x reaching this
--     unit is always small; this bound just keeps the on-chip integer
--     part arithmetic in a range where exact (unrounded) i2f holds.
--
-- Latency: one clock (registered on 'clk' when 'ce' = '1'), reading the
-- table combinationally in the same cycle -- modeled as a signal array
-- here; on an FPGA this infers as a small dual-port block/LUT RAM per
-- slot with the same one-cycle read latency.
entity generic_lookup is
  port (
    clk  : in  std_logic;
    ce   : in  std_logic;
    slot : in  unsigned(2 downto 0);
    x    : in  std_logic_vector(31 downto 0);
    y    : out std_logic_vector(31 downto 0);
    flag : out std_logic_vector(1 downto 0);

    -- table / slot-config load port, host-writable at any idle time
    ld_en    : in std_logic;                     -- latch mode/lo/hi/edges/bits for ld_slot
    ld_slot  : in unsigned(2 downto 0);
    ld_mode  : in tab_mode_t;
    ld_lo    : in std_logic_vector(31 downto 0);  -- TAB_RANGE only
    ld_hi    : in std_logic_vector(31 downto 0);  -- TAB_RANGE only
    ld_left  : in tab_edge_t;                     -- TAB_RANGE only, x < lo
    ld_right : in tab_edge_t;                     -- TAB_RANGE only, x > hi
    ld_bits  : in unsigned(3 downto 0);           -- log2(table depth), 1..10

    ld_addr  : in unsigned(9 downto 0);
    ld_value : in std_logic_vector(31 downto 0);
    ld_slope : in std_logic_vector(31 downto 0);
    ld_we    : in std_logic                       -- write table[ld_slot][ld_addr] this clock
  );
end entity generic_lookup;

architecture behavioral of generic_lookup is

  type fp_fields_t is record
    sign    : std_logic;
    exp     : integer range 0 to 255;
    mant    : unsigned(23 downto 0);
    is_zero : boolean;
    is_spec : boolean;
  end record;

  function unpack(v : std_logic_vector(31 downto 0)) return fp_fields_t is
    variable f : fp_fields_t;
  begin
    f.sign    := v(31);
    f.exp     := to_integer(unsigned(v(30 downto 23)));
    f.is_spec := (f.exp = 255);
    if f.exp = 0 then
      f.mant    := (others => '0');
      f.is_zero := true;
    else
      f.mant    := '1' & unsigned(v(22 downto 0));
      f.is_zero := false;
    end if;
    return f;
  end function unpack;

  constant ONE_FP32 : std_logic_vector(31 downto 0) := x"3F800000";

  function negate(v : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    return (not v(31)) & v(30 downto 0);
  end function negate;

  -- round-to-nearest-even pack, same contract as generic_fpu's round_pack:
  -- mant's implicit leading 1 must sit at bit (frac_bits+23) (mant=0 is
  -- an exact zero).
  procedure round_pack(sign : in std_logic; exp_u : in integer;
                        mant : in unsigned; frac_bits : in natural;
                        yy : out std_logic_vector(31 downto 0);
                        ff : out std_logic_vector(1 downto 0)) is
    variable head : unsigned(24 downto 0);
    variable round_bit, sticky, lsb : std_logic;
    variable e : integer;
  begin
    if mant = 0 then
      yy := sign & (30 downto 0 => '0');
      ff := FLAG_OK;
      return;
    end if;
    e    := exp_u;
    head := '0' & mant(frac_bits + 23 downto frac_bits);
    if frac_bits = 0 then
      round_bit := '0'; sticky := '0';
    else
      round_bit := mant(frac_bits - 1);
      if frac_bits >= 2 then
        sticky := (or std_logic_vector(mant(frac_bits - 2 downto 0)));
      else
        sticky := '0';
      end if;
    end if;
    lsb := head(0);
    if (round_bit = '1') and ((sticky = '1') or (lsb = '1')) then
      head := head + 1;
    end if;
    if head(24) = '1' then
      head := shift_right(head, 1);
      e := e + 1;
    end if;
    if e > 127 then
      ff := FLAG_OVERFLOW;
      yy := sign & "11111110" & (22 downto 0 => '1');
    elsif e < -126 then
      ff := FLAG_FLUSHED;
      yy := sign & (30 downto 0 => '0');
    else
      ff := FLAG_OK;
      yy := sign & std_logic_vector(to_unsigned(e + 127, 8)) & std_logic_vector(head(22 downto 0));
    end if;
  end procedure round_pack;

  constant WIDE : natural := 64;

  -- a + b, full round-to-nearest-even fp32 add (same algorithm as
  -- generic_fpu.vhdl's ALU_ADD, kept local so this unit is self-contained).
  function local_add(a, b : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable fa, fb : fp_fields_t;
    variable big, small : fp_fields_t;
    variable big_sign : std_logic;
    variable ediff : integer;
    variable wbig, wsmall, shifted : unsigned(WIDE - 1 downto 0);
    variable stbit, carry_lost : std_logic;
    variable sum_mag : unsigned(WIDE downto 0);
    variable res_sign : std_logic;
    variable rexp : integer;
    variable lead : integer;
    variable yy : std_logic_vector(31 downto 0);
    variable ff : std_logic_vector(1 downto 0);
  begin
    fa := unpack(a); fb := unpack(b);
    if fa.is_spec or fb.is_spec then
      return (31 downto 0 => '0');
    elsif fa.is_zero and fb.is_zero then
      return (31 downto 0 => '0');
    elsif fa.is_zero then
      return b;
    elsif fb.is_zero then
      return a;
    end if;

    if fa.exp >= fb.exp then
      big := fa; small := fb;
    else
      big := fb; small := fa;
    end if;
    ediff := big.exp - small.exp;
    wbig   := shift_left(resize(big.mant, WIDE), WIDE - 24);
    wsmall := shift_left(resize(small.mant, WIDE), WIDE - 24);
    if ediff >= WIDE then
      shifted := (others => '0');
      stbit := '1';
    else
      if ediff = 0 then
        stbit := '0';
      else
        stbit := (or std_logic_vector(wsmall(ediff - 1 downto 0)));
      end if;
      shifted := shift_right(wsmall, ediff);
    end if;
    shifted(0) := shifted(0) or stbit;

    if big.sign = small.sign then
      sum_mag  := resize(wbig, WIDE + 1) + resize(shifted, WIDE + 1);
      res_sign := big.sign;
    elsif wbig >= shifted then
      sum_mag  := resize(wbig, WIDE + 1) - resize(shifted, WIDE + 1);
      res_sign := big.sign;
    else
      sum_mag  := resize(shifted, WIDE + 1) - resize(wbig, WIDE + 1);
      res_sign := small.sign;
    end if;

    rexp := big.exp - 127;
    if sum_mag(WIDE) = '1' then
      carry_lost := sum_mag(0);
      sum_mag := shift_right(sum_mag, 1);
      sum_mag(0) := sum_mag(0) or carry_lost;
      rexp := rexp + 1;
    elsif sum_mag(WIDE - 1) = '0' and sum_mag /= 0 then
      lead := 0;
      while (lead < WIDE - 1) and (sum_mag(WIDE - 1 - lead) = '0') loop
        lead := lead + 1;
      end loop;
      sum_mag := shift_left(sum_mag, lead);
      rexp := rexp - lead;
    end if;

    round_pack(res_sign, rexp, sum_mag(WIDE - 1 downto 0), WIDE - 24, yy, ff);
    return yy;
  end function local_add;

  -- a * b, full round-to-nearest-even fp32 multiply.
  function local_mul(a, b : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable fa, fb : fp_fields_t;
    variable msign : std_logic;
    variable product : unsigned(47 downto 0);
    variable mexp : integer;
    variable yy : std_logic_vector(31 downto 0);
    variable ff : std_logic_vector(1 downto 0);
  begin
    fa := unpack(a); fb := unpack(b);
    msign := fa.sign xor fb.sign;
    if fa.is_spec or fb.is_spec then
      return (31 downto 0 => '0');
    elsif fa.is_zero or fb.is_zero then
      return msign & (30 downto 0 => '0');
    end if;
    product := fa.mant * fb.mant;
    mexp := (fa.exp - 127) + (fb.exp - 127);
    if product(47) = '1' then
      round_pack(msign, mexp + 1, resize(product, 64), 24, yy, ff);
    else
      round_pack(msign, mexp, resize(shift_left(product, 1), 64), 24, yy, ff);
    end if;
    return yy;
  end function local_mul;

  -- Exact multiply-by-2**shift: only the exponent field moves, so no
  -- rounding is needed -- saturates/flushes the same as round_pack.
  function exp_shift(v : std_logic_vector(31 downto 0); shift : integer) return std_logic_vector is
    variable fv : fp_fields_t := unpack(v);
    variable new_exp : integer;
  begin
    if fv.is_spec or fv.is_zero then
      return v;
    end if;
    if shift > 400 then
      return fv.sign & "11111110" & (22 downto 0 => '1');
    elsif shift < -400 then
      return fv.sign & (30 downto 0 => '0');
    end if;
    new_exp := fv.exp + shift;
    if new_exp > 254 then
      return fv.sign & "11111110" & (22 downto 0 => '1');
    elsif new_exp < 1 then
      return fv.sign & (30 downto 0 => '0');
    else
      return fv.sign & std_logic_vector(to_unsigned(new_exp, 8)) & std_logic_vector(fv.mant(22 downto 0));
    end if;
  end function exp_shift;

  -- Reinterprets the low 'width' bits of a fixed-point fraction (value =
  -- bits/2**width, bits in [0,2**width)) as an fp32 number in [0,1).
  function frac_to_fp32(bits : unsigned; width : natural) return std_logic_vector is
    variable lead : natural := 0;
    variable m    : unsigned(23 downto 0);
    variable e    : integer;
    variable msb  : integer;
  begin
    if width = 0 or bits = 0 then
      return (31 downto 0 => '0');
    end if;
    while (lead < width - 1) and (bits(width - 1 - lead) = '0') loop
      lead := lead + 1;
    end loop;
    msb := width - 1 - lead;   -- index of the leading 1
    e   := msb - width;        -- unbiased exponent (negative: value < 1)
    if msb >= 23 then
      m := bits(msb downto msb - 23);
    else
      m := shift_left(resize(bits, 24), 23 - msb);
    end if;
    return '0' & std_logic_vector(to_unsigned(e + 127, 8)) & std_logic_vector(m(22 downto 0));
  end function frac_to_fp32;

  -- Exact fp32 representation of a small nonnegative integer (no
  -- rounding: callers only use this for n < 2**23).
  function small_uint_to_fp32(n : unsigned) return std_logic_vector is
    variable lead : natural := 0;
    variable w    : natural := n'length;
    variable m    : unsigned(23 downto 0);
    variable msb  : integer;
  begin
    if n = 0 then
      return (31 downto 0 => '0');
    end if;
    while (lead < w - 1) and (n(w - 1 - lead) = '0') loop
      lead := lead + 1;
    end loop;
    msb := w - 1 - lead;
    if msb >= 23 then
      m := n(msb downto msb - 23);
    else
      m := shift_left(resize(n, 24), 23 - msb);
    end if;
    return '0' & std_logic_vector(to_unsigned(msb + 127, 8)) & std_logic_vector(m(22 downto 0));
  end function small_uint_to_fp32;

  -- floor(v * 2**width) as an unsigned 'width'-bit value, for v in a
  -- known-nonnegative fp32 value already < 1.0 in magnitude (as produced
  -- by the TAB_FRAC path below).
  function fp32frac_to_fixed(v : std_logic_vector(31 downto 0); width : natural) return unsigned is
    variable fv : fp_fields_t := unpack(v);
    variable e_u, shiftamt : integer;
    variable wide_v : unsigned(width + 23 downto 0);
  begin
    if fv.is_zero or width = 0 then
      return (width - 1 downto 0 => '0');
    end if;
    e_u := fv.exp - 127; -- < 0 since v < 1
    shiftamt := e_u + width - 23;
    if shiftamt <= -(width + 24) then
      return (width - 1 downto 0 => '0');
    elsif shiftamt >= 0 then
      return resize(shift_left(resize(fv.mant, width + 24), shiftamt), width);
    else
      wide_v := shift_right(resize(fv.mant, width + 24), -shiftamt);
      return wide_v(width - 1 downto 0);
    end if;
  end function fp32frac_to_fixed;

  constant EXTRA_BITS : natural := 20; -- interpolation-fraction precision beyond the index

  type slot_cfg_t is record
    mode  : tab_mode_t;
    lo    : std_logic_vector(31 downto 0);
    hi    : std_logic_vector(31 downto 0);
    left  : tab_edge_t;
    right : tab_edge_t;
    bits  : natural range 1 to 10;
  end record;
  type slot_cfg_arr_t is array (0 to 7) of slot_cfg_t;
  signal cfg : slot_cfg_arr_t := (others => (TAB_RANGE, (others => '0'), (others => '0'), EDGE_CLAMP, EDGE_CLAMP, 1));

  type table_entry_t is record
    value : std_logic_vector(31 downto 0);
    slope : std_logic_vector(31 downto 0);
  end record;
  type table_mem_t is array (0 to 1023) of table_entry_t;
  type table_arr_t is array (0 to 7) of table_mem_t;
  signal tables : table_arr_t := (others => (others => (x"00000000", x"00000000")));

begin

  -- load port: table writes and slot-config writes
  load_proc : process (clk)
  begin
    if rising_edge(clk) then
      if ld_en = '1' then
        cfg(to_integer(ld_slot)).mode  <= ld_mode;
        cfg(to_integer(ld_slot)).lo    <= ld_lo;
        cfg(to_integer(ld_slot)).hi    <= ld_hi;
        cfg(to_integer(ld_slot)).left  <= ld_left;
        cfg(to_integer(ld_slot)).right <= ld_right;
        cfg(to_integer(ld_slot)).bits  <= to_integer(ld_bits);
      end if;
      if ld_we = '1' then
        tables(to_integer(ld_slot))(to_integer(ld_addr)).value <= ld_value;
        tables(to_integer(ld_slot))(to_integer(ld_addr)).slope <= ld_slope;
      end if;
    end if;
  end process load_proc;

  -- evaluation
  eval_proc : process (clk)
    variable c        : slot_cfg_t;
    variable fx        : fp_fields_t;
    variable idxbits    : natural;
    variable idx          : natural;
    variable fracbits      : natural;
    variable frac_fp        : std_logic_vector(31 downto 0);
    variable entry_val, entry_slope : std_logic_vector(31 downto 0);
    variable tval             : std_logic_vector(31 downto 0);
    variable shifted_res      : std_logic_vector(31 downto 0);
    variable y_v, ff           : std_logic_vector(31 downto 0);
    variable flag_v              : std_logic_vector(1 downto 0);

    -- rsqrt
    variable e_u, k, p              : integer;

    -- range
    variable span_fields               : fp_fields_t;
    variable log2span                   : integer;
    variable below, above                : boolean;
    variable x_used                       : std_logic_vector(31 downto 0);
    variable normalized                    : std_logic_vector(31 downto 0);
    variable wide_fixed_r                   : unsigned(31 downto 0);

    -- frac (exp2)
    variable itrunc                          : integer;
    variable itrunc_fp                        : std_logic_vector(31 downto 0);
    variable raw_frac                          : std_logic_vector(31 downto 0);
    variable ipart                              : integer;
    variable f2i_shift                           : integer;
    variable f2i_mag                              : unsigned(55 downto 0);
    variable wide_fixed_f                          : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if ce = '1' then
        c  := cfg(to_integer(slot));
        fx := unpack(x);
        flag_v := FLAG_OK;
        y_v    := (others => '0');
        idxbits := c.bits;

        case c.mode is

          ------------------------------------------------------------
          when TAB_MANT => -- reciprocal, domain [1,2)
            if fx.is_spec or fx.is_zero then
              flag_v := FLAG_ERROR;
              y_v := (others => '0');
            else
              fracbits := 23 - idxbits;
              idx := to_integer(fx.mant(22 downto fracbits));
              if fracbits = 0 then
                frac_fp := (others => '0');
              else
                frac_fp := frac_to_fp32(fx.mant(fracbits - 1 downto 0), fracbits);
              end if;
              entry_val := tables(to_integer(slot))(idx).value;
              entry_slope := tables(to_integer(slot))(idx).slope;
              tval := local_add(entry_val, local_mul(entry_slope, frac_fp));
              shifted_res := exp_shift(tval, 127 - fx.exp);
              y_v := fx.sign & shifted_res(30 downto 0);
              flag_v := FLAG_OK;
            end if;

          ------------------------------------------------------------
          when TAB_RSQRT => -- domain [1,4), input must be nonnegative
            if fx.is_spec or fx.is_zero or fx.sign = '1' then
              flag_v := FLAG_ERROR;
              y_v := (others => '0');
            else
              e_u := fx.exp - 127;
              p := e_u mod 2;   -- VHDL 'mod' takes the sign of the divisor: 0 or 1
              k := (e_u - p) / 2;
              fracbits := 23 - (idxbits - 1);
              if idxbits - 1 = 0 then
                idx := p;
              else
                idx := p * (2 ** (idxbits - 1)) + to_integer(fx.mant(22 downto fracbits));
              end if;
              if fracbits = 0 then
                frac_fp := (others => '0');
              else
                frac_fp := frac_to_fp32(fx.mant(fracbits - 1 downto 0), fracbits);
              end if;
              entry_val := tables(to_integer(slot))(idx).value;
              entry_slope := tables(to_integer(slot))(idx).slope;
              tval := local_add(entry_val, local_mul(entry_slope, frac_fp));
              shifted_res := exp_shift(tval, -k);
              y_v := '0' & shifted_res(30 downto 0);
              flag_v := FLAG_OK;
            end if;

          ------------------------------------------------------------
          when TAB_FRAC => -- exp2, |x| < 256
            if fx.is_spec then
              flag_v := FLAG_ERROR;
              y_v := (others => '0');
            elsif (not fx.is_zero) and (fx.exp - 127 >= 8) then
              flag_v := FLAG_OVERFLOW;
              y_v := fx.sign & "11111110" & (22 downto 0 => '1');
            elsif fx.is_zero then
              entry_val := tables(to_integer(slot))(0).value;
              entry_slope := tables(to_integer(slot))(0).slope;
              y_v := entry_val; -- frac = 0 at x = 0, so y = T[0] exactly
              flag_v := FLAG_OK;
            else
              -- itrunc = trunc(x) toward zero, exact since |x| < 256
              f2i_shift := (fx.exp - 127) - 23;
              if f2i_shift >= 0 then
                f2i_mag := shift_left(resize(fx.mant, 56), f2i_shift);
              else
                f2i_mag := shift_right(resize(fx.mant, 56), -f2i_shift);
              end if;
              itrunc := to_integer(f2i_mag(30 downto 0));
              -- exact i2f of a small nonnegative integer (itrunc < 256, no rounding needed)
              itrunc_fp := small_uint_to_fp32(to_unsigned(itrunc, 9));

              if fx.sign = '0' then
                ipart := itrunc;
                raw_frac := local_add(x, negate(itrunc_fp)); -- x - trunc(x), trunc(x) = +itrunc_fp
              else
                -- trunc(x) toward zero = -itrunc_fp here, so raw_frac = x - (-itrunc_fp) = x + itrunc_fp
                raw_frac := local_add(x, itrunc_fp);
                if unpack(raw_frac).is_zero then
                  ipart := -itrunc;
                else
                  ipart := -itrunc - 1;
                  raw_frac := local_add(raw_frac, ONE_FP32);
                end if;
              end if;

              wide_fixed_f := resize(fp32frac_to_fixed(raw_frac, idxbits + EXTRA_BITS), 32);
              idx := to_integer(wide_fixed_f(idxbits + EXTRA_BITS - 1 downto EXTRA_BITS));
              frac_fp := frac_to_fp32(wide_fixed_f(EXTRA_BITS - 1 downto 0), EXTRA_BITS);

              entry_val := tables(to_integer(slot))(idx).value;
              entry_slope := tables(to_integer(slot))(idx).slope;
              tval := local_add(entry_val, local_mul(entry_slope, frac_fp));
              y_v := exp_shift(tval, ipart);
              flag_v := FLAG_OK;
            end if;

          ------------------------------------------------------------
          when TAB_RANGE =>
            if fx.is_spec then
              flag_v := FLAG_ERROR;
              y_v := (others => '0');
            else
              below := unsigned(f32_key(x)) < unsigned(f32_key(c.lo));
              above := unsigned(f32_key(x)) > unsigned(f32_key(c.hi));
              if below and c.left = EDGE_ZERO then
                y_v := (others => '0'); flag_v := FLAG_OK;
              elsif below and c.left = EDGE_IDENTITY then
                y_v := x; flag_v := FLAG_OK;
              elsif above and c.right = EDGE_ZERO then
                y_v := (others => '0'); flag_v := FLAG_OK;
              elsif above and c.right = EDGE_IDENTITY then
                y_v := x; flag_v := FLAG_OK;
              else
                if below then
                  x_used := c.lo;
                elsif above then
                  x_used := c.hi;
                else
                  x_used := x;
                end if;
                normalized := local_add(x_used, negate(c.lo)); -- always in [0, span]
                span_fields := unpack(local_add(c.hi, negate(c.lo)));
                log2span := span_fields.exp - 127; -- exact since span must be a power of two

                if unpack(normalized).is_zero then
                  idx := 0;
                  frac_fp := (others => '0');
                else
                  -- normalized / span, as a value in [0,1], via one exact
                  -- exponent shift (span is a power of two)
                  wide_fixed_r := resize(fp32frac_to_fixed(exp_shift(normalized, -log2span), idxbits + EXTRA_BITS), 32);
                  idx := to_integer(wide_fixed_r(idxbits + EXTRA_BITS - 1 downto EXTRA_BITS));
                  if idx > 2 ** idxbits - 1 then
                    idx := 2 ** idxbits - 1; -- x = hi exactly: clamp into the last entry
                  end if;
                  frac_fp := frac_to_fp32(wide_fixed_r(EXTRA_BITS - 1 downto 0), EXTRA_BITS);
                end if;
                entry_val := tables(to_integer(slot))(idx).value;
                entry_slope := tables(to_integer(slot))(idx).slope;
                y_v := local_add(entry_val, local_mul(entry_slope, frac_fp));
                flag_v := FLAG_OK;
              end if;
            end if;

        end case;

        y    <= y_v;
        flag <= flag_v;
      end if;
    end if;
  end process eval_proc;

end architecture behavioral;
