library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic logical barrel shifter (syseng_docs/04-vhdl-module-list.md's
-- L0 utility 'barrel_shift'), zero-filling either direction. Built as
-- clog2(WIDTH) stages, each shifting by a fixed power-of-two distance
-- (stage k shifts by 2**k) that's either applied or skipped based on
-- 'amt's bit k, using generic_mux2 for both the per-bit direction pick
-- and the per-bit apply-this-stage pick -- a classic log-shifter, not a
-- runtime-computed shift.
entity generic_barrel_shift is
  generic (
    WIDTH : positive := 32
  );
  port (
    d   : in  std_logic_vector(WIDTH - 1 downto 0);
    amt : in  unsigned(clog2(WIDTH) - 1 downto 0);
    dir : in  std_logic; -- '0' = shift left, '1' = shift right
    y   : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_barrel_shift;

architecture structural of generic_barrel_shift is
  constant STAGES : natural := clog2(WIDTH);
  type stage_arr_t is array (0 to STAGES) of std_logic_vector(WIDTH - 1 downto 0);
  signal stage : stage_arr_t;
begin

  stage(0) <= d;

  -- WIDTH = 1 needs no shift stages at all (STAGES = 0): just wire
  -- through, since a single bit can never be shifted anywhere.
  passthrough_gen : if STAGES = 0 generate
    y <= stage(0);
  end generate passthrough_gen;

  stage_gen : if STAGES > 0 generate
  begin
    per_stage : for k in 0 to STAGES - 1 generate
      constant SH : positive := 2 ** k;
      signal right_cand, left_cand, dir_cand : std_logic_vector(WIDTH - 1 downto 0);
    begin

      bit_gen : for i in 0 to WIDTH - 1 generate
        right_inbound : if i + SH < WIDTH generate
          right_cand(i) <= stage(k)(i + SH);
        end generate right_inbound;
        right_oob : if i + SH >= WIDTH generate
          right_cand(i) <= '0';
        end generate right_oob;

        left_inbound : if i >= SH generate
          left_cand(i) <= stage(k)(i - SH);
        end generate left_inbound;
        left_oob : if i < SH generate
          left_cand(i) <= '0';
        end generate left_oob;
      end generate bit_gen;

      dir_mux : entity work.generic_mux2
        generic map (WIDTH => WIDTH)
        port map (sel => dir, d0 => left_cand, d1 => right_cand, y => dir_cand);

      amt_mux : entity work.generic_mux2
        generic map (WIDTH => WIDTH)
        port map (sel => amt(k), d0 => stage(k), d1 => dir_cand, y => stage(k + 1));

    end generate per_stage;

    y <= stage(STAGES);
  end generate stage_gen;

end architecture structural;
