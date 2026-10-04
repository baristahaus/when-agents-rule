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
| bitwise `^` for XOR (it is deref only; the operator is `~`) | `x ~ y`. Copying the reference's `hashSeed` verbatim fails to parse, with an error pointing at the operand, not the operator. |
| `inout`/`ref` parameter modes | they do not exist in this compiler — `proc(x: ^u32)`, and read it as `x^`. Modes are a Rust/Go reflex worth unlearning early. |
| `*p` to read through a pointer | `p^` — the caret is postfix. `*a` is a syntax error ("Operator '*' is not a valid unary operator", suggesting `a^`). For new code prefer `inout`, which needs no deref syntax at all. |
| `fmt.println("{}", x)` interpolating | it does not — it prints its arguments space-separated and leaves the braces in the text, so a passing gate prints like a broken one. Use `fmt.printfln("{}", x)` (verified to interpolate). `tprintfln` also exists but **returns values that must be handled**, and `or_ignore` on it does not parse. |
| `cast[u32](x)` | `cast(u32)(x)`. Bare `u32(x)` also works. |
| `wrapping_mul(a, b)` | no such builtin — `a * b` on `u32` already wraps, as does `+` and `-` |
| `a +# b`, `a +^ b` | no wrapping/saturating operators in this version; plain operators are the wrapping ones |
| `strings.builder_free(&sb)` | gone; `strings.to_string(sb)` takes the builder **by value**. Simplest is to avoid the builder — the spike builds its key text in a stack array, so there is no allocation to free |
| `mem.dump_allocations(mem.track)` | not present — grepped the installed tree at `<install>/core/mem/*.odin` (the tarball has `core/` and `vendor/` at the top level, **not** `base/core/`, so a doc path like `base/core/mem` sends you grepping nothing and concluding a feature is missing). The leak tracker therefore needs finding before the first long-running match test; until then the arena-per-match discipline is unverified. |
| `x := 1 << 32` as a constant | overflows an untyped constant and the error points at the cast nearby — write `4294967296.0` |
