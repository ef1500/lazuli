library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic true dual-port RAM (syseng_docs/04-vhdl-module-list.md's L0
-- utility 'tdp_ram': "Inferred block/LUT RAM", generics W, DEPTH). Two
-- fully independent, symmetric ports, each able to read and/or write
-- its own address every cycle, sharing a single clock. Useful for
-- weight double-buffering (one port fills the "next" tile while the
-- other drains the "active" one) or any other two-accessor structure --
-- see syseng_docs/03-architecture-units.md U9's weight-loader discussion.
--
-- Synchronous (registered) read on both ports, 1-cycle latency, same
-- inference shape as generic_sdp_ram.vhdl (one array signal, one
-- clocked process) so it maps to block RAM rather than registers.
--
-- Same-address collision (both ports touch the same address the same
-- cycle): each port's read reflects the PRE-edge array contents --
-- i.e. if port A writes address X while port B reads address X in the
-- same cycle, port B's rdata is the old value, not A's new write. If
-- both ports write the same address the same cycle, the result is the
-- implementation's arbitrary pick between the two (port B's write wins
-- here, since it is applied second in program order) -- avoid doing
-- that from the two accessors in the first place, as with any real
-- true dual-port block RAM.
entity generic_tdp_ram is
  generic (
    WIDTH : positive := 32;
    DEPTH : positive := 1024
  );
  port (
    clk : in std_logic;

    we_a    : in  std_logic;
    addr_a  : in  unsigned(clog2(DEPTH) - 1 downto 0);
    wdata_a : in  std_logic_vector(WIDTH - 1 downto 0);
    rdata_a : out std_logic_vector(WIDTH - 1 downto 0);

    we_b    : in  std_logic;
    addr_b  : in  unsigned(clog2(DEPTH) - 1 downto 0);
    wdata_b : in  std_logic_vector(WIDTH - 1 downto 0);
    rdata_b : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_tdp_ram;

architecture behavioral of generic_tdp_ram is
  type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin

  process (clk)
  begin
    if rising_edge(clk) then
      rdata_a <= mem(to_integer(addr_a));
      rdata_b <= mem(to_integer(addr_b));
      if we_a = '1' then
        mem(to_integer(addr_a)) <= wdata_a;
      end if;
      if we_b = '1' then
        mem(to_integer(addr_b)) <= wdata_b;
      end if;
    end if;
  end process;

end architecture behavioral;
