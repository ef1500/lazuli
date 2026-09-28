library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Rescaler integer stage (claude_docs/08-vhdl-implementation-spec.md
-- S2.2, claude_docs/04-vhdl-module-list.md S2.2): sums a stream of
-- int_mul_scale products into one accumulator, synchronously cleared at
-- each super-block start (so 'rst' here is a per-group control pulse
-- from the caller, not a chip-wide reset). One instance serves any
-- group count/accumulator width the caller sets via generics (Q3_K/Q6_K
-- use a 24-bit accumulator over 16 groups per 04 S2.2 -- GROUPS itself
-- isn't a generic here, since this entity doesn't count groups or
-- auto-clear; whatever sequences the 16 'ce' pulses per super-block
-- also drives 'rst' for the one cycle after the last of them).
--
-- ACC_WIDTH must be >= IN_WIDTH (the accumulator can't be narrower than
-- one term); this is checked with an elaboration-time assertion rather
-- than silently truncating.
entity int_acc is
  generic (
    IN_WIDTH  : positive := 25;
    ACC_WIDTH : positive := 32
  );
  port (
    clk : in  std_logic;
    rst : in  std_logic; -- synchronous clear, pulse at each super-block start
    ce  : in  std_logic; -- accumulate 'd' into 'acc' this cycle
    d   : in  signed(IN_WIDTH - 1 downto 0);
    acc : out signed(ACC_WIDTH - 1 downto 0)
  );
end entity int_acc;

architecture structural of int_acc is
  signal acc_slv  : std_logic_vector(ACC_WIDTH - 1 downto 0);
  signal acc_next : signed(ACC_WIDTH - 1 downto 0);
begin

  assert ACC_WIDTH >= IN_WIDTH
    report "int_acc: ACC_WIDTH must be >= IN_WIDTH (accumulator can't be narrower than one term)"
    severity failure;

  -- numeric_std widens 'd' (IN_WIDTH) to match acc_slv's ACC_WIDTH
  -- automatically, since ACC_WIDTH >= IN_WIDTH is asserted above.
  acc_next <= signed(acc_slv) + d;

  acc_reg : entity work.generic_register
    generic map (WIDTH => ACC_WIDTH)
    port map (
      clk => clk, rst => rst, en => ce,
      d => std_logic_vector(acc_next), q => acc_slv
    );

  acc <= signed(acc_slv);

end architecture structural;
