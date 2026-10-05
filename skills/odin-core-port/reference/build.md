# The toolchain, as measured on this machine

Compiler: `dev-2026-09-nightly:a2fb372`. Install from
<https://github.com/odin-lang/Odin/releases> — the Linux asset is
`odin-linux-amd64-dev-2026-09.tar.gz` (about 70 MB, extracts to one directory, no LLVM install
needed, and it runs against a stock Ubuntu 24.04 userland). Point the gates at it with
`export ODIN_BIN=/path/to/odin`; they SKIP loudly rather than pass silently when it is absent.

## Commands this project uses

| job | command |
|---|---|
| build an executable | `odin build spike/odin -out:spike/bin/prng-spike` |
| build an object file for inspection | `odin build spike/fma -build-mode:obj -o:aggressive -out:spike/bin/probe.o` |
| vet and style | `odin check -vet -vet-unused -vet-shadowing -vet-tabs -strict-style <pkg>` |
| run the corpus gate | `node --test tests/golden-fixtures.test.cjs` |
| everything at once | `./spike/gates.sh` |

Optimization levels are `-o:none|minimal|size|speed|aggressive` (default `minimal`). There is no
`-opt:2`. CPU features are `-microarch:x86-64-v4` and `-target-features:"..."`; `-target-features:"?"`
lists them. The vet flags above are the ones `odin check --help` lists.

## The FMA measurement (spec §14.3, closed)

Built `spike/fma/main.odin` — one `a*b+c` with operands the compiler cannot fold, taken from the
command line's length — and disassembled the object with `objdump -d`, counting FMA mnemonics
(`vfmadd|vfmsub|vfnmadd|vfnmsub|fmadd|fmsub`) and multiplies, so an empty file cannot pass:

| configuration | FMA instructions | multiplies |
|---|---|---|
| `-o:speed` | 0 | 7 |
| `-o:aggressive` | 0 | 7 |
| `-o:aggressive -microarch:x86-64-v4` | 0 | 7 |
| `-o:aggressive -microarch:x86-64-v4 -target-features:fma` | 0 | 7 |

So the compiler does not contract, even when explicitly told the hardware can fuse. The multiply
and the add stay separate, which is what the reference's two roundings require. Gate 3 of
`spike/gates.sh` repeats this on every run — this table is a record, not a defence.

## Syntax this compiler rejects, learned the slow way

| guess | reality in dev-2026-09 |
|---|---|
| `fmt` width/precision/hex verbs (`{:08x}`, `{:.6}`) | this compiler substitutes `{}` and nothing else; a brace verb comes back as literal text and the value lands at the end of the line, so a gate's own output looks corrupted. `printfln` also warns `%!(NO VERB)`. Build hex by hand (`spike/coast/main.odin` has a small one). |
| `for i in reverse 0 ..< n` | no `reverse` on ranges; use the C form `for i := n-1; i >= 0; i -= 1`. |
| mutating a proc parameter | parameters are read-only; copy it (`in:` is a reserved word, so don't reach for that name either). |
| closures capturing locals in a nested proc | procs are not closures; index the array inline or pass it. |
| bitwise `^` for XOR (it is deref only; the operator is `~`) | `x ~ y`. Copying the reference's `hashSeed` verbatim fails to parse, with an error pointing at the operand, not the operator. |
| `inout`/`ref` parameter modes | they do not exist in this compiler — `proc(x: ^u32)`, and read it as `x^`. Modes are a Rust/Go reflex worth unlearning early. |
| `*p` to read through a pointer | `p^` — the caret is postfix. `*a` is a syntax error ("Operator '*' is not a valid unary operator", suggesting `a^`). For new code prefer `inout`, which needs no deref syntax at all. |
| `fmt.println("{}", x)` interpolating | it does not — it prints its arguments space-separated and leaves the braces in the text, so a passing gate prints like a broken one. Use `fmt.printfln("{}", x)` (verified to interpolate). `tprintfln` also exists but **returns values that must be handled**, and `or_ignore` on it does not parse. |
| `cast[u32](x)` | `cast(u32)(x)`. Bare `u32(x)` also works. |
| `wrapping_mul(a, b)` | no such builtin — `a * b` on `u32` already wraps, as does `+` and `-` |
| `a +# b`, `a +^ b` | no wrapping/saturating operators in this version; plain operators are the wrapping ones |
| `strings.builder_free(&sb)` | gone; `strings.to_string(sb)` takes the builder **by value**. Simplest is to avoid the builder — the spike builds its key text in a stack array, so there is no allocation to free |
| `mem.dump_allocations(mem.track)` | not present — the REAL tracker is `mem.Tracking_Allocator` (found 5 Oct 2026, in `<install>/core/mem/tracking_allocator.odin`): `tracking_allocator_init(&t, backing)` / `tracking_allocator(&t)` / `tracking_allocator_destroy(&t)`, counting `total_allocation_count` / `total_free_count` / `current_memory_allocated`, with a per-allocation map whose entries carry the source-code location. Proven in `spike/mem/main.odin` (gate 7): a balanced context, a leak that is seen and named, and the arena-per-match shape balancing after a match ends. |
| `x := 1 << 32` as a constant | overflows an untyped constant and the error points at the cast nearby — write `4294967296.0` |

## Two things still unverified, stated as unverified

- **The leak tracker — found, named, proven.** It is `mem.Tracking_Allocator` (5 Oct 2026):
  `tracking_allocator_init(&t, backing)` / `tracking_allocator(&t)` / `tracking_allocator_destroy(&t)`
  over `core:mem/tracking_allocator.odin`, counting `total_allocation_count` / `total_free_count` /
  `current_memory_allocated`, with a per-allocation map that carries each call's source-code
  location. `spike/mem/main.odin` (gate 7) proves the three things the one-arena-per-match shape
  needs: a balanced context, a leak that is seen and named, and the arena shape itself balancing
  after a match ends. "Odin's harness tracks memory" may be repeated again — with the symbol named.
- **The browser suite cannot be run on this machine.** `~/.cache/ms-playwright` does not exist, so
  Playwright is absent here, and CI is off the repo (removed 5 October 2026, `docs/ci-disabled/`):
  nothing automated runs the visual suites anywhere. The honest sentence about the UI
  after a change is "nothing automated has looked at it", not "it is probably fine".

## The map gate, when it is attempted

`golden/map-line-b1040.json` is the next byte-diff after the vectors. There is no dedicated
generator to transcribe — no `js/simulation/mapgen.js`, no `generateMap`/`buildMap` symbol, no
terrain table in a constants module — so start from the *record* instead: find what writes
`type: "map"` with `seeds`, `spawns` and `resources`, and read backward from there. Expect tables
plus one placement loop, and expect the loop's `Math.max(1, Math.round(...))` edges to be where
the first mismatch appears. That is where the retired Rust port first diverged, and it is why the
map gate is a real gate rather than a formality.
