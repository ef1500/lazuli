library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic table ROM from a constant array (syseng_docs/04-vhdl-module-
-- list.md's L0 utility 'rom_init'). CONTENTS packs all DEPTH entries
-- concatenated (entry i at CONTENTS((i+1)*WIDTH-1 downto i*WIDTH),
-- matching generic_mux's own packing convention), supplied by the
-- instantiating design as a generic constant.
--
-- Built the same way real distributed/LUT ROM works and the same way
-- everything else in this directory is built: register the address
-- (generic_register), then combinationally select the matching entry
-- out of CONTENTS with generic_mux -- giving a registered-address,
-- 1-cycle-latency read without any array-indexing loop of its own.
entity generic_rom_init is
  generic (
    WIDTH    : positive := 32;
    DEPTH    : positive := 16;
    CONTENTS : std_logic_vector -- DEPTH*WIDTH bits
  );
  port (
    clk  : in  std_logic;
    en   : in  std_logic := '1';
    addr : in  unsigned(clog2(DEPTH) - 1 downto 0);
    dout : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_rom_init;

architecture structural of generic_rom_init is
  signal addr_r : std_logic_vector(clog2(DEPTH) - 1 downto 0);
begin

  addr_reg : entity work.generic_register
    generic map (WIDTH => clog2(DEPTH))
    port map (clk => clk, rst => '0', en => en, d => std_logic_vector(addr), q => addr_r);

  mux_inst : entity work.generic_mux
    generic map (WIDTH => WIDTH, N => DEPTH)
    port map (sel => unsigned(addr_r), d => CONTENTS, y => dout);

end architecture structural;
