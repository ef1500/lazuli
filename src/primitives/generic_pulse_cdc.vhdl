library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Generic single-pulse clock-domain crossing (claude_docs/04-vhdl-
-- module-list.md's L0 utility 'pulse_cdc'): a 1-cycle pulse in the
-- source clock domain produces exactly one 1-cycle pulse in the
-- destination domain, however unrelated the two clocks are.
--
-- Toggle-and-resynchronize technique: a 1-bit register in the source
-- domain flips every time pulse_in fires; that bit is safe to cross
-- clock domains one bit at a time (no multi-bit skew hazard, unlike
-- crossing a whole counter). generic_delay_line.vhdl provides the
-- STAGES-deep synchronizer chain in the destination domain (its first
-- stage is where metastability could occur and gets resolved by the
-- remaining stages); one more destination-domain register captures the
-- synchronized bit's previous value, and pulse_out is the XOR of the
-- two -- high for exactly one cycle whenever the toggle bit has flipped.
entity generic_pulse_cdc is
  generic (
    STAGES : positive := 2 -- destination-domain synchronizer depth
  );
  port (
    src_clk, src_rst : in  std_logic;
    pulse_in         : in  std_logic;
    dst_clk, dst_rst : in  std_logic;
    pulse_out        : out std_logic
  );
end entity generic_pulse_cdc;

architecture structural of generic_pulse_cdc is
  signal toggle_q, toggle_d : std_logic_vector(0 downto 0);
  signal sync_q : std_logic_vector(0 downto 0);
  signal prev_q : std_logic_vector(0 downto 0);
begin

  toggle_d(0) <= toggle_q(0) xor pulse_in;

  toggle_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => src_clk, rst => src_rst, en => '1', d => toggle_d, q => toggle_q);

  sync_chain : entity work.generic_delay_line
    generic map (WIDTH => 1, STAGES => STAGES)
    port map (clk => dst_clk, rst => dst_rst, en => '1', d => toggle_q, q => sync_q);

  prev_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => dst_clk, rst => dst_rst, en => '1', d => sync_q, q => prev_q);

  pulse_out <= sync_q(0) xor prev_q(0);

end architecture structural;
