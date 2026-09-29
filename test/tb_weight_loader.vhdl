library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for weight_loader.vhdl. There is no special
-- bootstrap case: buf0 starts active (but uninitialized) and load_en
-- can only ever write the INACTIVE buffer, so even the first real tile
-- goes through the same "load the inactive buffer, then swap" sequence
-- used for every tile after it -- this testbench exercises exactly that
-- sequence, twice (to prove ping-pong alternation between buf0/buf1
-- actually happens, not just a one-shot pass), then checks holding
-- between swaps. The swap-vs-dsp_mac2 timing contract documented in
-- weight_loader.vhdl's header (swap must NOT ride the same cycle as
-- whatever eventually asserts a dsp_mac2's 'first') is array_seq's
-- responsibility, not testable from this entity in isolation -- see
-- tb_array_seq.vhdl for the integration test that exercises it.
entity tb_weight_loader is
end entity;

architecture sim of tb_weight_loader is
  constant DSP_COLUMNS : positive := 2;
  constant WEIGHT_W    : positive := 4;
  constant BUS_W       : positive := DSP_COLUMNS * 16 * WEIGHT_W;

  signal clk, rst : std_logic := '0';
  signal load_en : std_logic := '0';
  signal w1_load, w2_load : std_logic_vector(BUS_W - 1 downto 0) := (others => '0');
  signal swap : std_logic := '0';
  signal w1_next, w2_next : std_logic_vector(BUS_W - 1 downto 0);
  signal done : boolean := false;

  constant PATTERN_A1 : std_logic_vector(BUS_W - 1 downto 0) := (others => '1');
  constant PATTERN_A2 : std_logic_vector(BUS_W - 1 downto 0) := (0 => '1', others => '0');
  constant PATTERN_B1 : std_logic_vector(BUS_W - 1 downto 0) := (others => '0');
  constant PATTERN_B2 : std_logic_vector(BUS_W - 1 downto 0) := (BUS_W - 1 => '1', others => '0');
  constant PATTERN_C1 : std_logic_vector(BUS_W - 1 downto 0) := (1 => '1', others => '0');
  constant PATTERN_C2 : std_logic_vector(BUS_W - 1 downto 0) := (2 => '1', others => '0');
begin

  dut : entity work.weight_loader
    generic map (DSP_COLUMNS => DSP_COLUMNS, WEIGHT_W => WEIGHT_W)
    port map (
      clk => clk, rst => rst, load_en => load_en, w1_load => w1_load, w2_load => w2_load,
      swap => swap, w1_next => w1_next, w2_next => w2_next
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- tile 1: load (buf1, since buf0 starts active), then swap it in
    w1_load <= PATTERN_A1; w2_load <= PATTERN_A2; load_en <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    load_en <= '0';

    -- while inactive, w1_next/w2_next must still be whatever buf0
    -- (uninitialized) drives -- not checked, since it's genuinely 'U';
    -- the meaningful check is that they change to the loaded pattern
    -- exactly when swap fires, not before and not a cycle late.
    swap <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    if w1_next /= PATTERN_A1 or w2_next /= PATTERN_A2 then
      fails := fails + 1;
      report "FAIL tile1: w1_next/w2_next didn't reflect the loaded pattern on swap's own cycle" severity error;
    end if;
    swap <= '0';

    -- hold: over several idle cycles, w1_next/w2_next must not change
    for i in 0 to 2 loop
      wait until rising_edge(clk); wait for 1 ns;
      if w1_next /= PATTERN_A1 or w2_next /= PATTERN_A2 then
        fails := fails + 1;
        report "FAIL tile1: w1_next/w2_next changed without a swap" severity error;
      end if;
    end loop;

    -- tile 2: load buf0 (now inactive) with a different pattern while
    -- buf1 (tile 1's) is still what's live on w1_next/w2_next
    w1_load <= PATTERN_B1; w2_load <= PATTERN_B2; load_en <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    load_en <= '0';
    if w1_next /= PATTERN_A1 or w2_next /= PATTERN_A2 then
      fails := fails + 1;
      report "FAIL tile2: loading the inactive buffer disturbed the active one" severity error;
    end if;

    swap <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    if w1_next /= PATTERN_B1 or w2_next /= PATTERN_B2 then
      fails := fails + 1;
      report "FAIL tile2: w1_next/w2_next didn't switch to buf0's pattern on swap" severity error;
    end if;
    swap <= '0';

    -- tile 3: back to buf1
    w1_load <= PATTERN_C1; w2_load <= PATTERN_C2; load_en <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    load_en <= '0';

    swap <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    if w1_next /= PATTERN_C1 or w2_next /= PATTERN_C2 then
      fails := fails + 1;
      report "FAIL tile3: w1_next/w2_next didn't switch to buf1's new pattern on swap" severity error;
    end if;
    swap <= '0';

    wait until rising_edge(clk); wait for 1 ns;
    if w1_next /= PATTERN_C1 or w2_next /= PATTERN_C2 then
      fails := fails + 1;
      report "FAIL: w1_next/w2_next changed the cycle after swap without a new swap" severity error;
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
