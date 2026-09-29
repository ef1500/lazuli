library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for wt_reader.vhdl. BLOCK_BYTES=6 (small, so
-- the whole double-buffer/backpressure sequence is exhaustively
-- checkable byte-by-byte). Checks: (1) a block streamed in byte-by-
-- byte assembles correctly and pulses out_valid with the right byte
-- ordering; (2) after being consumed, out_valid drops and a second
-- block can be streamed the same way; (3) double buffering -- a SECOND
-- block can be streamed in immediately behind the first, without
-- waiting for out_ready, right up until its last byte, where in_ready
-- must drop (the one-pending-block limit from wt_reader.vhdl's header)
-- until the first block is consumed.
entity tb_wt_reader is
end entity;

architecture sim of tb_wt_reader is
  constant BLOCK_BYTES : positive := 6;

  signal clk, rst : std_logic := '0';
  signal in_valid : std_logic := '0';
  signal in_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal in_ready : std_logic;
  signal out_valid : std_logic;
  signal out_data  : std_logic_vector(BLOCK_BYTES * 8 - 1 downto 0);
  signal out_ready : std_logic := '0';
  signal done : boolean := false;
begin

  dut : entity work.wt_reader
    generic map (BLOCK_BYTES => BLOCK_BYTES)
    port map (
      clk => clk, rst => rst,
      in_valid => in_valid, in_data => in_data, in_ready => in_ready,
      out_valid => out_valid, out_data => out_data, out_ready => out_ready
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;

    procedure send_byte(v : integer) is
    begin
      in_data <= std_logic_vector(to_unsigned(v, 8));
      in_valid <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      -- caller must have already confirmed in_ready if needed; this
      -- procedure assumes it was high (checked separately where it matters)
      in_valid <= '0';
    end procedure;

    variable expect_data : std_logic_vector(BLOCK_BYTES * 8 - 1 downto 0);
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    if out_valid /= '0' then
      fails := fails + 1;
      report "FAIL: out_valid high before anything streamed" severity error;
    end if;

    -- === Block 1: stream BLOCK_BYTES bytes (10, 11, ..., 15) ===
    for i in 0 to BLOCK_BYTES - 1 loop
      if in_ready /= '1' then
        fails := fails + 1;
        report "FAIL: in_ready low mid-fill on a fresh buffer, byte " & integer'image(i) severity error;
      end if;
      send_byte(10 + i);
    end loop;

    if out_valid /= '1' then
      fails := fails + 1;
      report "FAIL: out_valid didn't assert right after the block's last byte" severity error;
    end if;
    for i in 0 to BLOCK_BYTES - 1 loop
      expect_data((i + 1) * 8 - 1 downto i * 8) := std_logic_vector(to_unsigned(10 + i, 8));
    end loop;
    if out_data /= expect_data then
      fails := fails + 1;
      report "FAIL: block 1 out_data mismatch (byte ordering bug?)" severity error;
    end if;

    -- consume it
    out_ready <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    out_ready <= '0';
    if out_valid /= '0' then
      fails := fails + 1;
      report "FAIL: out_valid didn't drop after consumption" severity error;
    end if;

    -- === Block 2: a fresh block, same check, proving the ping-pong
    -- buffer correctly resets/cycles ===
    for i in 0 to BLOCK_BYTES - 1 loop
      send_byte(20 + i);
    end loop;
    if out_valid /= '1' then
      fails := fails + 1;
      report "FAIL: block 2 out_valid didn't assert" severity error;
    end if;
    for i in 0 to BLOCK_BYTES - 1 loop
      expect_data((i + 1) * 8 - 1 downto i * 8) := std_logic_vector(to_unsigned(20 + i, 8));
    end loop;
    if out_data /= expect_data then
      fails := fails + 1;
      report "FAIL: block 2 out_data mismatch" severity error;
    end if;
    -- leave block 2 PENDING (not consumed yet) for the next phase

    -- === Double buffering: stream block 3 while block 2 is still
    -- pending. All bytes except the LAST must be accepted normally;
    -- in_ready must drop before the last byte. ===
    for i in 0 to BLOCK_BYTES - 2 loop
      if in_ready /= '1' then
        fails := fails + 1;
        report "FAIL: in_ready dropped too early during block 3's fill (byte " & integer'image(i) & ")" severity error;
      end if;
      send_byte(30 + i);
    end loop;

    -- now byte_cnt = BLOCK_BYTES-1, pending(block 2) still set: in_ready must be low
    in_data <= std_logic_vector(to_unsigned(30 + BLOCK_BYTES - 1, 8));
    in_valid <= '1';
    wait for 1 ns;
    if in_ready /= '0' then
      fails := fails + 1;
      report "FAIL: in_ready should be low for block 3's last byte while block 2 is still pending" severity error;
    end if;

    -- block 2's data must still be intact (not clobbered) while stalled
    for i in 0 to BLOCK_BYTES - 1 loop
      expect_data((i + 1) * 8 - 1 downto i * 8) := std_logic_vector(to_unsigned(20 + i, 8));
    end loop;
    if out_data /= expect_data or out_valid /= '1' then
      fails := fails + 1;
      report "FAIL: block 2 disturbed while block 3's last byte is stalled" severity error;
    end if;

    -- now consume block 2 -- this should unblock block 3's last byte.
    -- Consuming clears 'pending' AT this edge (visible post-edge), so
    -- in_ready only reads high starting next cycle -- block 3's last
    -- byte (still held on in_data/in_valid) is actually ACCEPTED on
    -- the FOLLOWING edge, not this one; keep in_valid high through it.
    out_ready <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    out_ready <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    in_valid <= '0';

    if out_valid /= '1' then
      fails := fails + 1;
      report "FAIL: block 3 out_valid didn't assert after its last byte was finally accepted" severity error;
    end if;
    for i in 0 to BLOCK_BYTES - 1 loop
      expect_data((i + 1) * 8 - 1 downto i * 8) := std_logic_vector(to_unsigned(30 + i, 8));
    end loop;
    if out_data /= expect_data then
      fails := fails + 1;
      report "FAIL: block 3 out_data mismatch" severity error;
    end if;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
