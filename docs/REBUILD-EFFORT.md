# Rebuild effort — the record of the Odin re-creation, and its lessons

Status: **the live record of the v2 rebuild effort** — where the port stands, what the method
is, what each piece cost, and what the effort is teaching us. Updated as work lands, not at
the end. Written 5 October 2026, and revised the same day after the branch reconciliation
and the b1054 merge; every number below was measured that day unless it names the date it
was measured.

What this document is *not*. It is not the product spec (`docs/DESIGN_SPEC.md` — what must be
true), not the plan (`docs/REBUILD_PROPOSAL.md` — what we build, in what order), not the
decision arithmetic (`docs/CORE-REPLAN.md` — why Odin, scored), and not the fork ledger
(`MERGE-STATE.MD` — where the fork stands against the parent). It is the record those four
kept deferring to each other: **the effort itself, and what it says about re-creating a
system like this one.** Where they disagree with this file, this file is wrong and says so
in its next revision; where they are silent, this file is the answer.

---

## 0. What this is studying

The fork exists to answer one question: **can a small team of LLM agents re-create a
complex, unfamiliar system — byte-exactly — from a reference it does not own, in a language
the agents barely know?**

- The **system** is the parent's browser game: 37,099 lines of top-level JavaScript, 44,135
  with `js/simulation/` and `js/engine/` (measured today; the smaller number is what
  `js/*.js` alone adds to).
- The **vehicle** is the Odin core (spec §14.1, decision 1) — a language chosen partly
  *because* agents know it poorly, which makes it a fair test of method-over-memory.
- The **measure** is the golden corpus: byte-exact recordings of the rules at build 1040,
  which a port either reproduces or does not, with no adjectives in between.
- The **point** is the lessons (§3), not the game. The Rust port that preceded this effort
  proved the method and was retired the day the question changed; nothing in this record
  should read as attachment to an artifact.

The evidence standard is the repo's, restated because it is the study's spine: **byte-exact
or wrong** ("close" keeps the numbers plausible while the divergence compounds); **measured
or marked unverified** (an unverified claim is a future retraction — this repo has
retracted a test count, a tool list, a file path and a whole harness that never existed);
**corrected in place, with the date**, where the next reader will land.

## 1. Where the effort stands — measured 5 October 2026

### 1.1 The gates, all green (run today)

`./spike/gates.sh`, eight gates, zero red — run locally, with the compiler at
`dev-2026-09` (CI is off this repo since the owner's decision the same day;
`docs/ci-disabled/` records the decision and keeps both workflow files):

| gate | what it proves | today's answer |
|---|---|---|
| 1 | the compiler, present and named | `dev-2026-09-nightly:a2fb372` |
| 2 | keyed vectors `#a9b8bccd` / `#9fd153da` | ok — the RNG transcription is exact |
| 2b | node counts 98/784/40/20 (the base, pre-clearance) | ok — nothing was dropped |
| 2d | coast table, `f32` **bit patterns** | ok — the noise lattice and wobble match |
| 2e | map lines, **four conditions** | byte-identical, re-measured 5 Oct 2026 after the re-record: `golden medium 4` 48,718 B (941 nodes); `alpha easy 2` 63,621 B; `alpha hard 3` 14,831 B; `beta medium 4` 48,586 B |
| 3 | no FMA, even forced | ok — 0 fused, 9 multiplies at `-o:aggressive -microarch:x86-64-v4 -target-features:fma` |
| 4 | `odin check -vet -vet-unused -vet-shadowing -vet-tabs -strict-style` | ok — no diagnostics |
| 5 | the golden corpus | ok — the fixtures are the pinned bytes and the states oracle regenerates |
| 6 | turn-1 state view, 8 lines | ok — 45,840 bytes byte-identical, gate 6 (measured 5 Oct) |
| 7 | leak tracker | ok — mem.Tracking_Allocator named and proven, gate 7 (measured 5 Oct) |

### 1.2 The corpus — the treaty, pinned and regenerating

`golden/MANIFEST.json` pins nine files by sha256 and byte count, enforced by
`tests/golden-fixtures.test.cjs` (which is why the suite grew from 622 to **628 tests,
628 pass, 0 fail, ~55 s — measured today**). Two properties matter more than the list:

- **The oracle regenerates.** Gate 5 re-runs `tools/golden/dump-states.cjs -at 0,1000`
  (civs `egyptian,greek,persian,yamato`) through `tools/golden/canonicalize-states.cjs`
  and byte-compares against `golden/states-b1040-t0-t1.canonical.jsonl` — 45,840 bytes,
  8 lines. The one-minute stream is checked the same way, by command
  (`tools/golden/record.cjs` and a `cmp`) — run locally; CI, which used to repeat it,
  is off the repo (`docs/ci-disabled/`). A fixture that cannot be
  regenerated is a rumour; none of the gates depend on a rumour.
- **One capture is provenance, not an oracle.** `golden/turn1-b1040.jsonl` (21,147 bytes)
  cannot be reproduced by today's reference at any whole step — its unit positions are the
  opening ones, its clock reads 1, and its `map`/`nodes`/`nearestNodes` match no single
  moment. The manifest says so, the corpus test asserts it, and §3's L4 records why.

### 1.3 The middle layer — the frozen JS port (gate green, b1054-current)

`tools/trace-states-port.cjs`, **1,807 lines**, is a re-implementation of the
entire turn-1 path — RNG, terrain, civ tables, the game core, `WarPositionRules`, the
250 ms discovery beat, and the whole `observe()` state view — run headless in Node.
Measured today: `node tools/trace-states-port.cjs golden/states-b1040-t0-t1.canonical.jsonl`
prints **`GATE PASS: 8 lines, byte-identical`** — before and after the b1054 merge, whose
elimination semantics it was updated to match the same day (the superseded fork gate inside
`canAffordAnyMilitary` removed, the parent's `room` gate and climb-back clauses transcribed
into the predicate). One part of the reference is honestly *not* transcribed yet: the
b1041/b1042 enemy-unit memory machinery, invisible at this gate's two moments and required
at the first gate with contacts in it (P0(c)); the port's header says so. Why the layer
exists and what it cost is §2's layer 3; how to read it is `spike/turn1/HANDOVER.md` §2
(a line map from a keyed draw to the canonicalizer).

### 1.4 The Odin transcription — gate green, 8 lines byte-identical

`spike/turn1/main.odin`, **3,034 lines**, is the transcription of the port into
Odin: one file, package `main`, byte-exact against the same 8-line fixture. Measured today,
not inherited:

- `odin build spike/turn1/main.odin -file` compiles clean; the driver runs and writes
  45,840 bytes; `cmp` against the golden is byte-identical — all four seats at t=0 and
  t=1000, all 21 sections each. The verification is wired into `spike/gates.sh` as gate 6
  (build, run, cmp), so the ledger owns it now, not a handover.
- The road there was an error-class catalogue the compiler wrote. The handover expected one
  syntax break (the cut-off tail) and instead found a full stratum of guessed syntax —
  Python and JS ternaries, Go-style `type X struct`, JS array literals and named-field
  colons, brace-grouped imports, `var`/`const` declarations, a `switch` with no `default`
  label in this compiler, proc values that do not capture an enclosing scope (the terrain's
  and make_eyes' closures were hoisted to file scope with their state threaded by
  pointer), `%` on floats (`m_fmod` ports the ECMAScript remainder, Sterbenz-exact at
  every step), `math.round` where JS rounds ties toward +inf (`floor(x+0.5)` now,
  including for the negative node coordinates), and one load-bearing bug the run found
  after the compile: `bits64` used `cast(u64)(x)` — the numeric conversion — so every fdlibm
  branch threshold compared against garbage (`rem_pio2` returned n=0 for π/2,
  `sin(-π/2)` printed 0). `transmute`, not `cast`; after it, `cos(π/2)` printed
  6.123233995736766e-17, bit-identical to Node.
- `j_f64` is the ECMA-262 `Number.prototype.toString` rule on top of strconv's shortest
  digits — Odin's `%v` switches to exponents at 1e8 and pads them; JS does not
  ("123456789.125", "1e-7").
- What the port leaves to later gates, recorded rather than hidden: the b1041/b1042
  enemy-unit memory and the enemy-building memory with its `id/owner/visible` entry shape
  are invisible at this gate's two moments (no seat's sight reaches another spawn) and
  become required at the first gate with contacts (P0(c)); the handover's own scoping,
  repeated in the commit that landed the step.
- What was already *good* in the file stayed alone: the fdlibm kernels and keyed RNG, the
  terrain tables, the civ data with `tech_ids` in tree order, `arena_spawns` and the keyed
  worker spread — and the worker positions at t=1000, after twenty steps of
  `WarPositionRules` pushes, came out byte-exact on the first run.

### 1.5 The suite and the tree

`npm test` → **671/671** (628 before the b1054 merge; the parent's 43 new tests included
— hold mode, enemy memory, history window, elimination-clear among them).
`node --test tests/contract.test.cjs` → 7/7. The ledger's caveat stands:
`npm test`'s glob runs `tests/*.test.cjs` and `tests/sim/*.test.cjs` only, so test files
sitting beside their `js/` sources are not in it.

The tree is committed and pushed: the four morning commits (the JS port, the turn-1 WIP
with its handover, the beads-skill retirement, the docs pass), the branch reconciliation,
and the b1054 merge with its ledgers. The working tree is clean.

### 1.6 The branches — measured, then decided (5 October 2026)

Measured in the morning: HEAD lived on `sync/upstream-b1039`, one commit past its remote
and seventeen past `origin/rebuild/v2`; `origin/main` measured as the parent's b1054 tip,
identical to `upstream/main`, which contradicted the ledger's "main = `33a1f11`, pushed".

Decided by the owner the same day, and enacted:

- **`origin/main` stays the parent's mirror.** The upstream path owns that branch; we do
  not push our line to it and we do not "fix" the mismatch — it is the design. All our
  work lives on our branches.
- **`rebuild/v2` is the v2 line again**, fast-forwarded from `c4a32da` to the effort's
  HEAD and pushed (`origin/rebuild/v2` = `1dae26a`). The proposal's §9 branch-hygiene
  sentence — "the work lands on `rebuild/v2`" — is true again, which is the point of
  reconciling rather than renaming.
- **`sync/upstream-b1039` is retired** (deleted locally and on origin; its tip was an
  ancestor of the new `rebuild/v2`). `work/v2-core`, a stale duplicate of the pre-merge
  snapshot, went with it. `save/pre-upstream-sync` = `33a1f11` stays as the abort path.
- The parent's fifteen builds are **absorbed** (b1040 → b1054, merged 5 October, §5's
  seventh item): three conflicts, one supersession found by their own test, the golden
  corpus measured unchanged by it. Our line carries **71 commits** since the fork point
  and is **0 builds behind** the parent.

## 2. The method — five layers, and why each exists

The effort did not start with this shape; it is what the map, the state view and one
retired language taught. Each layer exists because the layer below it was either
untrustworthy or unreadable, and each has a measured cost.

**Layer 0 — the reference.** The parent's `js/`, owned by them, authoritative for the
browser (spec §14.1, decision 5). It is the only definition of the rules — and it is
44,135 lines, DOM-entangled, with `observe()` alone spanning `js/openai-ai.js:2975–4079`
(≈1,105 lines, measured today; CORE-REPLAN §13 called it ~1,070). Nobody ports this
directly; every layer above exists to avoid having to.

**Layer 1 — the golden corpus.** Byte-exact recordings at build 1040, pinned by hash,
regenerated only by explicit decision (CORE-REPLAN's rule: "it fails" always means "the
port is wrong", never "the fixtures are stale"). Cost: a 10-minute and a 1-minute
recording, re-derived once at the merge. What it bought: a language-independent oracle —
the Rust port's byte-exactness survived the language swap precisely because the oracle
never knew what a port was.

**Layer 2 — the gates.** `spike/gates.sh`, run by hand (CI existed on this repo for
its first two days and is off it since 5 October 2026 — `docs/ci-disabled/`), ordered so each
gate is cheap where cheap is possible: vectors (≈120 lines) → counts (≈90) → coast (≈150,
as `f32` bit patterns) → map (≈230 plus a day of diagnosis) → FMA → vet → corpus. Three
design rules in the gates are load-bearing: a gate that cannot run **says SKIP and why**
("a green light from a check that did not execute is the worst kind of green"); the FMA
gate **counts multiplies first** so an empty object file cannot pass; and the map gate runs
**four conditions**, because one fixture hid the port's only real bug (§3, L2).

**Layer 3 — the frozen JS port.** `tools/trace-states-port.cjs`, 1,807 lines, born 5
October. The problem it answers: the state view is the *product* (it is what a model sees
every turn), it lives inside a 577 KB file inside the layer-0 bundle, and "transcribe
`observe()` from the browser game" means porting it twice — once to find out what it does,
once to do it. So the finding-out was made into an artifact: a single-file,
browser-free, Node-runnable re-implementation, **byte-verified against the same fixture
the Odin port must match**, small enough that a line map of it (HANDOVER §2) can serve as
a table of contents for the transcription. It also encodes quirks a diff would otherwise
attribute to the port: the two-mode `knownAmount` (observe-commit vs look), the NaN case
a coarse sight test produces, the 250 ms discovery beat that must not fire at t=0, the
monotonic rival-contact memory. Cost: one session, in the language the agents know best.
Payoff so far: the Odin WIP's verified-correct sections were transcribed from this file,
not from the game.

**Layer 4 — the Odin transcription.** `spike/turn1/main.odin`, transcribing layer 3 line
by line ("when in doubt, the port is the spec"). Two disciplines hold it to the reference:
byte-exact comparison against layer 1's regenerated oracle, and the compiler's own vet
(gate 4) for everything the bytes cannot see. It is the first layer with real language
risk — which is the study's point — and §3's L7 is the running account of that risk.

**The rules that hold the stack together**, stated once because every layer assumes them:
fixtures come from the reference, never from a port; a diff is `cmp`, not a similarity;
a claim is measured or marked unverified; session-minted ids are canonicalized before any
comparison; and the compiler is the reviewer of record — its diagnostics are free, fast,
and cannot be charmed.

## 3. The lessons — the study's findings so far

Each lesson is stated with its evidence; none is offered without one.

**L1 — Fixtures before code, and only from the reference.** The corpus predates every
green gate in this record, and it is what survived two language choices: the Rust port's
map line and the Odin map lines prove the *same* bytes, three weeks and one retirement apart
(47,098 at the first recording; 48,718 after the 5 October re-record below — the ports agree on
whichever is current, which is the point). The oracle must be produced by the thing being copied, never by the
thing being built — a port that generates its own fixtures is grading its own exam.

**L2 — One fixture is one condition.** The map port passed its one fixture and was wrong
at two and three seats: the spawn array was a fixed `[4]`, filled only as far as the seats
in play, and the keep-out loop iterated the whole array — so the unfilled tail sat at the
origin and rejected every stone and gold candidate. **The node counts stayed perfect.**
The bug cost a day of diagnosis and was invisible until a second and third condition
existed (`alpha/easy/2`, `alpha/hard/3`, `beta/medium/4` — about a minute each to record).
The general rule: a gate that checks one input tests one branch of every table behind it.

**L3 — "Close" is the failure mode that hurts.** The reference rounds stone
`round(20/3)=7` per seat at three seats, where `ceil` says 42 — and a `ceil` port *looked
correct at four seats*. The coast table is `Float32Array`, and comparing six decimal
digits is "exactly the slop that lets a wrong-coastline port look fine until positions
drift". This is why every gate is a `cmp`, and why the skill file's first rule is
"transcribe, never redesign".

**L4 — A fixture you cannot regenerate is a rumour, not a gate.** The legacy
`turn1-b1040.jsonl` capture matched no whole step of today's reference — unit positions
from t=0, a clock reading 1, map sections from neither moment — and a port diffed against
it would have chased a provenance artefact. The response was infrastructure, not caution:
`dump-states.cjs` (which names the moment in milliseconds, because "turn 1" is not a
moment), `canonicalize-states.cjs`, and a corpus gate that regenerates the oracle from the
reference on every run.

**L5 — Two look-alikes: locale and moment.** A first state dump reported `"Ägypter"`
because the bench harness loads no i18n and the reference's source strings are German; it
read as a stale core. The dumper now loads `js/i18n.js`, pins English, and *fails the run*
if a translated field did not change. With the moment question (L4) this makes the rule:
**when a state diff appears, decide which of three things it is — locale, moment, or a
real rule difference — before believing anything else.** The first two look exactly like
the third.

**L6 — Measure the claim; do not inherit it.** This repo has retracted, in writing: a
test count (6,074; the real number was 622, and is 628 today), a tool list that never
existed (`test/manifest.cjs`, `tools/gate-selftest.cjs` and friends), a spec path that
never existed (`docs/specs/REBUILD_SPEC.md`), a harness that never existed
(`js/war-harness.js`), and a misdiagnosis (the golden's frozen clock was a build 934–949
*bug*, not an invariant — the spec was wrong, not the fixture). Today's instance, found
while writing this record: the turn-1 handover quotes its target fixture at 49,555 bytes;
the file is 45,840 (corrected in place, with the date). In an agent-driven project prose
compounds errors unless something re-measures; here that something is the gates — which
fail on the next run whether or not anybody read the document. (They ran in CI for the
two days this repo had CI; it is off since 5 October 2026 — `docs/ci-disabled/` — and
the gates are unchanged, because a gate's teeth are the `cmp`, not the runner.)

**L7 — Agents write confident wrong Odin; the compiler is the cheapest reviewer.** The
first ~120-line spike needed four syntax corrections *found by the compiler, not by
memory* (XOR is `~` not `^`; deref is postfix `^`; no `inout`/`ref` modes; `fmt.println`
does not interpolate). `skills/odin-core-port/reference/build.md` now records a table of
rejected guesses — width verbs, `reverse` ranges, read-only parameters, no closures,
`cast(u32)(x)`, no `wrapping_mul` builtin, `strings.builder_free` gone — and today's WIP
adds the largest class yet: **single-quoted strings**, which Odin reads as rune literals,
in the civ tables of a 2,028-line file. The mitigation is mechanical, not attitudinal: a
reference file of this compiler's actual surface, and gates that fail without a human in
the loop. The cost of each correction is seconds; the cost of *not* making them is a port
that diverges silently — which is the one failure this method exists to prevent.

**L8 — Determinism unknowns are measured, not assumed — and re-measured by gate.** Odin's
floating-point contraction is documented nowhere, so it was measured: four build
configurations, including FMA explicitly enabled, produce **zero fused instructions**
(`llvm-dis`/`objdump`, counted). Gate 3 repeats the count on every run and checks the
multiply count first, because a compiler release is exactly the kind of thing that changes
quietly. The vet flags came from `odin check --help`, not folklore — after `check` was
caught exiting 0 while printing `Invalid flag`, which is a mistyped flag *masquerading as
a pass*. And the honesty runs both ways: the memory-leak tracker's real name was unfound for
a week — the repo's own reference file said "do not repeat 'Odin's harness tracks memory'"
rather than inheriting the claim from CORE-REPLAN §12.1 — and then it was found, named
(`mem.Tracking_Allocator`, `core:mem/tracking_allocator.odin`) and proven
(`spike/mem/main.odin`, gate 7), which is what withdrawing a claim until its check exists
looks like.

**L9 — The middle layer converts "port the game" into "transcribe the port".** 1,807
lines of JavaScript — the agents' strongest language — bought a headless runnable spec, a
line map that doubles as the Odin work's table of contents, an encoding of the quirks
(L4/L5's classes of confusion), and a second opinion on the rules. The alternative was
transcribing a ~1,105-line `observe()` out of a DOM-entangled 44,135-line bundle, twice.
The layer is also this effort's clearest *method* finding: when the cost of a step is
much larger than the plan assumed, **add a layer; do not grind.** Its own fate is §5's
sixth item.

**L10 — Costs, measured, reshape the plan.** CORE-REPLAN §13 priced turn 1 honestly
("it is not the next file; it is the game") and the plan bent: dumper first, data model
before tick, `observe()` last. The measured ladder so far: vectors ≈120 lines; counts ≈90;
coast ≈150; map ≈230 plus a day of diagnosis; the dumper and canonicalizer small; the JS
port 1,807 lines in one session; the Odin transcription 2,028 lines and unfinished —
against a Rust-era turn-1 gate that cost 746 lines of `state.rs` for a *smaller* oracle
(4 raw states, one moment, no canonical form). The two numbers are not comparable as
"Odin vs Rust" until the gate lands; they are comparable as evidence that the oracle
got richer and the method grew to match.

**L11 — Reproducibility needs a canonical form, not just reproducible bytes.** v1 mints
seat ids from `Math.random` by design; keyed draws make the *bytes* reproducible, but only
in first-appearance order, so `canonicalize-states.cjs` re-keys to `seat<n>` and
first-appearance entity ids before any comparison — "a fixture that only matches under one
id scheme would hide a drift in exactly that scheme". The same discipline exists between
two recorded runs (`tools/golden/compare.cjs`), which is what makes "byte-identical" a
statement about the rules rather than about one session's random numbers.

**L12 — Honest instrumentation is part of the study.** The beads tracker's embedded
backend accepts creates and refuses every update and close — measured, not guessed, and
recorded with the exact failures (`docs/MERGE-STATE.MD`, 2026-10-04): "a tracker you can
append to but never close is worse than no tracker." The CI workflow describes itself as
"a claim about a machine I am not on"; Playwright is absent on this box, so the honest
sentence about the UI is "CI has not looked at it". A study about verification cannot
launder its own bookkeeping failures — they get recorded with dates, like everything else.

## 4. The design as it stands (v2 in brief)

The depth lives in the spec and the proposal; this is the state of it, so the record is
complete without six documents open.

**The three bets** (proposal §1): **B1** a deterministic core, written once, run
everywhere it matters; **B2** the agent harness as a daemon that owns the provider
conversation and writes the full trace; **B3** a match's record as a folder — transcript,
frame-accurate events, per-seat traces — complete by construction.

**The faces** (proposal §2, amended by spec §14): the browser keeps the parent's JS and
every v1 property ("open the folder and play") — **v2 ships no browser core**; the
desktop is one native binary around a webview the project owns (Tauri rejected on one
fact: its backend is Rust); the headless binary is `war-core` (`--serve`, `--batch`,
`--record`); a hosted arena is P4 and optional; mobile is a spectator, later.

**The phases and their gates** (proposal §9): P0 the core, P1 the trace, P2 the face,
P3 the eyes, P4 optional. No phase starts until the prior one is green. Where P0 stands
today:

| P0 gate step | status |
|---|---|
| (a) map line byte-identical | **green** — four conditions, re-measured 5 October 2026 (the true 800-world maps, post Town Center clearance) |
| (b) turn-1 state view byte-identical | **green** — 8 lines, 45,840 bytes, byte-identical in both the JS port and the Odin port (gate 6), measured 5 October 2026 |
| (c) state sequence for a fixed seed set | **not started** — the first gate with real size (a 2.7 MB stream), where the method meets its scaling test (§6) |

**The decisions closed** (spec §14.1): Odin for the core; no browser face for it; the
web UI survives its demotion (it reads a record); no Tauri; the golden is the treaty
between engines. **The reopen triggers** stand as written: fused multiply-add in the
compiler's output (measured zero, re-checked every run — gate 3); the first webview shim
costing more than a few days (§14.3's fallback: reconsider the shell, not ship three
languages by drift).

**Still open, needing an owner's call** (proposal §10, items 3–5): whether v2 ends at P3
or includes P4; whether the small embedded mesh set is acceptable for §7's look; the
name (`war-core`, alias `war`). Plus one this record adds: the fate of layer 3 once the
turn-1 gate lands (§5, item 6).

## 5. The road ahead, in order

1. **Land the turn-1 gate — done, 5 October 2026.** The handover's §7 order ran to the
   end: the tail repaired and a `main` stubbed, the four shape bugs fixed, the four
   missing sections transcribed, `stepOnce` and the driver added, all 8 lines
   byte-identical (45,840 bytes, the four t=1000 lines on the first run after the
   step machinery landed — the worker positions survived twenty steps of
   `WarPositionRules` pushes bit-exactly). The gate is wired into `spike/gates.sh` as
   gate 6 (build, run, `cmp`), per this record's own rule that a gate living only in
   a handover is a wish with a deadline.
2. **Commit the working tree — done, 5 October 2026.** Four commits, in the shape the
   first draft of this record proposed: the JS port ("the turn-1 spec, frozen"), the
   turn-1 WIP with its handover, the beads-skill retirement, and the docs pass itself.
3. **Reconcile the branches — done, 5 October 2026.** The owner decided: `origin/main`
   stays the parent's mirror (the upstream path owns it; our work lives on our branches),
   `rebuild/v2` was fast-forwarded to HEAD and pushed, and the `sync/upstream-b1039` line
   was retired. What remains of the branch question is the parent's 15 unmerged builds —
   item 7 below.
4. **The two owed items — both resolved, 5 October 2026.** The Town Center clearance:
   already transcribed twice over (the JS port's createMatch, the Odin port's
   terrain_clear_near) and gate-verified where it bites — and auditing it found the
   recorder's missing terrain size argument, so the map fixtures were re-recorded at the
   true 800-world and the clearance now removes nodes in every recorded condition (the
   re-record's story is CORE-REPLAN §15). The leak tracker: `mem.Tracking_Allocator`,
   named and proven in `spike/mem/main.odin` (gate 7) — a balanced context, a
   seen-and-named leak, and the arena-per-match shape balancing after a match ends; the
   one-arena-per-match shape now rests on a check, not on `Arena` plus discipline.
5. **After turn 1.** The tick is already in scope (`stepOnce` is part of the gate); a
   whole match then needs the rule brain, which is the first *behaviour* the port will
   have to agree on rather than a projection of state; then the P0(c) state-sequence
   gate; then P1 (the daemon, the event stream, the match folder) per the proposal.
6. **The fate of layer 3 — decided 5 October 2026, the day the turn-1 gate landed.**
   `trace-states-port.cjs` stays as **the line-map spec for the remaining transcription**,
   with a stated end date and a declined alternative:
   - **Why it stays:** the remaining gates still read it. The enemy-unit memory (b1041/42),
     the enemy-building memory, the rule brain and the whole-match sequence (P0(c)) are
     transcribed from its functions — its header already says which parts of the reference
     it does not carry, and those are exactly the parts the contacts gate will need first.
     Retiring it now would orphan the next gates' spec.
   - **Its end date:** when the Odin port covers a whole match (the rule-brain gate green,
     P0(c) green), the Odin port becomes the second oracle and this port retires — to
     provenance, like the raw captures: the frozen spec the transcription was read from.
   - **Declined: the standing second JS opinion.** The parent already ships `js/resim.js`
     as their second implementation; a third JS implementation without a stated role is a
     habit, not a check. The stated role is "the spec", and it has an end date.
   The decision is also stated in the port's own header, where the next reader will look.
7. **Absorb the parent's rules (b1040 → b1054) — done, 5 October 2026.** Merged at
   `c7fafd7`: three conflicts (their stamps, the taxonomy union with our `badCount`, their
   b1054 site clause), one supersession their own test caught (our room gate inside
   `canAffordAnyMilitary`, withdrawn — FORK-DIVERGENCES S5), D1–D4/D6 verified intact,
   D5 still open. **The golden corpus survived the merge byte for byte** — both the
   one-minute stream and the states oracle regenerate identically from the merged rules,
   because the recorded match exercises none of the changed paths — so no re-derivation
   was needed or done, and the b1040 fixtures are now proven against two rule versions.
   Our own reading of their changes and our direction is in the rules ledgers: a fork
   section in `docs/RULES-CHANGES.md`, the spec's §2/§4/§5/§13.2 updated for the absorbed
   rules, and the sync story in `MERGE-STATE.MD`.

## 6. What the study still wants to learn

The lessons in §3 are answered questions. These are the open ones, and they are the
reason the effort is worth its cost even if the game itself never ships a v2:

- **Velocity per gate, measured.** Lines and sessions per byte-exact gate, Odin against
  the Rust port at the *same* gate. Not comparable yet — the turn-1 oracle grew richer
  between the two — but comparable the moment gate (b) lands.
- **The agent-error taxonomy, growing.** `reference/build.md`'s rejected-guess table plus
  the rune-literal class from today is enough to see the shape: syntax guessed from
  Rust/JS intuition, and semantic traps (f32 vs f64, rounding discipline, no implicit
  conversions). Worth a per-gate tally once the port compiles — it is the raw material
  for the reference data no ecosystem provides (CORE-REPLAN §12.3's finding: there is no
  agent skill for this language, only name collisions pretending to be one).
- **Whether the middle layer generalizes.** Layer 3 was built for turn 1. The next gates
   — the tick, the rule brain, a whole match — will say whether "port the port" stays
   cheaper than "port the game" as the surface grows, or whether the JS layer becomes a
   second codebase to maintain.
- **Where the method stops scaling.** Byte-exact transcription has been cheap because
  every gate so far is small. P0(c) is a 2.7 MB stream — the corpus exists, but no port
  has yet been diffed against anything that size. That gate is where the method meets its
  first real scale, and the study should watch what breaks: the diff tooling, the
  diagnosis workflow, or the assumption that any divergence can be localized to a function.

## 7. The document map

| To answer | Read | Status |
|---|---|---|
| What must the product be? | `docs/DESIGN_SPEC.md` §0–13 | current |
| What was decided about the stack, and why? | spec §14 + `docs/CORE-REPLAN.md` §11–12 | current (the replan's §1–10 are the arithmetic behind a decision now taken; §13 is superseded by this record) |
| What is the v2 plan, in what order? | `docs/REBUILD_PROPOSAL.md` | current, amended for Odin (§2, §4, §8, §9, §10) |
| Where does the effort stand *right now*? | **this document** §1 | current — supersedes CORE-REPLAN §13, the skill's "next session" note, and the handover's status role |
| How does a port step get done? | `skills/odin-core-port/` (SKILL + `reference/`) + `spike/turn1/HANDOVER.md` | current (the handover is a mid-flight map; it retires when the turn-1 gate lands) |
| What are the fixtures and vectors? | `golden/MANIFEST.json` + `skills/odin-core-port/reference/golden.md` | current |
| Where does the fork stand against the parent? | `MERGE-STATE.MD` + `docs/FORK-DIVERGENCES.md` | current (ledger updated 5 October 2026) |
| Why is the tracker append-only? | `docs/MERGE-STATE.MD` (the 2026-10-04 note) | current |
| What did the quality review find? | `docs/QUALITY_REVIEW.md` | v1-era; historical |
| What changed in the rules, build by build? | `docs/RULES-CHANGES.md` | v1-era; the parent's convention |
| The v1 renderer branch? | `ENGINE.md` | parent-surface work, unrelated to the rebuild |

---

*How to keep this record honest: update §1 when a gate changes colour, with the date and
the run's numbers; add lessons in §3 only with evidence; correct wrong numbers in place
where the next reader will find them, never in a footnote elsewhere; and mark anything
this file cannot measure as unverified rather than softening it. The gates are the
arbiters — this document is their interpreter.*
