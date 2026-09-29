library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic simple dual-port RAM (syseng_docs/04-vhdl-module-list.md's L0
-- utility 'sdp_ram': "Inferred block/LUT RAM", generics W, DEPTH). One
-- write port and one independent read port, sharing a single clock.
--
-- Synchronous (registered) read, 1-cycle latency: rdata reflects the
-- value at raddr as of the last clock edge where re='1', matching how
-- FPGA block RAM actually behaves -- this is written to infer as block
-- RAM (a plain array signal with a single clocked process, no
-- asynchronous reset on the array itself), not as a bank of registers.
--
-- Same-address collision: if we='1' at waddr = raddr with re='1' on the
-- same clock, rdata gets the OLD value (the write and the read's memory
-- fetch happen from the same pre-edge array state) -- this is the usual
-- "read-old-data"/no-change behavior for inferred simple dual-port RAM.
entity generic_sdp_ram is
  generic (
    WIDTH : positive := 32;
    DEPTH : positive := 1024
  );
  port (
    clk : in std_logic;

    we    : in std_logic;
    waddr : in unsigned(clog2(DEPTH) - 1 downto 0);
    wdata : in std_logic_vector(WIDTH - 1 downto 0);

    re    : in std_logic;
    raddr : in unsigned(clog2(DEPTH) - 1 downto 0);
    rdata : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_sdp_ram;

architecture behavioral of generic_sdp_ram is
  type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin

  process (clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        mem(to_integer(waddr)) <= wdata;
      end if;
      if re = '1' then
        rdata <= mem(to_integer(raddr));
      end if;
    end if;
  end process;

end architecture behavioral;
