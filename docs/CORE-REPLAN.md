# Core replan — drop the Rust port, re-score the language, and decide with a spike

Status: **a proposal for a planning session. Nothing here has been done.** No file has been
deleted, no tag made, no branch moved. Written at build 1055 (parent at b1054), after the
sync, because the sync is what made this question live: the parent now ships its own JS
re-simulation (`js/resim.js`, `tests/sim/`), so "a second implementation" is no longer a
fork-only virtue — there is already a second one in the parent, in JS.

The ask was: drop all our prior Rust code, review and update the design spec, and consider
Odin instead of Rust. This document prices all three, and ends with the two decisions only
you can make.

## 1. What we actually have (measured, not remembered)

    wired into the build (lib.rs: data, mapgen, prng, sim, state)   2,512 lines
      data.rs    435   the shared tables
      state.rs   746   the turn-1 state builder (the gate's subject)
      sim/vision.rs 429  sight, the spatial question
      sim/model.rs  363  the sim's data types
      mapgen.rs  242   the map generator
      prng.rs    183   hash, mulberry32, KeyedRng
      bin/golden_diff.rs 96, lib.rs 18
    NOT compiled by anything (lib.rs never declares them)           1,133 lines
      model.rs   647   an owner's draft
      match.rs   486   an owner's draft
    tests                                                          173 lines + the unit tests in-file

Against the reference it is **7% of the rules** (the rules are 37,099 lines of JS in `js/`).
What it does prove is not nothing: the map line reproduces byte for byte (942 nodes,
47,097 bytes) and the turn-1 state is byte-exact for all four seats, including the keyed
worker spread and the corrected clock. What it does not have: movement, commerce, economy,
combat, research, commands, win conditions — i.e. everything that makes a match. It is a
proof that the porting method works, not a port.

So the honest framing of "drop it" is: **we would be discarding a working gate and a
demonstrated method, not an in-flight product.** That is a legitimate thing to want to do.
It is not a thing we would lose much sleep over.

## 2. What survives a language swap, regardless of the choice

These are the durable assets, and none of them is Rust:

- **The fixtures.** `samples/golden/initial/golden-initial.jsonl` (26,629,752 bytes, 10 min)
  and `rust/core/golden/stream-1m.jsonl` (2,722,912 bytes). Byte-exact recordings of the
  rules at b1040, expensive to re-derive and independent of any port. They should move to
  `golden/` and be declared the contract of the *rules*, not of the Rust directory.
- **The extracted vectors**: the four turn-1 states (`initial-states.jsonl`), the map line,
  and the keyed-draw vectors taken from `js/simulation/rng.js` (0.6629751205909997 and
  0.6242878348566592 for `s0:start-workers` draws 0 and 1). In any language, the first test
  of a new core is these numbers.
- **The gate definitions** — "map line byte-identical, then turn-1 state byte-exact, then
  beats" — which are the phase P0 gate in the proposal §9 and are worth more than the code
  that first passed them.
- **The corrections we wrote down** (spec §3.4 and §13, proposal §9, `docs/FORK-DIVERGENCES.md`):
  notably that the golden's frozen clock was a build 934–949 bug and not an invariant, and
  that keyed draws are the reference's mechanism. A new core inherits both, in any language.

Deleting the Rust source without moving the first two would be the actual vandalism.

## 3. What the spec requires of a core (this is what scores a language)

The proposal §2 fixes five faces, and the core is required in three of them:
**browser = WASM**, desktop = native (Tauri), headless/server = native (`war-core` with
`--serve`, `--batch`, `--record`). §4 chose Rust on four grounds and rejected TypeScript,
C++, and WASM-only. The determinism contract (§4, spec §3.1): single-threaded, fixed
timestep, seeded, integer or fixed-point for balance-critical numbers, and everything on
the sim clock. Any candidate is judged on exactly those, and the two rejections in §4
(build-system tax; a GC or runtime in the hot path) apply to a new candidate as much as
they applied to C++ and TypeScript.

**The browser is the primary face** (§2 calls it "the existing primary"). That single line
is the whole language question, because it means the core must compile to WASM that runs a
half-hour match in a mid-tier browser without jitter — not eventually, but at P2.

## 4. Odin, scored on those criteria, with sources

Where it is genuinely strong:

- **No GC, no runtime, C ABI, manual memory** — Odin is closer to the metal than Rust and
  simpler than C++; for the headless binary and the Tauri sidecar it is a very good fit.
  The rejection that killed C++ (per-target build tax) does not kill Odin: one `odin build`
  command, one static binary, no CMake.
- **Simplicity as a maintenance argument.** Our own worst artefacts in this repo are the two
  unwired Rust drafts (1,133 lines that nothing compiles). A language where a file either
  compiles into the binary or is obviously not in it would have made that state harder to
  reach, and borrowing is the single largest idea-cost in the Rust port (`state.rs` is
  746 lines of a language whose compiler is the strictest reviewer we have; an agent
  writing that code pays that tax every session).

Where it is weak against *our* spec, with the evidence I checked today:

- **The browser WASM path is DIY.** The target exists (`-target:js_wasm32`,
  `freestanding_wasm32`) and there is a community binding library (`thetarnav/odin-wasm`),
  but the working reports are friction stories: web builds emitting `.obj` where `emcc`
  wants `.o`, `fmt` output wrong on `js_wasm32` (issue #5179, open), `wasm64` only half
  implemented (PR #5853), and web requests for Windows ARM64 still open. There is no Rust-
  `wasm-bindgen` equivalent in the official toolchain, so the snapshot boundary between
  core and renderer is hand-rolled. Compare Rust: `wasm32-unknown-unknown` is a
  first-tier target with a mature, official interop layer.
- **The determinism posture is undocumented, and ours must be exact.** I could find no
  statement anywhere about Odin's floating-point contraction (whether LLVM is allowed to
  fuse `a*b+c` into an FMA). For a sim whose contract is "byte-identical to the reference",
  an undocumented answer is a blocking unknown, not a detail — Rust documents that it sets
  `fp-contract=off` precisely so this cannot happen. Note the spec's own escape hatch
  helps either way: balance-critical values are integer or fixed-point, so the exposure is
  in positions, sight radii and the spawn jitter — which is exactly the class of number the
  turn-1 gate is byte-exact on today.
- **This product is about agents, and agents know Rust far better than Odin.** Every fix,
  port and review in this repo has been produced by an LLM agent. Rust's corpus is orders
  of magnitude larger; Odin code is more likely to be confidently wrong in exactly the
  places (target quirks, calling conventions, build flags) where wrong costs a day. That is
  a real engineering factor for a one-person-plus-agents project, and it cuts against the
  simplicity argument above.

Verdict for the session: **Odin is a strong candidate for a headless/desktop-only core and
a weak candidate for the browser-primary core the spec currently describes.** Which makes
the decision not "Rust or Odin" but "does the browser have to run the new core?"

## 5. Three options, with what each one costs

**A. Keep Rust, keep the port, keep going.** Nothing to delete; the P0 gate stays green as
of today. Cost: the port is 7% done and the language tax is permanent. Fails if you have
lost enthusiasm for Rust — enthusiasm is a real resource in a project like this, and
"we'll grind it out in a language nobody enjoys" is how side projects die.

**B. Odin, headless and desktop only; the browser keeps the parent's JS rules.** Delete the
Rust, write `war-core` in Odin (native only: `--serve`, `--batch`, `--record`), and let the
browser face run the JS rules as it does today, with the golden as the contract *between*
the two implementations and `js/resim.js` as the parent's own second opinion. This aligns
with the direction the parent has already taken, kills the two-sims tension instead of
deepening it, and puts Odin exactly where Odin is strong. Cost: the spec's §2 matrix says
"WASM" in the browser row and §8 says the web build ships a compiled core; both must be
rewritten, and the P2 "core defaults to the new core in the browser" milestone is
cancelled. Also cost: two engines forever in one repo (JS and Odin), reconciled by the
golden rather than by one implementation.

**C. Odin everywhere, browser included.** Delete the Rust, port to Odin including
`js_wasm32`, and accept hand-rolled JS interop plus the open bugs on that target. Cost: the
biggest, and the risk lands on the *primary* face. If Odin is the language you want to
write, B gets you that language for the headless binary where it shines, and the browser
question can be revisited when the target matures.

What is *not* on the list: keeping a half-ported core in a language we are no longer sure
about. That is the option that produced two unwired drafts, and it is the one to rule out
explicitly.

## 6. Settle it with a spike, not with this document

The golden makes the language question cheap, because there is one test with no opinion in
it: **produce the map line byte-identically — 942 nodes, 47,097 bytes — from
`golden/stream-1m.jsonl`.** That needs the hash, mulberry32, the terrain tables and the
placement loop, and nothing else. Roughly 500–700 lines, a day for an agent that knows the
fixture, in any language.

The spike is the decision:

1. Write it in Odin (`freestanding_wasm32` *and* native), against the fixture.
2. Write the same in Rust, or run the Rust we already have, which passes today.
3. Compare four numbers, not adjectives: bytes matched, lines written, hours to green, and
   whether the emitted LLVM IR contains an `fma` instruction (`llvm-dis`, grep; the answer
   must be none, or the build must forbid it).
   Whoever wins the map line wins the language, and if Odin wins it with no FMA and a clean
   native build, option B becomes C by evidence and my objection above is retired.

## 7. If the answer is "delete", do it in this order

1. **Tag first.** `git tag rust-core-final-b1040` on the commit that passes both gates.
   Then deletion is reversible by construction, and the byte-exact gate remains runnable by
   anyone who checks the tag out.
2. **Move the fixtures out of the Rust tree** before the delete, in the same commit set:
   `rust/core/golden/stream-1m.jsonl` → `golden/stream-b1040-1m.jsonl`,
   `rust/core/tests/goldens/initial-states.jsonl` → `golden/turn1-b1040.jsonl`, and the
   keyed-draw vectors into `golden/vectors.md` (they are the first test of any new core).
   Update `tests/golden-*`, the docs and the CI job paths.
3. **Then `git rm -r rust/`** — including the 1,133 dead lines, which is the part that
   costs nothing and reads like a relief.
4. **Edit `.github/workflows/ci.yml`** in the same commit: the cargo job goes, and if the
   spike has produced a new core by then, its job replaces it. A CI that silently stops
   gating the port is the failure mode this repo keeps hitting.
5. **Say so in the two ledgers** (`docs/FORK-DIVERGENCES.md` S1's "ported into the core"
   note, and `MERGE-STATE.MD`), and in `docs/QUALITY_REVIEW.md`, whose October addendum
   cites the Rust gates as evidence. Do not let the docs keep asserting a green gate that
   no longer exists — that is exactly the class of claim I have had to retract twice this
   week (a test count I never measured, and tooling that never existed).

## 8. What the spec and the proposal need reviewed, either way

Not a rewrite — six specific edits, each of which is currently written as if the language
question were closed:

- **§4 "Language: Rust"** and its rejected list: add Odin, with §4's own four criteria and
  §4's own evidence standard. It was never scored; scoring it is the honest version of the
  section whichever way it lands.
- **§2's matrix, browser row (`WASM`) and §8's `?core=wasm` flag**: under option B these
  become "the parent's JS rules, golden-checked" — a bigger edit and the true cost of B.
- **§9's P0 gate**: currently expressed against `rust/core` paths; re-point it at
  `golden/` and at whichever binary exists, so the gate is a property of the repo rather
  than of a directory.
- **§11.3 / the README's "no build step" claim**: option B *weakens* the compiled-core
  story for the browser and strengthens it for the server; the claim has to be re-decided
  in writing, as §2 promises.
- **§13.1 (the second clock)**: unchanged, and worth restating in the review, because it is
  the one requirement a new core cannot quietly miss — five wall-clock reads inside v1's
  sim still make full reproducibility depend on wall time.
- **The two-simulators question**, which is currently in `MERGE-STATE.MD` as a TODO and is
  really the agenda item: the parent's `js/resim.js` and our port answer the same question.
  Options B and C answer it differently, and the spec should say which.

## 9. Session agenda, three hours

| | minutes | what |
|---|---|---|
| 1 | 20 | Read §2, §4, §8, §9 together. Agree the criteria *before* the candidates. |
| 2 | 25 | Decide the browser question: must the new core run in the browser at P2? Everything follows. |
| 3 | 30 | Spec review, §8's six edits above, written into the document live. |
| 4 | 25 | Deletion order (§7), and the tag. Nothing deleted before the tag and the fixture move. |
| 5 | 30 | Authorise the spike: map line in Odin, native + `js_wasm32`, against the fixture. |
| 6 | 20 | Write the outcome into `docs/REBUILD_PROPOSAL.md` §4 and `MERGE-STATE.MD`, including a date to revisit the browser question. |

## 10. My recommendation

Take option **B plus the spike**, in that order, and delete the Rust only after the tag and
the fixture move:

- The parent has already made a JS re-sim the parent's answer. Fighting that in the browser
  is choosing a fight on the parent's strongest ground, on the face users care about, for
  the least benefit.
- The headless binary is where the product's distinctive claims actually live (§11.1's
  unwatched match, the corpus, the batch matrix, the hosted arena) — and it is where Odin is
  genuinely better than what we have.
- The spike is what makes this a decision rather than a preference. If Odin prints the map
  byte-identically, with no `fma` in the IR and one build command, it has earned the core,
  and the objection in §4 about WASM is a browser objection, not an Odin objection.

Two decisions, then: **does the browser have to run the new core**, and **may I tag, move
the fixtures and delete `rust/`** — after which the spike is the next thing I do.

## 11. No web — what that actually takes off the table, and what indie Odin people ship on

The web question was answered first (§9, item 2): **no web face for the new core.** That
single decision does four things at once, and two of them were not obvious from §4–§5.

**What it dissolves:** §4's WASM objection to Odin, which was the whole objection. With no
browser face, Odin's `js_wasm32` quirks (#5179, the `.obj`/`.o` emcc mismatch, no
`wasm-bindgen` equivalent) are somebody else's problem. It also dissolves §2's "one renderer
codebase, two shells" premise, because there is now one shell.

**What it does not dissolve:** the FP-contraction question (§4's blocking unknown), which is
about native code too and must still be answered by `llvm-dis | grep fma` on the spike's own
object file. And it does not dissolve the *spec edits*: §2's matrix, §8's `?core=wasm` flag
and §9's P2 milestone are load-bearing text that option B deletes.

**What indie Odin games ship on — measured today, not from memory.** The ecosystem is small
and it is worth knowing exactly how small: **18 Odin repositories above 150 stars, 3 above
1,000** (the compiler, `ols` the language server at 1,196★, and `awesome-odin`). Above 150
stars you find the compiler, a language server, an awesome-list, `odin-lang/examples`, and
then the game-relevant ones: `karl2d` (696★, a beginner-friendly 2D library),
`odin-raylib-hot-reload-game-template` (627★), `odin-http` (447★), `tina` (390★,
thread-per-core), `Skald` (172★, Elm-style declarative GUI), `odin-godot` (165★),
`odin-tracy` (159★). So: single-maintainer libraries, mostly, and the honest reading is
*"you will read the source of what you depend on"* — which is the same posture this repo
already has with zero npm dependencies.

The more important list is what the **compiler distribution itself vendors** — because that
is the part that is first-party, and for a native RTS-ish product it is almost the whole
indie stack, checked from the repository tree today:

    ENet, OpenEXRCore, OpenGL, box2d, box3d, cgltf, commonmark, compress, curl,
    darwin, directx, egl, fontstash, ggpo, glfw, kb_text_shape, libc-shim, libc, lua,
    microui, miniaudio, nanovg, portmidi, raylib, sdl2, sdl3, stb, vulkan, wasm, wgpu,
    windows, x11, zlib

Read that list against the proposal's own wish list and it maps almost line for line:

| the proposal wants | the vendored answer |
|---|---|
| low-latency native audio (§8, desktop) | `miniaudio` |
| a window with GL, on three OSes (§2, §7) | `sdl3` / `glfw` / `raylib`, plus `OpenGL`, `vulkan`, `directx`, `egl` |
| the "classic RTS look, refined" without a DOM (§7) | `nanovg` + `fontstash` for vector text and shapes, `microui` for immediate-mode panels |
| a hosted arena with real-time human play (§8, P4) | `ENet` for UDP transport and **`ggpo` — rollback netcode, vendored** |
| models, textures, archives | `cgltf`, `stb`, `OpenEXRCore`, `zlib`, `compress` |
| scripting for scenarios/anchors | `lua` |
| OS APIs, no CMake | `windows`, `darwin`, `x11`, and `libc` / `libc-shim` |
| being profiled, because a half-hour match must not jitter (§2) | `odin-tracy`, `spall-web` (both above 150★) |

`ggpo` deserves its own sentence, because it turns this decision from a subtraction into an
addition. We already have the two properties rollback netcode needs and most games have to
build: a deterministic, seeded, fixed-timestep sim and a full command log that replays
byte-exactly. A real-time human-vs-human mode — which the proposal only imagines as a
WebSocket relay — becomes a rollback game for the price of the transport, and the transport
is vendored too. That is a P4+ idea, not a plan item, but it is the kind of thing that makes
"no web" a vision rather than a loss.

**The trap this exposes, and it is the one thing §2 of the proposal gets wrong:** the desktop
shell was chosen as **Tauri**, and **Tauri's backend is Rust**. Choosing an Odin core and
keeping Tauri buys three languages in one product — JS UI, Rust shell, Odin sim — which is
the opposite of the simplicity argument that would make Odin attractive in the first place.
The three real options:

1. **Webview we own** (recommended): the Odin binary serves the existing UI over a local
   socket and opens a webview through its C API (`webview2` on Windows, `WebKitGTK` on Linux,
   `WKWebView` on macOS — thin bindings exist, and where they don't, it is one small C ABI).
   This keeps the DOM renderer and the analyzer — thousands of lines of working JS that no
   one proposes to rewrite — and makes the desktop face a native process with a browser
   widget in it, which is what Tauri is, minus the Rust.
2. **Native UI**: `microui` / `nanovg`, and rewrite the observer and analyzer. Months of work
   on the least deterministic part of the product, for a look the DOM already gets close to.
3. **Keep Tauri**: fastest to a polished shell, and it means Rust is in the product forever
   anyway — in which case §5's option A (keep the Rust core) is the more coherent choice, and
   we should say so rather than drift into a three-language stack by accident.

Note what option 1 implies about "no web": **the web stops being a *face*, but the web UI
stays.** The renderer and the analyzer are JS that read a *record* — they do not need to run
the sim, and the record is the product's spine (§6). The parent's browser game also keeps
working, in JS, exactly as it does now; our Odin core is the canonical engine for our
headless and desktop line, and the golden is the treaty between the two engines. Saying
that in one paragraph in §2 is the honest version of the change, instead of leaving a matrix
row that says "WASM".

## 12. Before writing any Odin: best practice, tooling, and the reference data agents need

Everything below was checked today against the compiler repository, the language's own
docs source, or the community index — and anything I could not verify is marked as such,
because the last two weeks have taught me that an unverified claim in a document is a
future retraction.

### 12.1 The toolchain is the linter, and the linter is the compiler

There is no separate lint step to adopt, and that matters for a project where agents write
most of the code: the style and danger checks ship with the compiler.

| job | command | where I checked |
|---|---|---|
| build | `odin build` | compiler repo, docs |
| test suite | **`odin test`** — a suite is an ordinary program; a test is an ordinary procedure; `core:testing` provides expectations, logging, and **a memory tracker** (leak detection in the test harness itself) | official `content/docs/testing.md` |
| lint / vet | **`odin check`**, with `-vet-*` and `-strict-style` flag families | community index (`awesome-odin`, Tooling section) — *confirm exact flag names at spike time* |
| language server | `ols` (1,196★, MIT), plus JetBrains, Emacs, Vim and a **Tree-sitter grammar** | community index |
| profiler | `odin-tracy` (159★) / `spall-web` | community index |
| the standard library | `core:` ships `testing`, `mem`, `sync`, `thread`, `net`, `nbio`, `container`, `simd`, `strconv`, `hash`, `crypto`, `reflect`, `fmt`, `log`, `prof`, `dynlib`, `os`, `path`, `io`, `text`, `unicode`, `debug` | compiler repo, `core/` |
| the third-party stack | the `vendor/` list in §11 (`sdl3`, `raylib`, `glfw`, `miniaudio`, `nanovg`, `microui`, `box2d`, `box3d`, `ggpo`, `ENet`, `cgltf`, `stb`, `lua`, `curl`, `zlib`, `wgpu`, `vulkan`, …) | compiler repo, `vendor/` |

For a sim that must run for half an hour without drifting, the two lines that decided the
choice are `core:testing`'s **memory tracker** and `core:mem`/the context allocator: the
proposal's "a match is a process, a record is a folder" (§8) becomes testable in the
language's own harness rather than through an external tool.

### 12.2 Idioms worth naming before an agent fights them

From the FAQ's own answers, in the language's own words — the guiding principles are
*"simplicity and readability"*, *"minimal: there ought to be one way to write something"*,
*"code is about expressing algorithms — not the type system"*, and *"the entire language
specification should be possible to be memorized by a mere mortal"*. That last one is the
project's argument in the language's own mouth: a core whose every rule must be checkable
by a reader, human or agent, wants a language that fits in a head.

Concretely, the four that an agent coming from Rust or TypeScript will trip on, and which
therefore belong in the skill file rather than in a review comment:

1. **No implicit numeric conversions.** Good for us — the cost/roster/age tables (§13.8's
   "one source of truth") cannot silently widen, and every promotion between integer and
   fixed-point is written down. It will also produce the first hundred agent errors.
2. **No exceptions, no `?` sugar of the Rust kind** — results and `or_return`/`defect`, with
   the error path explicit. Our contract already prefers named failures (the spec's
   "visible, not absorbed" rule), so this is alignment, not friction.
3. **The context system is the allocator.** Every allocation flows through a context; a
   long-running sim gets one arena per match and the memory tracker proves it drained. That
   is a *better* fit for §8's "a match is a process" than Rust's per-container `Vec`, and it
   is where the Odin choice earns real money rather than stylistic money.
4. **`distinct` types, no method syntax, no operator overloading.** The tables become
   `Cost`, `Age`, `Seat` that will not mix by accident, and everything is a plain procedure
   taking a value — which is exactly the shape a byte-exact port wants, because the
   operation order is written where it happens.

And one that goes our way by accident: the FAQ's answer on float width is *"the default
floating point type is `f64` so if in doubt, prefer `f64`"* — the reference is JavaScript,
so every number in the golden is already an IEEE-754 double. We would not be translating
precision, only order, which is the thing §14.3's `llvm-dis` check is there to protect.
Still unverified, and still the spike's job: whether the compiler may contract `a*b+c` into
an FMA. The FAQ does not say, nothing I found says, so it gets measured, not assumed.

### 12.3 There is no agent skill for this language, and several that pretend to be

This is the finding worth having before anyone goes looking. Searching the skills ecosystem
for "Odin" returns confident false positives, and every one of them is a name collision:

| what a search returns | what it actually is |
|---|---|
| `OutlineDriven/odin-claude-plugin` (46 agents, 25+ skills), `/odin-codex-plugin`, a Gemini CLI extension, a PR bragging about *"616 skills, one ledger, four surfaces"* | **O**utline-**D**riven **IN**velopment — a development methodology, unrelated to the language |
| `4Players/odin-agent-skills`, in a Nix package set too | agent skills for the **ODIN voice-chat SDK** and game-server hosting |
| `Odin-Core/skills`, `Odin-Agent-`, "Skills OS" | a different product named Odin |
| `edlokedev/odin-skills` (57 skills) | another bundle from the same unrelated pile |

Install any of them and an agent gets worse, not better: it will be told things about a
voice SDK or a diagram methodology while porting a simulation core. There is
`jakubtomsu/awesome-odin` (1,066★) as the human index, `ols` for the loop, and Tree-sitter
for tooling — but **no reference data written for agents, in either direction** (neither
"how to write Odin" nor "how an agent's defaults mislead it here").

So the plan includes authoring it, because that is the cheapest thing in this whole
decision and the one thing that makes the language-choice risk survivable:

    skills/odin-core-port/
      SKILL.md            when to use it, the definition of done, what "byte-exact" means here
      reference/build.md  pinned compiler version; the exact build and test commands; the
                          vet/strict-style flag set; the llvm-dis | grep fma check and its
                          expected zero
      reference/golden.md the fixtures and the vectors: the map line (942 nodes, 47,097
                          bytes), the four turn-1 states, the keyed draws
                          0.6629751205909997 / 0.6242878348566592, and how to regenerate
      reference/idioms.md the four traps in §12.2, with the compiler error each produces,
                          plus allocator-context rules for a long-running match
      reference/vendor.md the §11 map: which vendored library answers which proposal
                          requirement, and what stays banned (nothing from the web)
      gates.sh            one command: build, test, vet, byte-diff the map, grep the IR

The skill is not documentation-by-fashion. It is the mechanism that converts "the agents
know less Odin than Rust" from a reason not to choose Odin into a one-time cost — and unlike
a style guide nobody reads, `gates.sh` fails in CI whether anybody read the skill or not.

### 12.4 Two known-unknowns to settle in the spike, before any port

1. **FP contraction** (§14.3): `llvm-dis` the object file, count `fma` instructions, and
   find the flag or the build target that makes it zero. If nothing does, the determinism
   requirement beats the language preference and the decision reopens, in writing.
2. **The exact vet flag set** — **closed.** From `odin check --help`, not folklore: `-vet`
   (with `-vet-unused`, `-vet-unused-variables`, `-vet-unused-imports`, `-vet-shadowing`,
   `-vet-using-stmt`), `-vet-cast`, `-vet-semicolon`, `-vet-style`, `-vet-tabs`,
   `-vet-packages:`, `-strict-style`, `-strict-style-packages:`. Gate 4 runs
   `-vet -vet-unused -vet-shadowing -vet-tabs -strict-style` and requires *empty* output, so a
   mistyped flag cannot masquerade as a pass (it nearly did: `check` exits 0 while printing
   `Invalid flag`).

   Two open items replace them, both smaller: the leak tracker's real name in this `core:mem`
   (my grep used a wrong path — the tarball puts `core/` at the top level, not `base/core/`), and
   the first real shim cost for the webview, which §14.1's decision 4 says is the revisit trigger.

Everything else in §11 and §12 is verified enough to plan on. These two are the ones an
optimistic paragraph would have hidden.
