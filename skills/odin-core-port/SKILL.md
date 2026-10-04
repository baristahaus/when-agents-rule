---
name: odin-core-port
description: Write or review the Odin simulation core (spike/ then core/), its golden-vector gates, and the JS-to-Odin transcriptions that must be byte-exact. Use before editing anything under spike/ or core/, before claiming a port step matches the reference, or when an Odin build, vet flag, or cast syntax error is confusing — the reference files record this compiler's actual surface, which differs from common Odin folklore.
---

# Porting the rules to Odin

The rules of *When Agents Rule* are being transcribed from JavaScript (the reference, owned by
the parent repository) into Odin. A transcription is byte-exact or it is wrong; "close" is the
failure mode that hurts, because the numbers stay plausible while the divergence compounds. The
decision and its conditions are `docs/DESIGN_SPEC.md` §14; the arithmetic behind it is
`docs/CORE-REPLAN.md`.

## What to do, in this order

1. `./spike/gates.sh` before and after any edit. It builds, runs, disassembles, and checks the
   corpus. Its exit code is the answer.
2. Transcribe, never redesign. Copy the JS expression, then make Odin say the same thing. When
   Odin wants something structurally different, that is a signal to read the JS again, not to
   improve it.
3. Order the work by the golden: the map line (942 nodes, 47,097 bytes), then the four turn-1
   states, then a whole match. Each step is a gate the previous one already passed. See
   `reference/golden.md`.
4. Run `"$ODIN" check -vet -vet-unused -vet-shadowing -vet-tabs -strict-style` on what you wrote
   (the flags are from `odin check --help`, not folklore) and read every diagnostic — they are
   the compiler's own answer to "what would a reviewer catch later".

## The three rules that keep the determinism contract

- **Exact 32-bit integer arithmetic only.** The reference multiplies with `Math.imul`, which is
  modular, not `a*b|0` in floating point. Odin's `*`, `+`, `-` on `u32`/`i32` wrap, which
  matches — see `spike/odin/main.odin` for the transcription this project has already proved.
- **No fused multiply-add, ever.** `reference/build.md` records the measurement: this compiler
  emits none, even at `-o:aggressive -microarch:x86-64-v4 -target-features:fma`. Gate 3 of
  `spike/gates.sh` re-checks it on every run, because a contraction rounds once where the
  reference rounds twice, and that divergence is silent and seed-independent.
- **Floats are `f64`**, because the reference is JavaScript and every number in the golden is
  already an IEEE-754 double. Do not "optimize" to `f32`; that changes answers, not just speed.

## Things not to do

- Do not edit anything under `golden/`. The hashes are pinned in `golden/MANIFEST.json` and a
  test enforces them. Re-deriving the corpus is a decision with a section in
  `docs/CORE-REPLAN.md`, not a side effect.
- Do not read, import, or copy from the parent repository's `rust/` — it is deleted. The
  byte-exact Rust port is the tag `rust-core-final-b1040`, useful only as a second oracle.
- Do not trust an example's syntax from another Odin version. `reference/build.md` lists what
  this compiler rejects, and three of those four lines came from me guessing wrong.
