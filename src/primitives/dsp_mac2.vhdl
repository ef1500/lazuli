library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- The array's only compute primitive (claude_docs/08-vhdl-implementation
-- -spec.md S2.1, claude_docs/04-vhdl-module-list.md S2.1). Packs two
-- weight lanes into one wide DSP operand, A = w1 + (w2 << SPACING), and
-- runs P <= P_in + A * x_in every cycle 'ce' is asserted. One DSP slice
-- does two independent weight*activation products per multiply because
-- the packing keeps w1's product entirely below bit SPACING and w2's
-- product entirely at or above it, as long as SPACING is wide enough
-- that w1's product can never carry into w2's field -- verified [V] for
-- Q3_K/Q4_K/Q6_K with SPACING=17, depth 16, activations clamped to
-- +-127 (04 S2.1). This entity only builds A and runs the multiply-
-- accumulate; it never unpacks P back into lane0/lane1 -- that's
-- int_mul_scale.vhdl's job (its header explains why it takes an
-- already-extracted lane_sum rather than the raw packed P word).
--
-- 'first' swaps the "next" weight pair into the "active" pair before
-- this same cycle's multiply, so the multiply-accumulate and the
-- weight-swap ride the same clock edge with no separate wavefront
-- controller. There is no register upstream of w1_next/w2_next inside
-- this entity -- whatever drives them (weight_loader, not yet built)
-- must hold the correct "next" value steady through the cycle 'first'
-- is asserted. There is also no reset port: the weight registers and P
-- are only ever loaded via 'first'/'ce' (matching the literal port list
-- this entity is built from), never asynchronously cleared -- an idle
-- column simply never pulses 'ce'.
--
-- lane0_valid/lane1_valid: the module-list's port table calls for these
-- to "pulse at super-block boundaries", but nothing upstream of this
-- entity (array_seq / weight_loader, not yet built) exists to define
-- that boundary for it. Until that sequencer exists, this is a
-- documented placeholder [D]: both lanes always live in the same packed
-- P word, so they pulse together, one cycle after 'ce' -- exactly when
-- p_out reflects a freshly issued MAC. Revisit once array_seq can supply
-- a real per-tile/per-group boundary pulse instead.
entity dsp_mac2 is
  generic (
    A_PORT_W : positive := 27; -- 25 for DSP48E1 (A100T), 27 for DSP48E2 (VU9P) -- also selects the device in ARCH="xilinx"
    ACC_W    : positive := 48;
    WEIGHT_W : positive := 6;  -- signed bits for one weight lane (sbits(qlo,qhi): 3 Q3_K, 4 Q4_K, 6 Q6_K)
    SPACING  : positive := 17;
    ARCH     : string   := "behav" -- "behav" (plain numeric_std) or "xilinx" (DSP48E1/E2 instantiation)
  );
  port (
    clk     : in  std_logic;
    ce      : in  std_logic; -- accumulate this clock
    first   : in  std_logic; -- swap next -> active this clock, before the multiply
    w1_next : in  signed(WEIGHT_W - 1 downto 0);
    w2_next : in  signed(WEIGHT_W - 1 downto 0);
    x_in    : in  signed(7 downto 0);  -- activation, this cell's row
    p_in    : in  signed(ACC_W - 1 downto 0); -- partial sum from the cell above (0 for row 0)
    x_out   : out signed(7 downto 0);  -- to the cell on the right (or a tree fan-out -- see sys_array)
    p_out   : out signed(ACC_W - 1 downto 0); -- to the cell below

    lane0_valid : out std_logic;
    lane1_valid : out std_logic
  );
end entity dsp_mac2;

-- "behav": plain numeric_std, built from generic_register per the
-- project's usual "state lives in generic_register, arithmetic is
-- written directly where it's genuinely arithmetic" split (see
-- generic_rr_arb.vhdl for the register half of that split, generic_
-- round_sat.vhdl for the arithmetic half). This is the architecture
-- built and tested first, and the one every testbench in test/ binds to
-- explicitly -- "xilinx" is analyzed for syntax but never elaborated in
-- this repo (no UNISIM library here).
architecture behav of dsp_mac2 is
  signal w1_active_slv, w2_active_slv : std_logic_vector(WEIGHT_W - 1 downto 0);
  signal a_word     : signed(A_PORT_W - 1 downto 0);
  signal mac_result : signed(ACC_W - 1 downto 0);
  signal p_out_slv  : std_logic_vector(ACC_W - 1 downto 0);
  signal ce_d       : std_logic_vector(0 downto 0);
begin

  w1_reg : entity work.generic_register
    generic map (WIDTH => WEIGHT_W)
    port map (clk => clk, rst => '0', en => first, d => std_logic_vector(w1_next), q => w1_active_slv);

  w2_reg : entity work.generic_register
    generic map (WIDTH => WEIGHT_W)
    port map (clk => clk, rst => '0', en => first, d => std_logic_vector(w2_next), q => w2_active_slv);

  a_word <= resize(signed(w1_active_slv), A_PORT_W) +
            shift_left(resize(signed(w2_active_slv), A_PORT_W), SPACING);

  mac_result <= resize(p_in + a_word * x_in, ACC_W);

  p_reg : entity work.generic_register
    generic map (WIDTH => ACC_W)
    port map (clk => clk, rst => '0', en => ce, d => std_logic_vector(mac_result), q => p_out_slv);

  p_out <= signed(p_out_slv);
  x_out <= x_in;

  ce_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => '0', en => '1', d(0) => ce, q => ce_d);

  lane0_valid <= ce_d(0);
  lane1_valid <= ce_d(0);

end architecture behav;

-- "xilinx": instantiates DSP48E1 (A_PORT_W=25) or DSP48E2 (A_PORT_W=27)
-- directly by generic rather than relying on inference, per 04 S2.1
-- ("direct inference of cascade paths is unreliable"). P = PCIN + A*B:
-- A carries the packed weight word, B carries the sign-extended
-- activation, PCIN/PCOUT carry the running partial sum up/down
-- pe_column's cascade. OPMODE/ALUMODE/INMODE below select that
-- configuration (Z=PCIN, X=Y=the multiplier result M, straight add, no
-- pre-adder) from the standard MAC-with-cascade template in UG479 (7
-- Series DSP48E1) / UG579 (UltraScale DSP48E2) -- **[R] recalled, not
-- checked against those guides or a vendor simulation this session; the
-- "behav" architecture above is the one actually verified.** All control
-- inputs not needed for that fixed configuration (resets, dynamic
-- pre-adder/register bypass selects, carry chain) are tied to their
-- inactive/straight-through value, since this entity has no reset port
-- and never uses the pre-adder.
--
-- Known open question [R]: DSP48's internal A/B/M/P pipeline stages
-- give this architecture more than the "behav" architecture's 1-cycle
-- w*_next/x_in/p_in -> p_out latency; matching that up (via INMODE's
-- register-bypass bits, or by adding matching delay around this
-- instantiation) is exactly the cascade-mechanism work flagged as still
-- needing UG579/UG479 verification.
--
-- No UNISIM library is available in this repo's GHDL setup, so DSP48E1/
-- DSP48E2 are declared here as plain (unbound) components -- this
-- analyzes cleanly (ghdl -a only type-checks the component declaration
-- and its port map) but cannot be elaborated or simulated here; every
-- testbench in test/ binds to architecture "behav" explicitly instead.
architecture xilinx of dsp_mac2 is

  component DSP48E1 is
    generic (
      ALUMODEREG : integer := 1; CARRYINREG : integer := 1; CARRYINSELREG : integer := 1;
      MREG : integer := 1; OPMODEREG : integer := 1; PREG : integer := 1;
      AREG : integer := 1; BREG : integer := 1; INMODEREG : integer := 1;
      A_INPUT : string := "DIRECT"; B_INPUT : string := "DIRECT";
      USE_MULT : string := "MULTIPLY"
    );
    port (
      CLK : in std_logic;
      CEA2, CEB2, CEM, CEP, CEALUMODE, CECTRL, CECARRYIN, CEINMODE : in std_logic;
      RSTA, RSTB, RSTM, RSTP, RSTALUMODE, RSTCTRL, RSTINMODE : in std_logic;
      A : in std_logic_vector(24 downto 0);
      B : in std_logic_vector(17 downto 0);
      C : in std_logic_vector(47 downto 0);
      PCIN : in std_logic_vector(47 downto 0);
      ALUMODE : in std_logic_vector(3 downto 0);
      OPMODE : in std_logic_vector(6 downto 0);
      INMODE : in std_logic_vector(4 downto 0);
      CARRYIN : in std_logic;
      CARRYINSEL : in std_logic_vector(2 downto 0);
      P : out std_logic_vector(47 downto 0);
      PCOUT : out std_logic_vector(47 downto 0)
    );
  end component DSP48E1;

  component DSP48E2 is
    generic (
      AREG : integer := 1; BREG : integer := 1; MREG : integer := 1; PREG : integer := 1;
      ALUMODEREG : integer := 1; CARRYINREG : integer := 1; CARRYINSELREG : integer := 1;
      OPMODEREG : integer := 1; INMODEREG : integer := 1;
      A_INPUT : string := "DIRECT"; B_INPUT : string := "DIRECT";
      USE_MULT : string := "MULTIPLY"
    );
    port (
      CLK : in std_logic;
      CEA2, CEB2, CEM, CEP, CEALUMODE, CECTRL, CECARRYIN, CEINMODE : in std_logic;
      RSTA, RSTB, RSTM, RSTP, RSTALUMODE, RSTCTRL, RSTINMODE : in std_logic;
      A : in std_logic_vector(29 downto 0);
      B : in std_logic_vector(17 downto 0);
      C : in std_logic_vector(47 downto 0);
      PCIN : in std_logic_vector(47 downto 0);
      ALUMODE : in std_logic_vector(3 downto 0);
      OPMODE : in std_logic_vector(8 downto 0);
      INMODE : in std_logic_vector(4 downto 0);
      CARRYIN : in std_logic;
      CARRYINSEL : in std_logic_vector(2 downto 0);
      P : out std_logic_vector(47 downto 0);
      PCOUT : out std_logic_vector(47 downto 0)
    );
  end component DSP48E2;

  signal w1_active_slv, w2_active_slv : std_logic_vector(WEIGHT_W - 1 downto 0);
  signal a_word : signed(A_PORT_W - 1 downto 0);
  signal b_word : std_logic_vector(17 downto 0);
  signal p_slv  : std_logic_vector(47 downto 0);
  signal ce_d   : std_logic_vector(0 downto 0);

begin

  w1_reg : entity work.generic_register
    generic map (WIDTH => WEIGHT_W)
    port map (clk => clk, rst => '0', en => first, d => std_logic_vector(w1_next), q => w1_active_slv);

  w2_reg : entity work.generic_register
    generic map (WIDTH => WEIGHT_W)
    port map (clk => clk, rst => '0', en => first, d => std_logic_vector(w2_next), q => w2_active_slv);

  a_word <= resize(signed(w1_active_slv), A_PORT_W) +
            shift_left(resize(signed(w2_active_slv), A_PORT_W), SPACING);

  b_word <= std_logic_vector(resize(x_in, 18));

  e1_gen : if A_PORT_W = 25 generate
    signal a_port : std_logic_vector(24 downto 0);
  begin
    a_port <= std_logic_vector(resize(a_word, 25));

    dsp_inst : DSP48E1
      generic map (
        AREG => 0, BREG => 0, MREG => 0, PREG => 1,
        ALUMODEREG => 0, CARRYINREG => 0, CARRYINSELREG => 0, OPMODEREG => 0, INMODEREG => 0
      )
      port map (
        CLK => clk,
        CEA2 => first, CEB2 => '1', CEM => ce, CEP => ce,
        CEALUMODE => '1', CECTRL => '1', CECARRYIN => '1', CEINMODE => '1',
        RSTA => '0', RSTB => '0', RSTM => '0', RSTP => '0',
        RSTALUMODE => '0', RSTCTRL => '0', RSTINMODE => '0',
        A => a_port, B => b_word, C => (others => '0'),
        PCIN => std_logic_vector(resize(p_in, 48)),
        ALUMODE => "0000",       -- Z + X + Y (+ CARRYIN), straight add [R]
        OPMODE  => "0110101",    -- Z=PCIN(011), Y=M(01), X=M(01): P = PCIN + A*B [R]
        INMODE  => "00000",      -- direct A2*B2, no pre-adder [R]
        CARRYIN => '0', CARRYINSEL => "000",
        P => p_slv, PCOUT => open
      );
  end generate e1_gen;

  e2_gen : if A_PORT_W = 27 generate
    signal a_port : std_logic_vector(29 downto 0);
  begin
    a_port <= std_logic_vector(resize(a_word, 30));

    dsp_inst : DSP48E2
      generic map (
        AREG => 0, BREG => 0, MREG => 0, PREG => 1,
        ALUMODEREG => 0, CARRYINREG => 0, CARRYINSELREG => 0, OPMODEREG => 0, INMODEREG => 0
      )
      port map (
        CLK => clk,
        CEA2 => first, CEB2 => '1', CEM => ce, CEP => ce,
        CEALUMODE => '1', CECTRL => '1', CECARRYIN => '1', CEINMODE => '1',
        RSTA => '0', RSTB => '0', RSTM => '0', RSTP => '0',
        RSTALUMODE => '0', RSTCTRL => '0', RSTINMODE => '0',
        A => a_port, B => b_word, C => (others => '0'),
        PCIN => std_logic_vector(resize(p_in, 48)),
        ALUMODE => "0000",         -- Z + X + Y (+ CARRYIN), straight add [R]
        OPMODE  => "000110101",    -- W=0(00), Z=PCIN(011), Y=M(01), X=M(01): P = PCIN + A*B [R]
        INMODE  => "00000",        -- direct A2*B2, no pre-adder [R]
        CARRYIN => '0', CARRYINSEL => "000",
        P => p_slv, PCOUT => open
      );
  end generate e2_gen;

  unsupported_gen : if A_PORT_W /= 25 and A_PORT_W /= 27 generate
    assert false
      report "dsp_mac2(xilinx): A_PORT_W must be 25 (DSP48E1) or 27 (DSP48E2)"
      severity failure;
  end generate unsupported_gen;

  p_out <= signed(p_slv(ACC_W - 1 downto 0));
  x_out <= x_in;

  ce_reg : entity work.generic_register
    generic map (WIDTH => 1)
    port map (clk => clk, rst => '0', en => '1', d(0) => ce, q => ce_d);

  lane0_valid <= ce_d(0);
  lane1_valid <= ce_d(0);

end architecture xilinx;
