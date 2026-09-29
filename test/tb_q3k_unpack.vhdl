library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.q3k_vectors.all;

-- Self-checking testbench for q3k_unpack.vhdl. NOT a bit-exactness
-- check against real ggml-quants.c (no such reference is available in
-- this repo -- see q3k_unpack.vhdl's header) -- this checks that the
-- VHDL correctly implements the formula documented in q3k_unpack.
-- vhdl's header, against test vectors computed by an INDEPENDENT
-- reimplementation of that same formula (test/gen/gen_q3k_vectors.pl,
-- a from-scratch Perl port, not copy-pasted from the VHDL), so a
-- transcription slip in either the VHDL or the generator shows up as a
-- mismatch here. Vectors: all-zero, all-ones (both easy to hand-check:
-- q2bit=0/3, hbit=0/1 uniformly), then 4 pseudo-random 110-byte blocks
-- exercising every group/row's indexing and the full scale shuffle.
entity tb_q3k_unpack is
end entity;

architecture sim of tb_q3k_unpack is
  signal block_in   : std_logic_vector(879 downto 0);
  signal weight_out : std_logic_vector(16 * 16 * 3 - 1 downto 0);
  signal scale_out  : std_logic_vector(16 * 6 - 1 downto 0);
  signal d_out      : std_logic_vector(15 downto 0);
begin

  dut : entity work.q3k_unpack
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
          got_w := to_integer(signed(weight_out((g * 16 + r + 1) * 3 - 1 downto (g * 16 + r) * 3)));
          if got_w /= expected_weights(v, g * 16 + r) then
            fails := fails + 1;
            report "FAIL vec=" & integer'image(v) & " group=" & integer'image(g) & " row=" & integer'image(r) &
                   " expect=" & integer'image(expected_weights(v, g * 16 + r)) & " got=" & integer'image(got_w)
                   severity error;
          end if;
        end loop;

        got_s := to_integer(unsigned(scale_out((g + 1) * 6 - 1 downto g * 6)));
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
