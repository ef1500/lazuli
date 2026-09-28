library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity tb_generic_barrel_shift is
end entity;

architecture sim of tb_generic_barrel_shift is
  signal d : std_logic_vector(7 downto 0);
  signal amt : unsigned(clog2(8)-1 downto 0);
  signal dir : std_logic;
  signal y : std_logic_vector(7 downto 0);
begin
  dut: entity work.generic_barrel_shift generic map (WIDTH=>8) port map (d=>d, amt=>amt, dir=>dir, y=>y);
  process
    variable fails : integer := 0;
    procedure check(dv:std_logic_vector(7 downto 0); a:integer; dr:std_logic; exp:std_logic_vector(7 downto 0)) is
    begin
      d<=dv; amt<=to_unsigned(a,3); dir<=dr;
      wait for 1 ns;
      if y /= exp then
        fails := fails+1;
        report "FAIL d=" & to_hstring(dv) & " amt=" & integer'image(a) & " dir=" & std_logic'image(dr) &
               " expect=" & to_hstring(exp) & " got=" & to_hstring(y) severity error;
      end if;
    end procedure;
  begin
    check("00000001", 0, '1', "00000001"); -- no shift
    check("00000001", 3, '1', "00000000"); -- right shift 3, bit shifted out
    check("10000000", 1, '1', "01000000"); -- right shift 1
    check("00000001", 3, '0', "00001000"); -- left shift 3
    check("10000000", 1, '0', "00000000"); -- left shift 1, top bit shifted out
    check("11111111", 4, '1', "00001111"); -- right shift 4
    check("11111111", 4, '0', "11110000"); -- left shift 4
    check("10101010", 7, '1', "00000001"); -- right shift 7
    check("10101010", 7, '0', "00000000"); -- left shift 7 (bit0=0, so top bit after shift is 0)
    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;
end architecture;
