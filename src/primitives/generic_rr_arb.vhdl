library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic round-robin arbiter (syseng_docs/04-vhdl-module-list.md's L0
-- utility 'rr_arb'): N requesters, one grant per cycle, priority
-- rotating so the requester right after the last one granted goes
-- first next time.
--
-- Priority-mask technique, avoiding any dynamic rotator: mask(i) = '1'
-- for every requester at or before last_grant (a per-bit comparison
-- against last_grant, not a runtime-rotated vector), so masked_req
-- keeps only requesters strictly after last_grant. Finding "the lowest-
-- indexed set bit" in a vector is the same operation as generic_lzc's
-- leading-zero count run on the BIT-REVERSED vector (reversing turns
-- "scan from the top" into "scan from the bottom"), so this reuses
-- generic_lzc twice -- once on the masked (higher-priority) requests,
-- once on the full request set as a wrap-around fallback when nothing
-- is pending after last_grant -- rather than building a separate
-- priority encoder. One-hot 'grant' is built with project_types'
-- existing decode() function (already used by generic_fifo.vhdl for
-- exactly this).
--
-- Reset convention: last_grant resets to 0 (generic_register only
-- resets to all-zeros, kept that way deliberately -- see its own header
-- comment), which the mask logic reads as "requester 0 was already
-- serviced." So the first grant after reset starts at requester 1, not
-- 0; the rotation from there on is exactly round-robin.
entity generic_rr_arb is
  generic (
    N : positive := 4
  );
  port (
    clk, rst : in  std_logic;
    req      : in  std_logic_vector(N - 1 downto 0);
    advance  : in  std_logic; -- '1' to accept this grant and rotate priority past it
    grant    : out std_logic_vector(N - 1 downto 0); -- one-hot
    grant_idx: out unsigned(clog2(N) - 1 downto 0);
    valid    : out std_logic -- '1' if any requester is asking this cycle
  );
end entity generic_rr_arb;

architecture structural of generic_rr_arb is
  signal last_grant : std_logic_vector(clog2(N) - 1 downto 0);
  signal mask, masked_req : std_logic_vector(N - 1 downto 0);
  signal req_rev, masked_rev : std_logic_vector(N - 1 downto 0);

  signal req_zero, masked_zero : std_logic;
  signal req_idx, masked_idx : unsigned(clog2(N + 1) - 1 downto 0);

  signal grant_idx_i : unsigned(clog2(N) - 1 downto 0);
  signal grant_idx_wide : std_logic_vector(clog2(N + 1) - 1 downto 0);
  signal req_idx_n, masked_idx_n : std_logic_vector(clog2(N + 1) - 1 downto 0);
begin

  mask_gen : for i in 0 to N - 1 generate
    mask(i) <= '1' when i <= to_integer(unsigned(last_grant)) else '0';
  end generate mask_gen;

  masked_req <= req and not mask;

  rev_gen : for i in 0 to N - 1 generate
    req_rev(i) <= req(N - 1 - i);
    masked_rev(i) <= masked_req(N - 1 - i);
  end generate rev_gen;

  req_lzc : entity work.generic_lzc
    generic map (WIDTH => N)
    port map (d => req_rev, all_zero => req_zero, count => req_idx);

  masked_lzc : entity work.generic_lzc
    generic map (WIDTH => N)
    port map (d => masked_rev, all_zero => masked_zero, count => masked_idx);

  req_idx_n <= std_logic_vector(req_idx);
  masked_idx_n <= std_logic_vector(masked_idx);

  pick_mux : entity work.generic_mux2
    generic map (WIDTH => clog2(N + 1))
    port map (sel => masked_zero, d0 => masked_idx_n, d1 => req_idx_n, y => grant_idx_wide);

  grant_idx_i <= unsigned(grant_idx_wide(clog2(N) - 1 downto 0));
  grant_idx <= grant_idx_i;
  valid <= not req_zero;

  grant <= decode(std_logic_vector(grant_idx_i), not req_zero);

  last_grant_reg : entity work.generic_register
    generic map (WIDTH => clog2(N))
    port map (clk => clk, rst => rst, en => advance and (not req_zero),
              d => std_logic_vector(grant_idx_i), q => last_grant);

end architecture structural;
