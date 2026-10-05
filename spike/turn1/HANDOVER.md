# Handover — Odin turn-1 port (state view), mid-flight

**Why this handover exists:** the Pi agent harness and the LiteLLM proxy in
front of it are missdirecting traffic, so this session is being restarted.
Everything below is verified state as of the handover; the new session should
read this document first, then run the sanity gate in §4 before touching code.

**The one-line status:** the JS reference port passes its gate byte-identical;
the Odin port has ~70% of the state view written, has four shape bugs, is
missing four state sections + the 50 ms step + `main()`, and does not compile
(yet — by design, it is mid-refactor).

---

## 1. What the task is

Reproduce the reference C&C "first turn" (4 seats: egyptian, greek, persian,
yamato; seed `golden`, 1× speed, t = 0 and t = 1000 ms) as a single Odin
program:

```
spike/turn1/main.odin   (package main, single file)
golden/states-b1040-t0-t1.canonical.jsonl   (45,840 bytes, 8 lines — the target;
                                             corrected 5 Oct 2026: an earlier draft of
                                             this handover said 49,555, a number `wc -c`
                                             does not confirm)
```

- 8 lines: for t ∈ {0, 1000}, one line per seat 0..3: `{"seat":i,"playerId":…,
  "t":t,"state":{…}}`, canonicalized (see §3.9).
- **Pass condition: byte-identical output** (`cmp` against the golden).
- The state view has 21 sections in this exact order:
  `player, clock, epoch, resources, population, recentEvents, bonuses, map,
  nodes, nearestNodes, friendlyBuildings, enemyBuildings, friendlyUnits,
  workers, enemyUnits, research, unlockedContent, units, buildings, threats,
  gameStats`.

## 2. The spec: the verified JS port (frozen — do not modify)

`tools/trace-states-port.cjs` (~1,810 lines) is a byte-verified transcription
of the reference (`js/game.js` + `js/openai-ai.js` + `js/civilizations.js` +
`js/terrain.js` + `js/engine/texgen.js`). It passed `GATE PASS` in this session
(run command in §4). **When in doubt, the port is the spec — read its
functions, not the browser game.** Key line map:

| Concern | Port location |
|---|---|
| RNG: hashSeed, streams, keyed draws | 48–102 |
| Terrain (coast bisection table, scatter, TC clearing) | 104–220 |
| Civ tables (techs in tree order, UNIT_DEFS, BUILDING_DEFS) | 234–430 |
| `getTrainOptionsForBuilding` | 412 |
| `buildingMaxHealth` (50-step round, 1.5^age, civ mult) | 466 |
| `createUnit` / `createBuilding` | 502 / 539 |
| `makeGame` (clock, `game.rand`, `rngOwnerKey` = `'s<seat>'`, vision radii, `isIdleWorker`, `observedWorkerLoad`) | 580–658 |
| `markExploration` (42×42), `explorationSummary` (7×7, %), `tileLabelAt` | 659–720 |
| `updateRivalContacts` (monotonic first-contact memory) | 722–740 |
| `seatLabel` → **opponent ids are `<civ>-<seat+1>`** | 742–750 |
| `isPlayerEliminated` (four ways back in), `militaryOptions`, `canAffordAnyMilitary` | 752–815 |
| `stepOnce` (the 50 ms step, §3.5) | 822–845 |
| `WarPositionRules` (worker movement; the ONLY thing that moves units here) | 851–895 |
| `makeAIPlayer` / `makeAIManager` (250 ms discovery beat) | 901–960 |
| `isPositionVisibleToAI` / `buildVisionTest` | 969–1022 |
| `makeHarness`: `workerJob`, `splitByBlock`, `trainableUnitsFor`, `updateResourceDiscovery`, `updateEnemyBuildingDiscovery`, `observeStep` | 1024–1132 |
| `knownAmount` (two-mode: observe-commit vs look) | 1138–1157 |
| **`buildGameStateJSON` — the whole state view** | 1159–~1420 |
| `createMatch` (spawns, TC, workers, bonuses, controllers) | 1634–1716 |
| `canonicalize` (seat/player-id re-keying) | 1717–1750 |
| `main` (the 2-observe driver) | 1752–1807 |

## 3. Ground truth already verified (trust these; do not re-derive)

1. **Spawns**: seat i at angle `(i/4)·2π − π/2`, radius 306 (port 1643).
   Golden line 1 (raw bytes) has the egyptian TC at `{"x":0,"z":-306}` and
   `yourSpawnArea` `(0,-306)`. The WIP's `arena_spawns` uses the same formula
   — **it is correct; do not "fix" it.** (An earlier exploratory dump once
   printed the TC as (306,0); that was a mislabeled dump, the raw bytes and the
   passing port are authoritative.)
2. **Workers**: 3 per seat at `spawn + (rand('s<i>:start-workers')−0.5)·10`
   per axis, sequential draws (port 1666–1670). Seat 0's golden workers
   `(2,-305),(1,-308),(-1,-302)` = spawn `(0,-306)` + offsets `(2,1),(1,−2),(−1,4)`
   — the seat-keyed streams check out exactly.
3. **TCs** clear nodes within `9.5 + 3` of the spawn (port 1662); TC
   maxHealth = `buildingMaxHealth(town_center, civ, 'stone')` (port 466).
4. **t=0 specifics**: exploration all zeros (the 250 ms discovery beat has not
   fired); yet `map.discovered` is non-zero (e.g. egyptian `food:1, wood:8`)
   because the observation's own node pass (`known_amount(observe=true)`) fills
   the seat's known set *during the same look*. Consequence for the streaming
   Odin writer: **do a scratch node pass before writing the `map` section**,
   then write `nodes` from the scratch (the WIP's `obs_scratch` exists for
   exactly this).
5. **Worker motion t=0→1000** comes only from `WarPositionRules` (port 851):
   separation 1.2 / force 0.03 / `sepK=min(3, dt·60)=3`; building clearance
   4.5 / 0.05 / `clearK=3` (same owner, `!underConstruction`, `dist>0.01`,
   degenerate-distance fallback `±x` by `i%2`). No tasking brain runs: every
   seat is harness-controlled and issues no orders.
6. **research.available** = techs of the civ with age reached **and** all
   `requires` researched. Nothing is researched at t=0, so techs with `requires`
   are absent: egyptian → house, farm, barracks, pottery, longbow (no
   agriculture); greek → …, farsight, longbow (no falx); persian → 4 entries;
   yamato → …, speed, … (no bushido). Each entry always carries `blockedBy`
   (cost/age check vs current resources; `[]` is written as `[]`),
   `researchAt` defaults to `"town_center"`, and `requires` is listed.
7. **`unlockedContent` is `{"buildings":[]}`** — the whole section, for every
   seat at both times.
8. **`splitByBlock`** (port ~979): structural blocks =
   `['age','tech','host','alreadyBuilt']`; open entries = those with no
   structural block (a `cost`-only block stays open, `blockedBy` stripped when
   empty); blocked entries keep their full `blockedBy` in check order
   (e.g. `["age","host","cost"]`). `units.trainable` vocabulary order: hosts
   `town_center, barracks, archery_range, stable, temple`; a host needing an
   un-researched tech is skipped; age floor = building `requiredAge`; a unit id
   appears at its first (host, age) occurrence.
9. **Canonicalization** (port 1717): `playerId` → `seat<n>` in line order; any
   string matching `^(ai|u|m|e|b|s)_[a-z0-9]{5,}$` is re-minted
   (`AI0`, `U1`, …) in first-appearance order. Unit ids inside the state view
   are **numeric handles** (1,2,3) — no minting there.
10. **`gameStats`**: `{"wonderRequired":600,"opponents":[{id:"<civ>-<seat+1>",
    civilization, age, discovered, defeated}]}`; `discovered` from the
    monotonic rival-contact memory; `defeated` from `isPlayerEliminated`
    (port 752: live fighter / producing trainer / can-afford-military /
    TC+worker-funds / worker+under-construction-producer / TC / wonder-cost
    / barracks|archery|stable-funds — in that order).

## 4. Verification loop (run before and after any change)

```bash
cd /home/barista/zmodern/when-agents-rule
# (a) spec sanity — must print GATE PASS before you trust anything else
node tools/trace-states-port.cjs golden/states-b1040-t0-t1.canonical.jsonl
# (b) build the Odin side (compiler IS installed; see §5)
odin build -file spike/turn1/main.odin
# (c) run + byte-compare (main() takes: <output-path> [golden-path])
./spike/turn1 /tmp/odin-out.jsonl
cmp /tmp/odin-out.jsonl golden/states-b1040-t0-t1.canonical.jsonl
```

When a line mismatches: diff the two lines, find which section diverges, read
that section's port function (line map in §2), and fix the WIP to match the
port. The browser game is not the spec.

## 5. Toolchain notes

- The Odin compiler is installed: `/home/barista/.local/bin/odin` →
  `/home/barista/.local/share/odin/odin/odin` (140 MB, full tree with
  base/core/vendor). `odin build -file <f>` compiles a single-file
  `package main`. Note `odin --version` prints the usage text, not a version
  string — not a broken install.
- No Go on this box (not needed).
- Node is available (used by the port).

## 6. State of `spike/turn1/main.odin` (2,028 lines, untracked, does not compile)

**Good and verified (leave alone):** fdlibm math kernels + `hash_seed` /
`mulberry` / `keyed_draw` (RNG, §3.2); terrain (coast table, scatter,
clearing); civ data tables (4 civs with bonuses/wonder/exclusions/units/techs;
**the tech-id table `tech_ids` sits at :641**, in the same order as each civ's
tech array — the research section must use it); std unit/building defs
(:656–712); `building_max_health`; `arena_spawns`; setup (TC + 3 workers +
200/200/100/50 + pop 0/10); vision (immediate + batched tests, 42-grid
exploration, tile labels); the JSON writer (`jw`, comma/quote discipline,
`fmt.f64` shortest round-trip); state-view sections `player` → `research`;
`age_reached` / `has_resources` / `known_amount` (including the transcribed
NaN case: a node known only through the coarser step test shows for no one);
`obs_scratch` (per-type buckets + insertion-ordered "x,z"-keyed nearby map with
replace-in-place, matching the reference's `Map`).

**Bugs (four shape divergences vs the golden, all in written code):**
1. `workers` section — writes `idle/gatherFood/…/attackMove` keys; the golden
   wants `total, idle, building, farm, scouting, moving, fighting, food, wood,
   stone, gold`.
2. `unlockedContent` — writes a training/building object; must be exactly
   `{"buildings":[]}`. The current code is also the syntax break: it
   references fields that don't exist in the file's own structs
   (`c.unit_hosts` — the `civ` struct has no such field; `udef.at` — the
   struct field is `train_at`; `te.id` — `tech` has no `id`, use `tech_ids`),
   and the file's tail is cut off mid-block. No `func main`.
3. `friendlyBuildings` entries — missing `state/busy/activity/producing`
   (golden: `"state":"complete","busy":false,"activity":"idle","producing":null`).
4. `research.available` — `blockedBy` omitted when empty (must always be
   present); `researchAt` written raw (can be `""`; must default to
   `"town_center"`); tech ids taken from the missing `te.id` instead of
   `tech_ids[c.ci][t]`.

**Missing (not written yet):** the fixed `unlockedContent`; sections
`units` (trainable/blocked per §3.8), `buildings` (buildable/blocked; the
wonder entry carries `builtAs`/`isWonder`; `blockedBy` in check order),
`threats` (`underAttack`, `enemyWonders`); `gameStats` (§3.10); the
observation's close-object + line flush; the observation-ordering fix
(scratch the node pass before the `map` section, §3.4); **`stepOnce`**
(port 822: pop → 250 ms discovery beat [markExploration + updateRivalContacts]
→ clock += 50, stepNo++ → WarPositionRules → harness observeStep
[resource + enemy-building discovery]); and **`main()`** (build terrain →
setup → 4 lines at t=0 → 20 steps → 4 lines at t=1000 → write to argv path).

## 7. Suggested order of attack for the new session

1. Repair the tail: replace the broken `unlockedContent` block with
   `{"buildings":[]}`; add a stub `func main` so the file compiles; run the
   §4 loop — expect a line-1 mismatch only in the sections not yet written.
2. Fix the four shape bugs (§6) one by one, cmp after each.
3. Add `units` / `buildings` / `threats` / `gameStats` in golden order,
   transcribing the port functions in §2 (they are short and self-contained).
4. Add `stepOnce` + the driver `main()`; cmp all 8 lines; iterate on any
   worker-position or discovered-count drift using the §4 loop.
5. Only then: anything beyond the turn-1 gate is new design work — this
   artifact (single-file port, byte-exact gate, table-driven civs) is the
   intended foundation for the bigger builds.

## 8. Things NOT to do

- Do not edit `tools/trace-states-port.cjs` or the golden file.
- Do not "fix" the spawn formula or the worker keys in the WIP — both are
  verified correct (§3.1–3.2).
- Do not re-derive rules from the browser game; the port encodes every
  quirk (including the NaN known-amount case and the 250 ms beat).
- Do not add features beyond the 8-line gate in this artifact.
