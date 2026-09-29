library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for pv_lanes.vhdl. DIM=2, NUM_Q=2 -- small
-- enough to hand-run two chunks' worth of P.V accumulate-then-fold,
-- exercising seq_first='1' (chunk 1, no rescale) and seq_first='0'
-- (chunk 2, a real per-query rescale: 2.0 for query 0, 0.5 for query 1).
-- Every value chosen is an exact binary integer (p_q15 values are all
-- themselves powers of two, so p*v products, chunk sums, and the fold's
-- rescale-by-power-of-two are all exact in fp32 -- no rounding anywhere
-- in this reference).
entity tb_pv_lanes is
end entity;

architecture sim of tb_pv_lanes is
  constant DIM   : positive := 2;
  constant NUM_Q : positive := 2;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  signal seq_first : std_logic := '0';

  signal acc_valid : std_logic := '0';
  signal acc_query : unsigned(0 downto 0) := (others => '0');
  signal acc_p_q15 : std_logic_vector(15 downto 0) := (others => '0');
  signal v_vec      : std_logic_vector(DIM * 8 - 1 downto 0) := (others => '0');

  signal chunk_end, chunk_done : std_logic := '0';
  signal rescale_in : std_logic_vector(NUM_Q * 32 - 1 downto 0) := (others => '0');

  signal o_acc : std_logic_vector(NUM_Q * DIM * 32 - 1 downto 0);

  function byte(v : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(v, 8));
  end function;

  -- exact fp32 encode for any integer with |v| < 2**24 (every value used
  -- in this testbench is well inside that range) -- testbench-only
  -- verification helper, same role as tb_vec_seq.vhdl's own local
  -- int_to_fp32 function.
  function int_to_fp32(v : integer) return std_logic_vector is
    variable sign : std_logic;
    variable mag  : natural;
    variable exp  : natural;
    variable mant : natural;
  begin
    if v = 0 then
      return (31 downto 0 => '0');
    end if;
    if v < 0 then
      sign := '1'; mag := -v;
    else
      sign := '0'; mag := v;
    end if;
    exp := 0;
    while mag >= 2 ** (exp + 1) loop
      exp := exp + 1;
    end loop;
    mant := (mag - 2 ** exp) * (2 ** (23 - exp));
    return sign & std_logic_vector(to_unsigned(exp + 127, 8)) & std_logic_vector(to_unsigned(mant, 23));
  end function;
begin

  dut : entity work.pv_lanes
    generic map (DIM => DIM, NUM_Q => NUM_Q)
    port map (
      clk => clk, rst => rst, seq_first => seq_first,
      acc_valid => acc_valid, acc_query => acc_query, acc_p_q15 => acc_p_q15, v_vec => v_vec,
      chunk_end => chunk_end, rescale_in => rescale_in, chunk_done => chunk_done,
      o_acc => o_acc
    );

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

    procedure wait_pulse(signal sig : std_logic) is
    begin
      loop
        wait until rising_edge(clk);
        wait for 1 ns;
        exit when sig = '1';
      end loop;
    end procedure;

    procedure pulse(q : natural; p : natural; v0, v1 : integer) is
    begin
      acc_query <= to_unsigned(q, 1);
      acc_p_q15 <= std_logic_vector(to_unsigned(p, 16));
      v_vec     <= byte(v1) & byte(v0);
      acc_valid <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      acc_valid <= '0';
    end procedure;

    procedure check_o(q, d : natural; expect : integer; msg : string) is
      variable got : std_logic_vector(31 downto 0);
      variable exp_v : std_logic_vector(31 downto 0);
    begin
      got   := o_acc((q * DIM + d + 1) * 32 - 1 downto (q * DIM + d) * 32);
      exp_v := int_to_fp32(expect);
      check(got = exp_v, msg & " (got 0x" & to_hstring(got) & ", expected 0x" & to_hstring(exp_v) & ")");
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    ----------------------------------------------------------------
    -- chunk 1 (seq_first='1')
    ----------------------------------------------------------------
    seq_first <= '1';

    pulse(0, 8192,  2, -3);  -- q0: 8192*2=16384, 8192*-3=-24576
    pulse(0, 32768, 1, 4);   -- q0: 32768*1=32768, 32768*4=131072
    pulse(1, 1024,  5, 1);   -- q1: 1024*5=5120,   1024*1=1024
    pulse(1, 32768, 2, -1);  -- q1: 32768*2=65536, 32768*-1=-32768

    rescale_in(31 downto 0)  <= x"3F800000"; -- unused this chunk (seq_first='1')
    rescale_in(63 downto 32) <= x"3F800000";
    chunk_end <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    chunk_end <= '0';
    wait_pulse(chunk_done);

    check_o(0, 0, 16384 + 32768,  "chunk1 o[q0][d0]"); -- 49152
    check_o(0, 1, -24576 + 131072, "chunk1 o[q0][d1]"); -- 106496
    check_o(1, 0, 5120 + 65536,   "chunk1 o[q1][d0]");  -- 70656
    check_o(1, 1, 1024 - 32768,   "chunk1 o[q1][d1]");  -- -31744

    ----------------------------------------------------------------
    -- chunk 2 (seq_first='0'): rescale q0 by 2.0, q1 by 0.5
    ----------------------------------------------------------------
    seq_first <= '0';

    pulse(0, 16384, 1, 1);   -- q0: 16384*1=16384, 16384*1=16384
    pulse(0, 4096,  8, 0);   -- q0: 4096*8=32768,  4096*0=0
    pulse(1, 32768, 3, 3);   -- q1: 32768*3=98304, 32768*3=98304
    pulse(1, 256,   10, -10);-- q1: 256*10=2560,   256*-10=-2560

    rescale_in(31 downto 0)  <= x"40000000"; -- 2.0
    rescale_in(63 downto 32) <= x"3F000000"; -- 0.5
    chunk_end <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    chunk_end <= '0';
    wait_pulse(chunk_done);

    -- o_old[q0][d0]=49152 -> *2.0 + (16384+32768=49152) = 98304+49152=147456
    check_o(0, 0, 147456, "chunk2 o[q0][d0]");
    -- o_old[q0][d1]=106496 -> *2.0 + (16384+0=16384) = 212992+16384=229376
    check_o(0, 1, 229376, "chunk2 o[q0][d1]");
    -- o_old[q1][d0]=70656 -> *0.5 + (98304+2560=100864) = 35328+100864=136192
    check_o(1, 0, 136192, "chunk2 o[q1][d0]");
    -- o_old[q1][d1]=-31744 -> *0.5 + (98304-2560=95744) = -15872+95744=79872
    check_o(1, 1, 79872, "chunk2 o[q1][d1]");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
