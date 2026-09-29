library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Rescaler integer stage (claude_docs/08-vhdl-implementation-spec.md
-- S2.2, claude_docs/04-vhdl-module-list.md S2.2): multiplies a signed
-- per-group weight*activation sum (one dsp_mac2 lane, already extracted
-- from the packed P word -- lane0 = sext(P, SPACING), lane1 =
-- (P - lane0) >> SPACING, per dsp_mac2.vhdl's header -- that's a plain
-- signed slice/subtract the caller does inline, not its own primitive)
-- by the group's unsigned quantization scale byte. Widens by exactly
-- SCALE_WIDTH bits (LANE_WIDTH + SCALE_WIDTH total) so the product can
-- never overflow; no rounding or saturation here, that happens later in
-- the fp32 stage (sb_finish, not yet built).
--
-- LANE_WIDTH/SCALE_WIDTH are generic rather than a fmt_t format
-- selector, so one entity serves every K-quant format's scale width
-- (Q3_K/Q4_K: 6 bits, Q6_K: 8 bits, per 04 S2.2) without a format-to-
-- width lookup baked in here.
--
-- group_scale is SIGNED, not unsigned as an earlier version of this
-- entity assumed ("group_scale is always non-negative... it's a
-- magnitude, never a signed delta"). That was true for Q3_K/Q4_K but
-- wrong for Q6_K: 08-vhdl-implementation-spec.md S2.1's own table calls
-- Q6_K's group scale out explicitly as "8-bit signed group scale"
-- (matching ggml's block_q6_K, whose `scales` field is a plain
-- `int8_t` array, not a packed-unsigned field like Q3_K/Q4_K's). Found
-- while building q6k_unpack.vhdl and checking its scale output against
-- this entity's existing port type -- a real, spec-confirmed gap, not
-- just a recalled detail. Widening group_scale to signed is strictly
-- more general: Q3_K/Q4_K's non-negative 6-bit scales still fit and
-- multiply the same as before (a non-negative signed value equals its
-- unsigned reading), so this is a pure generalization, not a behavior
-- change for the formats that were already correct.
entity int_mul_scale is
  generic (
    LANE_WIDTH  : positive := 17;
    SCALE_WIDTH : positive := 8
  );
  port (
    clk         : in  std_logic;
    ce          : in  std_logic;
    lane_sum    : in  signed(LANE_WIDTH - 1 downto 0);
    group_scale : in  signed(SCALE_WIDTH - 1 downto 0);
    p           : out signed(LANE_WIDTH + SCALE_WIDTH - 1 downto 0)
  );
end entity int_mul_scale;

architecture behavioral of int_mul_scale is
  signal product : signed(LANE_WIDTH + SCALE_WIDTH - 1 downto 0);
  signal p_slv    : std_logic_vector(LANE_WIDTH + SCALE_WIDTH - 1 downto 0);
begin

  product <= lane_sum * group_scale;

  p_reg : entity work.generic_register
    generic map (WIDTH => LANE_WIDTH + SCALE_WIDTH)
    port map (
      clk => clk, rst => '0', en => ce,
      d => std_logic_vector(product),
      q => p_slv
    );

  p <= signed(p_slv);

end architecture behavioral;
