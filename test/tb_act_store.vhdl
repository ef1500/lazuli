library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for act_store.vhdl. BLOCK_SIZE=8, SUBGROUP=4
-- (NSUB=2), DEPTH=2 -- small enough to check every field by hand.
-- Proves: (1) a block written while a given buffer is inactive is read
-- back correctly once 'swap' makes that buffer active; (2) writing a
-- DIFFERENT address in the (now inactive) other buffer doesn't disturb
-- what's already there; (3) swapping back finds the ORIGINAL buffer's
-- data still intact, exercising the full buf0<->buf1<->buf0 alternation
-- the same way tb_weight_loader.vhdl does for its single-register case.
entity tb_act_store is
end entity;

architecture sim of tb_act_store is
  constant BS   : positive := 8;
  constant SG   : positive := 4;
  constant NSUB : positive := BS / SG;
  constant DEPTH : positive := 2;

  signal clk, rst : std_logic := '0';
  signal done : boolean := false;

  signal swap : std_logic := '0';
  signal wr_en : std_logic := '0';
  signal wr_addr : unsigned(0 downto 0) := (others => '0');
  signal wr_q : std_logic_vector(BS * 8 - 1 downto 0) := (others => '0');
  signal wr_scale : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_sum : std_logic_vector(NSUB * 13 - 1 downto 0) := (others => '0');

  signal rd_en : std_logic := '0';
  signal rd_addr : unsigned(0 downto 0) := (others => '0');
  signal rd_q : std_logic_vector(BS * 8 - 1 downto 0);
  signal rd_scale : std_logic_vector(31 downto 0);
  signal rd_sum : std_logic_vector(NSUB * 13 - 1 downto 0);

  constant Q_A : std_logic_vector(BS * 8 - 1 downto 0) := x"0102030405060708";
  constant Q_B : std_logic_vector(BS * 8 - 1 downto 0) := x"AABBCCDDEEFF0011";
  constant Q_C : std_logic_vector(BS * 8 - 1 downto 0) := x"1122334455667788";

  constant SCALE_A : std_logic_vector(31 downto 0) := x"3F800000"; -- 1.0
  constant SCALE_B : std_logic_vector(31 downto 0) := x"40000000"; -- 2.0
  constant SCALE_C : std_logic_vector(31 downto 0) := x"40400000"; -- 3.0

  signal sum_a, sum_b, sum_c : std_logic_vector(NSUB * 13 - 1 downto 0);
begin

  dut : entity work.act_store
    generic map (BLOCK_SIZE => BS, SUBGROUP => SG, DEPTH => DEPTH)
    port map (
      clk => clk, rst => rst, swap => swap,
      wr_en => wr_en, wr_addr => wr_addr, wr_q => wr_q, wr_scale => wr_scale, wr_sum => wr_sum,
      rd_en => rd_en, rd_addr => rd_addr, rd_q => rd_q, rd_scale => rd_scale, rd_sum => rd_sum
    );

  sum_a(NSUB * 13 - 1 downto 13) <= std_logic_vector(to_signed(5, 13));
  sum_a(12 downto 0)             <= std_logic_vector(to_signed(-3, 13));
  sum_b(NSUB * 13 - 1 downto 13) <= std_logic_vector(to_signed(9, 13));
  sum_b(12 downto 0)             <= std_logic_vector(to_signed(-9, 13));
  sum_c(NSUB * 13 - 1 downto 13) <= std_logic_vector(to_signed(1, 13));
  sum_c(12 downto 0)             <= std_logic_vector(to_signed(2, 13));

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;

    procedure check(lblok : boolean; msg : string) is
    begin
      if not lblok then
        fails := fails + 1;
        report "FAIL: " & msg severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- write block A to address 0 (active=0: goes into the inactive buffer)
    wr_en <= '1'; wr_addr <= "0"; wr_q <= Q_A; wr_scale <= SCALE_A; wr_sum <= sum_a;
    wait until rising_edge(clk); wait for 1 ns;
    wr_en <= '0';

    -- swap: that buffer becomes active
    swap <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    swap <= '0';

    rd_en <= '1'; rd_addr <= "0";
    wait until rising_edge(clk); wait for 1 ns;
    check(rd_q = Q_A, "block A q mismatch after first swap");
    check(rd_scale = SCALE_A, "block A scale mismatch after first swap");
    check(rd_sum = sum_a, "block A sum mismatch after first swap");

    -- 'active' is now 1 (reading A's buffer), so writes now target the
    -- OTHER (currently inactive, currently unreadable) buffer -- write
    -- C to address 1 THERE. By design this must NOT become visible
    -- until the next swap (writing to the buffer you're reading from
    -- would be the actual bug); addr 0 must still read A meanwhile.
    wr_en <= '1'; wr_addr <= "1"; wr_q <= Q_C; wr_scale <= SCALE_C; wr_sum <= sum_c;
    wait until rising_edge(clk); wait for 1 ns;
    wr_en <= '0';

    rd_addr <= "0";
    wait until rising_edge(clk); wait for 1 ns;
    check(rd_q = Q_A, "block A at addr 0 disturbed by addr 1's write to the other buffer");

    -- write block B to address 0, same (still-inactive) buffer as C --
    -- different address, must not disturb C
    rd_en <= '0';
    wr_en <= '1'; wr_addr <= "0"; wr_q <= Q_B; wr_scale <= SCALE_B; wr_sum <= sum_b;
    wait until rising_edge(clk); wait for 1 ns;
    wr_en <= '0';

    -- swap: B/C's buffer becomes active; both should now be visible
    swap <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    swap <= '0';

    rd_en <= '1'; rd_addr <= "0";
    wait until rising_edge(clk); wait for 1 ns;
    check(rd_q = Q_B, "block B q mismatch after second swap");
    check(rd_scale = SCALE_B, "block B scale mismatch after second swap");
    check(rd_sum = sum_b, "block B sum mismatch after second swap");

    rd_addr <= "1";
    wait until rising_edge(clk); wait for 1 ns;
    check(rd_q = Q_C, "block C at addr 1 mismatch after second swap");
    check(rd_scale = SCALE_C, "block C scale mismatch after second swap");
    check(rd_sum = sum_c, "block C sum mismatch after second swap");

    -- swap a third time: back to A's original buffer (untouched since
    -- the very first write) -- A must still be intact, proving the
    -- buf0<->buf1<->buf0 alternation (see header)
    rd_en <= '0';
    swap <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    swap <= '0';

    rd_en <= '1'; rd_addr <= "0";
    wait until rising_edge(clk); wait for 1 ns;
    check(rd_q = Q_A, "block A not intact after third swap (buf0<->buf1<->buf0)");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
