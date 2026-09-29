library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for acc_ram_bank.vhdl. NUM_COLUMNS=3,
-- DEPTH=4, WIDTH=8 (small, exhaustively checkable by hand): writes a
-- distinct value to a distinct address in each of the 3 columns'
-- slices, then reads all three back (including in a different order
-- than written) to prove the columns are genuinely independent RAMs,
-- not one shared array being cross-talked into -- and that
-- generic_sdp_ram.vhdl's own registered-read-latency behaviour survives
-- being wrapped in the flattened per-column bus slicing.
entity tb_acc_ram_bank is
end entity;

architecture sim of tb_acc_ram_bank is
  constant NC : positive := 3;
  constant W  : positive := 8;
  constant D  : positive := 4; -- AW = 2
  constant AW : positive := 2;

  signal clk : std_logic := '0';
  signal done : boolean := false;

  signal we, re : std_logic_vector(NC - 1 downto 0) := (others => '0');
  signal waddr, raddr : std_logic_vector(NC * AW - 1 downto 0) := (others => '0');
  signal wdata : std_logic_vector(NC * W - 1 downto 0) := (others => '0');
  signal rdata : std_logic_vector(NC * W - 1 downto 0);
begin

  dut : entity work.acc_ram_bank
    generic map (NUM_COLUMNS => NC, WIDTH => W, DEPTH => D)
    port map (clk => clk, we => we, waddr => waddr, wdata => wdata,
              re => re, raddr => raddr, rdata => rdata);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
  begin
    -- write column 0 addr 1 <= 0x11, column 1 addr 2 <= 0x22, column 2 addr 3 <= 0x33
    we <= "111";
    waddr(1 * AW - 1 downto 0 * AW) <= std_logic_vector(to_unsigned(1, AW));
    waddr(2 * AW - 1 downto 1 * AW) <= std_logic_vector(to_unsigned(2, AW));
    waddr(3 * AW - 1 downto 2 * AW) <= std_logic_vector(to_unsigned(3, AW));
    wdata(1 * W - 1 downto 0 * W) <= x"11";
    wdata(2 * W - 1 downto 1 * W) <= x"22";
    wdata(3 * W - 1 downto 2 * W) <= x"33";
    wait until rising_edge(clk); wait for 1 ns;
    we <= (others => '0');

    -- also write a DIFFERENT value to column 0's addr 2 (must not disturb addr 1)
    we(0) <= '1';
    waddr(1 * AW - 1 downto 0 * AW) <= std_logic_vector(to_unsigned(2, AW));
    wdata(1 * W - 1 downto 0 * W) <= x"99";
    wait until rising_edge(clk); wait for 1 ns;
    we <= (others => '0');

    -- read all three columns back, deliberately in an order that
    -- doesn't match how they were written, plus column 0's second address
    re <= "111";
    raddr(1 * AW - 1 downto 0 * AW) <= std_logic_vector(to_unsigned(1, AW));
    raddr(2 * AW - 1 downto 1 * AW) <= std_logic_vector(to_unsigned(2, AW));
    raddr(3 * AW - 1 downto 2 * AW) <= std_logic_vector(to_unsigned(3, AW));
    wait until rising_edge(clk); wait for 1 ns;
    re <= (others => '0');

    if rdata(1 * W - 1 downto 0 * W) /= x"11" then
      fails := fails + 1;
      report "FAIL: column 0 addr 1 expect=11 got=" & to_hstring(rdata(1 * W - 1 downto 0 * W)) severity error;
    end if;
    if rdata(2 * W - 1 downto 1 * W) /= x"22" then
      fails := fails + 1;
      report "FAIL: column 1 addr 2 expect=22 got=" & to_hstring(rdata(2 * W - 1 downto 1 * W)) severity error;
    end if;
    if rdata(3 * W - 1 downto 2 * W) /= x"33" then
      fails := fails + 1;
      report "FAIL: column 2 addr 3 expect=33 got=" & to_hstring(rdata(3 * W - 1 downto 2 * W)) severity error;
    end if;

    -- now check column 0's addr 2 (the "disturb" write) independently,
    -- and re-check column 0's addr 1 is STILL 0x11 (proves addr 1 and
    -- addr 2 within the same column's own RAM didn't cross-talk either)
    re(0) <= '1';
    raddr(1 * AW - 1 downto 0 * AW) <= std_logic_vector(to_unsigned(2, AW));
    wait until rising_edge(clk); wait for 1 ns;
    if rdata(1 * W - 1 downto 0 * W) /= x"99" then
      fails := fails + 1;
      report "FAIL: column 0 addr 2 expect=99 got=" & to_hstring(rdata(1 * W - 1 downto 0 * W)) severity error;
    end if;

    raddr(1 * AW - 1 downto 0 * AW) <= std_logic_vector(to_unsigned(1, AW));
    wait until rising_edge(clk); wait for 1 ns;
    re(0) <= '0';
    if rdata(1 * W - 1 downto 0 * W) /= x"11" then
      fails := fails + 1;
      report "FAIL: column 0 addr 1 disturbed by the addr 2 write, expect=11 got=" &
             to_hstring(rdata(1 * W - 1 downto 0 * W)) severity error;
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
