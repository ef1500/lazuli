library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Weight block reader (claude_docs/04-vhdl-module-list.md's U7 entry:
-- "Reads tile-ordered blocks from DDR"; claude_docs/03-architecture-
-- units.md's U7: "converter output, 14,080 B for Q3_K"). Assembles a
-- byte stream into complete, format-sized super-blocks and hands them
-- off one at a time to whichever unpacker (q3k_unpack/q4k_unpack/
-- q6k_unpack) the caller selects, double-buffered so the next block can
-- fill while the current one is still being consumed.
--
-- Interface [D] -- genuinely invented, not specified anywhere in this
-- repo: there is no DDR4 controller (vendor IP, not written here) or
-- generic DMA/AXI read port established by any OTHER entity yet
-- (dma_rd/dma_wr, L3, are not built). Rather than guess at a real
-- memory-mapped protocol this repo has no other example of, this
-- entity takes the simplest generic contract that could stand in for
-- one: a plain byte-at-a-time valid/ready stream in (in_valid/in_data/
-- in_ready), one byte per accepted beat. A real DMA engine would
-- deliver much wider bursts (03 U7's own "~55 B/clock" figure) --
-- widening IN_WORD_BYTES to match is future work once dma_rd/dma_wr
-- exist to actually drive it; byte-at-a-time is what's testable and
-- correct today without inventing that interface too.
--
-- BLOCK_BYTES is a generic, not per-format logic here: the caller picks
-- 110 (Q3_K), 144 (Q4_K) or 210 (Q6_K) to match whichever unpacker this
-- instance feeds -- this entity has no format-specific knowledge at
-- all, matching 04's "Generic fmt_t selects one unpacker per tile-load"
-- (the format selection happens by which unpacker the caller wires
-- out_data into, not inside this entity).
--
-- Double buffering: while buffer A is `pending` (complete, waiting for
-- the consumer to take it via out_ready), filling continues into buffer
-- B. Since there is only one `pending`/`pending_buf` pair (not a depth-
-- 2 FIFO), completing a SECOND block while the first is still pending
-- would silently lose the first one -- prevented by blocking exactly
-- the LAST byte of the second block's fill (in_ready drops) until the
-- first is consumed, rather than blocking every byte of the second
-- fill (which would give up the overlap double-buffering exists for).
entity wt_reader is
  generic (
    BLOCK_BYTES : positive := 110 -- one super-block's raw byte count (110 Q3_K, 144 Q4_K, 210 Q6_K)
  );
  port (
    clk, rst : in std_logic;

    in_valid : in  std_logic;
    in_data  : in  std_logic_vector(7 downto 0);
    in_ready : out std_logic;

    out_valid : out std_logic;
    out_data  : out std_logic_vector(BLOCK_BYTES * 8 - 1 downto 0);
    out_ready : in  std_logic
  );
end entity wt_reader;

architecture behav of wt_reader is
  constant CNT_W : positive := 16; -- generous headroom over any real BLOCK_BYTES

  signal active_fill, active_fill_next : std_logic_vector(0 downto 0);
  signal pending, pending_next         : std_logic_vector(0 downto 0);
  signal pending_buf, pending_buf_next : std_logic_vector(0 downto 0);
  signal byte_cnt, byte_cnt_next       : std_logic_vector(CNT_W - 1 downto 0);

  signal accept, completing, in_ready_i : std_logic;
  signal en_active_fill, en_pending, en_pending_buf, en_byte_cnt : std_logic;

  type buf_arr_t is array (0 to 1) of std_logic_vector(BLOCK_BYTES * 8 - 1 downto 0);
  signal buf : buf_arr_t;
begin

  in_ready_i <= '0' when (pending(0) = '1' and unsigned(byte_cnt) = BLOCK_BYTES - 1) else '1';
  in_ready   <= in_ready_i;
  accept     <= in_valid and in_ready_i;
  completing <= accept when unsigned(byte_cnt) = BLOCK_BYTES - 1 else '0';

  -- byte_cnt: 0 on completion, +1 on every other accepted beat
  en_byte_cnt   <= accept;
  byte_cnt_next <= (others => '0') when completing = '1' else std_logic_vector(unsigned(byte_cnt) + 1);

  byte_cnt_reg : entity work.generic_register
    generic map (WIDTH => CNT_W)
    port map (clk => clk, rst => rst, en => en_byte_cnt, d => byte_cnt_next, q => byte_cnt);

  -- active_fill: toggles on completion
  en_active_fill   <= completing;
  active_fill_next <= not active_fill;

  active_fill_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => en_active_fill, d => active_fill_next, q => active_fill);

  -- pending/pending_buf: set on completion (latching which buffer),
  -- cleared when the consumer takes it
  en_pending      <= completing or (pending(0) and out_ready);
  pending_next(0) <= '1' when completing = '1' else '0';

  pending_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => en_pending, d => pending_next, q => pending);

  en_pending_buf   <= completing;
  pending_buf_next <= active_fill;

  pending_buf_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => rst, en => en_pending_buf, d => pending_buf_next, q => pending_buf);

  -- byte storage: one generic_register per (buffer, byte position)
  buf_gen : for b in 0 to 1 generate
    byte_gen : for p in 0 to BLOCK_BYTES - 1 generate
      signal en_byte : std_logic;
    begin
      en_byte <= accept when (unsigned(byte_cnt) = p and unsigned(active_fill) = b) else '0';

      byte_reg : entity work.generic_register
        generic map (WIDTH => 8)
        port map (clk => clk, rst => '0', en => en_byte, d => in_data, q => buf(b)((p + 1) * 8 - 1 downto p * 8));
    end generate byte_gen;
  end generate buf_gen;

  out_valid <= pending(0);
  out_data  <= buf(0) when pending_buf(0) = '0' else buf(1);

end architecture behav;
