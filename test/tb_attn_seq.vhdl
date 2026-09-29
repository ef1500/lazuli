library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Integration testbench for attn_seq.vhdl: wires attn_seq plus REAL
-- instances of kv_reader/qk_lanes/softmax_online/pv_lanes/attn_finish
-- (plus a run-buffer RAM standing in for kv_dma, see kv_reader.vhdl's
-- own header) together exactly as attn_seq.vhdl's own header says a
-- caller must: the data buses between the five sub-entities are DIRECT
-- wires here (not relayed through attn_seq), and attn_finish's l_in/
-- o_acc_in are muxed by attn_seq's own 'q_idx' output. This is a real
-- proof of the WIRING/sequencing (not a re-check of each entity's own
-- arithmetic, already covered by tb_qk_lanes/tb_kv_reader/tb_softmax_
-- online/tb_pv_lanes/tb_attn_finish), matching tb_vec_seq.vhdl's own
-- role for U12.
--
-- DIM=2, CHUNK=2, NUM_Q=2, one chunk (NUM_CHUNKS=1, so seq_first='1'
-- throughout -- multi-chunk rescale is already proven in isolation by
-- tb_softmax_online.vhdl/tb_pv_lanes.vhdl). q0=[1,0], q1=[0,1] (one-hot,
-- so each query's score is just one component of K); K0=[4,7], K1=[4,8]
-- (shared); V0=V1=[8,4] (shared). This makes q0 see EQUAL scores at
-- both tokens (score=4,4 -> p=[1.0,1.0], l=2.0, an exact power of two,
-- so attn_finish's degenerate-table recip(l) is EXACT) while q1 sees
-- DIFFERENT scores (7,8 -> p=[0.5,1.0], l=1.5, NOT a power of two, so
-- its recip is the degenerate table's floor-based approximation, not
-- the true reciprocal -- deliberately exercising both the clean and the
-- approximate path, and q1's resulting amax (393216 = 1.5*2**18) is
-- ALSO not a power of two, causing q1's first quantized element to
-- exceed +127 and clamp -- see the full derivation this testbench was
-- written from for every intermediate value.
entity tb_attn_seq is
end entity;

architecture sim of tb_attn_seq is
  constant DIM   : positive := 2;
  constant CHUNK : positive := 2;
  constant NUM_Q : positive := 2;
  constant SCORE_W : positive := 17; -- 16 + clog2(2)

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  -- attn_seq top-level
  signal seq_start, seq_busy, seq_done : std_logic := '0';
  signal num_chunks : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(1, 16));
  signal q_idx : unsigned(0 downto 0);
  signal out_valid : std_logic;

  -- kv_reader
  signal kv_start, kv_busy, kv_done : std_logic;
  signal kv_tok_valid, kv_tok_is_v, kv_tok_last, kv_tok_ack : std_logic;
  signal kv_tok_idx : unsigned(0 downto 0);
  signal kv_tok_data : std_logic_vector(DIM * 8 - 1 downto 0);
  signal run_re : std_logic;
  signal run_raddr : unsigned(1 downto 0); -- clog2(2*CHUNK)=clog2(4)=2
  signal run_rdata : std_logic_vector(DIM * 8 - 1 downto 0);

  -- qk_lanes
  signal qk_ce : std_logic;
  signal q_vec : std_logic_vector(NUM_Q * DIM * 8 - 1 downto 0);
  signal qk_score : std_logic_vector(NUM_Q * SCORE_W - 1 downto 0);

  -- softmax_online
  signal sm_seq_first, sm_k_start, sm_k_last_tok, sm_k_done : std_logic;
  signal sm_v_start, sm_v_done : std_logic;
  signal sm_k_tok_idx, sm_v_tok_idx : unsigned(0 downto 0);
  signal sm_p_valid : std_logic;
  signal sm_p_query : unsigned(0 downto 0);
  signal sm_p_q15 : std_logic_vector(15 downto 0);
  signal sm_rescale_out, sm_l_out : std_logic_vector(NUM_Q * 32 - 1 downto 0);

  -- pv_lanes
  signal pv_seq_first, pv_chunk_end, pv_chunk_done : std_logic;
  signal pv_o_acc : std_logic_vector(NUM_Q * DIM * 32 - 1 downto 0);

  -- attn_finish
  signal af_start, af_busy, af_done : std_logic;
  signal af_l_in : std_logic_vector(31 downto 0);
  signal af_o_acc_in : std_logic_vector(DIM * 32 - 1 downto 0);
  signal af_q_out : std_logic_vector(DIM * 8 - 1 downto 0);
  signal af_scale_out : std_logic_vector(31 downto 0);

  -- softmax_online's exp2 table load (slot 0)
  signal sm_ld_en, sm_ld_we : std_logic := '0';
  signal sm_ld_slot : unsigned(2 downto 0) := (others => '0');
  signal sm_ld_mode : tab_mode_t := TAB_FRAC;
  signal sm_ld_lo, sm_ld_hi : std_logic_vector(31 downto 0) := (others => '0');
  signal sm_ld_left, sm_ld_right : tab_edge_t := EDGE_CLAMP;
  signal sm_ld_bits : unsigned(3 downto 0) := (others => '0');
  signal sm_ld_addr : unsigned(9 downto 0) := (others => '0');
  signal sm_ld_value, sm_ld_slope : std_logic_vector(31 downto 0) := (others => '0');

  -- attn_finish's recip table load (slot 0, broadcast to its internal act_quantizer too)
  signal af_ld_en, af_ld_we : std_logic := '0';
  signal af_ld_slot : unsigned(2 downto 0) := (others => '0');
  signal af_ld_mode : tab_mode_t := TAB_MANT;
  signal af_ld_lo, af_ld_hi : std_logic_vector(31 downto 0) := (others => '0');
  signal af_ld_left, af_ld_right : tab_edge_t := EDGE_CLAMP;
  signal af_ld_bits : unsigned(3 downto 0) := (others => '0');
  signal af_ld_addr : unsigned(9 downto 0) := (others => '0');
  signal af_ld_value, af_ld_slope : std_logic_vector(31 downto 0) := (others => '0');

  constant ONE_FP32 : std_logic_vector(31 downto 0) := x"3F800000";

  type ram_t is array (0 to 3) of std_logic_vector(DIM * 8 - 1 downto 0);
  signal ram : ram_t;

  function byte(v : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(v, 8));
  end function;

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

  -- run buffer: addr 0,1 = K0,K1; addr 2,3 = V0,V1
  ram(0) <= byte(7) & byte(4); -- K0 = [4,7]
  ram(1) <= byte(8) & byte(4); -- K1 = [4,8]
  ram(2) <= byte(4) & byte(8); -- V0 = [8,4]
  ram(3) <= byte(4) & byte(8); -- V1 = [8,4]

  ram_read : process (clk)
  begin
    if rising_edge(clk) then
      if run_re = '1' then
        run_rdata <= ram(to_integer(run_raddr));
      end if;
    end if;
  end process;

  -- q0 = [1,0] (lower NUM_Q slot, per qk_lanes.vhdl's (q+1)*DIM*8-1
  -- downto q*DIM*8 packing), q1 = [0,1] (upper slot). Within one query's
  -- own DIM*8-bit slice, d0 is the LOW byte: q0 -> byte(d1=0)&byte(d0=1),
  -- q1 -> byte(d1=1)&byte(d0=0).
  q_vec <= (byte(1) & byte(0)) & (byte(0) & byte(1));

  seq : entity work.attn_seq
    generic map (CHUNK => CHUNK, NUM_Q => NUM_Q, CNT_W => 16)
    port map (
      clk => clk, rst => rst, start => seq_start, num_chunks => num_chunks,
      busy => seq_busy, done => seq_done,
      kv_start => kv_start, kv_done => kv_done,
      kv_tok_valid => kv_tok_valid, kv_tok_is_v => kv_tok_is_v, kv_tok_idx => kv_tok_idx,
      kv_tok_last => kv_tok_last, kv_tok_ack => kv_tok_ack,
      qk_ce => qk_ce,
      sm_seq_first => sm_seq_first, sm_k_start => sm_k_start, sm_k_tok_idx => sm_k_tok_idx,
      sm_k_last_tok => sm_k_last_tok, sm_k_done => sm_k_done,
      sm_v_start => sm_v_start, sm_v_tok_idx => sm_v_tok_idx, sm_v_done => sm_v_done,
      pv_seq_first => pv_seq_first, pv_chunk_end => pv_chunk_end, pv_chunk_done => pv_chunk_done,
      af_start => af_start, af_done => af_done,
      q_idx => q_idx, out_valid => out_valid
    );

  kv : entity work.kv_reader
    generic map (DIM => DIM, CHUNK => CHUNK)
    port map (
      clk => clk, rst => rst, start => kv_start, busy => kv_busy, done => kv_done,
      run_re => run_re, run_raddr => run_raddr, run_rdata => run_rdata,
      tok_valid => kv_tok_valid, tok_is_v => kv_tok_is_v, tok_idx => kv_tok_idx,
      tok_last => kv_tok_last, tok_data => kv_tok_data, tok_ack => kv_tok_ack
    );

  qk : entity work.qk_lanes
    generic map (DIM => DIM, NUM_Q => NUM_Q)
    port map (clk => clk, ce => qk_ce, k_vec => kv_tok_data, q_vec => q_vec, score => qk_score);

  sm : entity work.softmax_online
    generic map (CHUNK => CHUNK, NUM_Q => NUM_Q, SCORE_W => SCORE_W, LUT_SLOT => 0)
    port map (
      clk => clk, rst => rst, seq_first => sm_seq_first,
      k_start => sm_k_start, k_tok_idx => sm_k_tok_idx, k_score => qk_score,
      k_last_tok => sm_k_last_tok, k_done => sm_k_done,
      v_start => sm_v_start, v_tok_idx => sm_v_tok_idx, v_done => sm_v_done,
      p_valid => sm_p_valid, p_query => sm_p_query, p_q15 => sm_p_q15,
      rescale_out => sm_rescale_out, l_out => sm_l_out,
      ld_en => sm_ld_en, ld_slot => sm_ld_slot, ld_mode => sm_ld_mode,
      ld_lo => sm_ld_lo, ld_hi => sm_ld_hi, ld_left => sm_ld_left, ld_right => sm_ld_right,
      ld_bits => sm_ld_bits, ld_addr => sm_ld_addr, ld_value => sm_ld_value, ld_slope => sm_ld_slope,
      ld_we => sm_ld_we
    );

  pv : entity work.pv_lanes
    generic map (DIM => DIM, NUM_Q => NUM_Q)
    port map (
      clk => clk, rst => rst, seq_first => pv_seq_first,
      acc_valid => sm_p_valid, acc_query => sm_p_query, acc_p_q15 => sm_p_q15, v_vec => kv_tok_data,
      chunk_end => pv_chunk_end, rescale_in => sm_rescale_out, chunk_done => pv_chunk_done,
      o_acc => pv_o_acc
    );

  af_l_in     <= sm_l_out(31 downto 0)  when to_integer(q_idx) = 0 else sm_l_out(63 downto 32);
  af_o_acc_in <= pv_o_acc(DIM * 32 - 1 downto 0) when to_integer(q_idx) = 0 else
                 pv_o_acc(2 * DIM * 32 - 1 downto DIM * 32);

  af : entity work.attn_finish
    generic map (DIM => DIM, RECIP_SLOT => 0)
    port map (
      clk => clk, rst => rst, start => af_start, l_in => af_l_in, o_acc_in => af_o_acc_in,
      busy => af_busy, done => af_done, q_out => af_q_out, scale_out => af_scale_out,
      ld_en => af_ld_en, ld_slot => af_ld_slot, ld_mode => af_ld_mode,
      ld_lo => af_ld_lo, ld_hi => af_ld_hi, ld_left => af_ld_left, ld_right => af_ld_right,
      ld_bits => af_ld_bits, ld_addr => af_ld_addr, ld_value => af_ld_value, ld_slope => af_ld_slope,
      ld_we => af_ld_we
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

    procedure check_fp32(got, expect : std_logic_vector; msg : string) is
    begin
      check(got = expect, msg & " (got 0x" & to_hstring(got) & ", expected 0x" & to_hstring(expect) & ")");
    end procedure;

    procedure check_q(got : std_logic_vector; d : natural; expect : integer; msg : string) is
      variable v : integer;
    begin
      v := to_integer(signed(got((d + 1) * 8 - 1 downto d * 8)));
      check(v = expect, msg & " (got " & integer'image(v) & ", expected " & integer'image(expect) & ")");
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- load softmax_online's degenerate TAB_FRAC table (slot 0)
    sm_ld_slot <= to_unsigned(0, 3);
    sm_ld_mode <= TAB_FRAC;
    sm_ld_bits <= to_unsigned(1, 4);
    sm_ld_en   <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    sm_ld_en <= '0';
    sm_ld_slot <= to_unsigned(0, 3);
    sm_ld_addr <= to_unsigned(0, 10);
    sm_ld_value <= ONE_FP32; sm_ld_slope <= (others => '0'); sm_ld_we <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    sm_ld_addr <= to_unsigned(1, 10);
    wait until rising_edge(clk); wait for 1 ns;
    sm_ld_we <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    -- load attn_finish's degenerate TAB_MANT table (slot 0, also reaches
    -- its internal act_quantizer)
    af_ld_slot <= to_unsigned(0, 3);
    af_ld_mode <= TAB_MANT;
    af_ld_bits <= to_unsigned(1, 4);
    af_ld_en   <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    af_ld_en <= '0';
    af_ld_slot <= to_unsigned(0, 3);
    af_ld_addr <= to_unsigned(0, 10);
    af_ld_value <= ONE_FP32; af_ld_slope <= (others => '0'); af_ld_we <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    af_ld_addr <= to_unsigned(1, 10);
    wait until rising_edge(clk); wait for 1 ns;
    af_ld_we <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    seq_start <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    seq_start <= '0';

    -- query 0's result
    loop
      wait until rising_edge(clk); wait for 1 ns;
      exit when out_valid = '1';
    end loop;
    check(to_integer(q_idx) = 0, "first out_valid should be query 0");
    check_fp32(sm_l_out(31 downto 0), x"40000000", "l[q0] (expect 2.0)");
    check_fp32(pv_o_acc(31 downto 0), int_to_fp32(524288), "o_acc[q0][d0] (expect 524288)");
    check_fp32(pv_o_acc(63 downto 32), int_to_fp32(262144), "o_acc[q0][d1] (expect 262144)");
    check_fp32(af_scale_out, x"45800000", "scale[q0] (expect 4096.0)");
    check_q(af_q_out, 0, 127, "q_out[q0][d0]");
    check_q(af_q_out, 1, 64,  "q_out[q0][d1] (63.5 round-to-even)");

    -- query 1's result
    loop
      wait until rising_edge(clk); wait for 1 ns;
      exit when out_valid = '1';
    end loop;
    check(to_integer(q_idx) = 1, "second out_valid should be query 1");
    check_fp32(sm_l_out(63 downto 32), x"3FC00000", "l[q1] (expect 1.5)");
    check_fp32(pv_o_acc(95 downto 64), int_to_fp32(393216), "o_acc[q1][d0] (expect 393216)");
    check_fp32(pv_o_acc(127 downto 96), int_to_fp32(196608), "o_acc[q1][d1] (expect 196608)");
    check_fp32(af_scale_out, x"45800000", "scale[q1] (expect 4096.0)");
    check_q(af_q_out, 0, 127, "q_out[q1][d0] (190.5 clamped to 127)");
    check_q(af_q_out, 1, 95,  "q_out[q1][d1]");

    loop
      wait until rising_edge(clk); wait for 1 ns;
      exit when seq_done = '1';
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
