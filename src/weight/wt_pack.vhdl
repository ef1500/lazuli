library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Weight path's two-lane packer (syseng_docs/04-vhdl-module-list.md's
-- U7 entry: "Builds q1 + (q2 << 17) words"). Purely combinational --
-- mirrors dsp_mac2.vhdl's OWN a_word formula exactly (resize q1, add
-- q2 shifted left by SPACING), since that IS the packed-A-word format
-- the array's DSP slices expect.
--
-- Consumer [D] -- genuinely undetermined by anything else built in this
-- repo, flagged rather than guessed: weight_loader.vhdl (already built)
-- takes w1_load/w2_load as TWO SEPARATE per-lane buses, not one packed
-- word, so this entity's output does NOT feed weight_loader directly --
-- wiring a pre-packed word there would just need re-splitting, pure
-- waste. The likeliest real use (04 S3's storage table lists `wt_stage`
-- as holding a tile's raw bytes and `scale_ram` separately, neither
-- specifying a packed-word width) is compacting two lanes into one
-- narrower word for on-chip STORAGE between wt_reader and the array
-- (halving wt_stage's width), not for driving the array directly. Built
-- here as a small, correct, reusable primitive matching the one formula
-- 04 actually specifies; wiring it into wt_reader's staging path (or
-- wherever else needs it) is left to whichever future entity turns out
-- to need it, rather than forced onto an assumption made here.
entity wt_pack is
  generic (
    WEIGHT_W : positive := 6;  -- signed bits for one weight lane
    SPACING  : positive := 17;
    OUT_W    : positive := 27  -- A_PORT_W; must be >= WEIGHT_W + SPACING
  );
  port (
    q1 : in  signed(WEIGHT_W - 1 downto 0);
    q2 : in  signed(WEIGHT_W - 1 downto 0);
    y  : out signed(OUT_W - 1 downto 0)
  );
end entity wt_pack;

architecture behav of wt_pack is
begin

  y <= resize(q1, OUT_W) + shift_left(resize(q2, OUT_W), SPACING);

end architecture behav;
