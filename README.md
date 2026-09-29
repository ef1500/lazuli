# Lazuli

Lazuli is a VHDL implementation of a TPU-style hardware accelerator for
transformer inference, targeting an Artix-7 prototype board and a Virtex
UltraScale+ production board. It's built bottom-up from generic, reusable
primitives (FIFOs, RAMs, an fp32 ALU, a table-driven lookup unit for
`exp`/`recip`/`rsqrt`/sigmoid/etc.) into the larger architectural units a
transformer forward pass needs: a weight-stationary systolic matrix array,
a quantized weight path (Q3_K/Q4_K/Q6_K), an activation quantizer, a
rescaler, an attention engine, and a vector unit for norms/RoPE/sampling.

The design and reasoning behind it live in `claude_docs/` (feasibility
study, architecture units, the full VHDL module list, and the
implementation spec every entity is built against).

## Status

Every entity built so far is real, synthesizable-style VHDL-2008 (behavioral
where the target is unambiguous, one Xilinx-primitive-instantiation
architecture where it isn't), each with its own self-checking testbench.
Run the whole suite with GHDL:

```sh
test/run_tests.sh
```

It compiles and simulates every testbench from a clean build and fails
loudly if any of them doesn't report `ALL PASS`.

**Built:**
- L0 structural primitives — registers, muxes, FIFOs (sync/async), RAMs
  (SDP/TDP), barrel shifter, leading-zero counter, round-and-saturate,
  round-robin arbiter, reset/pulse clock-domain crossing, ROM init
- The fp32 core — add/sub, multiply, max, int↔float and fp16↔fp32
  conversion, folded into one `generic_fpu` ALU
- A table-driven lookup unit (`generic_lookup`) for reciprocal, rsqrt,
  exp2, and range-based functions (sigmoid/SiLU/GELU)
- One vector-ALU lane (`generic_vector_unit`) and a full vector-unit tile
  (`lazuli.vhdl`) wiring several lanes together with FIFO-buffered
  operand/result queues
- **The matrix array (U9):** PE cell/column, input/output skew banks, the
  systolic array wrapper (chain-load and direct-write weight
  distribution), and its control sequencer
- **The weight path (U7):** Q3_K/Q4_K/Q6_K super-block unpackers and a
  double-buffered block reader/assembler
- **The rescaler (U10):** per-column group-scale accumulate, the fp32
  finishing sequencer, and the per-column accumulator RAM bank
- **Activation quantization (U8):** the abs-max → reciprocal → quantize
  pipeline and its double-buffered ping-pong store
- **The vector unit's sequencer (U12, partial):** the descriptor-walking
  operand sequencer that drives `lazuli.vhdl`

**Not yet built:** the attention engine (U11), the vector unit's top-k
sampler, the memory system (DDR arbitration, DMA, KV page management),
command/control (`cmd_link`, CSRs, perf counters), and tile/chip-level
integration (the reduce ring, tile/chip top).

See `CLAUDE.md` for the full build log — every design decision, every
bug found and fixed, and exactly what's built vs. still open.

## Repository layout

```
src/primitives/   L0/L1 generic building blocks (registers, muxes, RAMs,
                  fp32 ALU, lookup unit, integer MAC/accumulate)
src/array/        U9  — the matrix array
src/weight/       U7  — the weight path
src/rescaling/    U10 — the rescaler
src/activation/   U8  — activation quantize/store
src/attention/    U11 — the attention engine
src/vector/       U12 — vector-unit sequencer and sampler
src/memory/       L3  — memory system (not yet built)
src/control/      L4  — command/control (not yet built)
src/tile/         L5  — tile/chip top (not yet built)
test/             one self-checking testbench per entity, plus
                  test/run_tests.sh to run all of them
claude_docs/      the design docs everything here is built against
```

**Author:** Christopher J. Cole.
