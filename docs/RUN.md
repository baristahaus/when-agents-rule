# Running our version of the engine — and what is left before it can be used as is

Status: 5 October 2026. Branch `rebuild/v2`. Written the day the ledger's §5 list
cleared through item 6; this file answers the two questions a new session asks first:
*what runs today*, and *what is left before the Odin engine can be used as is*.

The one-line answer to the second: **the Odin engine is a turn-1 gate holder, not yet a
match engine.** It can build the true 800-world map and run one tick, byte-verified
against the reference — but it has no rule brain, no match loop, no event stream, no
LLM seats. The first milestone where it can be *used* as the sandbox eval is **P1 green**
(the headless 4-seat match that writes a folder). To play the game *today*, run the
v1 browser build (`node serve.cjs --open`) — that engine is complete and shipped.

---

## What runs today (every command verified 5 October 2026)

### The Odin core — what exists of the rebuild

The port lives in `spike/`. It is a **transcription** of the browser game's rules, not a
redesign, and it is held to the reference by ten gates. What it covers today: the map
builder, the arena construction, and the whole first turn (the tick `stepOnce`, the
per-seat state view at t=0 and t=1000 ms) — byte-identical to the reference fixtures.

```bash
./spike/gates.sh                # all ten gates, ~1 minute; every gate green as of today
```

Run the turn-1 fixture yourself (what gate 6 does):

```bash
odin build spike/turn1/main.odin -file -out:/tmp/turn1
/tmp/turn1 /tmp/turn1-out.jsonl
cmp /tmp/turn1-out.jsonl golden/states-b1040-t0-t1.canonical.jsonl   # → identical
```

The output is 8 lines (4 seats × the two moments), 45,840 bytes. The single file
`spike/turn1/main.odin` (3,034 lines) holds the whole port; its architecture and line map
are in `spike/turn1/HANDOVER.md`.

The other Odin programs, each a gated proof:

```bash
odin build spike/map -out:spike/bin/map && ./spike/bin/map    # the map builder, 4 conditions
odin build spike/mem -out:spike/bin/mem-track && ./spike/bin/mem-track   # the leak tracker (gate 7)
```

### The JS stack — the spec and the only complete engine today

```bash
node tools/trace-states-port.cjs golden/states-b1040-t0-t1.canonical.jsonl
# → GATE PASS: 8 lines, byte-identical   (no args: dumps the state view to stdout)

node tools/golden/record.cjs -out /tmp/new-recording.jsonl     # the headless reference recorder
# → takes ~1 minute (it records a full match-minute, 50 ms steps), then prints
#   the four seat summaries; the stream it writes is what the corpus test pins
node --test tests/golden-fixtures.test.cjs                     # the golden corpus test (6 pass)
npm test                                                        # the full v1 suite (671 tests)
```

`tools/trace-states-port.cjs` is the **line-map spec** for the remaining transcription
(its role is decided — see `docs/REBUILD-EFFORT.md` §5 item 6). It re-implements the
reference's rules in JS and regenerates the fixtures byte-identically; every remaining
Odin gate (the rule brain, the state sequence) is transcribed from its functions, not
from the browser game.

### The v1 browser game — playable today, end to end

```bash
node serve.cjs --open    # Node 18+, then open http://localhost:8088
```

This is the parent's engine plus our in-house renderer branch, complete and shipped:
four seats, real model calls (or rule brains when no model is configured), the full
match loop, the transcript and event recording. If "run the engine" means *play a match
or run an eval today*, this is the engine to run — not because the rebuild is behind
schedule, but because the rebuild is gated to byte-identity and has not reached the
match loop yet.

---

## What is left before the Odin engine can be used as is

The milestone ladder is defined in `docs/REBUILD_PROPOSAL.md` (§ "the milestones",
P0–P4). Where each one stands:

| Milestone | What it is | Status | What remains |
|---|---|---|---|
| **P0 (a)** the map line | the map builder, byte-identical | **green** — 4 conditions, the true 800-world, clearance included | — |
| **P0 (b)** the turn-1 state view | the tick and the per-seat observation | **green** — 8 lines, 45,840 bytes (gate 6) | — |
| **the rule brain** | the 250 ms discovery beat, the decisions (`js/ai.js`) | **not started** | the first *behaviour* the port must agree on, not a projection of state; transcribed from the JS spec's functions |
| **the enemy memories** | enemy-unit memory (b1041/42), enemy-building memory | **not started** (not transcribed anywhere yet — the JS port's header says so) | required by the first gate where seats meet rivals; the contacts gate needs them first |
| **P0 (c)** the state sequence | a whole recorded sequence byte-identical for a fixed seed set (the 2.7 MB stream) | **not started** | the method's scaling test; the JS oracle already regenerates the corpus byte-identically (gate 5 proves it), so the target exists and is green on the JS side — the Odin port must match it |
| **P1** the trace | the daemon, the event stream, the match folder, the redaction at export, the LLM seats | **not started** | a headless 4-seat match writes a folder: `transcript.jsonl` (schema v1), `events.jsonl` (same seed → empty diff), `traces/` with raw usage, exports with no key/endpoint/cost. This is where the arena-per-match + `mem.Tracking_Allocator` memory discipline lands — the shape gate 7 was proven for |
| **P2** the face | the webview shell, the renderer, playable and recordable on Win/macOS/Linux | **not started** | 60 fps on a mid desktop, the Playwright suite green, the browser question re-decided (the revisit trigger is the first real shim cost) |
| **P3/P4** the eyes, the arena | the analyzer, the hosted serve, the spectator feed | **not started; scope is an owner call** | §4's still-open product calls: P3/P4 scope, the mesh set, the name |

**The order of work** (from `docs/REBUILD-EFFORT.md` §5 item 5, now the only remaining
line in the effort record's list): the rule brain → then P0(c) → then P1 per the
proposal. The enemy memories land with or just before the rule-brain gate, because the
first contact between seats is exactly where they become required.

**What "used as is" means at each point:**

- **Today:** the Odin core is used as a *gate holder* — any change to the port, the
  toolchain, or the rules is proven against the reference in seconds. As a match engine
  it cannot be used: there is nothing to run a match with yet.
- **P0(c) green:** the Odin core replays a whole recorded minute byte-identically —
  a second oracle exists, and the JS spec port retires to provenance (its stated end
  date).
- **P1 green — the first real "used as is":** a headless 4-seat match with model seats
  runs and writes its folder, deterministically, with redacted exports. This is the
  sandbox eval, native, no browser.
- **P2 green:** playable in a window, recorded, on all three desktop platforms.
- **P3/P4:** analysis over match corpora, and the hosted arena — both pending the
  owner's scope calls.

---

## Where the deeper docs live

- `docs/REBUILD_PROPOSAL.md` — the milestones, their gates, and the five decided
  questions (the browser, the renderer, the spec, the memory shape, the language).
- `docs/REBUILD-EFFORT.md` — the effort record: what is done, with the measurements,
  and the remaining §5 list.
- `docs/CORE-REPLAN.md` — the architecture ledger (§12 invariants, §13/§14 the two
  owed items, both resolved).
- `spike/turn1/HANDOVER.md` — the turn-1 port's line map and the debug loop.
- `skills/odin-core-port/reference/build.md` — the verified Odin-facts table (what the
  compiler accepts, what `core:fmt`/`core:mem` actually ship in this build).
- `MERGE-STATE.MD` — the per-session ledger: what to check, what remains, the commands.
