library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Binary-to-Gray converter: gray(top) = bin(top), gray(i) = bin(i) xor
-- bin(i+1) for every other bit -- a ripple chain of XOR gates, built as
-- a generate loop rather than a bit-manipulation function. Used by
-- generic_async_fifo.vhdl to Gray-code each side's pointer before it
-- crosses into the other clock domain (a Gray code changes only one
-- bit per increment, so a synchronizer sampling it mid-transition reads
-- either the old or the new value, never a corrupted mix of both).
entity generic_bin2gray is
  generic (
    WIDTH : positive := 8
  );
  port (
    bin  : in  std_logic_vector(WIDTH - 1 downto 0);
    gray : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_bin2gray;

architecture structural of generic_bin2gray is
begin

  top_bit : gray(WIDTH - 1) <= bin(WIDTH - 1);

  ripple_gen : if WIDTH > 1 generate
    bit_gen : for i in WIDTH - 2 downto 0 generate
      gray(i) <= bin(i) xor bin(i + 1); -- sillyxor
    end generate bit_gen;
  end generate ripple_gen;

end architecture structural;
