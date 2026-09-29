library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for pe_column.vhdl (architecture "behav").
--
-- pe_column has no act_skew of its own (that's a separate, not-yet-
-- built entity applied upstream by sys_array) -- its 16 rows' x_in
-- lanes are independent ports, each expected to carry the SAME agent's
-- element r, r cycles after row 0's, once act_skew is in the picture.
-- To test the P cascade in isolation without needing that skew, this
-- testbench instead HOLDS x_in and the loaded weights constant for at
-- least 16 consecutive ce=1 cycles: with no new agent arriving to
-- compete for the pipeline, the partial sum only needs to finish
-- rippling from row 0 to row 15 (one row per ce cycle, since every
-- row's p register reads its p_in -- the row above's registered p_out
-- -- as it stood BEFORE the current edge), and the final value is
-- exactly Sigma_r (w1_r + w2_r*2**SPACING) * x_r, a fully general check
-- of both the cascade wiring (row r's sum correctly adds atop row
-- r-1's) and the per-row weight/activation lane wiring.
entity tb_pe_column is
end entity;

architecture sim of tb_pe_column is
  constant A_PORT_W : positive := 27;
  constant ACC_W     : positive := 48;
  constant WEIGHT_W  : positive := 6;
  constant SPACING   : positive := 17;
  constant ROWS      : positive := 16;

  signal clk, ce : std_logic := '0';
  signal x_in    : std_logic_vector(ROWS * 8 - 1 downto 0) := (others => '0');
  signal x_out   : std_logic_vector(ROWS * 8 - 1 downto 0);
  signal w1_next, w2_next : std_logic_vector(ROWS * WEIGHT_W - 1 downto 0) := (others => '0');
  signal first_in, last_in   : std_logic_vector(ROWS - 1 downto 0) := (others => '0');
  signal first_out, last_out : std_logic_vector(ROWS - 1 downto 0);
  signal p_out : signed(ACC_W - 1 downto 0);
  signal done  : boolean := false;
begin

  dut : entity work.pe_column(behav)
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
    port map (
      clk => clk, ce => ce,
      x_in => x_in, x_out => x_out,
      w1_next => w1_next, w2_next => w2_next,
      first_in => first_in, first_out => first_out,
      last_in => last_in, last_out => last_out,
      p_out => p_out
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails  : integer := 0;
    variable expect : integer;
    variable a_word, xr : integer;

    -- Loads w1_r/w2_r (r = 0..ROWS-1) into every row via first_in (all
    -- rows pulsed together, one cycle), then drives x_r into every row
    -- and holds it for ROWS consecutive ce=1 cycles so the cascade can
    -- fully drain, checking p_out against the directly-computed sum.
    procedure check_column(
      constant w1r, w2r, xr_arr : integer_vector(0 to ROWS - 1);
      tag : string
    ) is
    begin
      for r in 0 to ROWS - 1 loop
        w1_next((r + 1) * WEIGHT_W - 1 downto r * WEIGHT_W) <= std_logic_vector(to_signed(w1r(r), WEIGHT_W));
        w2_next((r + 1) * WEIGHT_W - 1 downto r * WEIGHT_W) <= std_logic_vector(to_signed(w2r(r), WEIGHT_W));
      end loop;
      first_in <= (others => '1');
      last_in  <= (others => '0');
      ce       <= '0';
      wait until rising_edge(clk); wait for 1 ns;

      first_in <= (others => '0');
      for r in 0 to ROWS - 1 loop
        x_in((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(to_signed(xr_arr(r), 8));
      end loop;
      ce <= '1';

      for cyc in 0 to ROWS - 1 loop
        wait until rising_edge(clk); wait for 1 ns;
      end loop;

      expect := 0;
      for r in 0 to ROWS - 1 loop
        a_word := w1r(r) + w2r(r) * (2 ** SPACING);
        expect := expect + a_word * xr_arr(r);
      end loop;

      if to_integer(p_out) /= expect then
        fails := fails + 1;
        report "FAIL " & tag & " expect=" & integer'image(expect) &
               " got=" & integer'image(to_integer(p_out)) severity error;
      end if;

      ce <= '0';
      wait until rising_edge(clk); wait for 1 ns;
    end procedure;

    variable w1a, w2a, xa : integer_vector(0 to ROWS - 1);
  begin
    -- pattern 1: w1_r = r+1, w2_r = 0, x_r = 1 for every row
    for r in 0 to ROWS - 1 loop
      w1a(r) := r + 1; w2a(r) := 0; xa(r) := 1;
    end loop;
    check_column(w1a, w2a, xa, "pattern1");

    -- pattern 2: w1_r = r+1, w2_r = 0, x_r = r+1 (varies both sides per row)
    for r in 0 to ROWS - 1 loop
      w1a(r) := r + 1; w2a(r) := 0; xa(r) := r + 1;
    end loop;
    check_column(w1a, w2a, xa, "pattern2");

    -- pattern 3: exercise the w2 (second packed) lane too, uniform across rows
    for r in 0 to ROWS - 1 loop
      w1a(r) := 1; w2a(r) := 2; xa(r) := 3;
    end loop;
    check_column(w1a, w2a, xa, "pattern3");

    -- per-row x_in -> x_out and first_in/last_in -> first_out/last_out:
    -- these are just pe_cell's own already-tested registers, exposed
    -- per row -- a light integration check, not exhaustive.
    x_in <= (others => '0');
    for r in 0 to ROWS - 1 loop
      x_in((r + 1) * 8 - 1 downto r * 8) <= std_logic_vector(to_signed(r, 8));
    end loop;
    first_in <= x"AAAA";
    last_in  <= x"5555";
    ce <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    ce <= '0';

    for r in 0 to ROWS - 1 loop
      if to_integer(signed(x_out((r + 1) * 8 - 1 downto r * 8))) /= r then
        fails := fails + 1;
        report "FAIL x_out passthrough row " & integer'image(r) severity error;
      end if;
    end loop;
    if first_out /= x"AAAA" or last_out /= x"5555" then
      fails := fails + 1;
      report "FAIL first_out/last_out passthrough" severity error;
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
