#!/usr/bin/env bash
# Compiles and runs every testbench in test/ against src/ with GHDL, in
# dependency order, and fails (nonzero exit) if any of them reports
# anything other than "ALL PASS". Regenerate the golden vector files
# first if src/primitives/generic_fpu.vhdl or generic_lookup.vhdl
# changed (test/gen/gen_fpu_vectors.py, test/gen/gen_lookup_vectors.py).
#
# Usage: test/run_tests.sh [--keep]
#   --keep   don't delete the scratch work directory when done (for
#            poking at it with `gtkwave`/`ghdl --vcd` afterward)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/test/.work"
STD=08

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

KEEP=0
if [[ "${1:-}" == "--keep" ]]; then
  KEEP=1
fi

analyze() {
  ghdl -a --std=$STD --work=work "$@"
}

FAIL=0
run_tb() {
  local tb="$1"
  local logfile="$WORK/$tb.log"
  ghdl -e --std=$STD --work=work "$tb"
  if ! ghdl -r --std=$STD --work=work "$tb" > "$logfile" 2>&1; then
    echo "SIMULATION CRASHED: $tb"
    cat "$logfile"
    FAIL=1
    return
  fi
  if grep -q "ALL PASS" "$logfile"; then
    echo "PASS  $tb"
  else
    echo "FAIL  $tb"
    grep -i "fail\|error" "$logfile" || cat "$logfile"
    FAIL=1
  fi
}

echo "== analyzing src/ =="
analyze "$ROOT/src/pkg/project_types.vhdl"

# L0 structural building blocks, in dependency order (each of these
# instantiates only entities analyzed before it).
analyze "$ROOT/src/primitives/generic_register.vhdl"
analyze "$ROOT/src/primitives/generic_mux2.vhdl"
analyze "$ROOT/src/primitives/generic_mux.vhdl"
analyze "$ROOT/src/primitives/generic_lzc.vhdl"
analyze "$ROOT/src/primitives/generic_delay_line.vhdl"
analyze "$ROOT/src/primitives/generic_barrel_shift.vhdl"
analyze "$ROOT/src/primitives/generic_round_sat.vhdl"
analyze "$ROOT/src/primitives/generic_rr_arb.vhdl"
analyze "$ROOT/src/primitives/generic_reset_sync.vhdl"
analyze "$ROOT/src/primitives/generic_pulse_cdc.vhdl"
analyze "$ROOT/src/primitives/generic_bin2gray.vhdl"
analyze "$ROOT/src/primitives/generic_rom_init.vhdl"
analyze "$ROOT/src/primitives/generic_async_fifo.vhdl"

# L1 arithmetic (claude_docs/04-vhdl-module-list.md S2.1/S2.2): the
# array's only compute primitive and the rescaler's integer path.
analyze "$ROOT/src/primitives/int_sum_tree.vhdl"
analyze "$ROOT/src/primitives/int_absmax_tree.vhdl"
analyze "$ROOT/src/primitives/int_mul_scale.vhdl"
analyze "$ROOT/src/primitives/int_acc.vhdl"
analyze "$ROOT/src/primitives/dsp_mac2.vhdl"

# L2 -- the matrix array (U9, claude_docs/08-vhdl-implementation-spec.md
# S3): pe_cell/pe_column so far.
analyze "$ROOT/src/array/pe_cell.vhdl"
analyze "$ROOT/src/array/pe_column.vhdl"

# L0 memory/queue primitives and L1/L2 compute units
analyze "$ROOT/src/primitives/generic_fifo.vhdl"
analyze "$ROOT/src/primitives/generic_fpu.vhdl"
analyze "$ROOT/src/primitives/generic_lookup.vhdl"
analyze "$ROOT/src/primitives/generic_vector_unit.vhdl"
analyze "$ROOT/src/primitives/generic_sdp_ram.vhdl"
analyze "$ROOT/src/primitives/generic_tdp_ram.vhdl"
analyze "$ROOT/src/lazuli.vhdl"

echo "== analyzing test/ =="
analyze "$ROOT/test/tb_generic_base.vhdl"
analyze "$ROOT/test/tb_generic_lzc.vhdl"
analyze "$ROOT/test/tb_generic_barrel_shift.vhdl"
analyze "$ROOT/test/tb_generic_round_sat.vhdl"
analyze "$ROOT/test/tb_generic_rr_arb.vhdl"
analyze "$ROOT/test/tb_generic_reset_sync.vhdl"
analyze "$ROOT/test/tb_generic_pulse_cdc.vhdl"
analyze "$ROOT/test/tb_generic_bin2gray.vhdl"
analyze "$ROOT/test/tb_generic_rom_init.vhdl"
analyze "$ROOT/test/tb_generic_async_fifo.vhdl"

analyze "$ROOT/test/tb_int_sum_tree.vhdl"
analyze "$ROOT/test/tb_int_absmax_tree.vhdl"
analyze "$ROOT/test/tb_int_mul_scale.vhdl"
analyze "$ROOT/test/tb_int_acc.vhdl"
analyze "$ROOT/test/tb_dsp_mac2.vhdl"

analyze "$ROOT/test/tb_pe_cell.vhdl"
analyze "$ROOT/test/tb_pe_column.vhdl"

analyze "$ROOT/test/tb_generic_fifo.vhdl"
analyze "$ROOT/test/fpu_vectors.vhdl"
analyze "$ROOT/test/tb_generic_fpu.vhdl"
analyze "$ROOT/test/lookup_vectors.vhdl"
analyze "$ROOT/test/tb_generic_lookup.vhdl"
analyze "$ROOT/test/tb_generic_vector_unit.vhdl"
analyze "$ROOT/test/tb_generic_sdp_ram.vhdl"
analyze "$ROOT/test/tb_generic_tdp_ram.vhdl"
analyze "$ROOT/test/tb_lazuli.vhdl"

echo "== running testbenches =="
run_tb tb_generic_base
run_tb tb_generic_lzc
run_tb tb_generic_barrel_shift
run_tb tb_generic_round_sat
run_tb tb_generic_rr_arb
run_tb tb_generic_reset_sync
run_tb tb_generic_pulse_cdc
run_tb tb_generic_bin2gray
run_tb tb_generic_rom_init
run_tb tb_generic_async_fifo
run_tb tb_int_sum_tree
run_tb tb_int_absmax_tree
run_tb tb_int_mul_scale
run_tb tb_int_acc
run_tb tb_dsp_mac2
run_tb tb_pe_cell
run_tb tb_pe_column
run_tb tb_generic_fifo
run_tb tb_generic_fpu
run_tb tb_generic_lookup
run_tb tb_generic_vector_unit
run_tb tb_generic_sdp_ram
run_tb tb_generic_tdp_ram
run_tb tb_lazuli

cd "$ROOT"
if [[ $KEEP -eq 0 ]]; then
  rm -rf "$WORK"
fi

if [[ $FAIL -ne 0 ]]; then
  echo "== ONE OR MORE TESTBENCHES FAILED =="
  exit 1
fi
echo "== all testbenches passed =="
