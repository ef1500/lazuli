library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.q6k_vectors.all;

-- Self-checking testbench for q6k_unpack.vhdl -- same caveat as
-- tb_q3k_unpack.vhdl: checks the VHDL against an independent Perl
-- reimplementation of q6k_unpack.vhdl's documented formula (test/gen/
-- gen_q6k_vectors.pl), not against real ggml-quants.c (not available
-- in this repo). All-zero, all-ones, and 4 pseudo-random 210-byte
-- blocks, checked exhaustively (every group/row plus the flat signed
-- scale array).
entity tb_q6k_unpack is
end entity;

architecture sim of tb_q6k_unpack is
  signal block_in   : std_logic_vector(1679 downto 0);
  signal weight_out : std_logic_vector(16 * 16 * 6 - 1 downto 0);
  signal scale_out  : std_logic_vector(16 * 8 - 1 downto 0);
  signal d_out      : std_logic_vector(15 downto 0);
begin

  dut : entity work.q6k_unpack
    port map (block_in => block_in, weight_out => weight_out, scale_out => scale_out, d_out => d_out);

  process
    variable fails : integer := 0;
    variable got_w : integer;
    variable got_s : integer;
  begin
    for v in 0 to NUM_VEC - 1 loop
      block_in <= blocks(v);
      wait for 1 ns;

      for g in 0 to 15 loop
        for r in 0 to 15 loop
          got_w := to_integer(signed(weight_out((g * 16 + r + 1) * 6 - 1 downto (g * 16 + r) * 6)));
          if got_w /= expected_weights(v, g * 16 + r) then
            fails := fails + 1;
            report "FAIL vec=" & integer'image(v) & " group=" & integer'image(g) & " row=" & integer'image(r) &
                   " expect=" & integer'image(expected_weights(v, g * 16 + r)) & " got=" & integer'image(got_w)
                   severity error;
          end if;
        end loop;

        got_s := to_integer(signed(scale_out((g + 1) * 8 - 1 downto g * 8)));
        if got_s /= expected_scales(v, g) then
          fails := fails + 1;
          report "FAIL vec=" & integer'image(v) & " group=" & integer'image(g) & " scale expect=" &
                 integer'image(expected_scales(v, g)) & " got=" & integer'image(got_s) severity error;
        end if;
      end loop;

      if to_integer(unsigned(d_out)) /= expected_d(v) then
        fails := fails + 1;
        report "FAIL vec=" & integer'image(v) & " d expect=" & integer'image(expected_d(v)) &
               " got=" & integer'image(to_integer(unsigned(d_out))) severity error;
      end if;
    end loop;

    if fails = 0 then
      report "ALL PASS";
    else
      report integer'image(fails) & " FAILURES" severity error;
    end if;
    wait;
  end process;

end architecture sim;
