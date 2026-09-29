library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for softmax_online.vhdl. CHUNK=2, NUM_Q=2,
-- SCORE_W=8 -- small enough to hand-run the whole online-softmax
-- recurrence (base-2, see the DUT's own header) across TWO chunks of one
-- sequence, exercising both seq_first='1' (no rescale/no m-compare) and
-- seq_first='0' (a real rescale, including query 1's non-trivial 0.5
-- factor) paths, plus the K-then-V two-pass score readback.
--
-- Uses CLAUDE.md practice #17's degenerate mock table: every TAB_FRAC
-- entry loaded as {value=1.0, slope=0}, which collapses generic_lookup's
-- 2^x to EXACTLY 2^floor(x) for any x (traced through generic_lookup.
-- vhdl's own TAB_FRAC code: local_mul(0, frac)=0 zeroes the
-- interpolation term unconditionally, leaving tval=T[idx]=1.0 exactly,
-- then y=exp_shift(1.0, ipart)=2^ipart with ipart=floor(x)) -- every
-- score delta chosen below is an exact integer, so this always lands
-- exactly on that hand-computable function; generic_lookup's own
-- interpolation accuracy is covered separately (tb_generic_lookup.vhdl).
--
-- Reference (query 0 / query 1 raw scores, per chunk):
--   chunk 1: q0 = [3,5], q1 = [1,6]   (seq_first = '1')
--   chunk 2: q0 = [4,2], q1 = [7,0]   (seq_first = '0')
-- Full derivation of every m/l/rescale/p_q15 value below is in the
-- conversation this testbench was written from; every intermediate is
-- an exact sum of powers of two (no fp32 rounding anywhere) so the
-- expected bit patterns are exact, not tolerance-checked.
entity tb_softmax_online is
end entity;

architecture sim of tb_softmax_online is
  constant CHUNK   : positive := 2;
  constant NUM_Q   : positive := 2;
  constant SCORE_W : positive := 8;

  signal clk, rst : std_logic := '0';
  signal done_sim : boolean := false;

  signal seq_first : std_logic := '0';

  signal k_start, k_last_tok, k_done : std_logic := '0';
  signal k_tok_idx : unsigned(0 downto 0) := (others => '0'); -- clog2(2)=1
  signal k_score   : std_logic_vector(NUM_Q * SCORE_W - 1 downto 0) := (others => '0');

  signal v_start, v_done : std_logic := '0';
  signal v_tok_idx : unsigned(0 downto 0) := (others => '0');

  signal p_valid : std_logic;
  signal p_query : unsigned(0 downto 0); -- clog2(2)=1
  signal p_q15   : std_logic_vector(15 downto 0);

  signal rescale_out, l_out : std_logic_vector(NUM_Q * 32 - 1 downto 0);

  signal ld_en, ld_we : std_logic := '0';
  signal ld_slot : unsigned(2 downto 0) := (others => '0');
  signal ld_mode : tab_mode_t := TAB_FRAC;
  signal ld_lo, ld_hi : std_logic_vector(31 downto 0) := (others => '0');
  signal ld_left, ld_right : tab_edge_t := EDGE_CLAMP;
  signal ld_bits : unsigned(3 downto 0) := (others => '0');
  signal ld_addr : unsigned(9 downto 0) := (others => '0');
  signal ld_value, ld_slope : std_logic_vector(31 downto 0) := (others => '0');

  constant ONE_FP32 : std_logic_vector(31 downto 0) := x"3F800000";

  type p_arr_t is array (0 to NUM_Q - 1) of integer;

  function byte(v : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(v, SCORE_W));
  end function;
begin

  dut : entity work.softmax_online
    generic map (CHUNK => CHUNK, NUM_Q => NUM_Q, SCORE_W => SCORE_W, LUT_SLOT => 0)
    port map (
      clk => clk, rst => rst, seq_first => seq_first,
      k_start => k_start, k_tok_idx => k_tok_idx, k_score => k_score, k_last_tok => k_last_tok, k_done => k_done,
      v_start => v_start, v_tok_idx => v_tok_idx, v_done => v_done,
      p_valid => p_valid, p_query => p_query, p_q15 => p_q15,
      rescale_out => rescale_out, l_out => l_out,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right, ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  clk <= not clk after 5 ns when not done_sim else '0';

  process
    variable fails : integer := 0;
    variable captured : p_arr_t;

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

    procedure k_token(idx : natural; s0, s1 : integer; last : std_logic) is
    begin
      k_tok_idx  <= to_unsigned(idx, 1);
      k_score    <= byte(s1) & byte(s0);
      k_last_tok <= last;
      k_start    <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      k_start <= '0';
      wait_pulse(k_done);
    end procedure;

    -- runs one V token, capturing both queries' p_valid/p_q15 pulses
    -- along the way (they land on different cycles within the wait).
    procedure v_token(idx : natural) is
    begin
      captured := (others => -1);
      v_tok_idx <= to_unsigned(idx, 1);
      v_start   <= '1';
      wait until rising_edge(clk); wait for 1 ns;
      v_start <= '0';
      loop
        wait until rising_edge(clk); wait for 1 ns;
        if p_valid = '1' then
          captured(to_integer(p_query)) := to_integer(unsigned(p_q15));
        end if;
        exit when v_done = '1';
      end loop;
    end procedure;

    procedure check_fp32(got, expect : std_logic_vector; msg : string) is
    begin
      check(got = expect, msg & " (got 0x" & to_hstring(got) & ", expected 0x" & to_hstring(expect) & ")");
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    rst <= '0';

    -- load the degenerate 2-entry exp2 table into slot 0 (see header)
    ld_slot <= to_unsigned(0, 3);
    ld_mode <= TAB_FRAC;
    ld_bits <= to_unsigned(1, 4);
    ld_en   <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ld_en <= '0';

    ld_slot  <= to_unsigned(0, 3);
    ld_addr  <= to_unsigned(0, 10);
    ld_value <= ONE_FP32; ld_slope <= (others => '0'); ld_we <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ld_addr <= to_unsigned(1, 10);
    wait until rising_edge(clk); wait for 1 ns;
    ld_we <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    ----------------------------------------------------------------
    -- chunk 1 (seq_first='1'): q0=[3,5], q1=[1,6]
    ----------------------------------------------------------------
    seq_first <= '1';

    k_token(0, 3, 1, '0');
    k_token(1, 5, 6, '1');

    v_token(0);
    check(captured(0) = 8192,  "chunk1 tok0 q0 p_q15 (expect 0.25*32768=8192)");
    check(captured(1) = 1024,  "chunk1 tok0 q1 p_q15 (expect 0.03125*32768=1024)");

    v_token(1);
    check(captured(0) = 32768, "chunk1 tok1 q0 p_q15 (expect 1.0*32768=32768)");
    check(captured(1) = 32768, "chunk1 tok1 q1 p_q15 (expect 1.0*32768=32768)");

    check_fp32(l_out(31 downto 0),  x"3FA00000", "chunk1 l[q0] (expect 1.25)");
    check_fp32(l_out(63 downto 32), x"3F840000", "chunk1 l[q1] (expect 1.03125)");

    ----------------------------------------------------------------
    -- chunk 2 (seq_first='0'): q0=[4,2], q1=[7,0]
    ----------------------------------------------------------------
    seq_first <= '0';

    k_token(0, 4, 7, '0');
    k_token(1, 2, 0, '1');

    check_fp32(rescale_out(31 downto 0),  x"3F800000", "chunk2 rescale[q0] (expect 1.0)");
    check_fp32(rescale_out(63 downto 32), x"3F000000", "chunk2 rescale[q1] (expect 0.5)");

    v_token(0);
    check(captured(0) = 16384, "chunk2 tok0 q0 p_q15 (expect 0.5*32768=16384)");
    check(captured(1) = 32768, "chunk2 tok0 q1 p_q15 (expect 1.0*32768=32768)");

    v_token(1);
    check(captured(0) = 4096,  "chunk2 tok1 q0 p_q15 (expect 0.125*32768=4096)");
    check(captured(1) = 256,   "chunk2 tok1 q1 p_q15 (expect 0.0078125*32768=256)");

    check_fp32(l_out(31 downto 0),  x"3FF00000", "chunk2 final l[q0] (expect 1.875)");
    check_fp32(l_out(63 downto 32), x"3FC30000", "chunk2 final l[q1] (expect 1.5234375)");

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done_sim <= true;
    wait;
  end process;

end architecture sim;
