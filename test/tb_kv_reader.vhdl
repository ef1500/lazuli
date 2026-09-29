library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for kv_reader.vhdl. DIM=2, CHUNK=3 -- small
-- enough to walk every token of both phases by hand and check the
-- K-then-V ordering, tok_idx/tok_is_v/tok_last, and the tok_ack
-- backpressure (holds tok_data until acked, only then advances).
entity tb_kv_reader is
end entity;

architecture sim of tb_kv_reader is
  constant DIM   : positive := 2;
  constant CHUNK : positive := 3;
  constant ADDR_W : positive := 3; -- clog2(2*3) = clog2(6) = 3

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  signal start : std_logic := '0';
  signal busy, done : std_logic;

  signal run_re    : std_logic;
  signal run_raddr : unsigned(ADDR_W - 1 downto 0);
  signal run_rdata : std_logic_vector(DIM * 8 - 1 downto 0);

  signal tok_valid, tok_is_v, tok_last, tok_ack : std_logic := '0';
  signal tok_idx  : unsigned(1 downto 0); -- clog2(3) = 2
  signal tok_data : std_logic_vector(DIM * 8 - 1 downto 0);

  -- run RAM: 6 entries (K0,K1,K2,V0,V1,V2), 2 bytes each -- entry n's low
  -- byte = n, high byte = n+100, so each entry is trivially identifiable.
  type ram_t is array (0 to 5) of std_logic_vector(DIM * 8 - 1 downto 0);
  signal ram : ram_t;
begin

  gen_ram : for i in 0 to 5 generate
    ram(i) <= std_logic_vector(to_unsigned(i + 100, 8)) & std_logic_vector(to_unsigned(i, 8));
  end generate gen_ram;

  dut : entity work.kv_reader
    generic map (DIM => DIM, CHUNK => CHUNK)
    port map (
      clk => clk, rst => rst, start => start, busy => busy, done => done,
      run_re => run_re, run_raddr => run_raddr, run_rdata => run_rdata,
      tok_valid => tok_valid, tok_is_v => tok_is_v, tok_idx => tok_idx,
      tok_last => tok_last, tok_data => tok_data, tok_ack => tok_ack
    );

  -- registered read, 1-cycle latency, matching generic_sdp_ram.vhdl
  ram_read : process (clk)
  begin
    if rising_edge(clk) then
      if run_re = '1' then
        run_rdata <= ram(to_integer(run_raddr));
      end if;
    end if;
  end process;

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        fails := fails + 1;
        report "FAIL: " & msg severity error;
      end if;
    end procedure;

    -- Waits for tok_valid, checks it against the expected token, then
    -- acks it for exactly one cycle (proving the DUT holds tok_data
    -- steady until acked, not just for one cycle on its own).
    procedure expect_token(exp_idx : natural; exp_is_v : std_logic; exp_last : std_logic;
                            exp_ram_addr : natural; lbl : string) is
    begin
      wait until rising_edge(clk); wait for 1 ns;
      check(tok_valid = '1', lbl & ": tok_valid should be high");
      check(tok_is_v = exp_is_v, lbl & ": tok_is_v mismatch");
      check(to_integer(tok_idx) = exp_idx, lbl & ": tok_idx mismatch");
      check(tok_last = exp_last, lbl & ": tok_last mismatch");
      check(to_integer(unsigned(tok_data(7 downto 0))) = exp_ram_addr,
            lbl & ": tok_data low byte should identify run RAM entry " & integer'image(exp_ram_addr));
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    check(busy = '0', "idle: busy should be low before start");

    start <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    start <= '0';
    check(busy = '1', "busy should go high after start");

    -- K-phase: tokens 0,1,2 (is_v='0'), last on token 2, ram addr = idx
    expect_token(0, '0', '0', 0, "K0");
    tok_ack <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    tok_ack <= '0';

    expect_token(1, '0', '0', 1, "K1");
    tok_ack <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    tok_ack <= '0';

    expect_token(2, '0', '1', 2, "K2 (last of K phase)");
    tok_ack <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    tok_ack <= '0';

    -- V-phase: tokens 0,1,2 (is_v='1'), last on token 2, ram addr =
    -- CHUNK+idx = 3+idx, done pulses after the last ack.
    expect_token(0, '1', '0', 3, "V0");
    tok_ack <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    tok_ack <= '0';

    expect_token(1, '1', '0', 4, "V1");
    tok_ack <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    tok_ack <= '0';

    expect_token(2, '1', '1', 5, "V2 (last of V phase)");
    check(done = '0', "done should not pulse until the last token is acked");
    tok_ack <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    check(done = '1', "done should pulse the cycle after V2 is acked");
    tok_ack <= '0';

    wait until rising_edge(clk); wait for 1 ns;
    check(busy = '0', "busy should drop back to idle after done");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
