library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for lazuli.vhdl, the top-level tensor unit.
-- The arithmetic itself is already exhaustively verified by
-- tb_generic_fpu.vhdl/tb_generic_lookup.vhdl, so this focuses on the
-- integration-level behavior that's unique to lazuli: operand-queue to
-- result-queue plumbing under a stall, back-to-back issue with no stall,
-- per-lane independence (a broadcast-value test can't catch a lane-
-- index/slicing bug), the broadcast table-load bus, and the result RAM
-- (random-access readback of retired results, independent of out_ren).
entity tb_lazuli is
end entity;

architecture sim of tb_lazuli is
  constant LANES : positive := 8;
  constant RDEPTH : positive := 32;
  signal clk, rst : std_logic := '0';
  signal op  : alu_op_t := ALU_ADD;
  signal sub : std_logic_vector(2 downto 0) := "000";
  signal cvt : cvt_op_t := CVT_I2F;
  signal lut_slot : unsigned(2 downto 0) := "000";

  signal a_data, b_data : std_logic_vector(LANES*32-1 downto 0) := (others=>'0');
  signal in_wen : std_logic := '0';
  signal in_full : std_logic;

  signal y_data : std_logic_vector(LANES*32-1 downto 0);
  signal flag_data : std_logic_vector(LANES*2-1 downto 0);
  signal out_ren : std_logic := '0';
  signal out_empty : std_logic;

  signal result_addr : unsigned(clog2(RDEPTH)-1 downto 0) := (others => '0');
  signal result_data : std_logic_vector(LANES*32-1 downto 0);
  signal result_wraddr : unsigned(clog2(RDEPTH)-1 downto 0);

  signal ld_en, ld_we : std_logic := '0';
  signal ld_slot : unsigned(2 downto 0) := "000";
  signal ld_mode : tab_mode_t := TAB_FRAC;
  signal ld_lo, ld_hi : std_logic_vector(31 downto 0) := (others=>'0');
  signal ld_left, ld_right : tab_edge_t := EDGE_CLAMP;
  signal ld_bits : unsigned(3 downto 0) := (others=>'0');
  signal ld_addr : unsigned(9 downto 0) := (others=>'0');
  signal ld_value, ld_slope : std_logic_vector(31 downto 0) := (others=>'0');

  signal done : boolean := false;

  type int_fp_arr_t is array (1 to 16) of std_logic_vector(31 downto 0);
  constant INT_FP : int_fp_arr_t := (
    x"3F800000", x"40000000", x"40400000", x"40800000", x"40A00000", x"40C00000",
    x"40E00000", x"41000000", x"41100000", x"41200000", x"41300000", x"41400000",
    x"41500000", x"41600000", x"41700000", x"41800000"
  );
  constant TWO : std_logic_vector(31 downto 0) := INT_FP(2);
  constant THREE : std_logic_vector(31 downto 0) := INT_FP(3);
  constant FOUR : std_logic_vector(31 downto 0) := INT_FP(4);
  constant FIVE : std_logic_vector(31 downto 0) := INT_FP(5);
  constant NINE : std_logic_vector(31 downto 0) := INT_FP(9);

  function lane_word(v : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(LANES*32-1 downto 0);
  begin
    for i in 0 to LANES-1 loop
      r((i+1)*32-1 downto i*32) := v;
    end loop;
    return r;
  end function;

  function lane_check(w : std_logic_vector(LANES*32-1 downto 0); v : std_logic_vector(31 downto 0)) return boolean is
  begin
    for i in 0 to LANES-1 loop
      if w((i+1)*32-1 downto i*32) /= v then
        return false;
      end if;
    end loop;
    return true;
  end function;
begin

  dut: entity work.lazuli
    generic map (LANES => LANES, QDEPTH => 16, RDEPTH => RDEPTH)
    port map (
      clk => clk, rst => rst, op => op, sub => sub, cvt => cvt, lut_slot => lut_slot,
      a_data => a_data, b_data => b_data, in_wen => in_wen, in_full => in_full,
      y_data => y_data, flag_data => flag_data, out_ren => out_ren, out_empty => out_empty,
      result_addr => result_addr, result_data => result_data, result_wraddr => result_wraddr,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode, ld_lo => ld_lo, ld_hi => ld_hi,
      ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    variable base_addr : unsigned(clog2(RDEPTH)-1 downto 0);
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- === scenario 1: a stall between issue and retirement ===
    -- push pair 1 (2+3=5) for exactly one cycle
    op <= ALU_ADD;
    a_data <= lane_word(TWO); b_data <= lane_word(THREE);
    in_wen <= '1';
    wait until rising_edge(clk);
    in_wen <= '0';

    -- idle cycles with a_fifo/b_fifo empty: lane_ce naturally drops
    -- while pair 1 is mid-pipeline
    for i in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;

    -- push pair 2 (4+5=9) for exactly one cycle
    a_data <= lane_word(FOUR); b_data <= lane_word(FIVE);
    in_wen <= '1';
    wait until rising_edge(clk);
    in_wen <= '0';

    for i in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;

    -- drain the output queue: generic_fifo's rdata is combinational
    -- (always the current front item), so check it BEFORE pulsing ren
    -- to advance past it, not after.
    if out_empty = '1' then
      fails := fails + 1;
      report "FAIL: out_empty before any read (expected pair 1's result queued)" severity error;
    end if;
    if not lane_check(y_data, FIVE) then
      fails := fails + 1;
      report "FAIL: stalled scenario, first result expected 5.0, got " & to_hstring(y_data) severity error;
    end if;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;

    if not lane_check(y_data, NINE) then
      fails := fails + 1;
      report "FAIL: stalled scenario, second result expected 9.0, got " & to_hstring(y_data) severity error;
    end if;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;
    if out_empty /= '1' then
      fails := fails + 1;
      report "FAIL: expected out_empty after draining exactly 2 results (no duplicate/stuck write)" severity error;
    end if;

    -- === scenario 2: back-to-back issue, no stall ===
    op <= ALU_ADD;
    a_data <= lane_word(TWO); b_data <= lane_word(THREE);
    in_wen <= '1';
    wait until rising_edge(clk);
    a_data <= lane_word(FOUR); b_data <= lane_word(FIVE);
    wait until rising_edge(clk);
    in_wen <= '0';
    for i in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;

    if not lane_check(y_data, FIVE) then
      fails := fails + 1;
      report "FAIL: back-to-back first result expected 5.0, got " & to_hstring(y_data) severity error;
    end if;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;

    if not lane_check(y_data, NINE) then
      fails := fails + 1;
      report "FAIL: back-to-back second result expected 9.0, got " & to_hstring(y_data) severity error;
    end if;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;
    if out_empty /= '1' then
      fails := fails + 1;
      report "FAIL: expected out_empty after draining back-to-back results" severity error;
    end if;

    -- === scenario 3: distinct per-lane operands ===
    -- lane i computes (i+1)+(i+1) = 2*(i+1), to catch any lane-index/
    -- slicing mistake a broadcast test can't see
    for i in 0 to LANES-1 loop
      a_data((i+1)*32-1 downto i*32) <= INT_FP(i+1);
      b_data((i+1)*32-1 downto i*32) <= INT_FP(i+1);
    end loop;
    in_wen <= '1';
    wait until rising_edge(clk);
    in_wen <= '0';
    for i in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;

    for i in 0 to LANES-1 loop
      if y_data((i+1)*32-1 downto i*32) /= INT_FP(2*(i+1)) then
        fails := fails + 1;
        report "FAIL: lane " & integer'image(i) & " expected " & to_hstring(INT_FP(2*(i+1))) &
               " got " & to_hstring(y_data((i+1)*32-1 downto i*32)) severity error;
      end if;
    end loop;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;
    if out_empty /= '1' then
      fails := fails + 1;
      report "FAIL: expected out_empty after draining the per-lane test" severity error;
    end if;

    -- === scenario 4: broadcast table load + ALU_LUT ===
    -- load a trivial exp2 table (2 entries) into every lane's
    -- generic_lookup at once, then check every lane independently
    -- evaluates exp2(0) = 1.0 through it
    ld_slot <= "000"; ld_mode <= TAB_FRAC; ld_bits <= to_unsigned(1,4);
    ld_left <= EDGE_CLAMP; ld_right <= EDGE_CLAMP; ld_lo <= (others=>'0'); ld_hi <= (others=>'0');
    ld_en <= '1';
    wait until rising_edge(clk);
    ld_en <= '0';
    ld_addr <= "0000000000"; ld_value <= x"3F800000"; ld_slope <= x"3F3504F3"; ld_we <= '1';
    wait until rising_edge(clk);
    ld_addr <= "0000000001"; ld_value <= x"3FB504F3"; ld_slope <= x"3F3504F3"; ld_we <= '1';
    wait until rising_edge(clk);
    ld_we <= '0';
    wait until rising_edge(clk);

    op <= ALU_LUT; lut_slot <= "000";
    a_data <= (others => '0'); b_data <= (others => '0');
    in_wen <= '1';
    wait until rising_edge(clk);
    in_wen <= '0';
    for i in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;
    if not lane_check(y_data, x"3F800000") then
      fails := fails + 1;
      report "FAIL: broadcast lut exp2(0) expected 1.0 in every lane, got " & to_hstring(y_data) severity error;
    end if;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;
    if out_empty /= '1' then
      fails := fails + 1;
      report "FAIL: expected out_empty after draining the lut test" severity error;
    end if;

    -- === scenario 5: result RAM random-access readback ===
    -- push 3 distinct-valued pairs, then read them back OUT OF ORDER by
    -- address through result_ram -- independent of out_ren/y_fifo,
    -- which is already empty at this point. result_wraddr is a
    -- free-running counter across the whole simulation (it only resets
    -- on rst), so record where it starts rather than assuming 0.
    base_addr := result_wraddr;

    op <= ALU_ADD;
    a_data <= lane_word(INT_FP(1)); b_data <= lane_word(INT_FP(1)); -- -> 2
    in_wen <= '1';
    wait until rising_edge(clk);
    a_data <= lane_word(INT_FP(2)); b_data <= lane_word(INT_FP(2)); -- -> 4
    wait until rising_edge(clk);
    a_data <= lane_word(INT_FP(3)); b_data <= lane_word(INT_FP(3)); -- -> 6
    wait until rising_edge(clk);
    in_wen <= '0';
    for i in 1 to 6 loop
      wait until rising_edge(clk);
    end loop;

    if result_wraddr /= base_addr + 3 then
      fails := fails + 1;
      report "FAIL: result_wraddr expected to advance by 3, got " &
             integer'image(to_integer(result_wraddr)) & " from base " & integer'image(to_integer(base_addr)) severity error;
    end if;

    -- read the third pushed value first (out of order), then the first
    result_addr <= base_addr + 2;
    wait until rising_edge(clk);
    wait for 1 ns;
    if not lane_check(result_data, INT_FP(6)) then
      fails := fails + 1;
      report "FAIL: result_ram[base+2] expected 6.0, got " & to_hstring(result_data) severity error;
    end if;

    result_addr <= base_addr;
    wait until rising_edge(clk);
    wait for 1 ns;
    if not lane_check(result_data, INT_FP(2)) then
      fails := fails + 1;
      report "FAIL: result_ram[base+0] expected 2.0, got " & to_hstring(result_data) severity error;
    end if;

    -- draining y_fifo afterward must be unaffected by the result_ram reads
    if not lane_check(y_data, INT_FP(2)) then
      fails := fails + 1;
      report "FAIL: y_fifo front expected 2.0 after result_ram reads, got " & to_hstring(y_data) severity error;
    end if;
    out_ren <= '1';
    wait until rising_edge(clk);
    out_ren <= '0';
    wait for 1 ns;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
