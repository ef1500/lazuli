library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- U11 entity 2/6 (syseng_docs/04-vhdl-module-list.md's `kv_reader` row:
-- "Gets 4 KiB runs (from kv_dma), presents K then V"; 08-vhdl-
-- implementation-spec.md S5.1's "16-token chunk (4 KiB read granularity,
-- matching kv_page_mgr's page geometry)").
--
-- INTERFACE [D] -- genuinely invented, same situation as wt_reader.vhdl
-- (see its own header): `kv_dma` (L3) is not built, so there is no real
-- burst/streaming convention anywhere in this repo to match this
-- entity's DMA-facing side against. Rather than reconstruct one, this
-- entity takes the "4 KiB run" as ALREADY ASSEMBLED into an on-chip
-- dual-port RAM (exactly what a real kv_dma would hand off once a run
-- completes) and does the one job that's actually testable today: walk
-- that RAM in the K-then-V order attention needs, presenting one
-- token's DIM-wide vector at a time. Widening this into kv_dma's real
-- streaming/burst interface is future work once kv_dma exists.
--
-- LAYOUT [D]: the run RAM is addressed 0..CHUNK-1 for K token 0..CHUNK-1,
-- then CHUNK..2*CHUNK-1 for V token 0..CHUNK-1 -- one flat DIM*8-bit-wide
-- entry per token (INT8 KV, see attn_seq.vhdl's header for why INT8 over
-- FP16: at DIM=128 tokens, CHUNK=16, DIM*8*2*CHUNK/8 = 4096 B = 4 KiB,
-- exactly matching 08 S5.1's own "4 KiB runs" figure for INT8 KV -- this
-- is confirmation the INT8 assumption is the one 08's own numbers were
-- computed against, not an arbitrary pick).
--
-- HANDSHAKE: `tok_valid`/`tok_data`/... are presented and HELD (not a
-- single-cycle pulse) until the caller acks with `tok_ack` -- a plain
-- valid/ack handshake, not a pipelined/ready-in-advance one, since the
-- caller (attn_seq, via qk_lanes/softmax_online or pv_lanes) takes
-- several cycles per token to actually consume it and there is no FIFO
-- elasticity here to absorb that. `run_re`/`run_raddr` follow
-- generic_sdp_ram.vhdl's own convention: 1-cycle registered read
-- latency, so this entity's own FSM has an ISSUE state (assert re) and a
-- separate PRESENT state (rdata now valid) for every token, exactly the
-- read-ahead shape already used by wt_pack/act_quantizer's own RAM reads.
entity kv_reader is
  generic (
    DIM   : positive := 128; -- per-token K/V dimension
    CHUNK : positive := 16   -- tokens per KV chunk (4 KiB read granularity)
  );
  port (
    clk, rst : in std_logic;

    start : in  std_logic; -- begin a new chunk: K-phase token 0
    busy  : out std_logic;
    done  : out std_logic; -- pulses once the V-phase's last token has been ack'd

    run_re    : out std_logic;
    run_raddr : out unsigned(clog2(2 * CHUNK) - 1 downto 0);
    run_rdata : in  std_logic_vector(DIM * 8 - 1 downto 0);

    tok_valid : out std_logic;
    tok_is_v  : out std_logic;
    tok_idx   : out unsigned(clog2(CHUNK) - 1 downto 0);
    tok_last  : out std_logic; -- this is token CHUNK-1 of its phase
    tok_data  : out std_logic_vector(DIM * 8 - 1 downto 0);
    tok_ack   : in  std_logic
  );
end entity kv_reader;

architecture behav of kv_reader is
  constant ADDR_W : positive := clog2(2 * CHUNK);

  constant PH_IDLE    : std_logic_vector(1 downto 0) := "00";
  constant PH_ISSUE   : std_logic_vector(1 downto 0) := "01";
  constant PH_PRESENT : std_logic_vector(1 downto 0) := "10";
  constant PH_DONE    : std_logic_vector(1 downto 0) := "11";

  signal phase, phase_next : std_logic_vector(1 downto 0);

  signal addr_slv, addr_next_slv : std_logic_vector(ADDR_W - 1 downto 0);
  signal addr : unsigned(ADDR_W - 1 downto 0);
begin

  addr <= unsigned(addr_slv);

  phase_next <=
    PH_ISSUE   when (phase = PH_IDLE and start = '1') else
    PH_PRESENT when (phase = PH_ISSUE) else
    PH_DONE    when (phase = PH_PRESENT and tok_ack = '1' and addr = 2 * CHUNK - 1) else
    PH_ISSUE   when (phase = PH_PRESENT and tok_ack = '1') else
    PH_PRESENT when (phase = PH_PRESENT) else
    PH_IDLE    when (phase = PH_DONE) else
    PH_IDLE;

  phase_reg : entity work.generic_register
    generic map (WIDTH => 2)
    port map (clk => clk, rst => rst, en => '1', d => phase_next, q => phase);

  -- addr: 0 on the start edge; +1 each time PRESENT is ack'd (except the
  -- very last token, which just sits until PH_DONE recycles to PH_IDLE
  -- -- the next 'start' resets it to 0 again).
  addr_next_slv <=
    std_logic_vector(to_unsigned(0, ADDR_W)) when (phase = PH_IDLE and start = '1') else
    std_logic_vector(addr + 1)               when (phase = PH_PRESENT and tok_ack = '1' and addr /= 2 * CHUNK - 1) else
    addr_slv;

  addr_reg : entity work.generic_register
    generic map (WIDTH => ADDR_W)
    port map (clk => clk, rst => rst, en => '1', d => addr_next_slv, q => addr_slv);

  run_re    <= '1' when phase = PH_ISSUE else '0';
  run_raddr <= addr;

  -- No capture register here: run_rdata is ITSELF already a registered
  -- signal (generic_sdp_ram.vhdl's own convention) that lands its new
  -- value at the very edge that moves this FSM from PH_ISSUE to
  -- PH_PRESENT -- re-registering it at that same edge would read its
  -- PRE-edge (stale) value, the same same-edge peer-register race as
  -- CLAUDE.md practice #11. By the time PH_PRESENT is live, run_rdata
  -- already holds the right value and stays stable (run_re is only
  -- asserted during PH_ISSUE), so tok_data reads it directly.
  busy <= '0' when (phase = PH_IDLE) else '1';
  done <= '1' when (phase = PH_DONE) else '0';

  tok_valid <= '1' when phase = PH_PRESENT else '0';
  tok_is_v  <= '1' when addr >= CHUNK else '0';
  tok_idx   <= resize(addr, clog2(CHUNK)) when addr < CHUNK else resize(addr - CHUNK, clog2(CHUNK));
  tok_last  <= '1' when (phase = PH_PRESENT and (addr = CHUNK - 1 or addr = 2 * CHUNK - 1)) else '0';
  tok_data  <= run_rdata;

end architecture behav;
