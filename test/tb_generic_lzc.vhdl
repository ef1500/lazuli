library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Self-checking testbench for generic_lzc.vhdl. Exhaustively checks
-- every possible input for two widths: WIDTH=8 (a power of two, so the
-- public entity's padding wrapper is a no-op and this exercises the
-- recursive core directly) and WIDTH=5 (not a power of two, so this
-- exercises the pad-with-1s-at-the-LSB-end wrapper, including the
-- all-zero case that originally exposed a bug in that wrapper's
-- all_zero derivation -- see generic_lzc.vhdl's header comment).
entity tb_generic_lzc is
end entity;

architecture sim of tb_generic_lzc is
  signal d8 : std_logic_vector(7 downto 0);
  signal az8 : std_logic;
  signal c8 : unsigned(clog2(9) - 1 downto 0);

  signal d5 : std_logic_vector(4 downto 0);
  signal az5 : std_logic;
  signal c5 : unsigned(clog2(6) - 1 downto 0);

  function ref_lzc(v : std_logic_vector) return integer is
  begin
    for i in v'high downto v'low loop
      if v(i) = '1' then
        return v'high - i;
      end if;
    end loop;
    return v'length; -- all zero
  end function;
begin
  dut8: entity work.generic_lzc generic map (WIDTH => 8) port map (d => d8, all_zero => az8, count => c8);
  dut5: entity work.generic_lzc generic map (WIDTH => 5) port map (d => d5, all_zero => az5, count => c5);

  process
    variable fails : integer := 0;
    variable ref : integer;
  begin
    for i in 0 to 255 loop
      d8 <= std_logic_vector(to_unsigned(i, 8));
      wait for 1 ns;
      ref := ref_lzc(std_logic_vector(to_unsigned(i, 8)));
      if (ref = 8 and az8 /= '1') or (ref < 8 and (az8 /= '0' or to_integer(c8) /= ref)) then
        fails := fails + 1;
        report "FAIL WIDTH=8 d=" & integer'image(i) & " expect_count=" & integer'image(ref) &
               " got az=" & std_logic'image(az8) & " count=" & integer'image(to_integer(c8)) severity error;
      end if;
    end loop;

    for i in 0 to 31 loop
      d5 <= std_logic_vector(to_unsigned(i, 5));
      wait for 1 ns;
      ref := ref_lzc(std_logic_vector(to_unsigned(i, 5)));
      if (ref = 5 and az5 /= '1') or (ref < 5 and (az5 /= '0' or to_integer(c5) /= ref)) then
        fails := fails + 1;
        report "FAIL WIDTH=5 d=" & integer'image(i) & " expect_count=" & integer'image(ref) &
               " got az=" & std_logic'image(az5) & " count=" & integer'image(to_integer(c5)) severity error;
      end if;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;
end architecture sim;
