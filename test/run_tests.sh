#!/usr/bin/env bash
# Compiles and runs every testbench in test/ against src/ with GHDL, in
# dependency order, and fails (nonzero exit) if any of them reports
# anything other than "ALL PASS". Regenerate the golden vector files
# first if src/primitives/generic_fpu.vhdl or generic_lookup.vhdl
# changed (test/gen/gen_fpu_vectors.py, test/gen/gen_lookup_vectors.py),
# or if any of src/weight/q3k_unpack.vhdl/q4k_unpack.vhdl/q6k_unpack.
# vhdl's documented formula changes (test/gen/gen_q3k_vectors.pl,
# gen_q4k_vectors.pl, gen_q6k_vectors.pl -- Perl, not Python, since no
# Python interpreter was available when those were written).
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
# S3).
analyze "$ROOT/src/array/pe_cell.vhdl"
analyze "$ROOT/src/array/pe_column.vhdl"
analyze "$ROOT/src/array/act_skew.vhdl"
analyze "$ROOT/src/array/ctrl_skew.vhdl"
analyze "$ROOT/src/array/sys_array.vhdl"
analyze "$ROOT/src/array/weight_loader.vhdl"
analyze "$ROOT/src/array/array_seq.vhdl"

# L2 -- weight path (U7, claude_docs/08-vhdl-implementation-spec.md S4).
analyze "$ROOT/src/weight/wt_pack.vhdl"
analyze "$ROOT/src/weight/q3k_unpack.vhdl"
analyze "$ROOT/src/weight/q4k_unpack.vhdl"
analyze "$ROOT/src/weight/q6k_unpack.vhdl"
analyze "$ROOT/src/weight/wt_reader.vhdl"

# L2 -- rescaler (U10, claude_docs/08-vhdl-implementation-spec.md S2.2).
# generic_fpu.vhdl/generic_sdp_ram.vhdl/generic_lookup.vhdl are pulled
# forward from the L0/L1 block below (ghdl -a needs a direct 'entity
# work.X' instantiation's entity already analyzed, so these are analyzed
# here instead of twice) -- moved rather than duplicated, so they're
# removed from their original spot further down.
analyze "$ROOT/src/primitives/generic_fpu.vhdl"
analyze "$ROOT/src/primitives/generic_sdp_ram.vhdl"
analyze "$ROOT/src/primitives/generic_lookup.vhdl"
analyze "$ROOT/src/rescaling/group_scale_acc.vhdl"
analyze "$ROOT/src/rescaling/sb_finish.vhdl"
analyze "$ROOT/src/rescaling/acc_ram_bank.vhdl"

# L2 -- activations (U8, claude_docs/03-architecture-units.md's U8 /
# claude_docs/04-vhdl-module-list.md's act_quantizer/act_store rows).
analyze "$ROOT/src/activation/act_quantizer.vhdl"
analyze "$ROOT/src/activation/act_store.vhdl"

# L0 memory/queue primitives and L1/L2 compute units
analyze "$ROOT/src/primitives/generic_fifo.vhdl"
analyze "$ROOT/src/primitives/generic_vector_unit.vhdl"
analyze "$ROOT/src/primitives/generic_tdp_ram.vhdl"
analyze "$ROOT/src/lazuli.vhdl"

# L2 -- vector unit (U12, claude_docs/08-vhdl-implementation-spec.md
# S6.1's vec_seq). Only needs generic_register/project_types itself, but
# lives here since tb_vec_seq.vhdl drives a real lazuli.vhdl instance.
analyze "$ROOT/src/vector/vec_seq.vhdl"

# L2 -- attention engine (U11, claude_docs/08-vhdl-implementation-spec.md
# S5.1). qk_lanes/kv_reader are independent; softmax_online/pv_lanes need
# generic_fpu/generic_lookup/generic_sdp_ram/int_acc (already analyzed
# above); attn_finish additionally needs act_quantizer (already analyzed
# in the U8 block); attn_seq is a pure sequencer (project_types/generic_
# register only) but lives here with its siblings for readability.
analyze "$ROOT/src/attention/qk_lanes.vhdl"
analyze "$ROOT/src/attention/kv_reader.vhdl"
analyze "$ROOT/src/attention/softmax_online.vhdl"
analyze "$ROOT/src/attention/pv_lanes.vhdl"
analyze "$ROOT/src/attention/attn_finish.vhdl"
analyze "$ROOT/src/attention/attn_seq.vhdl"

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
analyze "$ROOT/test/tb_act_skew.vhdl"
analyze "$ROOT/test/tb_ctrl_skew.vhdl"
analyze "$ROOT/test/tb_sys_array.vhdl"
analyze "$ROOT/test/tb_weight_loader.vhdl"
analyze "$ROOT/test/tb_array_seq.vhdl"

analyze "$ROOT/test/tb_wt_pack.vhdl"
analyze "$ROOT/test/q3k_vectors.vhdl"
analyze "$ROOT/test/tb_q3k_unpack.vhdl"
analyze "$ROOT/test/q4k_vectors.vhdl"
analyze "$ROOT/test/tb_q4k_unpack.vhdl"
analyze "$ROOT/test/q6k_vectors.vhdl"
analyze "$ROOT/test/tb_q6k_unpack.vhdl"
analyze "$ROOT/test/tb_wt_reader.vhdl"

analyze "$ROOT/test/tb_group_scale_acc.vhdl"
analyze "$ROOT/test/tb_sb_finish.vhdl"
analyze "$ROOT/test/tb_acc_ram_bank.vhdl"
analyze "$ROOT/test/tb_rescaler_q4k.vhdl"

analyze "$ROOT/test/tb_act_quantizer.vhdl"
analyze "$ROOT/test/tb_act_store.vhdl"

analyze "$ROOT/test/tb_vec_seq.vhdl"

analyze "$ROOT/test/tb_qk_lanes.vhdl"
analyze "$ROOT/test/tb_kv_reader.vhdl"
analyze "$ROOT/test/tb_softmax_online.vhdl"
analyze "$ROOT/test/tb_pv_lanes.vhdl"
analyze "$ROOT/test/tb_attn_finish.vhdl"
analyze "$ROOT/test/tb_attn_seq.vhdl"

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
run_tb tb_act_skew
run_tb tb_ctrl_skew
run_tb tb_sys_array
run_tb tb_weight_loader
run_tb tb_array_seq
run_tb tb_wt_pack
run_tb tb_q3k_unpack
run_tb tb_q4k_unpack
run_tb tb_q6k_unpack
run_tb tb_wt_reader
run_tb tb_group_scale_acc
run_tb tb_sb_finish
run_tb tb_acc_ram_bank
run_tb tb_rescaler_q4k
run_tb tb_act_quantizer
run_tb tb_act_store
run_tb tb_vec_seq
run_tb tb_qk_lanes
run_tb tb_kv_reader
run_tb tb_softmax_online
run_tb tb_pv_lanes
run_tb tb_attn_finish
run_tb tb_attn_seq
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
