library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U8 entity 2/2 (claude_docs/04-vhdl-module-list.md's `act_store` row:
-- "act_ram + act_scale_ram with ping-pong"). Double-buffered storage for
-- act_quantizer.vhdl's per-block output (q_out/scale_out/sum_out) --
-- one buffer feeds the array/rescaler while the vector unit's next
-- layer's worth of activations is being quantized into the other, swapped
-- once per layer.
--
-- PING-PONG CONVENTION matches weight_loader.vhdl exactly (same project,
-- same problem shape): 'swap' flips 'active' one cycle later (a plain
-- generic_register toggle), writes are steered to the INACTIVE buffer
-- (en0 <= wr_en and active; en1 <= wr_en and not active -- write buffer
-- 0 while buffer 1 is the one being read, and vice versa), and reads are
-- muxed from the ACTIVE buffer. Unlike weight_loader's single-register
-- buffers, each side here is three generic_sdp_ram instances (q/scale/
-- sum), since a "buffer" is now DEPTH-many independently addressable
-- per-block entries, not one fixed value. Also like weight_loader.vhdl:
-- 'active' is a toggle (`not active`), which can never reach a DEFINED
-- value on its own from an uninitialized register ('not U' is still
-- 'U') -- 'rst' must be pulsed once before the first real use to give
-- it a starting value, the same "must be well-defined before the very
-- first load" requirement weight_loader.vhdl's own header documents.
--
-- ADDRESSING IS DELIBERATELY GENERIC/UNRESOLVED, [D]: `04`'s act_ram
-- entry describes "8b x 36 agents x (4096+3584) elems" -- a real
-- (agent, hidden-vs-FFN-slice, block-within-that) address space this
-- entity does not attempt to reconstruct, since nothing in this repo's
-- docs spells out the exact linearization and guessing one would be
-- silently committing to an unverified layout. DEPTH is instead a plain
-- caller-supplied generic (one slot per act_quantizer block this
-- instance needs to hold), and wr_addr/rd_addr are opaque indices the
-- caller computes -- same treatment as wt_reader.vhdl's invented
-- streaming interface: a real, working, generic building block, with
-- the actual address-space layout left to whichever control unit
-- (`csr_block`/`tile_top`, neither built yet) ends up owning it.
--
-- 1-cycle registered read latency throughout (generic_sdp_ram.vhdl's own
-- behaviour) -- rd_q/rd_scale/rd_sum reflect rd_addr as of the last
-- clock edge where rd_en='1', not combinationally.
entity act_store is
  generic (
    BLOCK_SIZE : positive := 256;
    SUBGROUP   : positive := 32;
    DEPTH      : positive := 72
  );
  port (
    clk, rst : in std_logic; -- rst clears 'active' to a defined value before first use -- see header

    swap : in std_logic; -- ping-pong toggle; 'active' flips one cycle later (weight_loader.vhdl convention)

    wr_en    : in std_logic;
    wr_addr  : in unsigned(clog2(DEPTH) - 1 downto 0);
    wr_q     : in std_logic_vector(BLOCK_SIZE * 8 - 1 downto 0);
    wr_scale : in std_logic_vector(31 downto 0);
    wr_sum   : in std_logic_vector((BLOCK_SIZE / SUBGROUP) * 13 - 1 downto 0);

    rd_en    : in std_logic;
    rd_addr  : in unsigned(clog2(DEPTH) - 1 downto 0);
    rd_q     : out std_logic_vector(BLOCK_SIZE * 8 - 1 downto 0);
    rd_scale : out std_logic_vector(31 downto 0);
    rd_sum   : out std_logic_vector((BLOCK_SIZE / SUBGROUP) * 13 - 1 downto 0)
  );
end entity act_store;

architecture structural of act_store is
  constant SUM_W : positive := (BLOCK_SIZE / SUBGROUP) * 13;

  signal active_slv, active_next : std_logic_vector(0 downto 0);
  signal active : std_logic;
  signal en0, en1 : std_logic;

  signal q0, q1 : std_logic_vector(BLOCK_SIZE * 8 - 1 downto 0);
  signal scale0, scale1 : std_logic_vector(31 downto 0);
  signal sum0, sum1 : std_logic_vector(SUM_W - 1 downto 0);
begin

  active_next(0) <= not active_slv(0);
  active_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => swap, d => active_next, q => active_slv);
  active <= active_slv(0);

  -- write the buffer NOT currently selected for read (see header)
  en0 <= wr_en and active;
  en1 <= wr_en and not active;

  q_ram0 : entity work.generic_sdp_ram
    generic map (WIDTH => BLOCK_SIZE * 8, DEPTH => DEPTH)
    port map (clk => clk, we => en0, waddr => wr_addr, wdata => wr_q, re => rd_en, raddr => rd_addr, rdata => q0);
  q_ram1 : entity work.generic_sdp_ram
    generic map (WIDTH => BLOCK_SIZE * 8, DEPTH => DEPTH)
    port map (clk => clk, we => en1, waddr => wr_addr, wdata => wr_q, re => rd_en, raddr => rd_addr, rdata => q1);

  scale_ram0 : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => DEPTH)
    port map (clk => clk, we => en0, waddr => wr_addr, wdata => wr_scale, re => rd_en, raddr => rd_addr, rdata => scale0);
  scale_ram1 : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => DEPTH)
    port map (clk => clk, we => en1, waddr => wr_addr, wdata => wr_scale, re => rd_en, raddr => rd_addr, rdata => scale1);

  sum_ram0 : entity work.generic_sdp_ram
    generic map (WIDTH => SUM_W, DEPTH => DEPTH)
    port map (clk => clk, we => en0, waddr => wr_addr, wdata => wr_sum, re => rd_en, raddr => rd_addr, rdata => sum0);
  sum_ram1 : entity work.generic_sdp_ram
    generic map (WIDTH => SUM_W, DEPTH => DEPTH)
    port map (clk => clk, we => en1, waddr => wr_addr, wdata => wr_sum, re => rd_en, raddr => rd_addr, rdata => sum1);

  -- active=0 reads buf0 (en1 is the one being written then); active=1
  -- reads buf1 (en0 is the one being written) -- generic_mux2's sel=0
  -- selects d0, so d0 must be the buf0 signal, d1 the buf1 signal.
  q_mux : entity work.generic_mux2
    generic map (WIDTH => BLOCK_SIZE * 8)
    port map (sel => active, d0 => q0, d1 => q1, y => rd_q);

  scale_mux : entity work.generic_mux2
    generic map (WIDTH => 32)
    port map (sel => active, d0 => scale0, d1 => scale1, y => rd_scale);

  sum_mux : entity work.generic_mux2
    generic map (WIDTH => SUM_W)
    port map (sel => active, d0 => sum0, d1 => sum1, y => rd_sum);

end architecture structural;
