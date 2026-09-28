library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

entity tb_generic_rom_init is
end entity;

architecture sim of tb_generic_rom_init is
  constant WIDTH : positive := 8;
  constant DEPTH : positive := 4;
  constant CONTENTS : std_logic_vector(DEPTH*WIDTH-1 downto 0) :=
    x"04" & x"03" & x"02" & x"01"; -- entry0=01, entry1=02, entry2=03, entry3=04

  signal clk : std_logic := '0';
  signal en : std_logic := '1';
  signal addr : unsigned(clog2(DEPTH)-1 downto 0) := (others=>'0');
  signal dout : std_logic_vector(WIDTH-1 downto 0);
  signal done : boolean := false;
begin
  dut: entity work.generic_rom_init generic map (WIDTH=>WIDTH, DEPTH=>DEPTH, CONTENTS=>CONTENTS)
    port map (clk=>clk, en=>en, addr=>addr, dout=>dout);

  clk <= not clk after 5 ns when not done else '0';

  process
    variable fails : integer := 0;
    procedure check(a : integer; exp : integer) is
    begin
      addr <= to_unsigned(a, clog2(DEPTH));
      wait until rising_edge(clk);
      wait for 1 ns;
      if to_integer(unsigned(dout)) /= exp then
        fails := fails + 1;
        report "FAIL addr=" & integer'image(a) & " expect=" & integer'image(exp) &
               " got=" & integer'image(to_integer(unsigned(dout))) severity error;
      end if;
    end procedure;
  begin
    check(0, 1);
    check(1, 2);
    check(2, 3);
    check(3, 4);
    check(0, 1); -- back to the start, confirm no state leakage

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    done <= true;
    wait;
  end process;
end architecture;
