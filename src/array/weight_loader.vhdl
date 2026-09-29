library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Drives sys_array's w1_next/w2_next/first_in/last_in bus (claude_docs/
-- 08-vhdl-implementation-spec.md S4.2). Direct-write only [D] -- see
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
-- array. When array_seq (not yet built -- it is what actually knows
-- when a tile's B clocks are up) decides it's time, it pulses 'swap'
-- for one clock: the inactive buffer becomes active (and is what
-- w1_next/w2_next present) THAT SAME clock, with first_out riding the
-- identical clock so dsp_mac2's weight-swap register (dsp_mac2.vhdl
-- S2.1 item 1) latches the correct, already-buffered values -- not the
-- old ones with the new ones landing a cycle late. last_out is swap
-- ANDed with the caller's own 'is_last' (this entity has no notion of
-- how many tiles remain; only array_seq does).
--
-- 'active' is the buffer serving w1_next/w2_next as of the LAST clock
-- edge; 'effective_active' folds in a same-cycle swap combinationally
-- (active XOR swap) so the output mux reflects the POST-swap buffer
-- immediately, the cycle swap is asserted, rather than one clock late.
--
-- Unlike dsp_mac2/pe_cell, this entity DOES need a reset: 'active'
-- makes a binary routing decision (which buffer is safe for load_en to
-- overwrite) that must be well-defined before the very first load, not
-- just "don't care until first used" the way an idle MAC's registers
-- are. Without it, 'active' starts as an undefined bit and load_en's
-- very first pulse targets neither buffer cleanly.
entity weight_loader is
  generic (
    DSP_COLUMNS : positive := 8;
    WEIGHT_W    : positive := 6
  );
  port (
    clk, rst : in std_logic;

    load_en : in std_logic;
    w1_load, w2_load : in std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0);

    swap    : in std_logic; -- one-cycle pulse: make the loaded buffer active now
    is_last : in std_logic; -- this swap is the last tile of the current matmul

    w1_next, w2_next     : out std_logic_vector(DSP_COLUMNS * 16 * WEIGHT_W - 1 downto 0);
    first_out, last_out  : out std_logic
  );
end entity weight_loader;

architecture structural of weight_loader is
  constant BUS_W : positive := DSP_COLUMNS * 16 * WEIGHT_W;

  signal active_slv, active_next : std_logic_vector(0 downto 0);
  signal active, effective_active : std_logic;

  signal en0, en1 : std_logic;
  signal buf0_w1, buf0_w2, buf1_w1, buf1_w2 : std_logic_vector(BUS_W - 1 downto 0);
begin

  active <= active_slv(0);
  active_next(0) <= not active;
  effective_active <= active xor swap;

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
    port map (sel => effective_active, d0 => buf0_w1, d1 => buf1_w1, y => w1_next);

  out_mux_w2 : entity work.generic_mux2
    generic map (WIDTH => BUS_W)
    port map (sel => effective_active, d0 => buf0_w2, d1 => buf1_w2, y => w2_next);

  first_out <= swap;
  last_out  <= swap and is_last;

end architecture structural;
