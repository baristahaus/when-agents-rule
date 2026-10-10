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

node tools/golden/record.cjs -seed golden -seats 4 -minutes 1 -difficulty medium -out /tmp/x.jsonl
# → takes ~1 minute; two runs are byte-identical; the output matches
#   golden/stream-1m.jsonl (cmp), the alive-world corpus recorded 5 Oct 2026 after
#   the recorder's clearScene fix — before it, every recorded match was a frozen
#   world (no unit ever moved; CORE-REPLAN §16)
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
| **P0 (a)** the map line | the map builder, byte-identical | **green** — 4 conditions, the true 800-world, clearance included (gate 2e) | — |
| **P0 (b)** the turn-1 state view | the tick and the per-seat observation | **green** — 8 lines, byte-identical at the b1081 rules (gate 6), now on the jittered arena layout | — |
| **the rule brain** | the 250 ms discovery beat, the decisions (`js/ai.js`) | **green** — ported in `spike/match` and pinned by the whole-match streams | — |
| **the enemy memories** | enemy-unit memory (b1041/42), enemy-building memory | **green** — note/sweep per state build, the beat's detectContacts, first-contact gating (gameStats.opponents), ported in `spike/match` | — |
| **P0 (c)** the state sequence | the whole-match stream byte-identical in Odin | **green** — `spike/match` replays `golden/stream-1m`, `-5m` and `-10m` byte for byte at the merged b1081 rules, plus the four map lines; measured 8 Oct 2026 | — |
| **P1** the trace | the daemon, the event stream, the match folder, the redaction at export, the LLM seats | **folder, traces, batch and redaction green** (gate 8, measured 10 Oct 2026): `spike/match <dir> N seed seats diff folder` writes the full folder — `meta.json` (the conditions + `core:"odin"`), `transcript.jsonl` (byte-identical to the pinned golden stream: it IS the v1 contract), `events.jsonl` (the frame-accurate action log: orders, creations, damage, kills, node depletion, research, battles, the end), `traces/seat-N.jsonl` (one line per turn: the model, `null` for a rule seat, and the decisions taken since its last look). Two runs of one seed diff to empty on every file, at 1m and 10m; `batch` runs the four corpus conditions as folders in one call; the export greps clean of key/endpoint/usageRaw (the schema's `cost` objects are game data, present in every shipped v1 sample). `serve` is green too (gate 9): the core listens on a port, four seats attach over TCP, each receives its state record per turn exactly as the transcript carries it and answers `{"actions":[...]}`; the v1 executor codes `train_unit`, `build_structure`, `research_tech` and `explore` through the same gates the brain uses (everything else is refused with the `[ERROR]` shape, never dropped). An attached seat's discrete orders come only from its client — the rule brain's 2 s think switches off for it while every per-step machine beneath keeps running, exactly as the reference's model seats behave. The served match leaves its folder at the end, the client's orders in its events and traces. The LLM seat slot is **green too** (gate 10): `tools/llm-seat.cjs` plays a seat through the serve protocol — with `WAR_ENDPOINT`/`WAR_API_KEY`/`WAR_MODEL` it asks a real OpenAI-compatible endpoint (the state record as the user message, the four coded actions as tools) and sends the tool-calls back with the usage and reply text; without an endpoint it plays a deterministic scripted policy, so a served match of model seats **diffs to empty across two runs** (gate 10) — the model tier lands in `traces/seat-N.jsonl` (`model`, `reply.usage`, `reply.text`) written by the core, single-writer, from what the client sent. Remaining: a real-model corpus run, and the redaction pass's second look once a real seat's usage (pricing) flows into a folder |
| **P2** the face | the webview shell, the renderer, playable and recordable on Win/macOS/Linux | **increment 1 green** (gate 11, 10 Oct 2026): `spike/face` — the replay viewer — renders the pinned 1m corpus through **Vulkan** offscreen (instance → device → flat-quad pipeline → 800×800 read-back), 12 sampled frames per run with per-frame pixel digests, **byte-identical across runs**; `--png` writes PPMs for the eye (verified: terrain, water, the four spawn clusters in civ colors). This answers spec §13.12's native-surface question with a measurement: the NVIDIA driver refuses linear-tiled color attachments, so the path is optimal-tiled render + copy-to-buffer. **increment 2** (10 Oct 2026): the camera (zoom about a world point, verified by zoomed-frame digests), the map line's 941 resource nodes as static scenery, and **the 60 fps budget measured: 3.94 ms/frame (254 fps)** on the RTX 3090 rendering all 120 frames — found and fixed on the way: uncached mapped read-back ran at PCIe speeds (41 ms/frame until the read-back buffer took `HOST_CACHED`), and the transcript's JSON walk was the other slow path (the scenes now parse once). **increment 3** (10 Oct 2026): **the fog of war** — the state's `map.exploration` grid drives dark quads over the tiles the viewed seat has not seen (tile labels read north-down, pinned by the D1-is-seat-0's-base check); the viewer plays one seat's knowledge, its own units over the fog as the reference's own seat is never fogged for itself. **increment 4**: faithful marks — workers smaller than soldiers, and the state's ongoing `battles` drawn as red frames (`--turn N` renders any turn; the 10m raid at turn 1181 shows 115 entities, 2 rings, verified by pixel counts). The transcript walk is now **one pass** (each line parsed once, routed to its own turn — the per-turn rescan was the 10m slow path). **increment 5**: **the HUD** — a generated 5×7 bitmap font drawn in screen space (a second push-constant set, two draws per pass): the turn number and each seat's resources/population in its civ colour, read straight from the state records. The bench holds **2.84 ms/frame (353 fps)** with the HUD on. Remaining: the SDL2 window + swapchain (written when a display exists to verify against — this box is headless), the mesh/text set, the live camera controls; the webview-shell shims stay per spec §14 — the Vulkan face is the native-surface track, side by side |
| **P3/P4** the eyes, the arena | the analyzer, the hosted serve, the spectator feed | **not started; scope is an owner call** | §4's still-open product calls: P3/P4 scope, the mesh set, the name |

**Known dormant gaps** (8 Oct 2026, after the b1081 absorption): the four new
civilizations (Rome, Vikings, Maya), the 1200 map, the raid/farm civ bonuses and the
b1076 arena layout outside the recorded conditions are **not transcribed** in Odin —
the corpus does not exercise them, so the gates cannot see them. They surface as new
gate work the day a corpus records them; nothing else blocks P1.

**The order of work**: P0 closed 8 October 2026. Next: P1 per the proposal — the
daemon, the folder, the determinism gate — then P2.

**What "used as is" means at each point:**

- **Today:** the Odin core replays whole recorded matches byte-identically (P0 green,
  8 Oct 2026) — any change to the port, the toolchain, or the rules is proven against
  the reference in seconds, and a second full oracle (5m and 10m) stands beside the 1m.
- **P0(c) green (reached):** the Odin core replays whole recorded matches byte-identically
  — the JS spec port (`tools/trace-states-port.cjs`) retires to provenance per its stated
  end date; `spike/turn1` stays as the fast gate-6 holder.
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
