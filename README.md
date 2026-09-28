# Lazuli

Lazuli is a VHDL implementation of a TPU (Tensor Processing Unit): a
hardware accelerator for transformer inference. The design targets an
Artix-7 prototype board and a Virtex UltraScale+ production board, and
is built up from generic, reusable primitives (FIFOs, RAMs, an fp32 ALU,
a table-driven lookup unit, a vector-unit tile, and the surrounding
structural building blocks) documented in `claude_docs/`.

**Author:** Christopher J. Cole.
