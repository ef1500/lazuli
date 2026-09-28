library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for generic_tdp_ram.vhdl: independent
-- concurrent access from both ports (different addresses at once),
-- cross-port visibility (a write on port A becomes visible to a later
-- read on port B), and the read-old-data same-address collision
-- behavior documented in the DUT.
entity tb_generic_tdp_ram is
end entity;

architecture sim of tb_generic_tdp_ram is
  constant WIDTH : positive := 16;
  constant DEPTH : positive := 8;

  signal clk : std_logic := '0';
  signal we_a : std_logic := '0';
  signal addr_a : unsigned(clog2(DEPTH)-1 downto 0) := (others => '0');
  signal wdata_a : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
  signal rdata_a : std_logic_vector(WIDTH-1 downto 0);
  signal we_b : std_logic := '0';
  signal addr_b : unsigned(clog2(DEPTH)-1 downto 0) := (others => '0');
  signal wdata_b : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
  signal rdata_b : std_logic_vector(WIDTH-1 downto 0);

  signal done : boolean := false;
begin

  dut: entity work.generic_tdp_ram
    generic map (WIDTH => WIDTH, DEPTH => DEPTH)
    port map (clk => clk, we_a => we_a, addr_a => addr_a, wdata_a => wdata_a, rdata_a => rdata_a,
              we_b => we_b, addr_b => addr_b, wdata_b => wdata_b, rdata_b => rdata_b);

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

    -- port A writes address 1, port B writes address 2, concurrently
    addr_a <= to_unsigned(1, clog2(DEPTH)); wdata_a <= std_logic_vector(to_unsigned(11, WIDTH)); we_a <= '1';
    addr_b <= to_unsigned(2, clog2(DEPTH)); wdata_b <= std_logic_vector(to_unsigned(22, WIDTH)); we_b <= '1';
    wait until rising_edge(clk);
    we_a <= '0'; we_b <= '0';

    -- port A reads what port B just wrote (cross-port visibility), and
    -- vice versa
    addr_a <= to_unsigned(2, clog2(DEPTH));
    addr_b <= to_unsigned(1, clog2(DEPTH));
    wait until rising_edge(clk);
    wait for 1 ns;
    check(rdata_a, std_logic_vector(to_unsigned(22, WIDTH)), "port A reads port B's earlier write");
    check(rdata_b, std_logic_vector(to_unsigned(11, WIDTH)), "port B reads port A's earlier write");

    -- same-address collision: A writes address 4 while B reads address 4
    -- at the same time -- B should see the OLD value
    addr_a <= to_unsigned(4, clog2(DEPTH)); wdata_a <= std_logic_vector(to_unsigned(44, WIDTH)); we_a <= '1';
    addr_b <= to_unsigned(4, clog2(DEPTH));
    wait until rising_edge(clk);
    we_a <= '0';
    wait for 1 ns;
    check(rdata_b, std_logic_vector(to_unsigned(0, WIDTH)), "collision: B's read reflects the pre-write (reset) value");

    addr_a <= to_unsigned(4, clog2(DEPTH));
    wait until rising_edge(clk);
    wait for 1 ns;
    check(rdata_a, std_logic_vector(to_unsigned(44, WIDTH)), "the collision-cycle write is visible afterward");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
