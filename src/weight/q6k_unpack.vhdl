library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Q6_K unpacker (claude_docs/08-vhdl-implementation-spec.md S4.1,
-- claude_docs/04-vhdl-module-list.md S1/S4). Turns one raw 210-byte
-- Q6_K super-block (256 weights) into 16 GROUPS of 16 weights each
-- plus that group's own 8-bit SIGNED scale, plus one shared fp16 `d`.
--
-- [R] as with q3k_unpack.vhdl: the byte layout and index arithmetic
-- below are reconstructed from memory of ggml-quants.c's block_q6_K /
-- dequantize_row_q6_K, not read from source this session (not in this
-- repo) -- user-approved risk, see q3k_unpack.vhdl's header for the
-- full reasoning. This one is structurally SIMPLER than Q3_K/Q4_K,
-- though: the scale array is a plain flat `int8_t[16]`, no shuffle at
-- all (matches 08 S4.1's own table: "int8 scale, one per 16"), which
-- is the one part of this entity with real independent corroboration.
--
-- block_q6_K layout assumed, byte 0 at bits 7 downto 0:
--   bytes   0..127 : ql[128]   -- low 4 bits of each 6-bit weight
--   bytes 128..191 : qh[64]    -- high 2 bits of each 6-bit weight
--   bytes 192..207 : scales[16] -- flat SIGNED int8, one per group
--   bytes 208..209 : d          -- fp16 super-block scale
--
-- Weight formula (given directly by 08 S4.1): q = (ql&0xF | (qh>>shift
-- &3)<<4) - 32 (signed, -32..31, matches WEIGHT_W=6, qlo,qhi=-32,31).
--
-- Group g (0..15) -> (n_half, subgroup, is_bit) decomposition [R]:
-- n_half = g/8, subgroup = (g mod 8)/2, is_bit = g mod 2. Per group:
--   shift  = subgroup*2                          (0, 2, 4, 6)
--   l(r)   = is_bit*16 + r                        (0..31)
--   qh byte index = n_half*32 + l(r)              (0..63)
--   ql base offset = (subgroup odd) ? 32 : 0
--   ql byte index = n_half*64 + ql_base + l(r)    (0..127)
--   nibble = (subgroup >= 2) ? high nibble : low nibble
-- scale index = g directly (flat array, no shuffle).
entity q6k_unpack is
  port (
    block_in   : in  std_logic_vector(210 * 8 - 1 downto 0);
    weight_out : out std_logic_vector(16 * 16 * 6 - 1 downto 0); -- [group][row]
    scale_out  : out std_logic_vector(16 * 8 - 1 downto 0);      -- [group], signed 8-bit
    d_out      : out std_logic_vector(15 downto 0)
  );
end entity q6k_unpack;

architecture behav of q6k_unpack is
begin

  d_out <= block_in(210 * 8 - 1 downto 208 * 8);

  scale_out_gen : for g in 0 to 15 generate
    scale_out((g + 1) * 8 - 1 downto g * 8) <= block_in((192 + g + 1) * 8 - 1 downto (192 + g) * 8);
  end generate scale_out_gen;

  group_gen : for g in 0 to 15 generate
    constant n_half   : natural := g / 8;
    constant subgroup : natural := (g mod 8) / 2;
    constant is_bit    : natural := g mod 2;

    constant shift    : natural := subgroup * 2;
    constant ql_base  : natural := n_half * 64 + (subgroup mod 2) * 32 + is_bit * 16;
    constant qh_base  : natural := n_half * 32 + is_bit * 16;
    constant use_hi   : boolean := subgroup >= 2;
  begin

    row_gen : for r in 0 to 15 generate
      signal ql_byte : unsigned(7 downto 0);
      signal qh_byte : unsigned(7 downto 0);
      signal nibble : unsigned(3 downto 0);
      signal hi2    : unsigned(1 downto 0);
      signal raw6   : unsigned(5 downto 0);
      signal weight : signed(6 downto 0);
    begin
      ql_byte <= unsigned(block_in((ql_base + r + 1) * 8 - 1 downto (ql_base + r) * 8));
      qh_byte <= unsigned(block_in((128 + qh_base + r + 1) * 8 - 1 downto (128 + qh_base + r) * 8));
      nibble <= ql_byte(7 downto 4) when use_hi else ql_byte(3 downto 0);
      hi2    <= shift_right(qh_byte, shift)(1 downto 0);
      raw6   <= hi2 & nibble;
      weight <= resize(signed(resize(raw6, 7)), 7) - 32;

      weight_out((g * 16 + r + 1) * 6 - 1 downto (g * 16 + r) * 6) <=
        std_logic_vector(resize(weight, 6));
    end generate row_gen;

  end generate group_gen;

end architecture behav;
