# Quality review: what is actually hard about this codebase

September 24, 2026. A read-and-run review of the whole repo (~40k lines, 92 tracked
files), followed by a fix pass on the parts that could be changed without deciding a
game-balance question on someone else's behalf.

Nothing below is claimed on inference. Every finding was either executed against the
real shipped code or read at the line it names, and every fix is backed by a test that
was red before it and green after. The one class of exception is called out in
[Not verified](#not-verified).

## How it was checked

| Method | What it proved |
|---|---|
| `node --test tests/*.test.cjs` | 259 tests green before any change — the baseline was healthy, and it stayed green through the whole pass (now 268) |
| `node tests/browser/shared-updates.cjs` | The repo's own Playwright suite works (~29 s alone, 45–58 s under load). It was never wired to anything |
| `tests/browser/trust-boundary.cjs` (new) | Three trust boundaries, driven in Chromium against the shipped files |
| Real transcripts | 11.2 MB / 730 records parsed in 53 ms; the bundled Episode 1 replay parses in 2.3 s, draws a 247-entry list, scrubs to turn 216 |
| Seeded generation | Same seed → byte-identical 1236-node layout; stone 10 and gold 5 per player with **identical radii** across all four sectors; food exactly 8 per cell × 49, wood 16 × 49 |
| `grep` over `samples/` | Zero keys, endpoints, hostnames — but see *Invoices in the export* below |

## The challenges

### 1. A trust boundary drawn around text, not around attributes

`escapeHtml` escaped `&`, `<`, `>`. It did not escape `"`. That is fine for text
position and fatal for attribute position, and attribute position is where this file
lives: **254 of its 900 `${}` interpolations sit inside a double-quoted attribute value**,
and the helper is called at 219 sites — `value="${e(m.endpoint)}"`, `title="${e(m._status.text)}"`,
`data-v="${e(one)}"`, `data-key="${esc(e.turn)}"`. A value containing a quote closes the
attribute and opens the next one. (Not all of those carry hostile data; the four named
above are, and they were enough.)

Three paths reached the page as executable script, all demonstrated in Chromium against
unmodified `js/`:

- a model id from any configured endpoint's `/models` list (`openai-ai.js:2083` maps
  `m.id || m.name` with no character filtering; `ui.js:1635` renders it into `data-v`);
- a shared or imported model catalogue (`ui.js:1282/1284`, `normalizeArenaModel` sanitises nothing);
- a transcript file — the analyzer's *stated purpose* is a match that was "recorded,
  downloaded, handed on, and opened here", and on a hosted copy the analyzer is the only
  surface there is.

The transcript case was the worst: `ui.js:5558/5560` pushed `h.simSpeed` and
`a.results.build` into `anMeta.innerHTML` **raw**, while the three fields either side of
them were escaped. Opening a file executed script before a single click. A second payload
in the same file rode in through `data-key="${esc(e.turn)}"` and fired on hover.

The fix went into the helper rather than into the twelve call sites, because a rule that
needs remembering in twelve places is a rule that will be broken again:

```js
.replace(/"/g, '&quot;')
.replace(/'/g, '&#39;');
```

The two raw fields needed their own fix — a helper cannot help a call site that never
calls it. `tests/browser/trust-boundary.cjs` now asserts all three, and asserts that the
model id still survives **verbatim as data**, so the fix is escaping and not silent
truncation.

*Lesson:* escaping is a property of the **sink**, not of the data. A helper named
`escapeHtml` that is safe in one of the two positions it is used in is a trap.

### 2. A model's own typo became the model's fault

`Math.max(1, Math.min(params.count || 20, 20))`. Send `{"count":"all"}` — which is
exactly what a model means when it says "send everyone" — and `Math.min("all", 20)` is
`NaN`. Every consumer of that number compares against it, and `NaN` compares false
against everything, so the same one typo meant three different things:

| Handler | Guard | What `NaN` did |
|---|---|---|
| `delete_unit` | `removed < count` | deleted nothing, returned **`OK - Deleted , freeing population.`** |
| `repair_building` | `.slice(0, count)` | sent nobody, returned *"all are constructing"* — a cause that was not true |
| `assign_workers` | `if (moved >= count) break` | never broke: **reassigned every worker the seat owned** |

The first is the one that damages the product rather than the match: a false `OK` is
counted in `successRate`, which is 34% of the strategy score, and is written to the
transcript as a command that succeeded. An eval harness has to be able to tell "the model
was wrong" apart from "the harness could not read what the model wrote", and it was
scoring them identically.

Now refused at the edge with one sentence naming the field, the range, and what was sent
(`OpenAIAIManager.parseCount`), plus the localized outcome line for de/es/zh.

The mirror of the same mistake sat in the scoring: a rate whose denominator was empty read
as **0**, which is the number for "answered and was wrong". `successRate`, `formatOk` and
`reliability` together weigh 0.67 of the strategy score, so a seat the harness never asked —
every turn cut by a context overflow, which is the harness's budgeting, not the model's
behaviour — could not score above 33 no matter how it played, and a seat whose endpoint was
unreachable for the whole match looked *identical* in the export. Those two are different
facts and the file must be able to say so. An unknown rate is now `null`, `computeSoundness`
drops unknown terms and re-normalises the rest over what is known, and the card prints `—`
where it printed `0%` (measured in a live page: an iron-age seat with every turn cut scored
10 before, 30 now, while the genuinely dead endpoint scores 21 with a *measured*
`Reliability: 0%`). One trap came with it: `null < 0.5` is true in JS, so the "many failed
commands" tag had to learn to skip a rate it cannot see.

### 3. One fact, two predicates; one vocabulary, three copies

The action vocabulary exists in `OpenAIAIManager.ACTIONS` (what models are offered), in
the `switch` in `executeAction` (what the engine accepts), and in `README.md`. A comment
in `openai-ai.js:69-70` asserted "a test holds it against the switch in `executeAction`".
No such test existed. It does now — it reads the dispatcher's own source via
`executeAction.toString()` rather than re-parsing the file, and it pins the README list
too, so the third copy cannot drift silently.

The same shape exists in the elimination rules — and the first version of this document got
it wrong in a way worth keeping as an example. It claimed `isPlayerEliminated` (sim) and
`isControllerDefeated` (harness) answered "is this seat out?" from **two different
definitions**. They do not: `openai-ai.js:8883` delegates straight to the sim's predicate, so
there is one rule, deliberately shared (campaign and arena were unified at `game.js:5629` for
the same reason). Reading the delegation instead of trusting the function names is what
turned a plausible "two predicates" story into the defect that was actually there:

the one predicate asked "can this seat still train a unit?" from a **hand-copied map of
three buildings and their units**, while the game keeps that table in `BUILDING_TRAIN_TIERS`
plus each building's own `trainOptions`. The copy missed the temple — whose priest lives in
the building def, not in the tier table — and every civ-unique unit. A seat whose last
trainer was a temple was deleted from a match while its own controller was still being told
priests were available, and whether a seat that could field Egypt's chariot survived depended
on which building it happened to own rather than on the rules. Fixed: the predicate now uses
the same resolution order as the training panel and the model-facing vocabulary, and a test
asserts the two sets cannot drift apart.

The shape reappeared in a place I had already audited, which is the lesson worth keeping.
Sight — "can this seat see that spot?" — had **four** implementations: the authority
(`game.unitVision` / `game.buildingVision`: 15 infantry, 22.5 cavalry, ×vision techs; 20
buildings, 40 town centers, 80 towers, 0 under construction), the rule AI's targeting test, the
predicate that gates what a model is told about enemies and nodes, and the seat overlay on the
minimap. The last two had drifted to their own numbers — 12 for buildings, 60 for towers,
cavalry ×1.2 instead of 1.5, and no Farsight bonus at all. Reading the call graph rather than
the function names decided the severity: the drifted copies feed *presentation* (the per-seat
overlay, the analyzer's replayed fog, the starting grace radius), not the simulation, so no
match was ever played on the wrong numbers — but the overlay is precisely the tool a reader
uses to ask "what could this model have known?", and it was drawing a smaller world than the
seat actually saw. The transcript viewer states the same promise in its own header — a single
seat is "the honest reconstruction of what that model could see" (`analyzer.js:330`) — and its
per-seat filtering is sound (`scene()` drops every seat but the one being replayed); only the
radii were wrong. That was checked rather than assumed: read alone, `ui.js`'s fog pass looked like
it was leaking all four seats' vision into one seat's view, and it is not.
All four now read the two authority functions, and
`tests/sight-authority.test.cjs` probes the same points through every path and refuses any
disagreement, with anchors (cavalry at 20, Farsight at −76, a tower at 121) chosen so the
retired numbers would each fail.

What is left of it is a nit, not a ranking item: the defensive fallback at
`openai-ai.js:8886` (reached only if the game object somehow lacks the predicate) states a
*laxer* rule — no units and no buildings — so it is the last second definition, in a branch
that never runs.

The same shape, one rule over: **"can this seat field a unit?"** is answered in four places —
`trainUnit` and the model-facing executor both refuse at `population >= maxPopulation`,
`canAffordAnyMilitary` decides whether the seat is still in the match, and `trainableUnitsFor`
tells the model what it may order. Three of them read cost, age and host; none read the population
cap. The cap comes entirely from buildings (`recomputeMaxPopulation` sums `popBonus` — 10 per Town
Center, 5 per house, ceiling 100), so a seat whose Town Center and houses are all razed has a cap
of **zero**, and if a temple survived the wrecking the predicate swore that seat could still field
a priest. It could not field anything, and *everything else knew so*: the state a seat is shown
marks every unit `blockedBy: ["pop"]` at the cap (openai-ai.js:3263 — that gate went in after one
match showed a seat spending 227 of its 474 turns being told "Population limit reached", which is
also why the same list warns about `age`, `host` and `cost`), and the executor refuses. The
survival rule was the one implementation that never learned about the cap, so the seat stayed in
the match, correctly informed that it could do nothing, forever.

Which is a smaller and stranger bug than it first looked. I wrote the first version of this
paragraph claiming the harness was telling such a seat "a priest is available" every turn; it is
not — `trainableUnits` gates on population and has since that 227-turn match. The defect is
between the sim's own two answers to one question, not between the sim and the model.

The state is reachable, and this pass made it more so: widening `canAffordAnyMilitary` to see
temples and civ-unique units (last round, correctly) enlarged the set of seats the predicate is
willing to spare, and the cap was never part of the question. It is closed by one clause reading
the condition the executor already reads. A seat with a living worker is still spared by the
pre-existing "can rebuild a Town Center" branch, so what this condemns is a seat holding no units
at all — one that cannot build, gather or train, and was therefore already out by the rule as the
code states it in its own comment above the predicate.

Every site that answers it, enumerated rather than sampled, because "I fixed the one I found" is
how this class of bug survives: `trainUnit` and `executeTrainUnit` (the two refusals),
`trainableUnitsFor` → `blockedBy: ["pop"]` (the disclosure), `canAffordAnyMilitary` (survival, the
one that was missing it), and the rule AI's own train gate at `ai.js:685` — which had the
condition right all along, and had a house-building heuristic beside it (`ai.js:165`) that builds
houses precisely because the cap is real. Everything else that reads `maxPopulation` displays it:
the HUD counter, the leaderboard row, the analyzer header. The cap itself is computed in exactly
one place, `recomputeMaxPopulation`, whose ceiling is `MAX_POPULATION_CAP` (buildings.js:3, 100).
That constant is copied three times in openai-ai.js as `typeof … !== 'undefined' ? … : 100`
fallbacks at 2523, 6031 and 6158; they cannot fire, since buildings.js is loaded first by
`index.html` and `tests/shipped-files.test.cjs` enforces that graph, so they are left as the
paranoid guards they are — same shape as the fallback nit above, and noted rather than churned for
the same reason.

Deliberately unchanged: `trainableUnitsFor` still lists units a seat has no room for right now. A
seat at 10/10 with an army is one house or one battle from room, the state it is shown carries
`population.capacityNow`, and an option list that goes quiet on a playable seat is a worse lie than
one that is merely early. The asymmetry that mattered was "harness says alive, engine says no", and
that is one condition in one place now.

### 4. The published contract had drifted from the payload

`game-state-schema.json` is the file README points model-tool authors at. It still
required `trainableUnits` and `buildableStructures`, which the builder stopped emitting
long ago; declared `buildings` as an aggregate (`total/idle/busy/…`) when the payload
carries `{buildable, blocked}`; and required `workers.onFood/onWood/…` where the payload
says `workers.food/wood/…`. Every one of the seven bundled recordings failed validation
against the contract shipped beside them.

The rewrite was verified mechanically rather than by eye: `required` vs a real record
(now zero missing, zero undeclared), the three regrouped properties checked key by key,
and all six `$ref` targets confirmed to resolve.

### 5. Documentation is a live dependency

Comments and strings in this repo are unusually good — 38% of `openai-ai.js` is comment,
and almost all of it is *why*, including the bug each guard exists for. That is exactly
why the stale ones hurt: they are load-bearing and people trust them.

The one that mattered: the Wonder's description — shown to every model, in all four
languages — read **"hold 180s to win"**. The game requires **600 s**
(`wonderRequired = 600`). Four seats' worth of decisions were being planned against a
defence window that was 3.3× shorter than reality. Fixed in `civilizations.js` ×4 and its
three translations, plus two comments that repeated the old number and two more that
asserted rules the code contradicts (a farm *can* be staffed by `assign_workers "farm"`;
scarce-node counts round to a whole share per seat, so four seats see 20 gold, not 18).

What that costs is measurable here, which is unusual. A line in the *last* message of every
turn read "choose the single best action for THIS turn" long after the harness had raised the
turn budget from one command to three (`MAX_COMMANDS_PER_TURN`, openai-ai.js:1570) — and the
last message outranks the system prompt by position alone. Measured over one match: the two
large seats ignored it and averaged 2.5 commands a turn; the two small ones obeyed and sent
exactly one on 80% and 89% of their turns. Same rule text, four seats, two different games —
which is also why the fix had to be to the *sentence*, not to a constant. Where a number is
worth changing, this repo mostly does interpolate it: all nine mentions of the turn budget read
`OpenAIAIManager.MAX_COMMANDS_PER_TURN`, none hard-codes 3, and the audited constants that were
found to be duplicated by hand (sight radii, §3) are now single-sourced too.

### 6. Invoices in the export

`rawUsage` stored the provider's usage object verbatim into every turn record, so `cost`,
`is_byok` and `cost_details.upstream_inference_*` rode along. Across the seven shipped
samples that published **$94.62** of the operator's account spend over 2836 priced turns.
README's claim is literally true — the files are key-free and endpoint-free — and a reader
still does not expect a per-turn bill when they are handed a "safe to share" example.

Fixed at the source: `rawUsage` copies the usage block minus a named set of pricing and
account fields, and the seven samples were scrubbed of exactly those members (3389 lines
before and after, 2836 changed, nothing else moved, verified by parsing both versions and
comparing every record outside `usageRaw`). A test asserts both the filter and the artefact,
so a future priced sample fails the suite.

An earlier note here said the fix would invalidate "the token-budget arithmetic that reads
those numbers". It would not: `grep -rn usageRaw js/` shows exactly one write site and no
reader — the field exists for whoever downloads the transcript, which is the second reason
what is in it matters. Note too what this does **not** undo: the figures are in git history,
and only a history rewrite removes them from a public remote. That is the author's call and
not mine to take.

### 7. Sim duties living in the render loop — moved, and measured

`gamerenderer.js` used to say it in its own header: *unit movement lerp, separation,
building clearance — game correctness*, running from `requestAnimationFrame`, while the
hidden-tab driver (`game.js`) calls `tick()` straight from a Worker. So while nobody was
looking — which is most of a long match, since "keeps running in a background tab" is a
headline feature — the match ran with no separation and no building clearance at all.

The two positional passes now live in `EngineRenderer.simulateStep(dt)` and are called from
`Game.simulateStep`, which already slices real elapsed time into ≤100 ms quanta whether or
not a frame is ever painted. `animate()` draws. Movement was already in `game.js` — the
header's "movement lerp" was stale, and a comment there records the day a duplicated mover
made AI armies run 33% hot.

Measured by pinning a pile of units, stubbing everything that could move them on its own
(AI, worker re-tasking, movement integration, combat, auto-defence, shore clamp — without
that the experiment just measures the AI walking the pile apart, which is exactly what the
first version of it did), and then running the same pile in a tab that paints frames and a
tab where `requestAnimationFrame` never fires again:

| | visible tab | backgrounded tab |
|---|---|---|
| before (passes in `animate`) | min separation 0.26 → 1.2 | **0.042 → 0.042** |
| after (passes on the sim clock) | 0.26 → 1.2 | **0.042 → 1.2** |

Two things came out of building that measurement, both pre-existing and both fixed with it.
Units standing on **exactly** the same coordinate were skipped by separation (`dist > 0.01`),
and the building escape sent every unit caught in dead centre to the *same* point (`+x`), so a
stack that ever landed on one spot was welded there for the rest of the match — the eight-units
pile measured `minSep 0.000 → 0.000` over seven seconds of a running game, frames and all.
Both directions are now derived from the index rather than random, so replays and background
tabs referee identically.

Three consequences worth knowing, all intended. The first is a side effect nobody asked for
and everyone benefits from: `keepUnitsAshore()` runs after the sub-step loop, so with the pushes
now inside it, the shore clamp gets the **last** word on where a unit may stand — where before,
separation ran after the whole tick and could drop a unit into the sea, to sit there until the
next frame (and in a background tab, indefinitely, since there was no next frame). Measured after
the change: parking a friendly stack on the coastline so separation has work to do exactly there,
then sampling every live unit against `terrain.landLimit` — 24 samples across a visible and a
hidden tab, **zero** units outside the land limit, worst overshoot 0.000.

Pause really pauses now: with the budget at 0
no sub-step runs, so nothing is pushed apart any more while the match is stopped, where
before the render loop kept refereeing a frozen game. And the `sepK` cap (three times the
60 Hz-normalised push, so one long step cannot fling anyone) means a Worker tick applies
less push per wall-clock second than a 60 fps tab does — a backgrounded match is refereed
*close* to a watched one instead of exactly. Raising the cap would close the rest; that is
tuning, and tuning is a gameplay call.

Related and smaller, and now half-fixed: auto-acquisition scans for enemies within an aggro
radius of 24 (melee) or weapon range + 20 — **32 for an archer** — against a sight of 15 for
infantry and 22.5 for cavalry. There was no visibility test in the scan at all, so a unit
reacted to enemies its seat had no way of knowing about, which is the opposite of the rule the
models are told and made a fogged match one board watched by four omniscient brains.

The scan now takes a `requireSight` flag, and acquisition passes it, using the same sight rule
the fog, the model-facing state and rival discovery already use (a seat sees what its living
units and finished buildings cover — `aiManager.isVisibleTo`, not the human's single-observer
fog grid, because an arena has four seats whose knowledge must not be one). Measured on a
deliberately placed board — two facing lines of recruits 22 apart, mid-map, out of sight of
any town center, inside every aggro radius: **8 units would acquire, all 8 blind; with the gate
all 8 hold.** Base defence is untouched, because a town center sees 40 and the attackers walk
into that long before the archers react.

What remains is the other half, and it is a feature rather than a filter: `attack_target` pins
an object and then steers on its **live** coordinates forever, so a chased unit that has walked
into fog is still being run down exactly as the crow flies. Doing that properly means target
memory — last-known position, an age, and a give-up rule — and inventing a give-up window in
the same breath as changing who lives is not a swap anyone should review as one change. It is
open item 1.

### 8. Testing a page of classic scripts

There is no module system, so nothing is importable — and yet all 25 existing test files
behave properly: they load real `js/` source into a `node:vm` context and drive real
methods. Zero of them assert against source text. The conventions that make this work are
undocumented and cost me real time, so they are worth writing down:

- `class`/`const` at top level are **lexical**, not `window` properties. Only 18 files'
  worth of `window.X =` exports exist; `Game`, `UIManager` and friends are reachable only
  by evaluating *inside* the same context.
- `game.js` must be loaded up to `split('\nconst WAR_PRIVATE_HOST')[0]` — the tail reads
  `location`, which a test context has no business faking.
- Arrays returned from `page.evaluate` (or a vm) carry the **other realm's**
  `Array.prototype`, and `assert.deepEqual` under `node:assert/strict` is prototype-strict:
  two empty arrays are never equal across the boundary. Compare joined strings.
- Serving the app under a fake public hostname works via route interception, but the
  document must not be typed `application/octet-stream` or the browser aborts the
  navigation before your code runs.
- Headless Chromium needs `--enable-unsafe-swiftshader`, or the analyzer never finishes
  booting and you spend an afternoon suspecting the app.
- In that same page, Playwright's `waitForFunction` polls on `requestAnimationFrame` by
  default. The app owns a heavy rAF render loop, so raf-polling can starve and time out on
  work that has plainly already happened. Pass `polling: 100`. A predicate that *throws*
  (reading `.length` off a field the app has not created yet) also aborts the wait rather
  than retrying, so guard every link in the chain.
- One Chromium per scenario, not one per suite. Three full app boots inside a single
  browser process degrade under software GL until the third misses its own boot timeout —
  the failure looked exactly like an app regression, and the control that proved otherwise
  was running the same suite against a `git archive` of HEAD. Isolating each scenario made
  the suite deterministic and about eight times faster (3 runs in 30 s).
- And measure your own numbers. An earlier draft of this document said "205 call sites"
  from memory; the file has 219 escape calls and 254 attribute interpolations. Both wrong
  claims were in prose, where nothing checks them.

### 9. The review-reliability problem

Worth stating plainly because it changed the method: five slice reviews were delegated in
parallel, and **four returned findings citing code that does not exist** — an invented
`staffMax` farm-capacity field, a nonexistent "TC-less and population 0" elimination
branch, `classifyError`/`endpointUnreachable`/`NON-RETRYABLE` symbols absent from the
file, an `escapeAttr` helper and a `startCampaign` call that were never written, mesh
capacity constants that do not exist, and a Google token bug in a codebase whose comments
explicitly warn against the mistake that bug would be. One report's line numbers were
shifted by ~300 and it contradicted itself about its own finding's reachability.

Nothing in this document survived that filter unchallenged: the two reports whose claims
were confirmed (the escaping boundary, the `$94.62`) were confirmed by running them, not
by reading them. A `git grep` for the exact symbol is the cheapest control there is, and
it is not optional.

## Fixed in this pass

| Where | Change | Evidence |
|---|---|---|
| `js/ui.js` `escapeHtml` | escape `"` and `'` | trust-boundary block 2 and 3 |
| `js/ui.js` `anRender` | the two raw transcript fields go through `esc()` like their neighbours | block 3: `#anMeta` has no element children |
| `js/ui.js` `showScreen` | showcase mode refuses the credential-asking screens in JS, not CSS | block 1: none of the four activate |
| `js/openai-ai.js` | `parseCount` + refusal at all four `count` sites; `log.out.badCount` in de/es/zh | `tests/action-vocabulary.test.cjs` |
| `game-state-schema.json` | `required` and three regrouped properties | script-checked against a real record |
| `js/civilizations.js`, `js/i18n.js`, `js/game.js`, `js/units.js` | Wonder hold 180 s → 600 s (model-visible strings included) | grep for `180s` now returns nothing rule-shaped |
| `js/game.js`, `js/terrain.js` | three comments that stated rules the code contradicts | read |
| `js/openai-ai.js` | two dead duplicates of `isOwnedByAI` removed | grep |
| `tests/action-vocabulary.test.cjs` (new) | vocabulary parity across `ACTIONS` / dispatcher / README; `parseCount` semantics; refusal-is-not-success | 4 tests |
| `tests/browser/trust-boundary.cjs` (new) | the three boundaries, in Chromium | PASS |
| `package.json` | `npm run test:browser`, and a note on why Playwright stays undeclared | — |
| `README.md` | a *Running the tests* section — the suite existed and nothing pointed at it | — |
| `tests/shipped-files.test.cjs` (new) | the hand-maintained script graph: every referenced file exists, every file on disk is referenced exactly once, every tag is a positive integer | 5 tests |
| `js/engine/gamerenderer.js` | `handleContextLost()`: `preventDefault()`, flag, and the draw loop stops instead of paying full frame cost into a dead context | forced with `WEBGL_lose_context`: frames 3→0 per 1.5 s while ticks went 3→90 |
| `js/game.js`, `css/styles.css`, `js/i18n.js` | dismissable bottom banner in four languages — deliberately *not* the boot-failure overlay, because the match carries on and the leaderboard/decision log/results are DOM | same run: `.ctx-lost` present, `body.boot-failed` absent, `gameScreen` still active, no pageerror |
| `js/ui.js` metrics block | `successRate`/`formatOk`/`reliability`/`reasonRate` are `null` when the denominator is empty; `computeSoundness` re-normalises over judged terms | `tests/soundness-scoring.test.cjs` (6) + a live render check |
| `js/ui.js` `pct`, results card, markdown export | unknown renders `—` / `n/a`; a measured zero still prints `0%`; the export prints the denominator beside format fidelity | `n/a (0 answered)` vs `0%` for the two failure kinds |
| `js/ui.js` `computeBehaviorTags` | an unjudged success rate no longer tags a seat as failing | the counter-party case (a measured 20%) still earns the tag |
| `js/game.js` `canAffordAnyMilitary` + new `trainOptionsFor` | survival reads the game's training tables instead of a hand-copied map, so the temple and civ-unique units count | `tests/elimination-predicate.test.cjs` (5); its two bug-defining tests fail against the old map |
| `js/openai-ai.js` `rawUsage` | copies the usage block without pricing/account fields (`cost`, `cost_details`, `total_cost`, `is_byok`, `native_statistics`), leaving the token detail that is the field's whole purpose | `tests/usage-redaction.test.cjs` |
| `samples/*.jsonl` | 8508 pricing members removed from 2836 turns; every other byte identical | both versions parsed and compared record by record; the new test fails against the old files |
| `.gitignore` | `results_*.md`, `match-*.jsonl`, `screenshots/` — a run's own output cannot be published by one `git add -A` | — |
| `js/engine/gamerenderer.js` `_buildTextures` | frees the texture set it replaces; safe because all four `setTerrain` callers clear the scene first | A/B on identical paths: 39 textures left resident per theme change, then 0 |
| `js/engine/gamerenderer.js` `simulateStep`, `js/game.js` | the two positional passes left the render loop and run per simulation sub-step; `animate()` only draws | pinned pile, backgrounded tab: `minSep 0.042 → 0.042` before, `→ 1.2` after, same run as the visible tab |
| `js/game.js` `findNearestEnemyInRange` + `canOwnerSee`/`visionSources` | auto-acquisition requires the seat to see the target; ordered attacks and retaliation do not | placed board: 8 would-acquire, 8 blind → 0 acquisitions; base defence unchanged |
| `tests/fog-acquisition.test.cjs` (new) | the sight/aggro band, town-center sight, ruins and corpses, enemy buildings, the per-step cache and the no-cache-outside-a-step case | 8 tests |
| `js/fogofwar.js`, `js/openai-ai.js`, `js/ui.js` | four implementations of "can this seat see X" collapsed onto `game.unitVision`/`game.buildingVision`; local copies (15/12/60, cavalry ×1.2) deleted, and a dying unit no longer scouts in the model-facing path | `tests/sight-authority.test.cjs` (4); two of them fail against HEAD |
| `js/engine/gamerenderer.js` coincident cases | separation now reaches units on the identical point, and the dead-centre building escape fans by index instead of `+x` | welded stack `0.000 → 0.000` over 7 s before; `→ 1.2` after |
| `js/game.js` `canAffordAnyMilitary` | "can this seat field a unit?" now includes having a population slot — the condition the executor *and the model-facing state* already applied, and the survival rule alone did not | `tests/elimination-predicate.test.cjs` (6); fails with the clause removed |
| `tests/roster-advancement.test.cjs` (new) | the shared roster closes on itself; the per-civ free-upgrade table recorded verbatim | 5 tests; deleting `archer:`'s path, retargeting at `ghost_unit`, `slinger -> elite_archer` at neolithic and giving hoplite a path each fail it (the first escaped an earlier version of this test) |
| `tests/host-classifier.test.cjs` (new) | the showcase gate's input: 13 private forms, 9 public ones, the prefix-bypass shapes, `?full=1` and `file://` | 4 tests; an unanchored v4 regex (a fail-open) is caught by it |
| `js/openai-ai.js` | dead `roundStillOpen` deleted and the comment that leaned on it rewritten to say what the code actually does | grep: no call sites; the gap it implied is now open item 9 |
| `.github/workflows/ci.yml` | nightly + on-demand job for the two Playwright suites, screenshots kept as an artefact | commands run here; the runner is the unverified part |
| `tests/elimination.test.cjs` | loads the real tables instead of stubbing them — the old stubs were only possible because the predicate carried its own copy | 7 tests, unchanged assertions |
| `js/i18n.js` `sum.legend` ×4 | the legend says terms can be dropped and the rest share the score | rendered text in the summary |
| `index.html` | `?v=` → 908 for the first pass's seven scripts, → 909 (+ stylesheet 837) for the context-loss change, → 910 for the scoring pass | repo convention held |
| `.github/workflows/ci.yml` (new) | syntax-check every shipped file, parse both JSON contracts, run the suite — every step was executed locally first | commands run here |

Suite state: **309/309 unit tests**, and the browser suites now also pass against the real GPU (see *Reproducing*) — (259 before the pass; +3 engine guard, +6 scoring, +5 elimination, +3 redaction, +4 classifier, +2 net from retargeting the refereeing tests);; the visual suite and the trust-boundary suite each
run **three times, green every time**. The trust-boundary suite was also watched failing,
before the fixes, on exactly the three assertions it now passes — a green security test is
only worth what its red run was worth. The context-loss path was proven the same way, by
forcing a loss in Chromium rather than trusting that the handler would be reached: 12
checks, and the interesting number is that the simulation ran **thirty times faster** once
the dead draw loop stopped (3 ticks per 1.2 s before, 90 per 1.5 s after, under software
GL) — the loop was not merely wasting power, it was starving the match it could no longer
draw. That gap is an artefact of this environment's swiftshader, not a claim about real
GPUs; the direction is the part that holds.

## Still open, ranked

1. **S2 — a chased target is never lost.** Acquisition is sight-gated now (§7), but
   `attack_target` still steers on the target's live coordinates indefinitely, so a unit runs
   down an enemy it stopped seeing several turns ago. Needs last-known-position memory plus a
   give-up window; the window is a gameplay decision and should be reviewed as one.
2. **S3 — the browser job has never run on a runner.** `.github/workflows/ci.yml` now has
   two jobs: the push job (`node --check` over every shipped file, both JSON contracts,
   `node --test`) and a nightly `workflow_dispatch` job for the two Playwright suites, with
   the screenshots kept as an artefact. They are off push because each downloads a browser
   and a check that is red for network reasons trains people to ignore it — but the commands
   are verified locally and the runner is not. Watch the first scheduled run.
   Still unenforced: the `?v=`-must-move-with-the-change rule
   (`tests/shipped-files.test.cjs` checks every tag *exists* and every file is *loaded*, not
   that a touched file got a new tag — that needs git history, which is a CI step).
3. **S2 — match-level reproducibility.** Terrain is seeded; unit positions, harvest
   targets and `explore` tile resolution use unseeded `Math.random()` (40 sites in
   `game.js`, 15 in `openai-ai.js`). Same *layout*, not same *match*. One `Game.rand`
   seeded from the map seed closes it.
4. **S3 — size.** `buildGameStateJSON` is 1093 lines and `sendToOpenAI` 810: the state
    contract and the request path are each one un-reviewable function. Byte-identical
    `git mv` into one file per concern keeps all 303 tests green — that is the whole
    migration.
5. **S3 — repo weight.** 108 MiB pack for 2.6 MiB of text (51.3 MiB transcripts, 28.7 MiB
    media, no LFS). The two things this app writes into its own folder, `results_*.md` and
    `match-*.jsonl`, are now ignored; the existing history still needs LFS or a rewrite.
6. **S4 — no GPU diagnostics:** `getError` appears nowhere in `js/engine/`, and
    `makeMesh` returns `-1` on failure with unchecked callers — so the default engine
    failure is "a unit silently never appears", which the transcript will blame on the
    model's build order.
7. **S2 — nothing rejects an answer for a round that already closed.** After a rate-limit
    backoff the retry is skipped only when the run stopped or the seat's deadline was
    aborted; there is no staleness check where a reply is applied (`lane.askedInRound` is
    stamped and logged, never compared on arrival), so an answer to round 40's question can
    be executed against round 41's world. A dead `roundStillOpen` implied the check existed;
    it is deleted and the comment at the retry now states what really happens. Wiring a guard
    is a decision about what a turn-based match means — a late answer is still a good answer
    to a question nobody is asking — and a correct one needs both halves the helper named:
    the round number catches an answer overtaken by a later round, and the phase catches the
    round that resolved *without* this seat, since a timeout flush leaves the number alone.
8. **S4 — the structural version of §1.** Escaped strings still reach attributes by string
    interpolation rather than by DOM API, and 254 interpolations sit inside double-quoted
    attribute values in `ui.js`. After the helper fix, every one of them that can carry an
    outsider's string routes through it (audited: `data-v`, `title`, and the four `value=`
    fields for name/endpoint/model/reasoning). What is left raw is internal —
    `class="…${m._status.cls}"` (three literals: ok/err/pending), `placeholder="${t(…)}"`
    (the dictionary), `onclick="${clickHandler}"` and `data-cost='${JSON.stringify(cost)}'`
    (numbers and identifiers the code builds). So the residual risk is future, not present,
    and the durable shape is `textContent` + `dataset` + `addEventListener`, which removes
    the category instead of policing it. There is now one helper and it is deliberately the
    strict one: if a text-position-only escape is ever genuinely needed, add a second helper
    rather than loosening this one.

9. **S2 — a free upgrade the participant is never told about, and it is not free for every
   seat.** When a player researches an age, `upgradeFieldUnits` (game.js:3124) walks its army and
   silently re-types each veteran using `UNIT_UPGRADE_PATHS` (buildings.js:198): a bronze warrior
   becomes a champion at iron, at no cost, with no order given. Two things are wrong-looking about
   that, and the tables make them *exactly* true rather than approximately:

   * Nothing model-facing mentions it. The only "upgrade" in the vocabulary is the `upgrade_age`
     **action**; no prompt or state field says what taking it then does to the army. A model whose
     previous state read "4 warriors" sees "4 champions" in the next and is given no reason, and
     the stat jump is worth real combat — it is a free effect of a decision it made for other
     reasons.
   * It applies unevenly across seats. Persia's `uniqueUnits` are the **standard** ids
     `archer`/`cavalry`/`heavy_cavalry`, so a Persian veteran inherits those paths and does
     advance; the other three civs own distinct types — Egyptian slinger and horse carriage,
     Greek hoplite and phalanx, Yamato samurai — and **none** of them appears in
     `UNIT_UPGRADE_PATHS`, so on one island at one age-up one seat's army is upgraded for free
     and three seats' are untouched. Persia's are also the only "signature" units that are not
     actually distinct units.

   Not fixed, because both repairs are balance decisions: adding paths for the five uniques hands
   three civs a free stat jump they have been silently paying for, and advertising the rule in the
   prompt changes how models value `upgrade_age` (which is itself measured in every score this
   project has published). What is fixed is the ability to see it: the whole per-civ table is
   asserted in `tests/roster-advancement.test.cjs`, along with three invariants that do hold and
   would break on a careless edit — every shared-roster unit fieldable before the last age has a
   path, no path targets a unit no host produces, and no morph fires at an age before its target
   is trainable. Deleting `archer:` fails the first; retargeting a path at `ghost_unit` fails the
   second; `slinger -> elite_archer` at neolithic fails the third; giving hoplite a path fails the
   civ table. (The first of those tests passed with `archer`'s path deleted until it was
   re-scoped: it had been excluding civ uniques, and Persia's uniques *are* `archer` and `cavalry`
   — which is how this was found at all.)

## Not verified

Claims from the delegated reviews that I did not confirm, and therefore do not assert
here: two divergent rate-limit definitions; malformed-call placeholders appended out of
position; a plan discarded with a false error when sharing a reply with an unparsable
command; the `_ctxShrink` ratchet being permanent; harvest over-delivery on a node's last
trip; a destroyed farm retargeting its worker through fog; a campaign AI Wonder pinning
speed at 1×. Each is checkable in the way the confirmed ones were.

One transient page error seen while loading a 1-turn transcript in a diagnostic run did
**not** reproduce once the test waited for the row instead of sleeping. My race, not the
app's — recorded here because it looked like a finding.

## Reproducing

```bash
npm test                      # 309 unit tests, ~77 s, needs only Node
npm run test:browser          # optional: needs Playwright reachable via WAR_PLAYWRIGHT_PATH
                              #   WAR_PLAYWRIGHT_PATH=/path/to/node_modules/playwright \
                              #   WAR_CHROME_PATH=/path/to/chrome WAR_QA_DIR=/tmp/qa \
                              #   node tests/browser/trust-boundary.cjs
```

**Which GPU a browser run is really using.** Nothing in this section's frame-rate claims means
anything until that is answered, and the obvious answers are all wrong: headless Chromium picks
software rasterisation and keeps picking it whether or not a card is installed. Measured here on
a machine with a Radeon AI PRO R9700 bound to `amdgpu` with a Mesa Vulkan ICD present:

| launch flags | `UNMASKED_RENDERER_WEBGL` | rAF fps | rebuild of the 39-texture set |
|---|---|---|---|
| (none) | ANGLE … SwiftShader Device (Subzero) | 20.7 | 518 ms |
| `--enable-unsafe-swiftshader` (what the suites pass) | ANGLE … SwiftShader Device | 21.8 | 512 ms |
| `--use-gl=egl` | ANGLE … SwiftShader Device | 21.2 | 513 ms |
| `--use-gl=glx` | ANGLE … SwiftShader Device | 21.2 | 540 ms |
| `--use-gl=angle --use-angle=vulkan` | **ANGLE (AMD, Vulkan 1.4.354 (AMD Radeon AI PRO R9700 (RADV GFX1201)), radv)** | **60.0** | **281 ms** |

`MAX_TEXTURE_SIZE` differs too — 8192 under software against 16384 on the card — so a texture
that fits on one may not fit on the other. The suites take `WAR_CHROME_ARGS` for exactly this:

```bash
WAR_CHROME_ARGS="--use-gl=angle --use-angle=vulkan" npm run test:browser
```

Why it is a correctness note and not a speed note: `requestAnimationFrame` cadence is the whole
subject of §7, and a 21 fps tab takes ~46 ms ticks while a real one takes ~16 ms — so the
sub-step counts differ, and with them anything measured in frames. Claims here that depend on
frame timing were re-run on the card; the earlier software numbers stay in the text where they
were first recorded, labelled as such.

**What this pass changes in published numbers.** Scores move. A seat the harness silenced is
now ranked on the play the game can see rather than on a manufactured zero, so comparing a
results file written after this change against one written before it is comparing two
different statistics. The `match-*.jsonl` ranking export likewise carries `null` where it
carried a `0`; a downstream reader doing arithmetic on those fields sees the absence now,
which is the point, but it is a visible change in the artefact's meaning.

Elimination changes too, and that one is not cosmetic: seats that can still train a priest or
a civ-unique unit are no longer deleted. Matches run longer, `defeated` in the model-facing
state appears later, and a ranking produced by an older build may have condemned a seat the
current one keeps alive — every score published before this change came from a different
elimination rule.
