library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_generic_round_sat is
end entity;

architecture sim of tb_generic_round_sat is
  -- IN_WIDTH=24, OUT_WIDTH=16: FRAC_BITS = 8, and by construction the
  -- kept integer part (d(IN_WIDTH-1 downto FRAC_BITS)) is always
  -- exactly OUT_WIDTH bits -- so the only way to overflow is via a
  -- rounding carry pushing the max representable value up by one, not
  -- from an out-of-range integer part (there isn't one to construct:
  -- OUT_WIDTH bits can only ever hold an OUT_WIDTH-bit-range value).
  signal ds : std_logic_vector(23 downto 0);
  signal ys : std_logic_vector(15 downto 0);
  signal sats : std_logic;

  signal du : std_logic_vector(23 downto 0);
  signal yu : std_logic_vector(15 downto 0);
  signal satu : std_logic;
begin
  duts: entity work.generic_round_sat generic map (IN_WIDTH=>24, OUT_WIDTH=>16, IS_SIGNED=>true)
    port map (d=>ds, y=>ys, sat=>sats);
  dutu: entity work.generic_round_sat generic map (IN_WIDTH=>24, OUT_WIDTH=>16, IS_SIGNED=>false)
    port map (d=>du, y=>yu, sat=>satu);

  process
    variable fails : integer := 0;
    procedure checks(whole, frac256ths : integer; exp_y : integer; exp_sat : std_logic) is
    begin
      ds <= std_logic_vector(to_signed(whole * 256 + frac256ths, 24));
      wait for 1 ns;
      if to_integer(signed(ys)) /= exp_y or sats /= exp_sat then
        fails := fails + 1;
        report "FAILs " & integer'image(whole) & "+" & integer'image(frac256ths) & "/256 got_y=" &
               integer'image(to_integer(signed(ys))) & " got_sat=" & std_logic'image(sats) severity error;
      end if;
    end procedure;
    procedure checku(whole, frac256ths : integer; exp_y : integer; exp_sat : std_logic) is
    begin
      du <= std_logic_vector(to_unsigned(whole * 256 + frac256ths, 24));
      wait for 1 ns;
      if to_integer(unsigned(yu)) /= exp_y or satu /= exp_sat then
        fails := fails + 1;
        report "FAILu " & integer'image(whole) & "+" & integer'image(frac256ths) & "/256 got_y=" &
               integer'image(to_integer(unsigned(yu))) & " got_sat=" & std_logic'image(satu) severity error;
      end if;
    end procedure;
  begin
    -- exact integer values, no rounding, no overflow
    checks(0, 0, 0, '0');
    checks(1, 0, 1, '0');
    checks(-1, 0, -1, '0');
    checks(100, 0, 100, '0');
    checks(32767, 0, 32767, '0'); -- max int16, exact
    checks(-32768, 0, -32768, '0'); -- min int16, exact

    -- rounding, no overflow
    checks(2, 128, 2, '0');  -- 2.5 -> 2 (nearest even)
    checks(3, 128, 4, '0');  -- 3.5 -> 4 (nearest even)
    checks(2, 102, 2, '0');  -- 2.4 -> 2
    checks(2, 154, 3, '0');  -- 2.6 -> 3
    checks(-2, -128, -2, '0'); -- -2.5 -> -2 (nearest even)

    -- rounding carry into overflow: 32767.5 rounds up to 32768, which
    -- doesn't fit in int16 -> saturate. (There's no symmetric negative
    -- case to construct: -32768.5 isn't representable in this 24-bit
    -- Q16.8 format at all, since -32768.0 is already the minimum.)
    checks(32767, 128, 32767, '1');

    -- unsigned: exact and rounding-carry overflow
    checku(0, 0, 0, '0');
    checku(65535, 0, 65535, '0');
    checku(65535, 128, 65535, '1'); -- 65535.5 rounds up to 65536, saturate

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;
end architecture;
