library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for generic_fifo.vhdl. Exercises: FIFO
-- ordering, empty/full flags, below_threshold, overwrite-on-full,
-- simultaneous read/write on an empty FIFO (the 'special' case), and
-- enable_fifo = '0' (single-register mode). Reports "ALL PASS" and
-- exits with a plain 'report ... severity error' per failure (grep for
-- either from a runner script; see test/run_tests.sh).
entity tb_generic_fifo is
end entity;

architecture sim of tb_generic_fifo is
  constant BITS  : integer := 8;
  constant DEPTH : integer := 4;

  signal clk, rst   : std_logic := '0';
  signal wdata      : std_logic_vector(BITS - 1 downto 0) := (others => '0');
  signal wen, ren    : std_logic := '0';
  signal enable_fifo : std_logic := '1';
  signal threshold   : std_logic_vector(clog2(DEPTH) - 1 downto 0) := (others => '0');
  signal rdata       : std_logic_vector(BITS - 1 downto 0);
  signal empty, full, below_threshold : std_logic;

  signal done : boolean := false;
  signal fails : integer := 0;

  procedure check_eq(actual, expect : std_logic_vector; msg : string; signal fail_ctr : inout integer) is
  begin
    if actual /= expect then
      fail_ctr <= fail_ctr + 1;
      report "FAIL: " & msg & " expect=" & to_hstring(expect) & " got=" & to_hstring(actual) severity error;
    end if;
  end procedure;

  procedure check_bit(actual, expect : std_logic; msg : string; signal fail_ctr : inout integer) is
  begin
    if actual /= expect then
      fail_ctr <= fail_ctr + 1;
      report "FAIL: " & msg & " expect=" & std_logic'image(expect) & " got=" & std_logic'image(actual) severity error;
    end if;
  end procedure;
begin

  dut: entity work.generic_FIFO
    generic map (bits => BITS, depth => DEPTH)
    port map (clk => clk, rst => rst, wdata => wdata, wen => wen, ren => ren,
              enable_fifo => enable_fifo, threshold => threshold, rdata => rdata,
              empty => empty, full => full, below_threshold => below_threshold);

  clk <= not clk after 5 ns when not done else '0';

  process
  begin
    rst <= '1'; wen <= '0'; ren <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- reset state: empty, not full
    check_bit(empty, '1', "after reset, empty", fails);
    check_bit(full, '0', "after reset, not full", fails);

    -- fill the FIFO (depth 4): 10,20,30,40
    for i in 0 to 3 loop
      wdata <= std_logic_vector(to_unsigned(10 * (i + 1), BITS));
      wen <= '1';
      wait until rising_edge(clk);
    end loop;
    wen <= '0';
    wait for 1 ns;
    check_bit(full, '1', "after 4 writes to depth-4 FIFO, full", fails);
    check_bit(empty, '0', "after 4 writes, not empty", fails);

    -- read them back in order: 10,20,30,40
    for i in 0 to 3 loop
      wait for 1 ns;
      check_eq(rdata, std_logic_vector(to_unsigned(10 * (i + 1), BITS)), "FIFO order pop " & integer'image(i), fails);
      ren <= '1';
      wait until rising_edge(clk);
      ren <= '0';
    end loop;
    wait for 1 ns;
    check_bit(empty, '1', "after popping all 4, empty", fails);

    -- overwrite-on-full: per the module's own documented contract,
    -- writing a 5th item while full overwrites the newest slot (not the
    -- oldest) -- fill with 1,2,3,4 then push a 5th value 99 while full
    for i in 1 to 4 loop
      wdata <= std_logic_vector(to_unsigned(i, BITS));
      wen <= '1';
      wait until rising_edge(clk);
    end loop;
    wdata <= std_logic_vector(to_unsigned(99, BITS));
    wait until rising_edge(clk); -- still wen='1', FIFO is now full: this write overwrites reg(depth-1)
    wen <= '0';
    -- expect 1,2,3,99 in order (the highest register got overwritten)
    for i in 1 to 3 loop
      wait for 1 ns;
      check_eq(rdata, std_logic_vector(to_unsigned(i, BITS)), "overwrite test pop " & integer'image(i), fails);
      ren <= '1';
      wait until rising_edge(clk);
      ren <= '0';
    end loop;
    wait for 1 ns;
    check_eq(rdata, std_logic_vector(to_unsigned(99, BITS)), "overwrite test: last slot holds the overwriting value", fails);
    ren <= '1';
    wait until rising_edge(clk);
    ren <= '0';
    wait for 1 ns;
    check_bit(empty, '1', "after draining the overwrite test, empty", fails);

    -- below_threshold: push 2 items (threshold = 2), expect below_threshold
    -- to go false once count reaches the threshold
    threshold <= std_logic_vector(to_unsigned(2, clog2(DEPTH)));
    wait for 1 ns;
    check_bit(below_threshold, '1', "empty FIFO is below a threshold of 2", fails);
    wdata <= std_logic_vector(to_unsigned(1, BITS)); wen <= '1';
    wait until rising_edge(clk);
    wen <= '0';
    wait for 1 ns;
    check_bit(below_threshold, '1', "count=1 is below a threshold of 2", fails);
    wdata <= std_logic_vector(to_unsigned(2, BITS)); wen <= '1';
    wait until rising_edge(clk);
    wen <= '0';
    wait for 1 ns;
    check_bit(below_threshold, '0', "count=2 is NOT below a threshold of 2", fails);
    -- drain
    ren <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    ren <= '0';

    -- simultaneous read/write on an empty FIFO: rdata should pass wdata
    -- straight through (the 'special' case in generic_fifo.vhdl)
    wait for 1 ns;
    check_bit(empty, '1', "drained before the simultaneous r/w test", fails);
    wdata <= std_logic_vector(to_unsigned(77, BITS));
    wen <= '1'; ren <= '1';
    wait for 1 ns;
    check_eq(rdata, std_logic_vector(to_unsigned(77, BITS)), "simultaneous r/w on empty FIFO passes wdata through", fails);
    wait until rising_edge(clk);
    wen <= '0'; ren <= '0';

    -- enable_fifo = '0': every write lands in register 0 (acts as a
    -- single register, not a queue)
    wait for 1 ns;
    if empty /= '1' then
      -- drain leftovers from the r/w-through write above, if any landed
      ren <= '1';
      wait until rising_edge(clk);
      ren <= '0';
    end if;
    enable_fifo <= '0';
    wdata <= std_logic_vector(to_unsigned(11, BITS)); wen <= '1';
    wait until rising_edge(clk);
    wdata <= std_logic_vector(to_unsigned(22, BITS));
    wait until rising_edge(clk);
    wen <= '0';
    wait for 1 ns;
    check_eq(rdata, std_logic_vector(to_unsigned(22, BITS)), "enable_fifo='0' acts as a single register (last write wins)", fails);
    enable_fifo <= '1';

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
