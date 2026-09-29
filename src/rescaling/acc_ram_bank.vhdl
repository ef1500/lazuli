library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.project_types.all;

-- Rescaler U10 entity 3/3 (claude_docs/04-vhdl-module-list.md's U10
-- table: "128 small RAM slices, one per column"). A thin generate-loop
-- bundle of NUM_COLUMNS independent generic_sdp_ram.vhdl instances, one
-- per output column's running fp32 accumulator -- there is no cross-
-- column sharing or arbitration here, since each column's sb_finish.vhdl
-- instance only ever touches its own slice.
--
-- Ports are flattened std_logic_vector buses (NUM_COLUMNS * per-column-
-- width bits, column c at bits [(c+1)*W-1 downto c*W]), matching this
-- project's existing convention for wide per-column/per-group buses
-- (q3k_unpack.vhdl/q4k_unpack.vhdl/q6k_unpack.vhdl's weight_out/
-- scale_out, sys_array.vhdl's activation bus) rather than a VHDL array
-- port type -- there's no existing array-port precedent in this repo to
-- match instead.
--
-- Pairing: wire one column's sb_finish.ram_we/ram_waddr/ram_wdata/
-- ram_re/ram_raddr into we(c)/waddr(c's slice)/wdata(c's slice)/re(c)/
-- raddr(c's slice) here, and this entity's rdata(c's slice) back into
-- that sb_finish's ram_rdata. (tb_sb_finish.vhdl instantiates a single
-- generic_sdp_ram directly instead, for a NUM_COLUMNS=1 case -- both
-- satisfy the same per-column port contract sb_finish.vhdl expects.)
entity acc_ram_bank is
  generic (
    NUM_COLUMNS : positive := 128;
    WIDTH       : positive := 32;
    DEPTH       : positive := 256
  );
  port (
    clk : in std_logic;

    we    : in  std_logic_vector(NUM_COLUMNS - 1 downto 0);
    waddr : in  std_logic_vector(NUM_COLUMNS * clog2(DEPTH) - 1 downto 0);
    wdata : in  std_logic_vector(NUM_COLUMNS * WIDTH - 1 downto 0);

    re    : in  std_logic_vector(NUM_COLUMNS - 1 downto 0);
    raddr : in  std_logic_vector(NUM_COLUMNS * clog2(DEPTH) - 1 downto 0);
    rdata : out std_logic_vector(NUM_COLUMNS * WIDTH - 1 downto 0)
  );
end entity acc_ram_bank;

architecture structural of acc_ram_bank is
  constant AW : positive := clog2(DEPTH);
begin

  col_gen : for c in 0 to NUM_COLUMNS - 1 generate
    ram_inst : entity work.generic_sdp_ram
      generic map (WIDTH => WIDTH, DEPTH => DEPTH)
      port map (
        clk   => clk,
        we    => we(c),
        waddr => unsigned(waddr((c + 1) * AW - 1 downto c * AW)),
        wdata => wdata((c + 1) * WIDTH - 1 downto c * WIDTH),
        re    => re(c),
        raddr => unsigned(raddr((c + 1) * AW - 1 downto c * AW)),
        rdata => rdata((c + 1) * WIDTH - 1 downto c * WIDTH)
      );
  end generate col_gen;

end architecture structural;
