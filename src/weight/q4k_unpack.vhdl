library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Q4_K unpacker (syseng_docs/08-vhdl-implementation-spec.md S4.1,
-- syseng_docs/04-vhdl-module-list.md S1/S4). Turns one raw 144-byte
-- Q4_K super-block (256 weights) into 16 GROUPS of 16 weights each
-- plus, per group, the (sc, m) pair its 32-weight PARENT group shares
-- -- Q4_K's asymmetric format ties one (sc,m) pair to two consecutive
-- 16-deep groups, per dsp_mac2.vhdl's own header note ("Q4_K's 32-
-- weight groups are two consecutive 16-deep tiles that share one
-- scale") -- plus the two shared fp16 values `d`/`dmin` for the whole
-- super-block.
--
-- [R] as with q3k_unpack.vhdl/q6k_unpack.vhdl: reconstructed from
-- memory of ggml-quants.c's block_q4_K / dequantize_row_q4_K /
-- get_scale_min_k4, not read from source this session -- user-approved
-- risk, see q3k_unpack.vhdl's header. Q4_K is the LEAST confidently
-- reconstructed of the three: get_scale_min_k4's exact byte-split is
-- corroborated only loosely by 04 S1's own text ("the last 4 groups
-- split across bytes 0-3 and 8-11" -- matches this file's q[j] vs
-- q[j+4]/q[j-4] indexing below, which is the best available cross-
-- check this session has).
--
-- ANOTHER open question this entity's header must flag, found while
-- deriving it, NOT resolved here: this project's array packs Q4_K's
-- weight as (nibble - 8) -- 08 S2.1's qlo,qhi=-8,7 -- to fit dsp_mac2's
-- signed WEIGHT_W=4 slot, matching Q3_K/Q6_K's own per-format offset
-- convention. But unlike Q3_K's (q-4) and Q6_K's (q-32), which ARE
-- ggml's own true dequant formula, Q4_K's true ggml formula is
-- `d*sc*q - dmin*m` using the RAW unsigned nibble q (0..15) directly,
-- with NO per-weight centering -- the asymmetry is handled entirely by
-- the per-group `m` term, not a per-weight constant. Packing q-8 into
-- the array therefore introduces a project-specific transform: the
-- array computes `Σ(sc·(q-8)·x) = Σ(sc·q·x) - 8·sc·Σx`, so recovering
-- the TRUE `Σ(sc·q·x) - dmin·m·Σx` needs BOTH `dmin·m·Σx` subtracted
-- (already documented, int_acc.vhdl's `min_term`) AND `8·d·sc·Σx`
-- ADDED BACK -- a term int_acc.vhdl's header does not mention and
-- 08 S2.2's rescaler-ops table does not list. This entity outputs sc/m
-- exactly as unpacked (no attempt to compensate here, since the
-- rescaler that would consume the correction isn't built yet); whoever
-- builds group_scale_acc/sb_finish (08 S4.3, not yet built) needs to
-- either add that term or confirm it's unnecessary for some reason not
-- yet identified in this session.
--
-- block_q4_K layout assumed, byte 0 at bits 7 downto 0:
--   bytes   0..1   : d       -- fp16, scales the `sc` (scale) values
--   bytes   2..3   : dmin    -- fp16, scales the `m` (min) values
--   bytes   4..15  : scales[12] -- 8 x (6-bit sc, 6-bit m) packed
--   bytes  16..143 : qs[128] -- 4-bit weights, 2 per byte
--
-- Weight: nibble (0..15) of qs, value = nibble - 8 (signed, -8..7,
-- WEIGHT_W=4). Column c (0..15) -> group_idx=c/2 (which of the 8
-- get_scale_min_k4 pairs), j_outer=group_idx/2 (0..3, outer 64-weight
-- step), nibble_bit=group_idx mod 2 (0=low,1=high -- LOW nibble half
-- uses the EVEN group_idx of a pair, HIGH uses the ODD), subhalf=c mod
-- 2 (which 16 of that nibble-half's 32 weights):
--   qs byte index = j_outer*32 + subhalf*16 + r   (0..127)
--   nibble = nibble_bit=0 ? low nibble : high nibble of that byte
--
-- get_scale_min_k4(group_idx, scales[12 bytes]) [R]:
--   if group_idx < 4: sc = scales[group_idx] & 0x3F
--                      m  = scales[group_idx+4] & 0x3F
--   else:              sc = (scales[group_idx+4] & 0x0F) | ((scales[group_idx-4] >> 6) << 4)
--                      m  = (scales[group_idx+4] >> 4)    | ((scales[group_idx]    >> 6) << 4)
-- Both sc and m are plain unsigned 6-bit values (0..63), no shuffle-
-- induced sign, unlike Q6_K's flat signed scale array.
entity q4k_unpack is
  port (
    block_in   : in  std_logic_vector(144 * 8 - 1 downto 0);
    weight_out : out std_logic_vector(16 * 16 * 4 - 1 downto 0); -- [group][row]
    scale_out  : out std_logic_vector(16 * 6 - 1 downto 0);      -- [group], unsigned 6-bit `sc`, duplicated across each 32-weight pair's 2 groups
    min_out    : out std_logic_vector(16 * 6 - 1 downto 0);      -- [group], unsigned 6-bit `m`, same duplication
    d_out      : out std_logic_vector(15 downto 0);
    dmin_out   : out std_logic_vector(15 downto 0)
  );
end entity q4k_unpack;

architecture behav of q4k_unpack is
  type byte_arr_t is array (0 to 11) of unsigned(7 downto 0);
  signal scales_b : byte_arr_t;
begin

  d_out    <= block_in(2 * 8 - 1 downto 0 * 8);
  dmin_out <= block_in(4 * 8 - 1 downto 2 * 8);

  scales_byte_gen : for i in 0 to 11 generate
    scales_b(i) <= unsigned(block_in((4 + i + 1) * 8 - 1 downto (4 + i) * 8));
  end generate scales_byte_gen;

  scale_min_gen : for group_idx in 0 to 7 generate
    signal sc, m : unsigned(5 downto 0);
  begin
    lo_gen : if group_idx < 4 generate
      sc <= scales_b(group_idx)(5 downto 0);
      m  <= scales_b(group_idx + 4)(5 downto 0);
    end generate lo_gen;

    hi_gen : if group_idx >= 4 generate
      sc <= scales_b(group_idx - 4)(7 downto 6) & scales_b(group_idx + 4)(3 downto 0);
      m  <= scales_b(group_idx)(7 downto 6) & shift_right(scales_b(group_idx + 4), 4)(3 downto 0);
    end generate hi_gen;

    -- duplicate across this pair's two 16-row groups (c = 2*group_idx, 2*group_idx+1)
    scale_out((2 * group_idx + 1 + 1) * 6 - 1 downto (2 * group_idx + 1) * 6) <= std_logic_vector(sc);
    scale_out((2 * group_idx + 1) * 6 - 1 downto (2 * group_idx) * 6)         <= std_logic_vector(sc);
    min_out((2 * group_idx + 1 + 1) * 6 - 1 downto (2 * group_idx + 1) * 6)   <= std_logic_vector(m);
    min_out((2 * group_idx + 1) * 6 - 1 downto (2 * group_idx) * 6)           <= std_logic_vector(m);
  end generate scale_min_gen;

  group_gen : for c in 0 to 15 generate
    constant group_idx  : natural := c / 2;
    constant j_outer     : natural := group_idx / 2;
    constant nibble_bit  : natural := group_idx mod 2;
    constant subhalf     : natural := c mod 2;
    constant qs_base     : natural := j_outer * 32 + subhalf * 16;
  begin

    row_gen : for r in 0 to 15 generate
      signal qs_byte : unsigned(7 downto 0);
      signal nibble : unsigned(3 downto 0);
      signal weight : signed(4 downto 0);
    begin
      qs_byte <= unsigned(block_in((16 + qs_base + r + 1) * 8 - 1 downto (16 + qs_base + r) * 8));
      nibble <= qs_byte(7 downto 4) when nibble_bit = 1 else qs_byte(3 downto 0);
      weight <= resize(signed(resize(nibble, 5)), 5) - 8;

      weight_out((c * 16 + r + 1) * 4 - 1 downto (c * 16 + r) * 4) <=
        std_logic_vector(resize(weight, 4));
    end generate row_gen;

  end generate group_gen;

end architecture behav;
