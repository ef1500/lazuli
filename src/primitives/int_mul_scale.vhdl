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
-- group_scale is always non-negative in every K-quant format this
-- project reads (it's a magnitude, never a signed delta), so it's typed
-- 'unsigned'. Multiplying a signed value by an unsigned one needs an
-- explicit zero-extend-then-reinterpret-as-signed step first: plain
-- numeric_std (unlike some VHDL-2008 packages) has no mixed signed *
-- unsigned "*" operator, checked against this project's GHDL.
entity int_mul_scale is
  generic (
    LANE_WIDTH  : positive := 17;
    SCALE_WIDTH : positive := 8
  );
  port (
    clk         : in  std_logic;
    ce          : in  std_logic;
    lane_sum    : in  signed(LANE_WIDTH - 1 downto 0);
    group_scale : in  unsigned(SCALE_WIDTH - 1 downto 0);
    p           : out signed(LANE_WIDTH + SCALE_WIDTH - 1 downto 0)
  );
end entity int_mul_scale;

architecture behavioral of int_mul_scale is
  signal scale_s : signed(SCALE_WIDTH downto 0);
  signal product : signed(LANE_WIDTH + SCALE_WIDTH downto 0);
  signal p_slv    : std_logic_vector(LANE_WIDTH + SCALE_WIDTH - 1 downto 0);
begin

  -- zero-extend group_scale by one guard bit, then reinterpret as
  -- signed: the guard bit is always '0' (unsigned zero-extension), so
  -- this represents the same non-negative value as a signed number
  -- without changing it.
  scale_s <= signed(resize(group_scale, SCALE_WIDTH + 1));
  product <= lane_sum * scale_s;

  p_reg : entity work.generic_register
    generic map (WIDTH => LANE_WIDTH + SCALE_WIDTH)
    port map (
      clk => clk, rst => '0', en => ce,
      d => std_logic_vector(resize(product, LANE_WIDTH + SCALE_WIDTH)),
      q => p_slv
    );

  p <= signed(p_slv);

end architecture behavioral;
