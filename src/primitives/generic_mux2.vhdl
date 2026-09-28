library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Generic WIDTH-bit 2:1 multiplexer: the other atomic structural
-- building block (alongside generic_register.vhdl) that barrel_shift,
-- rr_arb, generic_mux's own binary tree, and generic_lzc's recursive
-- combine step are built from. sel = '0' selects d0, sel = '1' selects
-- d1.
entity generic_mux2 is
  generic (
    WIDTH : positive := 8
  );
  port (
    sel    : in  std_logic;
    d0, d1 : in  std_logic_vector(WIDTH - 1 downto 0);
    y      : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_mux2;

architecture behavioral of generic_mux2 is
begin
  y <= d1 when sel = '1' else d0;
end architecture behavioral;
