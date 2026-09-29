library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Generic N-stage shift register (syseng_docs/04-vhdl-module-list.md's
-- L0 utility 'delay_line'): a straight chain of STAGES generic_register
-- instances. Used both for plain same-clock-domain pipeline alignment
-- and, driven from an asynchronous source signal, as the synchronizer
-- chain inside generic_reset_sync.vhdl and generic_pulse_cdc.vhdl.
--
-- STAGES is 'natural', not 'positive': 0 is a legal (zero-delay,
-- combinational passthrough) value, needed by anything that generates a
-- per-index delay bank whose index starts at 0 (act_skew.vhdl/ctrl_skew
-- .vhdl's row/column 0 -- see their headers) rather than special-casing
-- the zero-stage case at every call site.
entity generic_delay_line is
  generic (
    WIDTH  : positive := 8;
    STAGES : natural  := 1
  );
  port (
    clk : in  std_logic;
    rst : in  std_logic;
    en  : in  std_logic := '1';
    d   : in  std_logic_vector(WIDTH - 1 downto 0);
    q   : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity generic_delay_line;

architecture structural of generic_delay_line is
  type stage_arr_t is array (0 to STAGES) of std_logic_vector(WIDTH - 1 downto 0);
  signal stage : stage_arr_t;
begin

  stage(0) <= d;

  stage_gen : for i in 1 to STAGES generate
    reg_i : entity work.generic_register
      generic map (WIDTH => WIDTH)
      port map (clk => clk, rst => rst, en => en, d => stage(i - 1), q => stage(i));
  end generate stage_gen;

  q <= stage(STAGES);

end architecture structural;
