library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench covering the four smallest structural
-- primitives together: generic_register, generic_mux2, generic_mux and
-- generic_delay_line. Everything else in src/primitives/ is built out
-- of these, so bugs here would cascade everywhere -- worth its own
-- focused, thorough check rather than folding into a bigger test.
entity tb_generic_base is
end entity;

architecture sim of tb_generic_base is
  signal clk, rst : std_logic := '0';
  signal done : boolean := false;

  -- generic_register
  signal reg_en : std_logic := '0';
  signal reg_d, reg_q : std_logic_vector(7 downto 0) := (others => '0');
  signal areg_rst : std_logic := '0';
  signal areg_d, areg_q : std_logic_vector(0 downto 0) := (others => '0');

  -- generic_mux2
  signal m2_sel : std_logic;
  signal m2_d0, m2_d1, m2_y : std_logic_vector(7 downto 0);

  -- generic_mux (N=5, non-power-of-two)
  constant MUX_N : positive := 5;
  signal mux_sel : unsigned(clog2(MUX_N) - 1 downto 0);
  signal mux_d : std_logic_vector(MUX_N * 8 - 1 downto 0);
  signal mux_y : std_logic_vector(7 downto 0);

  -- generic_delay_line
  signal dl_d, dl_q : std_logic_vector(7 downto 0) := (others => '0');
begin

  reg_dut : entity work.generic_register
    generic map (WIDTH => 8)
    port map (clk => clk, rst => rst, en => reg_en, d => reg_d, q => reg_q);

  areg_dut : entity work.generic_register
    generic map (WIDTH => 1, ASYNC_RESET => true)
    port map (clk => clk, rst => areg_rst, en => '1', d => areg_d, q => areg_q);

  mux2_dut : entity work.generic_mux2
    generic map (WIDTH => 8)
    port map (sel => m2_sel, d0 => m2_d0, d1 => m2_d1, y => m2_y);

  mux_dut : entity work.generic_mux
    generic map (WIDTH => 8, N => MUX_N)
    port map (sel => mux_sel, d => mux_d, y => mux_y);

  dl_dut : entity work.generic_delay_line
    generic map (WIDTH => 8, STAGES => 3)
    port map (clk => clk, rst => rst, en => '1', d => dl_d, q => dl_q);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
  begin
    -- ---- generic_register: sync reset, enable-gating, hold ----
    rst <= '1';
    wait until rising_edge(clk);
    wait for 1 ns;
    if reg_q /= x"00" then
      fails := fails + 1;
      report "FAIL register: not zero after sync reset" severity error;
    end if;
    rst <= '0';

    reg_d <= x"AB"; reg_en <= '1';
    wait until rising_edge(clk);
    wait for 1 ns;
    if reg_q /= x"AB" then
      fails := fails + 1;
      report "FAIL register: didn't capture d when en=1" severity error;
    end if;

    reg_d <= x"FF"; reg_en <= '0'; -- en=0: must hold, ignore new d
    wait until rising_edge(clk);
    wait for 1 ns;
    if reg_q /= x"AB" then
      fails := fails + 1;
      report "FAIL register: changed value while en=0 (should hold)" severity error;
    end if;

    -- ---- generic_register: async reset ----
    areg_d <= "1";
    wait until rising_edge(clk);
    wait for 1 ns;
    if areg_q /= "1" then
      fails := fails + 1;
      report "FAIL async register: didn't capture d" severity error;
    end if;
    areg_rst <= '1'; -- assert mid-cycle, not at an edge
    wait for 1 ns;
    if areg_q /= "0" then
      fails := fails + 1;
      report "FAIL async register: reset should be immediate, not wait for a clock edge" severity error;
    end if;
    areg_rst <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;

    -- ---- generic_mux2 ----
    m2_d0 <= x"11"; m2_d1 <= x"22";
    m2_sel <= '0'; wait for 1 ns;
    if m2_y /= x"11" then
      fails := fails + 1; report "FAIL mux2: sel=0 should select d0" severity error;
    end if;
    m2_sel <= '1'; wait for 1 ns;
    if m2_y /= x"22" then
      fails := fails + 1; report "FAIL mux2: sel=1 should select d1" severity error;
    end if;

    -- ---- generic_mux (N=5) ----
    mux_d <= x"05" & x"04" & x"03" & x"02" & x"01"; -- entry0=01 .. entry4=05
    for i in 0 to MUX_N - 1 loop
      mux_sel <= to_unsigned(i, clog2(MUX_N));
      wait for 1 ns;
      if to_integer(unsigned(mux_y)) /= i + 1 then
        fails := fails + 1;
        report "FAIL mux: sel=" & integer'image(i) & " expect=" & integer'image(i + 1) &
               " got=" & integer'image(to_integer(unsigned(mux_y))) severity error;
      end if;
    end loop;

    -- ---- generic_delay_line: exactly 3-cycle latency ----
    dl_d <= x"AA";
    wait until rising_edge(clk); wait for 1 ns;
    if dl_q /= x"00" then
      fails := fails + 1; report "FAIL delay_line: output changed too early (1 of 3 cycles)" severity error;
    end if;
    dl_d <= x"00"; -- input can change again; output shouldn't reflect it until its own turn
    wait until rising_edge(clk); wait for 1 ns;
    if dl_q /= x"00" then
      fails := fails + 1; report "FAIL delay_line: output changed too early (2 of 3 cycles)" severity error;
    end if;
    wait until rising_edge(clk); wait for 1 ns;
    if dl_q /= x"AA" then
      fails := fails + 1;
      report "FAIL delay_line: expected AA after exactly 3 cycles, got " & to_hstring(dl_q) severity error;
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
