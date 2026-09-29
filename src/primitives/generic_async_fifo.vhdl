library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic asynchronous (dual-clock) FIFO (syseng_docs/04-vhdl-module-
-- list.md's L0 utility 'async_fifo': "Gray-code pointer FIFO for clock
-- crossings"). Depth is 2**ADDR_BITS. The classic Cummings design:
-- binary read/write pointers one bit wider than the address (the extra
-- bit disambiguates full from empty after wrapping), each converted to
-- Gray code and crossed into the other clock domain through a
-- generic_delay_line synchronizer chain, compared there to derive
-- wfull/rempty. Gray code is only needed for the pointer value that
-- crosses domains -- comparing two Gray codes for equality works
-- exactly like comparing their binary equivalents, so no gray-to-binary
-- conversion is needed anywhere (the local binary counters address the
-- memory directly).
--
-- Binary-to-Gray conversion is generic_bin2gray.vhdl (a ripple of XOR
-- gates via a generate loop), instantiated once per side.
--
-- Memory: a plain dual-clock array (write side clocked by wclk, read
-- side clocked by rclk) -- the same "array signal behind one clocked
-- process" shape as generic_sdp_ram.vhdl, just with the read and write
-- processes on independent clocks instead of a shared one, which is
-- the one part of an async FIFO that genuinely has to be a memory
-- description rather than a composition of smaller structural pieces.
entity generic_async_fifo is
  generic (
    WIDTH      : positive := 32;
    ADDR_BITS  : positive := 4; -- depth = 2**ADDR_BITS
    SYNC_STAGES : positive := 2
  );
  port (
    wclk, wrst : in  std_logic;
    wdata      : in  std_logic_vector(WIDTH - 1 downto 0);
    wen        : in  std_logic;
    wfull      : out std_logic;

    rclk, rrst : in  std_logic;
    rdata      : out std_logic_vector(WIDTH - 1 downto 0);
    ren        : in  std_logic;
    rempty     : out std_logic
  );
end entity generic_async_fifo;

architecture structural of generic_async_fifo is
  constant DEPTH : positive := 2 ** ADDR_BITS;
  constant PTR_BITS : positive := ADDR_BITS + 1;

  type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  -- write side
  signal wptr_bin, wptr_bin_next : unsigned(PTR_BITS - 1 downto 0) := (others => '0');
  signal wptr_gray, wptr_gray_next : std_logic_vector(PTR_BITS - 1 downto 0);
  signal rptr_gray_wsync : std_logic_vector(PTR_BITS - 1 downto 0);
  signal wfull_i : std_logic;
  signal wfull_cmp : std_logic_vector(PTR_BITS - 1 downto 0);

  -- read side
  signal rptr_bin, rptr_bin_next : unsigned(PTR_BITS - 1 downto 0) := (others => '0');
  signal rptr_gray, rptr_gray_next : std_logic_vector(PTR_BITS - 1 downto 0);
  signal wptr_gray_rsync : std_logic_vector(PTR_BITS - 1 downto 0);
  signal rempty_i : std_logic;

begin

  ------------------------------------------------------------------
  -- write side
  ------------------------------------------------------------------
  -- wfull_i is gated by wptr_bin+1 or wptr_bin, but wfull_i ITSELF is
  -- derived below from wptr_gray -- the REGISTERED pointer (last
  -- cycle's committed state), not a same-cycle speculative value -- so
  -- there is no combinational loop here (wfull_i does not depend on
  -- wptr_bin_next). This also gets the boundary right: a write that
  -- brings the FIFO to exactly DEPTH is still accepted (wfull_i was '0'
  -- going into that cycle, since we weren't full yet); wfull_i only
  -- reads '1' starting the cycle after, correctly blocking the write
  -- that would have exceeded DEPTH. Using a same-cycle "would this
  -- write make us full" prediction instead (an earlier version of this
  -- file did) blocks the DEPTH-completing write itself, one entry too
  -- early.
  wptr_bin_next <= wptr_bin + 1 when (wen = '1' and wfull_i = '0') else wptr_bin;

  wptr_b2g : entity work.generic_bin2gray
    generic map (WIDTH => PTR_BITS)
    port map (bin => std_logic_vector(wptr_bin_next), gray => wptr_gray_next);

  wptr_bin_reg : process (wclk)
  begin
    if rising_edge(wclk) then
      if wrst = '1' then
        wptr_bin <= (others => '0');
      else
        wptr_bin <= wptr_bin_next;
      end if;
    end if;
  end process wptr_bin_reg;

  wptr_gray_reg : entity work.generic_register
    generic map (WIDTH => PTR_BITS)
    port map (clk => wclk, rst => wrst, en => '1', d => wptr_gray_next, q => wptr_gray);

  rptr_sync : entity work.generic_delay_line
    generic map (WIDTH => PTR_BITS, STAGES => SYNC_STAGES)
    port map (clk => wclk, rst => wrst, en => '1', d => rptr_gray, q => rptr_gray_wsync);

  -- full when the CURRENT (registered) write pointer (Gray) equals the
  -- synchronized read pointer with its top two bits flipped -- the
  -- Cummings trick that distinguishes full from empty despite both
  -- meaning "pointers equal" in the low bits.
  wfull_cmp <= (not rptr_gray_wsync(PTR_BITS - 1)) & (not rptr_gray_wsync(PTR_BITS - 2)) &
               rptr_gray_wsync(PTR_BITS - 3 downto 0);
  wfull_i <= '1' when wptr_gray = wfull_cmp else '0';
  wfull <= wfull_i;

  write_mem : process (wclk)
  begin
    if rising_edge(wclk) then
      if wen = '1' and wfull_i = '0' then
        mem(to_integer(wptr_bin(ADDR_BITS - 1 downto 0))) <= wdata;
      end if;
    end if;
  end process write_mem;

  ------------------------------------------------------------------
  -- read side
  ------------------------------------------------------------------
  rptr_bin_next <= rptr_bin + 1 when (ren = '1' and rempty_i = '0') else rptr_bin;

  rptr_b2g : entity work.generic_bin2gray
    generic map (WIDTH => PTR_BITS)
    port map (bin => std_logic_vector(rptr_bin_next), gray => rptr_gray_next);

  rptr_bin_reg : process (rclk)
  begin
    if rising_edge(rclk) then
      if rrst = '1' then
        rptr_bin <= (others => '0');
      else
        rptr_bin <= rptr_bin_next;
      end if;
    end if;
  end process rptr_bin_reg;

  rptr_gray_reg : entity work.generic_register
    generic map (WIDTH => PTR_BITS)
    port map (clk => rclk, rst => rrst, en => '1', d => rptr_gray_next, q => rptr_gray);

  wptr_sync : entity work.generic_delay_line
    generic map (WIDTH => PTR_BITS, STAGES => SYNC_STAGES)
    port map (clk => rclk, rst => rrst, en => '1', d => wptr_gray, q => wptr_gray_rsync);

  rempty_i <= '1' when rptr_gray = wptr_gray_rsync else '0';
  rempty <= rempty_i;

  read_mem : process (rclk)
  begin
    if rising_edge(rclk) then
      if ren = '1' and rempty_i = '0' then
        rdata <= mem(to_integer(rptr_bin(ADDR_BITS - 1 downto 0)));
      end if;
    end if;
  end process read_mem;

end architecture structural;
