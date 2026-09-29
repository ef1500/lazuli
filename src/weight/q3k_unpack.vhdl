library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Q3_K unpacker (claude_docs/08-vhdl-implementation-spec.md S4.1,
-- claude_docs/04-vhdl-module-list.md S1/S4). Turns one raw 110-byte
-- Q3_K super-block (256 weights) into 16 GROUPS of 16 weights each
-- (one group = one array column's 16-deep row, per dsp_mac2's ROWS=16)
-- plus that group's own 6-bit scale, plus one shared fp16 `d` for the
-- whole super-block.
--
-- [R] EVERYTHING about the exact byte/bit layout below is reconstructed
-- from memory of ggml-quants.c's block_q3_K / dequantize_row_q3_K, NOT
-- read from the source this session -- that file isn't in this repo,
-- and 08/04's own text quotes only the weight formula and names the
-- "kmask1/kmask2 shuffle" without spelling out the constants. This is a
-- deliberate, user-approved risk (asked and confirmed before writing
-- this file): build the best-recall structure, flag it loudly, and
-- treat the numeric output as UNVERIFIED until checked against a real
-- ggml-quants.c source or a numpy oracle, exactly as dsp_mac2.vhdl's
-- "xilinx" architecture's OPMODE/ALUMODE encodings are already flagged.
-- Every testbench for this entity is therefore a WIRING/STRUCTURAL
-- check (does the VHDL correctly implement the formula documented
-- here) not a bit-exactness check against ggml (tb_q3k_unpack.vhdl's
-- header says so again).
--
-- block_q3_K layout assumed, byte 0 at bits 7 downto 0 (matches every
-- other packed-bus convention in this repo -- see sys_array.vhdl's
-- "packed [column][row]" note):
--   bytes   0..31  : hmask[32]   -- high bit of each 3-bit weight
--   bytes  32..95  : qs[64]      -- low 2 bits of each 3-bit weight
--   bytes  96..107 : scales[12]  -- 16 x 6-bit scales, kmask-packed
--   bytes 108..109 : d           -- fp16 super-block scale
--
-- Weight formula (given directly by 08 S4.1): q = (qs>>shift & 3) |
-- (hmask_bit << 2); value = q - 4 (signed, -4..3, fits WEIGHT_W=3
-- exactly since 08 S2.1's qlo,qhi for Q3_K is -4,3).
--
-- Group g (0..15) -> (half, j, sub) decomposition [R, re-derived from
-- the recalled dequantize_row_q3_K loop structure]: half = g/8 (which
-- 128-weight half of the 256), j = (g mod 8)/2 (which of 4 shift
-- steps), sub = g mod 2 (first or second 16 of that step's 32). This
-- gives, per group:
--   shift    = j*2                      (0, 2, 4, 6)
--   hmask bit index (0..7) = half*4 + j -- SAME hmask byte, different
--                                          BIT, reused across shift steps
--   qs byte base  = half*32 + sub*16    (0..63)
--   hmask byte base = sub*16            (0..31 -- NOT half-dependent:
--                                          hmask's 32 bytes are reused
--                                          for BOTH halves, just a
--                                          different bit each time)
--   scale index = g directly (the recalled 'is' counter increments in
--                 exactly this g order, confirmed self-consistent by
--                 construction, not independently verified)
--
-- Scale shuffle [R]: scales[12 bytes] read as 3 little-endian uint32
-- words (aux0, aux1, tmp=aux2), byte-wise (no cross-byte carries, so
-- expressible as plain bit-slicing, no arithmetic -- matches 04's "the
-- three unpackers are wiring plus small scale shuffles, no arithmetic"
-- note): for byte lane i (0..3),
--   scale_byte(0*4+i) = (aux0_byte(i) and 0x0F) or ((tmp_byte(i) and 0x03) << 4)
--   scale_byte(1*4+i) = (aux1_byte(i) and 0x0F) or (((tmp_byte(i)>>2) and 0x03) << 4)
--   scale_byte(2*4+i) = ((aux0_byte(i)>>4) and 0x0F) or (((tmp_byte(i)>>4) and 0x03) << 4)
--   scale_byte(3*4+i) = ((aux1_byte(i)>>4) and 0x0F) or (((tmp_byte(i)>>6) and 0x03) << 4)
-- Each result byte's top 2 bits are always 0 by construction, so the
-- scale is a plain unsigned 6-bit value (0..63) -- matches int_mul_
-- scale.vhdl's signed port (a non-negative signed value reads the same
-- as unsigned) with no bias/centering term recalled or applied here.
entity q3k_unpack is
  port (
    block_in   : in  std_logic_vector(110 * 8 - 1 downto 0);
    weight_out : out std_logic_vector(16 * 16 * 3 - 1 downto 0); -- [group][row], group g row r at (g*16+r+1)*3-1 downto (g*16+r)*3
    scale_out  : out std_logic_vector(16 * 6 - 1 downto 0);      -- [group], unsigned 6-bit
    d_out      : out std_logic_vector(15 downto 0)               -- fp16 bits, passed through raw
  );
end entity q3k_unpack;

architecture behav of q3k_unpack is
begin

  d_out <= block_in(110 * 8 - 1 downto 108 * 8);

  group_gen : for g in 0 to 15 generate
    constant half : natural := g / 8;
    constant j    : natural := (g mod 8) / 2;
    constant sub  : natural := g mod 2;

    constant shift      : natural := j * 2;
    constant m_bit_idx  : natural := half * 4 + j;
    constant qs_base    : natural := half * 32 + sub * 16;
    constant hm_base    : natural := sub * 16;
  begin

    row_gen : for r in 0 to 15 generate
      signal qs_byte : unsigned(7 downto 0);
      signal hm_byte : unsigned(7 downto 0);
      signal q2bit  : unsigned(1 downto 0);
      signal hbit   : std_logic;
      signal raw3   : unsigned(2 downto 0);
      signal weight : signed(3 downto 0);
    begin
      qs_byte <= unsigned(block_in((32 + qs_base + r + 1) * 8 - 1 downto (32 + qs_base + r) * 8));
      hm_byte <= unsigned(block_in((hm_base + r + 1) * 8 - 1 downto (hm_base + r) * 8));
      q2bit <= shift_right(qs_byte, shift)(1 downto 0);
      hbit  <= hm_byte(m_bit_idx);
      raw3  <= hbit & q2bit;
      weight <= resize(signed(resize(raw3, 4)), 4) - 4;

      weight_out((g * 16 + r + 1) * 3 - 1 downto (g * 16 + r) * 3) <=
        std_logic_vector(resize(weight, 3));
    end generate row_gen;

  end generate group_gen;

  -- Scale shuffle: computed once (not per-group) into a flat 16-byte
  -- array, then sliced per group above via g directly.
  scale_shuffle : block
    type byte_arr_t is array (0 to 15) of unsigned(7 downto 0);
    signal scale_bytes : byte_arr_t;
  begin
    lane_gen : for i in 0 to 3 generate
      signal aux0_b : unsigned(7 downto 0);
      signal aux1_b : unsigned(7 downto 0);
      signal tmp_b  : unsigned(7 downto 0);
    begin
      aux0_b <= unsigned(block_in((96 + i + 1) * 8 - 1 downto (96 + i) * 8));
      aux1_b <= unsigned(block_in((100 + i + 1) * 8 - 1 downto (100 + i) * 8));
      tmp_b  <= unsigned(block_in((104 + i + 1) * 8 - 1 downto (104 + i) * 8));

      scale_bytes(0 * 4 + i) <= (aux0_b and "00001111") or (shift_left(tmp_b and "00000011", 4));
      scale_bytes(1 * 4 + i) <= (aux1_b and "00001111") or (shift_left(shift_right(tmp_b, 2) and "00000011", 4));
      scale_bytes(2 * 4 + i) <= (shift_right(aux0_b, 4) and "00001111") or (shift_left(shift_right(tmp_b, 4) and "00000011", 4));
      scale_bytes(3 * 4 + i) <= (shift_right(aux1_b, 4) and "00001111") or (shift_left(shift_right(tmp_b, 6) and "00000011", 4));
    end generate lane_gen;

    scale_out_gen : for g in 0 to 15 generate
      scale_out((g + 1) * 6 - 1 downto g * 6) <= std_logic_vector(scale_bytes(g)(5 downto 0));
    end generate scale_out_gen;
  end block scale_shuffle;

end architecture behav;
