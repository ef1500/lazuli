library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;
use work.lookup_vectors.all;

-- Self-checking testbench for generic_lookup.vhdl: loads the golden
-- LUT+slope tables from lookup_vectors.vhdl (recip, rsqrt, exp2,
-- sigmoid, silu, gelu -- see test/gen/gen_lookup_vectors.py) into all
-- six slots, then evaluates every case and checks the result against
-- Python's math/numpy reference within the case's stated tolerance
-- (this unit is a table+interpolation approximation, so exact bit
-- matching isn't the contract -- error-bound matching is).
entity tb_generic_lookup is
end entity;

architecture sim of tb_generic_lookup is
  signal clk  : std_logic := '0';
  signal ce   : std_logic := '1';
  signal slot : unsigned(2 downto 0) := (others => '0');
  signal x    : std_logic_vector(31 downto 0) := (others => '0');
  signal y    : std_logic_vector(31 downto 0);
  signal flag : std_logic_vector(1 downto 0);

  signal ld_en, ld_we : std_logic := '0';
  signal ld_slot : unsigned(2 downto 0) := (others => '0');
  signal ld_mode : tab_mode_t := TAB_RANGE;
  signal ld_lo, ld_hi : std_logic_vector(31 downto 0) := (others => '0');
  signal ld_left, ld_right : tab_edge_t := EDGE_CLAMP;
  signal ld_bits : unsigned(3 downto 0) := (others => '0');
  signal ld_addr : unsigned(9 downto 0) := (others => '0');
  signal ld_value, ld_slope : std_logic_vector(31 downto 0) := (others => '0');

  signal done : boolean := false;

  impure function to_real32(v : std_logic_vector(31 downto 0)) return real is
    variable sign : real := 1.0;
    variable e : integer;
    variable m : real;
  begin
    if v(31) = '1' then sign := -1.0; end if;
    e := to_integer(unsigned(v(30 downto 23)));
    if e = 0 then
      return 0.0;
    end if;
    m := 1.0;
    for i in 0 to 22 loop
      if v(22 - i) = '1' then
        m := m + 2.0 ** (-(i + 1));
      end if;
    end loop;
    return sign * m * (2.0 ** (e - 127));
  end function;

begin

  dut: entity work.generic_lookup
    port map (
      clk => clk, ce => ce, slot => slot, x => x, y => y, flag => flag,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right,
      ld_bits => ld_bits,
      ld_addr => ld_addr, ld_value => ld_value, ld_slope => ld_slope, ld_we => ld_we
    );

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    variable got_r, exp_r, tol_r, diff : real;
    variable rel_ok : boolean;
  begin
    wait until clk = '1';

    for s in SLOT_CFG'range loop
      ld_slot  <= to_unsigned(s, 3);
      ld_mode  <= SLOT_CFG(s).mode;
      ld_lo    <= SLOT_CFG(s).lo;
      ld_hi    <= SLOT_CFG(s).hi;
      ld_left  <= SLOT_CFG(s).left;
      ld_right <= SLOT_CFG(s).right;
      ld_bits  <= to_unsigned(SLOT_CFG(s).bits, 4);
      ld_en    <= '1';
      wait until rising_edge(clk);
    end loop;
    ld_en <= '0';

    for i in TABLE_0'range loop
      ld_slot <= to_unsigned(0, 3); ld_addr <= to_unsigned(i, 10);
      ld_value <= TABLE_0(i).value; ld_slope <= TABLE_0(i).slope; ld_we <= '1';
      wait until rising_edge(clk);
    end loop;
    for i in TABLE_1'range loop
      ld_slot <= to_unsigned(1, 3); ld_addr <= to_unsigned(i, 10);
      ld_value <= TABLE_1(i).value; ld_slope <= TABLE_1(i).slope; ld_we <= '1';
      wait until rising_edge(clk);
    end loop;
    for i in TABLE_2'range loop
      ld_slot <= to_unsigned(2, 3); ld_addr <= to_unsigned(i, 10);
      ld_value <= TABLE_2(i).value; ld_slope <= TABLE_2(i).slope; ld_we <= '1';
      wait until rising_edge(clk);
    end loop;
    for i in TABLE_3'range loop
      ld_slot <= to_unsigned(3, 3); ld_addr <= to_unsigned(i, 10);
      ld_value <= TABLE_3(i).value; ld_slope <= TABLE_3(i).slope; ld_we <= '1';
      wait until rising_edge(clk);
    end loop;
    for i in TABLE_4'range loop
      ld_slot <= to_unsigned(4, 3); ld_addr <= to_unsigned(i, 10);
      ld_value <= TABLE_4(i).value; ld_slope <= TABLE_4(i).slope; ld_we <= '1';
      wait until rising_edge(clk);
    end loop;
    for i in TABLE_5'range loop
      ld_slot <= to_unsigned(5, 3); ld_addr <= to_unsigned(i, 10);
      ld_value <= TABLE_5(i).value; ld_slope <= TABLE_5(i).slope; ld_we <= '1';
      wait until rising_edge(clk);
    end loop;
    ld_we <= '0';
    wait until rising_edge(clk);

    for i in CASES'range loop
      slot <= to_unsigned(CASES(i).slot, 3);
      x    <= CASES(i).x;
      wait until rising_edge(clk);
      wait for 1 ns;
      got_r := to_real32(y);
      exp_r := to_real32(CASES(i).expect);
      tol_r := to_real32(CASES(i).tol_abs);
      diff := got_r - exp_r;
      if diff < 0.0 then diff := -diff; end if;
      rel_ok := (CASES(i).tol_rel_ppm = 0) or (diff <= abs(exp_r) * real(CASES(i).tol_rel_ppm) / 1.0e6);
      if (diff > tol_r) and not rel_ok then
        fails := fails + 1;
        if fails <= 40 then
          report "FAIL case " & integer'image(i) & " slot=" & integer'image(CASES(i).slot) &
                 " x=" & to_hstring(CASES(i).x) &
                 " expect=" & real'image(exp_r) & " got=" & real'image(got_r) &
                 " diff=" & real'image(diff)
            severity error;
        end if;
      end if;
    end loop;

    report "generic_lookup: " & integer'image(CASES'length - fails) & " / " &
           integer'image(CASES'length) & " within tolerance";
    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
