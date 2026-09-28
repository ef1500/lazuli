library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for generic_sdp_ram.vhdl: write-then-read at
-- distinct addresses, 1-cycle registered read latency, and the
-- read-old-data same-address collision behavior documented in the DUT.
entity tb_generic_sdp_ram is
end entity;

architecture sim of tb_generic_sdp_ram is
  constant WIDTH : positive := 16;
  constant DEPTH : positive := 8;

  signal clk : std_logic := '0';
  signal we : std_logic := '0';
  signal waddr : unsigned(clog2(DEPTH)-1 downto 0) := (others => '0');
  signal wdata : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
  signal re : std_logic := '0';
  signal raddr : unsigned(clog2(DEPTH)-1 downto 0) := (others => '0');
  signal rdata : std_logic_vector(WIDTH-1 downto 0);

  signal done : boolean := false;
begin

  dut: entity work.generic_sdp_ram
    generic map (WIDTH => WIDTH, DEPTH => DEPTH)
    port map (clk => clk, we => we, waddr => waddr, wdata => wdata,
              re => re, raddr => raddr, rdata => rdata);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    procedure check(got, expect : std_logic_vector(WIDTH-1 downto 0); msg : string) is
    begin
      if got /= expect then
        fails := fails + 1;
        report "FAIL " & msg & " expect=" & to_hstring(expect) & " got=" & to_hstring(got) severity error;
      end if;
    end procedure;
  begin
    wait until clk = '1';

    -- write a distinct value into every address
    for i in 0 to DEPTH-1 loop
      waddr <= to_unsigned(i, clog2(DEPTH));
      wdata <= std_logic_vector(to_unsigned(100 + i, WIDTH));
      we <= '1';
      wait until rising_edge(clk);
    end loop;
    we <= '0';

    -- read them back in a different (reversed) order, checking the
    -- 1-cycle registered latency: rdata reflects the address that was
    -- on raddr one cycle ago, not the current one
    for i in DEPTH-1 downto 0 loop
      raddr <= to_unsigned(i, clog2(DEPTH));
      re <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      check(rdata, std_logic_vector(to_unsigned(100 + i, WIDTH)), "read back address " & integer'image(i));
    end loop;
    re <= '0';

    -- re='0' holds rdata steady even if raddr changes underneath
    wait for 1 ns;
    raddr <= to_unsigned(3, clog2(DEPTH));
    wait until rising_edge(clk);
    wait for 1 ns;
    check(rdata, std_logic_vector(to_unsigned(100 + 0, WIDTH)), "re='0' holds the last read value");

    -- same-address collision: write a new value to address 5 while
    -- simultaneously reading address 5 -- expect the OLD value back
    waddr <= to_unsigned(5, clog2(DEPTH));
    wdata <= std_logic_vector(to_unsigned(999, WIDTH));
    raddr <= to_unsigned(5, clog2(DEPTH));
    we <= '1'; re <= '1';
    wait until rising_edge(clk);
    we <= '0'; re <= '0';
    wait for 1 ns;
    check(rdata, std_logic_vector(to_unsigned(105, WIDTH)), "same-address collision reads the pre-write (old) value");

    -- and the new value is visible on a subsequent read
    raddr <= to_unsigned(5, clog2(DEPTH));
    re <= '1';
    wait until rising_edge(clk);
    re <= '0';
    wait for 1 ns;
    check(rdata, std_logic_vector(to_unsigned(999, WIDTH)), "the write from the collision cycle landed");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
