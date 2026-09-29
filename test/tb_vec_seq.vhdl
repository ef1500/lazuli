library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Integration testbench for vec_seq.vhdl: wires it to a REAL `lazuli`
-- instance (LANES=2) plus three generic_sdp_ram instances standing in
-- for operand A/B memory and destination memory, and drives a genuine
-- 2-level nested walk (count0=3, count1=2, count2=1 -- exercising both
-- the plain "i0 advances" step and the "i0 wraps, i1 advances the
-- checkpoint" step of the address-stepper's odometer logic; see
-- vec_seq.vhdl's header). op=ALU_ADD, so the check is exact integer
-- addition -- no rounding ambiguity to worry about.
--
-- Memory layout (all values small exact integers, encoded to fp32 by
-- this file's own int_to_fp32 helper -- a verification-only conversion,
-- not part of any DUT, same role as tb_generic_lookup.vhdl's to_real32):
--   A_ram address j (j=0..5): lane0 = j+1, lane1 = j+1+100
--   B_ram address 100+j:      lane0 = 10*(j+1), lane1 = 10*(j+1)+1000
-- Descriptor: base_a=0/stride(1,3,0), base_b=100/stride(1,3,0),
--             base_dst=200/stride(1,3,0), count=(3,2,1)
-- Walk order and the RAW address each operand visits:
--   (i1=0,i0=0): a=0   b=100  dst=200
--   (i1=0,i0=1): a=1   b=101  dst=201
--   (i1=0,i0=2): a=2   b=102  dst=202
--   (i1=1,i0=0): a=3   b=103  dst=203   <- i0 wrapped, i1's checkpoint advanced by stride*1=3
--   (i1=1,i0=1): a=4   b=104  dst=204
--   (i1=1,i0=2): a=5   b=105  dst=205
-- Expected dst[200+j], j=0..5: lane0 = (j+1) + 10*(j+1) = 11*(j+1)
--                              lane1 = (j+1+100) + (10*(j+1)+1000) = 11*(j+1) + 1100
entity tb_vec_seq is
end entity;

architecture sim of tb_vec_seq is
  constant LANES    : positive := 2;
  constant ADDR_W    : positive := 8;
  constant STRIDE_W  : positive := 9;
  constant WIDE      : positive := LANES * 32;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  -- vec_seq <-> testbench (descriptor + control)
  signal start : std_logic := '0';
  signal vs_busy, vs_done : std_logic;
  signal op_s : alu_op_t := ALU_ADD;
  signal sub_s : std_logic_vector(2 downto 0) := (others => '0');
  signal cvt_s : cvt_op_t := CVT_I2F;
  signal lut_slot_s : unsigned(2 downto 0) := (others => '0');
  signal base_a, base_b, base_dst : unsigned(ADDR_W - 1 downto 0) := (others => '0');
  signal sa0, sa1, sa2, sb0, sb1, sb2, sd0, sd1, sd2 : signed(STRIDE_W - 1 downto 0) := (others => '0');
  signal count0, count1, count2 : unsigned(15 downto 0) := (others => '0');

  -- vec_seq <-> lazuli
  signal lz_op : alu_op_t;
  signal lz_sub : std_logic_vector(2 downto 0);
  signal lz_cvt : cvt_op_t;
  signal lz_lut_slot : unsigned(2 downto 0);
  signal lz_a_data, lz_b_data : std_logic_vector(WIDE - 1 downto 0);
  signal lz_in_wen, lz_in_full : std_logic;
  signal lz_y_data : std_logic_vector(WIDE - 1 downto 0);
  signal lz_flag_data : std_logic_vector(LANES * 2 - 1 downto 0);
  signal lz_out_ren, lz_out_empty : std_logic;

  -- vec_seq <-> A/B/DST memories
  signal a_re : std_logic; signal a_raddr : unsigned(ADDR_W - 1 downto 0); signal a_rdata : std_logic_vector(WIDE - 1 downto 0);
  signal b_re : std_logic; signal b_raddr : unsigned(ADDR_W - 1 downto 0); signal b_rdata : std_logic_vector(WIDE - 1 downto 0);
  signal dst_we : std_logic; signal dst_waddr : unsigned(ADDR_W - 1 downto 0); signal dst_wdata : std_logic_vector(WIDE - 1 downto 0);

  -- testbench's own readback port into dst_ram (separate from vec_seq's write side)
  signal dst_re : std_logic := '0';
  signal dst_raddr : unsigned(ADDR_W - 1 downto 0) := (others => '0');
  signal dst_rdata : std_logic_vector(WIDE - 1 downto 0);

  -- testbench's own write port into a_ram/b_ram (to preload test data)
  signal pre_we : std_logic := '0';
  signal pre_waddr : unsigned(ADDR_W - 1 downto 0) := (others => '0');
  signal pre_wdata : std_logic_vector(WIDE - 1 downto 0) := (others => '0');
  signal pre_target_a : std_logic := '1'; -- '1' = writing into a_ram this cycle, '0' = b_ram

  signal a_we_mux, b_we_mux : std_logic;

  -- unused lazuli table-load ports (op under test is ALU_ADD, no lookup needed)
  constant LD0 : std_logic := '0';

  function int_to_fp32(n : integer) return std_logic_vector is
    variable un   : unsigned(30 downto 0);
    variable lead : natural := 0;
    variable msb  : integer;
    variable mant : unsigned(22 downto 0);
  begin
    if n = 0 then
      return (31 downto 0 => '0');
    end if;
    un := to_unsigned(n, 31);
    while (lead < 30) and (un(30 - lead) = '0') loop
      lead := lead + 1;
    end loop;
    msb := 30 - lead;
    if msb >= 23 then
      mant := un(msb - 1 downto msb - 23);
    else
      mant := shift_left(resize(un(msb - 1 downto 0), 23), 23 - msb);
    end if;
    return '0' & std_logic_vector(to_unsigned(msb + 127, 8)) & std_logic_vector(mant);
  end function int_to_fp32;

  function to_int(v : std_logic_vector(31 downto 0)) return integer is
    variable e : integer;
    variable m : unsigned(23 downto 0);
  begin
    if v(30 downto 23) = "00000000" then
      return 0;
    end if;
    e := to_integer(unsigned(v(30 downto 23))) - 127;
    m := '1' & unsigned(v(22 downto 0));
    -- all test values here are small non-negative integers with no
    -- fractional part, so e >= 23 - lead is never needed below 0
    return to_integer(shift_right(m, 23 - e));
  end function to_int;
begin

  dut : entity work.vec_seq
    generic map (LANES => LANES, ADDR_W => ADDR_W, STRIDE_W => STRIDE_W)
    port map (
      clk => clk, rst => rst, start => start,
      op => op_s, sub => sub_s, cvt => cvt_s, lut_slot => lut_slot_s,
      base_a => base_a, base_b => base_b, base_dst => base_dst,
      stride_a0 => sa0, stride_a1 => sa1, stride_a2 => sa2,
      stride_b0 => sb0, stride_b1 => sb1, stride_b2 => sb2,
      stride_d0 => sd0, stride_d1 => sd1, stride_d2 => sd2,
      count0 => count0, count1 => count1, count2 => count2,
      busy => vs_busy, done => vs_done,
      lz_op => lz_op, lz_sub => lz_sub, lz_cvt => lz_cvt, lz_lut_slot => lz_lut_slot,
      lz_a_data => lz_a_data, lz_b_data => lz_b_data, lz_in_wen => lz_in_wen, lz_in_full => lz_in_full,
      lz_y_data => lz_y_data, lz_flag_data => lz_flag_data, lz_out_ren => lz_out_ren, lz_out_empty => lz_out_empty,
      a_re => a_re, a_raddr => a_raddr, a_rdata => a_rdata,
      b_re => b_re, b_raddr => b_raddr, b_rdata => b_rdata,
      dst_we => dst_we, dst_waddr => dst_waddr, dst_wdata => dst_wdata
    );

  lz : entity work.lazuli
    generic map (LANES => LANES, QDEPTH => 4, RDEPTH => 8)
    port map (
      clk => clk, rst => rst,
      op => lz_op, sub => lz_sub, cvt => lz_cvt, lut_slot => lz_lut_slot,
      a_data => lz_a_data, b_data => lz_b_data, in_wen => lz_in_wen, in_full => lz_in_full,
      y_data => lz_y_data, flag_data => lz_flag_data, out_ren => lz_out_ren, out_empty => lz_out_empty,
      result_addr => (clog2(8) - 1 downto 0 => '0'), result_data => open, result_wraddr => open,
      ld_en => LD0, ld_slot => "000", ld_mode => TAB_RANGE,
      ld_lo => (others => '0'), ld_hi => (others => '0'),
      ld_left => EDGE_CLAMP, ld_right => EDGE_CLAMP, ld_bits => "0001",
      ld_addr => (others => '0'), ld_value => (others => '0'), ld_slope => (others => '0'), ld_we => LD0
    );

  a_we_mux <= pre_we and pre_target_a;
  b_we_mux <= pre_we and not pre_target_a;

  a_ram : entity work.generic_sdp_ram
    generic map (WIDTH => WIDE, DEPTH => 2 ** ADDR_W)
    port map (clk => clk, we => a_we_mux, waddr => pre_waddr, wdata => pre_wdata,
              re => a_re, raddr => a_raddr, rdata => a_rdata);

  b_ram : entity work.generic_sdp_ram
    generic map (WIDTH => WIDE, DEPTH => 2 ** ADDR_W)
    port map (clk => clk, we => b_we_mux, waddr => pre_waddr, wdata => pre_wdata,
              re => b_re, raddr => b_raddr, rdata => b_rdata);

  dst_ram : entity work.generic_sdp_ram
    generic map (WIDTH => WIDE, DEPTH => 2 ** ADDR_W)
    port map (clk => clk, we => dst_we, waddr => dst_waddr, wdata => dst_wdata,
              re => dst_re, raddr => dst_raddr, rdata => dst_rdata);

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;
    variable iters : integer;
    variable got0, got1, exp0, exp1 : integer;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- preload A_ram[0..5] and B_ram[0..5] (B's real addresses are 100+j,
    -- but this loop writes B_ram at plain j -- see the offset below)
    pre_target_a <= '1';
    for j in 0 to 5 loop
      pre_waddr <= to_unsigned(j, ADDR_W);
      pre_wdata <= int_to_fp32(j + 1 + 100) & int_to_fp32(j + 1); -- lane1 & lane0
      pre_we <= '1';
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    pre_we <= '0';

    pre_target_a <= '0';
    for j in 0 to 5 loop
      pre_waddr <= to_unsigned(100 + j, ADDR_W);
      pre_wdata <= int_to_fp32(10 * (j + 1) + 1000) & int_to_fp32(10 * (j + 1)); -- lane1 & lane0
      pre_we <= '1';
      wait until rising_edge(clk); wait for 1 ns;
    end loop;
    pre_we <= '0';

    -- descriptor: 2-level nested walk (count0=3, count1=2, count2=1)
    op_s <= ALU_ADD; sub_s <= (others => '0');
    base_a <= to_unsigned(0, ADDR_W);
    base_b <= to_unsigned(100, ADDR_W);
    base_dst <= to_unsigned(200, ADDR_W);
    sa0 <= to_signed(1, STRIDE_W); sa1 <= to_signed(3, STRIDE_W); sa2 <= to_signed(0, STRIDE_W);
    sb0 <= to_signed(1, STRIDE_W); sb1 <= to_signed(3, STRIDE_W); sb2 <= to_signed(0, STRIDE_W);
    sd0 <= to_signed(1, STRIDE_W); sd1 <= to_signed(3, STRIDE_W); sd2 <= to_signed(0, STRIDE_W);
    count0 <= to_unsigned(3, 16); count1 <= to_unsigned(2, 16); count2 <= to_unsigned(1, 16);

    start <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    start <= '0';

    iters := 0;
    while vs_done /= '1' and iters < 500 loop
      wait until rising_edge(clk); wait for 1 ns;
      iters := iters + 1;
    end loop;

    if vs_done /= '1' then
      fails := fails + 1;
      report "FAIL: vec_seq never signalled done within 500 cycles" severity error;
    end if;

    wait until rising_edge(clk); wait for 1 ns; -- let busy settle
    if vs_busy /= '0' then
      fails := fails + 1;
      report "FAIL: busy still high after done" severity error;
    end if;

    -- read back dst_ram[200..205] and check against the hand-derived table
    for j in 0 to 5 loop
      dst_re <= '1';
      dst_raddr <= to_unsigned(200 + j, ADDR_W);
      wait until rising_edge(clk); wait for 1 ns;
      dst_re <= '0';

      got0 := to_int(dst_rdata(31 downto 0));
      got1 := to_int(dst_rdata(63 downto 32));
      exp0 := 11 * (j + 1);
      exp1 := 11 * (j + 1) + 1100;

      if got0 /= exp0 then
        fails := fails + 1;
        report "FAIL dst[" & integer'image(200 + j) & "] lane0 expect=" & integer'image(exp0) &
               " got=" & integer'image(got0) severity error;
      end if;
      if got1 /= exp1 then
        fails := fails + 1;
        report "FAIL dst[" & integer'image(200 + j) & "] lane1 expect=" & integer'image(exp1) &
               " got=" & integer'image(got1) severity error;
      end if;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
