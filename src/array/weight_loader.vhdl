library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Drives sys_array's w1_next/w2_next bus (claude_docs/08-vhdl-
-- implementation-spec.md S4.2). Direct-write only [D] -- see
-- sys_array.vhdl's header for why chain-load isn't built: there is no
-- vendor DSP cascade port to drive one, so weight_loader's whole job
-- reduces to a double-buffered (ping-pong) register bank plus a
-- one-cycle pulse generator, not a shift-register sequencer.
--
-- Usage: while the array is busy on the CURRENT tile, the caller
-- streams the NEXT tile's already-unpacked weights in via w1_load/
-- w2_load with load_en pulsed once they're ready (the unpacker --
-- q3k_unpack/q4k_unpack/q6k_unpack, not yet built -- is what would
-- actually produce these; this entity takes them as a plain wide bus so
-- it doesn't need to depend on that). load_en always writes the
-- currently-INACTIVE buffer, never the one live on w1_next/w2_next, so
-- loading the next tile can happen at any time without disturbing the
-- array. When array_seq (src/array/array_seq.vhdl) decides it's time,
-- it pulses 'swap' for one clock and the inactive buffer becomes active
-- (and is what w1_next/w2_next present) THAT SAME clock.
--
-- 'active' selects which buffer drives w1_next/w2_next, and is used
-- directly (not "active xor swap" or similar same-cycle correction):
-- active_reg is a plain register like any other, so by the time
-- anything downstream (including this entity's own output mux) can
-- observe it, it has already settled to its post-edge value -- there
-- is no extra cycle of lag to compensate for. (An earlier version of
-- this entity computed "active xor swap" on the theory that 'active'
-- would still read its pre-edge value on swap's own cycle; simulation
-- showed that's wrong -- by the time anything checks it, 'active' is
-- already the new value, so XORing swap in again just flips it back.)
--
-- Unlike dsp_mac2/pe_cell, this entity DOES need a reset: 'active'
-- makes a binary routing decision (which buffer is safe for load_en to
-- overwrite) that must be well-defined before the very first load, not
-- just "don't care until first used" the way an idle MAC's registers
-- are. Without it, 'active' starts as an undefined bit and load_en's
-- very first pulse targets neither buffer cleanly.
--
-- CALLER CONTRACT -- read before wiring 'swap' to anything: w1_next/
-- w2_next update SAME-CYCLE with swap (above), but whatever eventually
-- feeds a dsp_mac2's 'first' port from this same tile-transition event
-- (directly or indirectly) MUST NOT assert 'first' on swap's own cycle.
-- dsp_mac2's own w1_active register and this entity's active_reg are
-- separate registers on the identical clock edge with only a
-- combinational mux between them (this entity's output mux) -- standard
-- same-edge peer-register semantics mean dsp_mac2 would sample w1_next
-- as it stood BEFORE that edge (the buffer being swapped AWAY from, not
-- the incoming one) if 'first' rode the same cycle as 'swap'. This was
-- caught by an uncommitted scratch integration testbench that actually
-- wired this entity into a dsp_mac2, not by hand-derivation (CLAUDE.md
-- practice #9) -- an earlier version of this entity tried to fix it
-- locally with a registered first_out/last_out output pair, but that
-- duplicated logic array_seq needs anyway AND still didn't produce a
-- correct sys_array.last_in (a PER-TILE "last agent of this tile's B-
-- cycle burst" signal that has nothing to do with weight-swap timing at
-- all -- only array_seq's own agent counter knows it). array_seq now
-- owns the entire fix: it pulses 'swap' here one full cycle before it
-- asserts sys_array.first_in for the incoming tile, using the exact
-- same state-machine transition it needs anyway to sequence tiles, so
-- the fix costs it nothing extra. See array_seq.vhdl's header for the
-- timing diagram.
entity weight_loader is
  generic (
    DSP_COLUMNS : positive := 8;
    WEIGHT_W    : positive := 6
  );
  port (
    clk, rst : in std_logic;

    load_en : in std_logic;
    w1_load, w2_load : in std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0);

    swap : in std_logic; -- one-cycle pulse: make the loaded buffer active now

    w1_next, w2_next : out std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0)
  );
end entity weight_loader;

architecture structural of weight_loader is
  constant BUS_W : positive := DSP_COLUMNS * 16 * WEIGHT_W;

  signal active_slv, active_next : std_logic_vector(0 downto 0);
  signal active : std_logic;

  signal en0, en1 : std_logic;
  signal buf0_w1, buf0_w2, buf1_w1, buf1_w2 : std_logic_vector(BUS_W - 1 downto 0);
begin

  active <= active_slv(0);
  active_next(0) <= not active;

  active_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => swap, d => active_next, q => active_slv);

  -- load_en always targets whichever buffer ISN'T currently active:
  -- buf0 is inactive (safe to overwrite) when active='1' (buf1 is
  -- serving w1_next/w2_next), and vice versa.
  en0 <= load_en and active;
  en1 <= load_en and not active;

  buf0_w1_reg : entity work.generic_register
    generic map (WIDTH => BUS_W)
    port map (clk => clk, rst => '0', en => en0, d => w1_load, q => buf0_w1);
  buf0_w2_reg : entity work.generic_register
    generic map (WIDTH => BUS_W)
    port map (clk => clk, rst => '0', en => en0, d => w2_load, q => buf0_w2);
  buf1_w1_reg : entity work.generic_register
    generic map (WIDTH => BUS_W)
    port map (clk => clk, rst => '0', en => en1, d => w1_load, q => buf1_w1);
  buf1_w2_reg : entity work.generic_register
    generic map (WIDTH => BUS_W)
    port map (clk => clk, rst => '0', en => en1, d => w2_load, q => buf1_w2);

  out_mux_w1 : entity work.generic_mux2
    generic map (WIDTH => BUS_W)
    port map (sel => active, d0 => buf0_w1, d1 => buf1_w1, y => w1_next);

  out_mux_w2 : entity work.generic_mux2
    generic map (WIDTH => BUS_W)
    port map (sel => active, d0 => buf0_w2, d1 => buf1_w2, y => w2_next);

end architecture structural;
