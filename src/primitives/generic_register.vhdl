library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Generic WIDTH-bit register: the one sequential building block every
-- other structural primitive in this directory is made of (delay_line,
-- barrel_shift, reset_sync, pulse_cdc, rr_arb, rom_init, async_fifo's
-- pointer/synchronizer logic). Deliberately does nothing but register
-- 'd' into 'q' -- no arithmetic, no decoding -- so those primitives can
-- be described as wiring together small pieces instead of writing one
-- monolithic process per entity.
--
-- ASYNC_RESET selects whether 'rst' is sampled only at a clock edge
-- (the default -- glitch-free, the usual in-fabric-clock-domain choice)
-- or takes effect immediately regardless of 'clk' (needed for the first
-- stage of a clock-domain-crossing reset synchronizer, where the
-- asserting edge may arrive with no clock running at all).
entity generic_register is
  generic (
    WIDTH       : positive := 8;
    ASYNC_RESET : boolean  := false
  );
  port (
    clk : in  std_logic;
    rst : in  std_logic;
    en  : in  std_logic := '1';
    d   : in  std_logic_vector(WIDTH - 1 downto 0);
    q   : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_register;

architecture behavioral of generic_register is
begin

  sync_gen : if not ASYNC_RESET generate
    process (clk)
    begin
      if rising_edge(clk) then
        if rst = '1' then
          q <= (others => '0');
        elsif en = '1' then
          q <= d;
        end if;
      end if;
    end process;
  end generate sync_gen;

  async_gen : if ASYNC_RESET generate
    process (clk, rst)
    begin
      if rst = '1' then
        q <= (others => '0');
      elsif rising_edge(clk) then
        if en = '1' then
          q <= d;
        end if;
      end if;
    end process;
  end generate async_gen;

end architecture behavioral;
