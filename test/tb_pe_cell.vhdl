library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for pe_cell.vhdl (architecture "behav"; the
-- "xilinx" architecture binds to dsp_mac2(xilinx), which has no UNISIM
-- library in this repo and is analyzed for syntax only). pe_cell is a
-- thin wrapper around two already-exhaustively-tested primitives
-- (dsp_mac2, generic_register), so this testbench checks WIRING, not
-- register semantics or MAC correctness in bulk: that x_in/first_in/
-- last_in register through to x_out/first_out/last_out exactly one
-- clock (held when ce=0, matching generic_register's own already-tested
-- behavior), and that first_in correctly drives dsp_mac2's weight-swap
-- ('first') while ce gates both the register and the MAC together, with
-- a handful of representative multiply-accumulate cases (not the full
-- exhaustive sweep -- that's tb_dsp_mac2.vhdl's job).
entity tb_pe_cell is
end entity;

architecture sim of tb_pe_cell is
  constant A_PORT_W : positive := 27;
  constant ACC_W     : positive := 48;
  constant WEIGHT_W  : positive := 6;
  constant SPACING   : positive := 17;

  signal clk, ce             : std_logic := '0';
  signal x_in                : signed(7 downto 0) := (others => '0');
  signal w1_next, w2_next    : signed(WEIGHT_W - 1 downto 0) := (others => '0');
  signal first_in, last_in   : std_logic := '0';
  signal p_in                : signed(ACC_W - 1 downto 0) := (others => '0');
  signal x_out                : signed(7 downto 0);
  signal first_out, last_out  : std_logic;
  signal p_out                : signed(ACC_W - 1 downto 0);
  signal done : boolean := false;
begin

  dut : entity work.pe_cell(behav)
    generic map (A_PORT_W => A_PORT_W, ACC_W => ACC_W, WEIGHT_W => WEIGHT_W, SPACING => SPACING)
    port map (
      clk => clk, ce => ce, x_in => x_in,
      w1_next => w1_next, w2_next => w2_next,
      first_in => first_in, last_in => last_in, p_in => p_in,
      x_out => x_out, first_out => first_out, last_out => last_out, p_out => p_out
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails  : integer := 0;
    variable a_word, expect : integer;
  begin
    -- x_in/first_in/last_in -> x_out/first_out/last_out, one clock, ce-gated
    x_in <= to_signed(11, 8); first_in <= '1'; last_in <= '0'; ce <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    if x_out /= to_signed(11, 8) or first_out /= '1' or last_out /= '0' then
      fails := fails + 1;
      report "FAIL: step 1 register capture" severity error;
    end if;

    x_in <= to_signed(22, 8); first_in <= '0'; last_in <= '1'; ce <= '1';
    wait until rising_edge(clk); wait for 1 ns;
    if x_out /= to_signed(22, 8) or first_out /= '0' or last_out /= '1' then
      fails := fails + 1;
      report "FAIL: step 2 register capture" severity error;
    end if;

    -- ce=0: must hold step 2's captured values, even though x_in/first_in/
    -- last_in are now presenting different values
    x_in <= to_signed(33, 8); first_in <= '1'; last_in <= '1'; ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;
    if x_out /= to_signed(22, 8) or first_out /= '0' or last_out /= '1' then
      fails := fails + 1;
      report "FAIL: step 3 should hold while ce=0" severity error;
    end if;

    ce <= '1'; -- x_in/first_in/last_in are still 33/1/1 from step 3
    wait until rising_edge(clk); wait for 1 ns;
    if x_out /= to_signed(33, 8) or first_out /= '1' or last_out /= '1' then
      fails := fails + 1;
      report "FAIL: step 4 register capture after ce returns to 1" severity error;
    end if;
    ce <= '0';
    wait until rising_edge(clk); wait for 1 ns;

    -- MAC wiring: first_in loads the weight pair, ce gates the multiply,
    -- p_out = p_in + (w1 + w2*2**SPACING) * x_in -- a handful of
    -- representative cases (dsp_mac2 itself already covers the full
    -- exhaustive sweep).
    for i in 0 to 4 loop
      case i is
        when 0 => w1_next <= to_signed(3, WEIGHT_W); w2_next <= to_signed(-4, WEIGHT_W);
        when 1 => w1_next <= to_signed(31, WEIGHT_W); w2_next <= to_signed(-32, WEIGHT_W);
        when 2 => w1_next <= to_signed(-32, WEIGHT_W); w2_next <= to_signed(31, WEIGHT_W);
        when 3 => w1_next <= to_signed(0, WEIGHT_W); w2_next <= to_signed(0, WEIGHT_W);
        when others => w1_next <= to_signed(-1, WEIGHT_W); w2_next <= to_signed(1, WEIGHT_W);
      end case;
      first_in <= '1'; last_in <= '0'; ce <= '0';
      wait until rising_edge(clk); wait for 1 ns;

      first_in <= '0'; ce <= '1';
      case i is
        when 0 => x_in <= to_signed(127, 8);
        when 1 => x_in <= to_signed(-127, 8);
        when 2 => x_in <= to_signed(1, 8);
        when 3 => x_in <= to_signed(-1, 8);
        when others => x_in <= to_signed(0, 8);
      end case;
      p_in <= to_signed(1000, ACC_W);
      wait until rising_edge(clk); wait for 1 ns;

      case i is
        when 0 => a_word := 3 + (-4) * (2 ** SPACING); expect := 1000 + a_word * 127;
        when 1 => a_word := 31 + (-32) * (2 ** SPACING); expect := 1000 + a_word * (-127);
        when 2 => a_word := -32 + 31 * (2 ** SPACING); expect := 1000 + a_word * 1;
        when 3 => a_word := 0; expect := 1000 + a_word * (-1);
        when others => a_word := -1 + 1 * (2 ** SPACING); expect := 1000 + a_word * 0;
      end case;
      if to_integer(p_out) /= expect then
        fails := fails + 1;
        report "FAIL MAC case " & integer'image(i) & " expect=" & integer'image(expect) &
               " got=" & integer'image(to_integer(p_out)) severity error;
      end if;
      ce <= '0';
      wait until rising_edge(clk); wait for 1 ns;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
