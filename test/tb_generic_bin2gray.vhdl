library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Self-checking testbench for generic_bin2gray.vhdl: checks every value
-- 0..2**WIDTH-1 converts correctly (compared against the standard
-- b xor (b >> 1) formula, computed here in the testbench, not reused
-- from the DUT's own logic) and, critically, that every consecutive
-- pair of values differs by exactly one bit -- the entire point of
-- using Gray code for a clock-domain-crossing pointer.
entity tb_generic_bin2gray is
end entity;

architecture sim of tb_generic_bin2gray is
  constant WIDTH : positive := 5;
  signal bin : std_logic_vector(WIDTH - 1 downto 0);
  signal gray : std_logic_vector(WIDTH - 1 downto 0);
begin
  dut: entity work.generic_bin2gray generic map (WIDTH => WIDTH) port map (bin => bin, gray => gray);

  process
    variable fails : integer := 0;
    variable expect : unsigned(WIDTH - 1 downto 0);
    variable prev_gray, cur_gray : std_logic_vector(WIDTH - 1 downto 0);
    variable diff_bits : natural;
  begin
    for i in 0 to 2 ** WIDTH - 1 loop
      bin <= std_logic_vector(to_unsigned(i, WIDTH));
      wait for 1 ns;

      expect := to_unsigned(i, WIDTH) xor shift_right(to_unsigned(i, WIDTH), 1);
      if gray /= std_logic_vector(expect) then
        fails := fails + 1;
        report "FAIL: bin2gray(" & integer'image(i) & ") expect=" & to_hstring(std_logic_vector(expect)) &
               " got=" & to_hstring(gray) severity error;
      end if;

      cur_gray := gray;
      if i > 0 then
        diff_bits := 0;
        for b in 0 to WIDTH - 1 loop
          if cur_gray(b) /= prev_gray(b) then
            diff_bits := diff_bits + 1;
          end if;
        end loop;
        if diff_bits /= 1 then
          fails := fails + 1;
          report "FAIL: gray(" & integer'image(i-1) & ")->gray(" & integer'image(i) &
                 ") changed " & integer'image(diff_bits) & " bits, expected exactly 1" severity error;
        end if;
      end if;
      prev_gray := cur_gray;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;
end architecture sim;
