library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Generic vector ALU lane (claude_docs/08-vhdl-implementation-spec.md
-- S6.1's 'vec_lane'): one fp32 add/sub/mul/max/cvt unit (generic_fpu)
-- plus one table-driven function unit (generic_lookup, recip/rsqrt/
-- exp2/sigmoid/silu/gelu), selected by 'op'. ALU_LUT reads 'a' through
-- the lookup unit at the given 'lut_slot'; every other op runs on
-- generic_fpu as documented there.
--
-- Real hardware builds 8 of these per tile (S6.1: "8 lanes per tile");
-- this file is the one lane -- claude_docs/08's 'vec_seq' (the
-- descriptor walker that feeds 8 lanes from a host tpu_vop command) is
-- out of scope here since it depends on a command struct (ref/tpu.h)
-- that doesn't exist in this repo yet.
--
-- Latency: 2 clocks (1 for the sub-unit, 1 to register the op-selected
-- mux), both gated by 'ce'.
entity generic_vector_unit is
  port (
    clk      : in  std_logic;
    ce       : in  std_logic;
    op       : in  alu_op_t;
    sub      : in  std_logic_vector(2 downto 0) := (others => '0');
    cvt      : in  cvt_op_t                     := CVT_I2F;
    lut_slot : in  unsigned(2 downto 0)         := (others => '0');
    a, b     : in  std_logic_vector(31 downto 0);
    y        : out std_logic_vector(31 downto 0);
    flag     : out std_logic_vector(1 downto 0);

    -- pass-through table/slot-config load port for the embedded
    -- generic_lookup (see generic_lookup.vhdl for field semantics)
    ld_en    : in std_logic;
    ld_slot  : in unsigned(2 downto 0);
    ld_mode  : in tab_mode_t;
    ld_lo    : in std_logic_vector(31 downto 0);
    ld_hi    : in std_logic_vector(31 downto 0);
    ld_left  : in tab_edge_t;
    ld_right : in tab_edge_t;
    ld_bits  : in unsigned(3 downto 0);
    ld_addr  : in unsigned(9 downto 0);
    ld_value : in std_logic_vector(31 downto 0);
    ld_slope : in std_logic_vector(31 downto 0);
    ld_we    : in std_logic
  );
end entity generic_vector_unit;

architecture structural of generic_vector_unit is
  signal fpu_y, lut_y     : std_logic_vector(31 downto 0);
  signal fpu_flag, lut_flag : std_logic_vector(1 downto 0);
begin

  fpu_inst : entity work.generic_fpu
    port map (
      clk => clk, ce => ce, op => op, sub => sub, cvt => cvt,
      a => a, b => b, y => fpu_y, flag => fpu_flag
    );

  lut_inst : entity work.generic_lookup
    port map (
      clk => clk, ce => ce, slot => lut_slot, x => a, y => lut_y, flag => lut_flag,
      ld_en => ld_en, ld_slot => ld_slot, ld_mode => ld_mode,
      ld_lo => ld_lo, ld_hi => ld_hi, ld_left => ld_left, ld_right => ld_right,
      ld_bits => ld_bits, ld_addr => ld_addr, ld_value => ld_value,
      ld_slope => ld_slope, ld_we => ld_we
    );

  -- select between the two sub-units' (already-registered) outputs,
  -- using a copy of 'op' delayed to match their 1-cycle latency
  select_proc : process (clk)
    variable op_d : alu_op_t := ALU_ADD;
  begin
    if rising_edge(clk) then
      if ce = '1' then
        -- fpu_y/lut_y just landed for the op presented last cycle (held
        -- in op_d); select on that before advancing op_d to this cycle's op
        if op_d = ALU_LUT then
          y    <= lut_y;
          flag <= lut_flag;
        else
          y    <= fpu_y;
          flag <= fpu_flag;
        end if;
        op_d := op;
      end if;
    end if;
  end process select_proc;

end architecture structural;
