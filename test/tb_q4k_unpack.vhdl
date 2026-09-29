library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.q4k_vectors.all;

-- Self-checking testbench for q4k_unpack.vhdl -- same caveat as
-- tb_q3k_unpack.vhdl/tb_q6k_unpack.vhdl: checks the VHDL against an
-- independent Perl reimplementation of q4k_unpack.vhdl's documented
-- formula (test/gen/gen_q4k_vectors.pl), not against real ggml-
-- quants.c (not available in this repo) -- and q4k_unpack.vhdl's own
-- header flags this as the LEAST confidently reconstructed of the
-- three formats. All-zero, all-ones, and 4 pseudo-random 144-byte
-- blocks, checked exhaustively: every group/row's weight, both sc and
-- m per group (duplication across each 32-weight pair's two groups
-- included, so a pairing bug shows up as a mismatch), d and dmin.
entity tb_q4k_unpack is
end entity;

architecture sim of tb_q4k_unpack is
  signal block_in   : std_logic_vector(1151 downto 0);
  signal weight_out : std_logic_vector(16 * 16 * 4 - 1 downto 0);
  signal scale_out  : std_logic_vector(16 * 6 - 1 downto 0);
  signal min_out    : std_logic_vector(16 * 6 - 1 downto 0);
  signal d_out      : std_logic_vector(15 downto 0);
  signal dmin_out   : std_logic_vector(15 downto 0);
begin

  dut : entity work.q4k_unpack
    port map (
      block_in => block_in, weight_out => weight_out,
      scale_out => scale_out, min_out => min_out,
      d_out => d_out, dmin_out => dmin_out
    );

  process
    variable fails : integer := 0;
    variable got_w, got_s, got_m : integer;
  begin
    for v in 0 to NUM_VEC - 1 loop
      block_in <= blocks(v);
      wait for 1 ns;

      for c in 0 to 15 loop
        for r in 0 to 15 loop
          got_w := to_integer(signed(weight_out((c * 16 + r + 1) * 4 - 1 downto (c * 16 + r) * 4)));
          if got_w /= expected_weights(v, c * 16 + r) then
            fails := fails + 1;
            report "FAIL vec=" & integer'image(v) & " col=" & integer'image(c) & " row=" & integer'image(r) &
                   " expect=" & integer'image(expected_weights(v, c * 16 + r)) & " got=" & integer'image(got_w)
                   severity error;
          end if;
        end loop;

        got_s := to_integer(unsigned(scale_out((c + 1) * 6 - 1 downto c * 6)));
        if got_s /= expected_scales(v, c) then
          fails := fails + 1;
          report "FAIL vec=" & integer'image(v) & " col=" & integer'image(c) & " sc expect=" &
                 integer'image(expected_scales(v, c)) & " got=" & integer'image(got_s) severity error;
        end if;

        got_m := to_integer(unsigned(min_out((c + 1) * 6 - 1 downto c * 6)));
        if got_m /= expected_mins(v, c) then
          fails := fails + 1;
          report "FAIL vec=" & integer'image(v) & " col=" & integer'image(c) & " m expect=" &
                 integer'image(expected_mins(v, c)) & " got=" & integer'image(got_m) severity error;
        end if;
      end loop;

      if to_integer(unsigned(d_out)) /= expected_d(v) then
        fails := fails + 1;
        report "FAIL vec=" & integer'image(v) & " d expect=" & integer'image(expected_d(v)) &
               " got=" & integer'image(to_integer(unsigned(d_out))) severity error;
      end if;
      if to_integer(unsigned(dmin_out)) /= expected_dmin(v) then
        fails := fails + 1;
        report "FAIL vec=" & integer'image(v) & " dmin expect=" & integer'image(expected_dmin(v)) &
               " got=" & integer'image(to_integer(unsigned(dmin_out))) severity error;
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
