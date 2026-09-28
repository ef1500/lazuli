library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity tb_generic_async_fifo is
end entity;

architecture sim of tb_generic_async_fifo is
  constant WIDTH : positive := 16;
  constant ADDR_BITS : positive := 3; -- depth = 8, deliberately small to force wraps/full often

  signal wclk, rclk : std_logic := '0';
  signal wrst, rrst : std_logic := '1';
  signal wdata : std_logic_vector(WIDTH-1 downto 0) := (others=>'0');
  signal wen : std_logic := '0';
  signal wfull : std_logic;
  signal rdata : std_logic_vector(WIDTH-1 downto 0);
  signal ren : std_logic := '0';
  signal rempty : std_logic;

  signal done : boolean := false;
  signal fails : integer := 0;
begin
  dut: entity work.generic_async_fifo
    generic map (WIDTH=>WIDTH, ADDR_BITS=>ADDR_BITS, SYNC_STAGES=>2)
    port map (wclk=>wclk, wrst=>wrst, wdata=>wdata, wen=>wen, wfull=>wfull,
              rclk=>rclk, rrst=>rrst, rdata=>rdata, ren=>ren, rempty=>rempty);

  -- deliberately unrelated (asynchronous) clock periods
  wclk <= not wclk after 3700 ps when not done else '0'; -- ~7.4ns period
  rclk <= not rclk after 5900 ps when not done else '0'; -- ~11.8ns period

  writer: process
    variable seed1, seed2 : positive := 1;
    variable rnd : real;
    variable gap : integer;
  begin
    wrst <= '1';
    wait until rising_edge(wclk);
    wait until rising_edge(wclk);
    wrst <= '0';
    wait until rising_edge(wclk);

    for i in 0 to 199 loop
      -- randomized gap before each write attempt (0..3 idle cycles)
      uniform(seed1, seed2, rnd);
      gap := integer(floor(rnd * 4.0));
      for g in 1 to gap loop
        wait until rising_edge(wclk);
        wait for 1 ns;
      end loop;

      -- wait for room if currently full (real backpressure, not a fixed
      -- delay -- exercises wfull crossing back from the read side).
      -- wfull depends on a multi-hop combinational chain (register ->
      -- generic_bin2gray -> comparison), so it needs a settling wait
      -- after the clock edge before this loop's condition re-reads it.
      while wfull = '1' loop
        wait until rising_edge(wclk);
        wait for 1 ns;
      end loop;

      wdata <= std_logic_vector(to_unsigned(i, WIDTH));
      wen <= '1';
      wait until rising_edge(wclk);
      wen <= '0';
      wait for 1 ns;
    end loop;

    wait;
  end process writer;

  reader: process
    variable seed1, seed2 : positive := 42;
    variable rnd : real;
    variable gap : integer;
    variable expected : integer := 0;
  begin
    rrst <= '1';
    wait until rising_edge(rclk);
    wait until rising_edge(rclk);
    rrst <= '0';
    wait until rising_edge(rclk);

    while expected < 200 loop
      uniform(seed1, seed2, rnd);
      gap := integer(floor(rnd * 4.0));
      for g in 1 to gap loop
        wait until rising_edge(rclk);
        wait for 1 ns;
      end loop;

      while rempty = '1' loop
        wait until rising_edge(rclk);
        wait for 1 ns;
      end loop;

      -- rdata becomes valid the cycle after ren is sampled high (a
      -- registered read, 1-cycle latency); pulse ren, then check rdata
      -- once it's settled past that same edge.
      ren <= '1';
      wait until rising_edge(rclk);
      ren <= '0';
      wait for 1 ns;
      if to_integer(unsigned(rdata)) /= expected then
        fails <= fails + 1;
        report "FAIL: expected " & integer'image(expected) & " got " &
               integer'image(to_integer(unsigned(rdata))) severity error;
      end if;
      expected := expected + 1;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process reader;

end architecture sim;
