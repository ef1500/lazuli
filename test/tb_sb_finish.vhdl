library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for sb_finish.vhdl, wired to a real
-- generic_sdp_ram (as it would be used with acc_ram_bank.vhdl) rather
-- than a stubbed ram_rdata, so the RAM-readback half of the "add into
-- acc_ram" contract is genuinely exercised, not assumed.
--
-- All operand values are chosen to be exact in fp32/fp16 (powers of two
-- or simple sums of two), so every expected bit pattern below is hand-
-- encoded IEEE-754 in this file's own comments -- not computed by
-- calling generic_fpu itself (that would be circular) and not run
-- through an independent script (unlike the Q3_K/Q4_K/Q6_K unpackers,
-- this is plain, checkable-by-hand binary arithmetic, not a recalled bit
-- layout).
--
-- Run 1 (first=1, old value ignored, must read as 0):
--   d=2.0 (0x4000 fp16), dmin=2.0 (0x4000 fp16), act_scale=2.0 (0x40000000),
--   sc_acc=4 (i2f->4.0), min_acc=1 (i2f->1.0)
--   d_scale = 2.0*2.0 = 4.0 ; dmin_scale = 2.0*2.0 = 4.0
--   d_contrib = 4.0*4.0 = 16.0 ; min_contrib = 1.0*4.0 = 4.0
--   delta = 16.0 - 4.0 = 12.0 = 1.1 x 2^3 -> 0x41400000
--   new_val = 0 (first) + 12.0 = 12.0 -> 0x41400000
-- Run 2 (first=0, same inputs -- old value must now be Run 1's 12.0):
--   delta = 12.0 again ; new_val = 12.0 + 12.0 = 24.0 = 1.1 x 2^4 -> 0x41C00000
entity tb_sb_finish is
end entity;

architecture sim of tb_sb_finish is
  constant AW : positive := 4;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  signal start : std_logic := '0';
  signal addr  : unsigned(AW - 1 downto 0) := (others => '0');
  signal first : std_logic := '0';
  signal sc_acc, min_acc : signed(31 downto 0) := (others => '0');
  signal d_f16, dmin_f16 : std_logic_vector(15 downto 0) := (others => '0');
  signal act_scale : std_logic_vector(31 downto 0) := (others => '0');
  signal busy, done : std_logic;

  signal ram_we : std_logic;
  signal ram_waddr : unsigned(AW - 1 downto 0);
  signal ram_wdata : std_logic_vector(31 downto 0);
  signal ram_re : std_logic;
  signal ram_raddr : unsigned(AW - 1 downto 0);
  signal ram_rdata : std_logic_vector(31 downto 0);
begin

  dut : entity work.sb_finish
    generic map (ADDR_WIDTH => AW)
    port map (
      clk => clk, rst => rst,
      start => start, addr => addr, first => first,
      sc_acc => sc_acc, min_acc => min_acc,
      d_f16 => d_f16, dmin_f16 => dmin_f16, act_scale => act_scale,
      busy => busy, done => done,
      ram_we => ram_we, ram_waddr => ram_waddr, ram_wdata => ram_wdata,
      ram_re => ram_re, ram_raddr => ram_raddr, ram_rdata => ram_rdata
    );

  ram : entity work.generic_sdp_ram
    generic map (WIDTH => 32, DEPTH => 2 ** AW)
    port map (
      clk => clk,
      we => ram_we, waddr => ram_waddr, wdata => ram_wdata,
      re => ram_re, raddr => ram_raddr, rdata => ram_rdata
    );

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;
    variable iters : integer;

    procedure run_one(expect_wdata : std_logic_vector(31 downto 0); lbl : string) is
    begin
      start <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      start <= '0';

      iters := 0;
      while done /= '1' and iters < 20 loop
        wait until rising_edge(clk); wait for 1 ns;
        iters := iters + 1;
      end loop;

      if done /= '1' then
        fails := fails + 1;
        report "FAIL " & lbl & ": done never pulsed within 20 cycles" severity error;
      elsif ram_wdata /= expect_wdata then
        fails := fails + 1;
        report "FAIL " & lbl & ": ram_wdata expect=" & to_hstring(expect_wdata) &
               " got=" & to_hstring(ram_wdata) severity error;
      end if;

      -- one more cycle so the write actually lands in generic_sdp_ram
      -- before the next run's RAM read (issued at its own step 0)
      wait until rising_edge(clk); wait for 1 ns;
      if busy /= '0' then
        fails := fails + 1;
        report "FAIL " & lbl & ": busy still high after done" severity error;
      end if;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    addr <= to_unsigned(3, AW);
    sc_acc <= to_signed(4, 32);
    min_acc <= to_signed(1, 32);
    d_f16 <= x"4000";    -- 2.0
    dmin_f16 <= x"4000"; -- 2.0
    act_scale <= x"40000000"; -- 2.0

    -- Run 1: first contribution to addr 3 -- old value must read as 0
    first <= '1';
    run_one(x"41400000", "run1 (12.0)");

    -- Run 2: same inputs, but now accumulating onto run 1's RAM value
    first <= '0';
    run_one(x"41C00000", "run2 (24.0)");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
