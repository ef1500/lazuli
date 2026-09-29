library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic fp32 ALU: add/sub, multiply, max, and int32<->fp32/fp16<->fp32
-- conversions, selected by 'op'. One-cycle latency (registered on 'clk'
-- when 'ce' = '1'). Semantics follow syseng_docs/08-vhdl-implementation-
-- spec.md S2.3:
--   * round to nearest, ties to even
--   * denormal operands are read as zero; a denormal/underflowing result
--     is flushed to zero (flag = FLAG_FLUSHED)
--   * NaN/Inf operands are not propagated: they raise FLAG_ERROR and the
--     output is forced to 0
--   * overflow saturates (to the largest-magnitude normal fp32, or for
--     CVT_F2I to the int32 range) and raises FLAG_OVERFLOW
--
-- op = ALU_ADD: y <= ea*a + eb*b, where ea/eb are a's/b's effective signs
--   after applying the 'sub' flags (NEG_A, NEG_B, ABS_A - see
--   project_types.vhdl). Plain add: sub = "000". a - b: sub(NEG_B) = '1'.
-- op = ALU_MUL: y <= a * b.
-- op = ALU_MAX: y <= the larger of a, b (IEEE ordering, via f32_key).
-- op = ALU_CVT: selected by 'cvt':
--   CVT_I2F        : a interpreted as a signed 32-bit integer -> y = fp32(a)
--   CVT_F2I        : a interpreted as fp32 -> y = signed 32-bit integer,
--                    saturated to y'high/y'low on overflow
--   CVT_F16_TO_F32 : a(15 downto 0) holds an IEEE-754 binary16 -> y = fp32
--   CVT_F32_TO_F16 : a holds an fp32 -> y(15 downto 0) holds binary16,
--                    y(31 downto 16) is '0'
entity generic_fpu is
  port (
    clk  : in  std_logic;
    ce   : in  std_logic;
    op   : in  alu_op_t;
    sub  : in  std_logic_vector(2 downto 0) := (others => '0');
    cvt  : in  cvt_op_t                     := CVT_I2F;
    a, b : in  std_logic_vector(31 downto 0);
    y    : out std_logic_vector(31 downto 0);
    flag : out std_logic_vector(1 downto 0)
  );
end entity generic_fpu;

architecture behavioral of generic_fpu is

  -- Unpacked fp32 operand. 'mant' carries the implicit leading '1' (so it
  -- is 0 for a true/flushed-denormal zero, else in [2**23, 2**24)).
  type fp_fields_t is record
    sign    : std_logic;
    exp     : integer range 0 to 255;
    mant    : unsigned(23 downto 0);
    is_zero : boolean;
    is_spec : boolean; -- NaN/Inf (exp = 255): not propagated, flagged instead
  end record;

  function unpack(x : std_logic_vector(31 downto 0)) return fp_fields_t is
    variable f : fp_fields_t;
  begin
    f.sign    := x(31);
    f.exp     := to_integer(unsigned(x(30 downto 23)));
    f.is_spec := (f.exp = 255);
    if f.exp = 0 then
      f.mant    := (others => '0'); -- true zero, or a denormal read as zero
      f.is_zero := true;
    else
      f.mant    := '1' & unsigned(x(22 downto 0));
      f.is_zero := false;
    end if;
    return f;
  end function unpack;

  constant WIDE : natural := 64; -- working width for the add's aligned mantissa

  -- Round-and-pack: 'mant' must be a normalized fixed-point magnitude
  -- whose implicit leading 1 sits at bit (frac_bits+23) -- i.e. reading
  -- mant(frac_bits+23 downto frac_bits) gives the 24-bit head (1.mmm..m)
  -- -- except that mant = 0 is accepted as an exact zero. 'exp_u' is the
  -- unbiased (no +127) exponent that head represents.
  procedure round_pack(sign : in std_logic; exp_u : in integer;
                        mant : in unsigned; frac_bits : in natural;
                        yy : out std_logic_vector(31 downto 0);
                        ff : out std_logic_vector(1 downto 0)) is
    variable head      : unsigned(24 downto 0);
    variable round_bit, sticky, lsb : std_logic;
    variable e         : integer;
  begin
    if mant = 0 then
      yy := sign & (30 downto 0 => '0');
      ff := FLAG_OK;
      return;
    end if;

    e    := exp_u;
    head := '0' & mant(frac_bits + 23 downto frac_bits);

    if frac_bits = 0 then
      round_bit := '0';
      sticky    := '0';
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

    if head(24) = '1' then -- rounding carried the leading 1 up one place
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

begin

  process (clk)
    variable fa, fb            : fp_fields_t;
    variable ea_sign, eb_sign  : std_logic;
    variable big, small        : fp_fields_t;
    variable big_sign, small_sign : std_logic;
    variable ediff             : integer;
    variable wbig, wsmall      : unsigned(WIDE - 1 downto 0);
    variable shifted           : unsigned(WIDE - 1 downto 0);
    variable stbit, carry_lost : std_logic;
    variable sum_mag           : unsigned(WIDE downto 0); -- one extra bit for carry-out
    variable res_sign          : std_logic;
    variable rexp              : integer;
    variable lead              : integer;
    variable product           : unsigned(47 downto 0);
    variable mexp              : integer;
    variable msign              : std_logic;
    variable y_v                : std_logic_vector(31 downto 0);
    variable flag_v             : std_logic_vector(1 downto 0);

    -- CVT_I2F working variables
    variable ival               : integer;
    variable umag                : unsigned(31 downto 0);
    variable ishift              : integer;
    variable imant                : unsigned(55 downto 0);

    -- CVT_F2I working variables
    variable f2i_shift          : integer;
    variable f2i_mag             : unsigned(55 downto 0);
    variable f2i_round, f2i_sticky, f2i_lsb : std_logic;
    variable f2i_int             : unsigned(31 downto 0);

    -- fp16 conversion variables
    variable h_sign              : std_logic;
    variable h_exp                : integer;
    variable h_mant                : std_logic_vector(9 downto 0);
  begin
    if rising_edge(clk) then
      if ce = '1' then
        flag_v := FLAG_OK;
        y_v    := (others => '0');

        case op is

          ----------------------------------------------------------------
          when ALU_ADD =>
            fa := unpack(a);
            fb := unpack(b);

            if sub(ABS_A) = '1' then
              ea_sign := '0';
            elsif sub(NEG_A) = '1' then
              ea_sign := not fa.sign;
            else
              ea_sign := fa.sign;
            end if;

            if sub(NEG_B) = '1' then
              eb_sign := not fb.sign;
            else
              eb_sign := fb.sign;
            end if;

            if fa.is_spec or fb.is_spec then
              flag_v := FLAG_ERROR;
              y_v    := (others => '0');
            elsif fa.is_zero and fb.is_zero then
              flag_v := FLAG_OK;
              y_v    := (others => '0');
            elsif fa.is_zero then
              flag_v := FLAG_OK;
              y_v    := eb_sign & std_logic_vector(to_unsigned(fb.exp, 8)) & std_logic_vector(fb.mant(22 downto 0));
            elsif fb.is_zero then
              flag_v := FLAG_OK;
              y_v    := ea_sign & std_logic_vector(to_unsigned(fa.exp, 8)) & std_logic_vector(fa.mant(22 downto 0));
            else
              if fa.exp >= fb.exp then
                big := fa; big_sign := ea_sign;
                small := fb; small_sign := eb_sign;
              else
                big := fb; big_sign := eb_sign;
                small := fa; small_sign := ea_sign;
              end if;
              ediff := big.exp - small.exp;

              wbig   := shift_left(resize(big.mant, WIDE), WIDE - 24);
              wsmall := shift_left(resize(small.mant, WIDE), WIDE - 24);

              if ediff >= WIDE then
                shifted := (others => '0');
                stbit   := '1'; -- small is nonzero (has the implicit leading 1)
              else
                if ediff = 0 then
                  stbit := '0';
                else
                  stbit := (or std_logic_vector(wsmall(ediff - 1 downto 0)));
                end if;
                shifted := shift_right(wsmall, ediff);
              end if;
              -- fold the sticky bit into the extended field's LSB: it sits
              -- far below the rounding boundary (bit 0 of 64, boundary at
              -- bit 40) so it only ever perturbs the sticky computation,
              -- never the kept mantissa or the round bit itself.
              shifted(0) := shifted(0) or stbit;

              if big_sign = small_sign then
                sum_mag  := resize(wbig, WIDE + 1) + resize(shifted, WIDE + 1);
                res_sign := big_sign;
              elsif wbig >= shifted then
                -- equal exponents don't guarantee 'big' also has the
                -- larger mantissa, so check rather than assume
                sum_mag  := resize(wbig, WIDE + 1) - resize(shifted, WIDE + 1);
                res_sign := big_sign;
              else
                sum_mag  := resize(shifted, WIDE + 1) - resize(wbig, WIDE + 1);
                res_sign := small_sign;
              end if;

              rexp := big.exp - 127;
              if sum_mag(WIDE) = '1' then
                -- carry out of an equal-sign add: renormalize right by 1,
                -- folding the bit that falls off into the new LSB so it
                -- still counts toward the sticky bit.
                carry_lost := sum_mag(0);
                sum_mag := shift_right(sum_mag, 1);
                sum_mag(0) := sum_mag(0) or carry_lost;
                rexp := rexp + 1;
              elsif sum_mag(WIDE - 1) = '0' and sum_mag /= 0 then
                -- a same-exponent subtract can cancel leading bits: renormalize left
                lead := 0;
                while (lead < WIDE - 1) and (sum_mag(WIDE - 1 - lead) = '0') loop
                  lead := lead + 1;
                end loop;
                sum_mag := shift_left(sum_mag, lead);
                rexp := rexp - lead;
              end if;

              round_pack(res_sign, rexp, sum_mag(WIDE - 1 downto 0), WIDE - 24, y_v, flag_v);
            end if;

          ----------------------------------------------------------------
          when ALU_MUL =>
            fa := unpack(a);
            fb := unpack(b);
            msign := fa.sign xor fb.sign;

            if fa.is_spec or fb.is_spec then
              flag_v := FLAG_ERROR;
              y_v    := (others => '0');
            elsif fa.is_zero or fb.is_zero then
              flag_v := FLAG_OK;
              y_v    := msign & (30 downto 0 => '0');
            else
              product := fa.mant * fb.mant; -- 24x24 -> 48 bits, in [2**46, 2**48)
              mexp := (fa.exp - 127) + (fb.exp - 127);
              if product(47) = '1' then
                round_pack(msign, mexp + 1, resize(product, 64), 24, y_v, flag_v);
              else
                round_pack(msign, mexp, resize(shift_left(product, 1), 64), 24, y_v, flag_v);
              end if;
            end if;

          ----------------------------------------------------------------
          when ALU_MAX =>
            if unsigned(f32_key(a)) >= unsigned(f32_key(b)) then
              y_v := a;
            else
              y_v := b;
            end if;
            flag_v := FLAG_OK;

          ----------------------------------------------------------------
          when ALU_CVT =>
            case cvt is

              when CVT_I2F =>
                ival := to_integer(signed(a));
                if ival = 0 then
                  y_v := (others => '0');
                  flag_v := FLAG_OK;
                else
                  if a = x"80000000" then
                    umag := x"80000000"; -- |INT32_MIN|, doesn't fit signed negation
                    msign := '1';
                  elsif ival < 0 then
                    umag := unsigned(to_signed(-ival, 32));
                    msign := '1';
                  else
                    umag := unsigned(a);
                    msign := '0';
                  end if;
                  lead := 0;
                  while (lead < 31) and (umag(31 - lead) = '0') loop
                    lead := lead + 1;
                  end loop;
                  -- umag's leading 1 sits at bit (31-lead); round_pack wants
                  -- it at bit (frac_bits+23) = 55, so shift left by (55 - (31-lead))
                  imant  := shift_left(resize(umag, 56), 24 + lead);
                  round_pack(msign, 31 - lead, imant, 32, y_v, flag_v);
                end if;

              when CVT_F2I =>
                fa := unpack(a);
                if fa.is_spec then
                  flag_v := FLAG_ERROR;
                  y_v := (others => '0');
                elsif fa.is_zero then
                  flag_v := FLAG_OK;
                  y_v := (others => '0');
                else
                  f2i_shift := (fa.exp - 127) - 23; -- true value = fa.mant * 2**f2i_shift
                  if f2i_shift >= 8 then
                    -- magnitude >= 2**31 regardless of the mantissa bits
                    flag_v := FLAG_OVERFLOW;
                    if fa.sign = '1' then
                      y_v := x"80000000";
                    else
                      y_v := x"7FFFFFFF";
                    end if;
                  elsif f2i_shift >= 0 then
                    f2i_mag := shift_left(resize(fa.mant, 56), f2i_shift);
                    if unsigned(f2i_mag(55 downto 31)) /= 0 then
                      flag_v := FLAG_OVERFLOW;
                      if fa.sign = '1' then
                        y_v := x"80000000";
                      else
                        y_v := x"7FFFFFFF";
                      end if;
                    else
                      f2i_int := resize(f2i_mag(30 downto 0), 32);
                      flag_v  := FLAG_OK;
                      if fa.sign = '1' then
                        y_v := std_logic_vector(-signed(f2i_int));
                      else
                        y_v := std_logic_vector(f2i_int);
                      end if;
                    end if;
                  elsif -f2i_shift > 24 then
                    -- magnitude < 0.5: rounds to zero
                    flag_v := FLAG_OK;
                    y_v    := (others => '0');
                  else
                    -- 0 < magnitude, shift right by -f2i_shift with round-to-nearest-even
                    f2i_mag   := resize(fa.mant, 56);
                    f2i_round := f2i_mag(-f2i_shift - 1);
                    if -f2i_shift >= 2 then
                      f2i_sticky := (or std_logic_vector(f2i_mag(-f2i_shift - 2 downto 0)));
                    else
                      f2i_sticky := '0';
                    end if;
                    f2i_int := resize(shift_right(f2i_mag, -f2i_shift), 32);
                    f2i_lsb := f2i_int(0);
                    if (f2i_round = '1') and ((f2i_sticky = '1') or (f2i_lsb = '1')) then
                      f2i_int := f2i_int + 1;
                    end if;
                    flag_v := FLAG_OK;
                    if fa.sign = '1' then
                      y_v := std_logic_vector(-signed(f2i_int));
                    else
                      y_v := std_logic_vector(f2i_int);
                    end if;
                  end if;
                end if;

              when CVT_F16_TO_F32 =>
                h_sign := a(15);
                h_exp  := to_integer(unsigned(a(14 downto 10)));
                h_mant := a(9 downto 0);
                if h_exp = 31 then
                  flag_v := FLAG_ERROR;
                  y_v := (others => '0');
                elsif h_exp = 0 then
                  -- zero or denormal: read as zero (project convention)
                  flag_v := FLAG_OK;
                  y_v := h_sign & (30 downto 0 => '0');
                else
                  flag_v := FLAG_OK;
                  y_v := h_sign & std_logic_vector(to_unsigned(h_exp - 15 + 127, 8)) & h_mant & "0000000000000";
                end if;

              when CVT_F32_TO_F16 =>
                fa := unpack(a);
                if fa.is_spec then
                  flag_v := FLAG_ERROR;
                  y_v := (others => '0');
                elsif fa.is_zero then
                  flag_v := FLAG_OK;
                  y_v := (31 downto 16 => '0') & fa.sign & (14 downto 0 => '0');
                else
                  h_exp := fa.exp - 127 + 15;
                  if h_exp >= 31 then
                    flag_v := FLAG_OVERFLOW;
                    y_v := (31 downto 16 => '0') & fa.sign & "11110" & "1111111111";
                  elsif h_exp <= 0 then
                    flag_v := FLAG_FLUSHED;
                    y_v := (31 downto 16 => '0') & fa.sign & (14 downto 0 => '0');
                  else
                    -- round-to-nearest-even on the low 13 mantissa bits being dropped
                    if (a(12) = '1') and ((unsigned(a(11 downto 0)) /= 0) or (a(13) = '1')) then
                      h_mant := std_logic_vector(unsigned(a(22 downto 13)) + 1);
                    else
                      h_mant := a(22 downto 13);
                    end if;
                    y_v := (31 downto 16 => '0') & fa.sign & std_logic_vector(to_unsigned(h_exp, 5)) & h_mant;
                    flag_v := FLAG_OK;
                  end if;
                end if;

            end case;

          when ALU_LUT =>
            -- Not this unit's job: table lookups are generic_lookup.vhdl.
            y_v    := (others => '0');
            flag_v := FLAG_ERROR;

        end case;

        y    <= y_v;
        flag <= flag_v;
      end if;
    end if;
  end process;

end architecture behavioral;
