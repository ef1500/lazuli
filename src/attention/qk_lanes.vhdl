library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U11 entity 1/6 (claude_docs/04-vhdl-module-list.md's `qk_lanes` row:
-- "Int8 x int8 dot products, one group per KV head"; claude_docs/08-vhdl-
-- implementation-spec.md S5.1: "int8xint8 dot product over 128 dims ->
-- 22-bit signed accumulator").
--
-- Computes, in ONE clock, the full DIM-wide dot product of one K token
-- vector against each of NUM_Q resident query vectors -- NUM_Q is the
-- GQA reuse factor (03-architecture-units.md's U11: "each K/V element is
-- reused by only 4 query heads", 04's own lane-count table), so this
-- entity is what actually SPENDS that reuse: one K vector read off the
-- DDR channel feeds NUM_Q independent dot products in parallel, not
-- NUM_Q separate reads.
--
-- Purely combinational per-element multiply (int8 x int8 -> 16-bit
-- signed, PROD_W) feeding one `int_sum_tree` per query (already generic,
-- already handles non-power-of-two DIM via pad-then-recurse -- no new
-- reduction primitive needed), registered on `ce`. One cycle latency,
-- same convention as `generic_fpu`/`generic_lookup`.
--
-- SCORE_W = PROD_W + clog2(DIM) is `int_sum_tree`'s own worst-case-safe
-- width formula (every element at the same-sign extreme). For DIM=128
-- that's 16+7=23 bits -- one bit wider than 08 S5.1's hand-checked
-- "128 x 127 x 127 fits in 22 bits" minimum, which only holds because
-- int_sum_tree's generic width is a conservative bound (any input,
-- padded elements are exact zeros), not a per-DIM-specific tightest fit;
-- 23 bits costs nothing extra downstream (softmax_online just sign-
-- extends it into an fp32 CVT_I2F input) so it isn't worth a special-
-- cased narrower width here.
--
-- q_vec is a flat NUM_Q*DIM*8-bit bus, query 0's DIM bytes first. CALLER
-- CONTRACT, same as vec_seq.vhdl's op/sub/cvt: q_vec must be held stable
-- by the caller for the whole run (the NUM_Q resident query vectors for
-- this KV head group don't change token-to-token within one chunk, or
-- indeed within one whole tpu_attn sequence) -- this entity has no
-- latch for it, deliberately, since re-registering something the caller
-- already holds stable would just be a wasted extra cycle of latency.
entity qk_lanes is
  generic (
    DIM   : positive := 128; -- per-token K/Q dimension
    NUM_Q : positive := 4    -- GQA reuse factor: resident queries sharing this KV head
  );
  port (
    clk : in std_logic;
    ce  : in std_logic; -- k_vec/q_vec valid this cycle; score registers on the next edge

    k_vec : in std_logic_vector(DIM * 8 - 1 downto 0);         -- one token's K vector, signed int8 lanes
    q_vec : in std_logic_vector(NUM_Q * DIM * 8 - 1 downto 0); -- NUM_Q resident query vectors, signed int8 lanes

    score : out std_logic_vector(NUM_Q * (16 + clog2(DIM)) - 1 downto 0) -- [q], signed, registered
  );
end entity qk_lanes;

architecture structural of qk_lanes is
  constant PROD_W  : positive := 16; -- int8 * int8
  constant SCORE_W : positive := PROD_W + clog2(DIM);
begin

  lane_gen : for q in 0 to NUM_Q - 1 generate
    signal prods    : std_logic_vector(DIM * PROD_W - 1 downto 0);
    signal tree_sum : signed(SCORE_W - 1 downto 0);
  begin

    elem_gen : for d in 0 to DIM - 1 generate
    begin
      -- signed(8b) * signed(8b) -> signed(16b) automatically (numeric_std
      -- sizes a signed product as left'length + right'length); no resize
      -- needed, and resizing the OPERANDS to PROD_W first would wrongly
      -- double the product width instead.
      prods((d + 1) * PROD_W - 1 downto d * PROD_W) <=
        std_logic_vector(
          signed(k_vec((d + 1) * 8 - 1 downto d * 8)) *
          signed(q_vec((q * DIM + d + 1) * 8 - 1 downto (q * DIM + d) * 8))
        );
    end generate elem_gen;

    tree : entity work.int_sum_tree
      generic map (WIDTH => PROD_W, N => DIM)
      port map (d => prods, sum => tree_sum);

    score_reg : entity work.generic_register
      generic map (WIDTH => SCORE_W)
      port map (clk => clk, rst => '0', en => ce,
                d => std_logic_vector(tree_sum), q => score((q + 1) * SCORE_W - 1 downto q * SCORE_W));

  end generate lane_gen;

end architecture structural;
