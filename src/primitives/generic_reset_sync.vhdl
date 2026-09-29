library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Generic reset synchronizer (syseng_docs/04-vhdl-module-list.md's L0
-- utility 'reset_sync'): takes an asynchronous, active-high reset
-- request and produces a version that asserts immediately (no clock
-- needed) but releases only after STAGES clean clock edges, avoiding a
-- recovery/removal violation on release.
--
-- Built from STAGES 1-bit generic_register instances with
-- ASYNC_RESET => true, chained together -- the same shape as
-- generic_delay_line.vhdl, just with an asynchronous instead of
-- synchronous reset on each stage and a different value convention.
-- generic_register's async reset always drives its output to '0', so
-- the chain here tracks "confirmed clear of reset" (1 = clear) rather
-- than "still in reset" directly: stage 0's synchronous input is tied
-- to a constant '1' (what should shift in once arst_in releases), each
-- later stage async-resets to '0' on arst_in and otherwise follows the
-- previous stage, and rst_out is the inverse of the last stage (0 once
-- every stage reads '1', i.e. STAGES clean edges after release; 1
-- immediately whenever arst_in asserts, since every stage's async reset
-- fires at once regardless of the clock).
entity generic_reset_sync is
  generic (
    STAGES : positive := 2
  );
  port (
    clk     : in  std_logic;
    arst_in : in  std_logic; -- asynchronous, active-high
    rst_out : out std_logic  -- synchronized, active-high
  );
end entity generic_reset_sync;

architecture structural of generic_reset_sync is
  type chain_arr_t is array (0 to STAGES) of std_logic_vector(0 downto 0);
  signal chain : chain_arr_t;
begin

  chain(0)(0) <= '1';

  stage_gen : for i in 1 to STAGES generate
    reg_i : entity work.generic_register
      generic map (WIDTH => 1, ASYNC_RESET => true)
      port map (clk => clk, rst => arst_in, en => '1', d => chain(i - 1), q => chain(i));
  end generate stage_gen;

  rst_out <= not chain(STAGES)(0);

end architecture structural;
