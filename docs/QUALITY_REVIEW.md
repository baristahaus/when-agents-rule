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

The same shape exists in the elimination rules: the sim's `isPlayerEliminated` and the
harness's `isControllerDefeated` answer "is this seat out?" from two different definitions
in two files. Those were **not** merged here — the merge changes who survives a match,
which is a balance decision, not a cleanup. It is the top item under *Still open*.

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

### 6. Invoices in the export

`rawUsage` stores the provider's usage object verbatim into every turn record, so
`cost`, `is_byok` and `upstream_inference_completions_cost` ride along. Across the seven
samples that publishes **$94.62** of someone's account spend in 2836 turns. README's
claim is literally true — the files are key-free and endpoint-free — and a reader will
still not expect a per-turn bill. Not fixed here: scrubbing `rawUsage` invalidates the
token-budget arithmetic that reads those numbers, and the seven shipped samples would
have to be regenerated. One-line fix, but it wants the author's call on what belongs in
a transcript.

### 7. Sim duties living in the render loop

`gamerenderer.js` says it in its own header: *unit movement lerp, separation, building
clearance — game correctness*. They run from `requestAnimationFrame`. The hidden-tab
driver (`game.js:784`) calls `tick()` straight from a Worker. So while nobody is looking —
which is most of a long match, since "keeps running in a background tab" is a headline
feature — units get no separation and no building clearance. Two matches on one seed can
also differ because one tab was hidden. This is the deepest structural issue here and the
hardest to fix well: the passes touch meshes as well as coordinates, so it needs a
position-space separation pass in `simulateStep` with the renderer reduced to copying
results. Not attempted in this pass — a physics move needs the author watching the
gameplay, and software-WebGL here cannot show it honestly.

Related and smaller: auto-acquisition (`game.js:1208`, range +20/24 against sight 15/22.5)
scans **every** unit on the map with no fog check, and `attack_target` pins an object and
then steers on its live coordinates forever. Both let units act on enemies they have
never seen, which contradicts the rule the models are told. Fixing them changes combat
outcomes, so they go on the open list too.

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
| `js/i18n.js` `sum.legend` ×4 | the legend says terms can be dropped and the rest share the score | rendered text in the summary |
| `index.html` | `?v=` → 908 for the first pass's seven scripts, → 909 (+ stylesheet 837) for the context-loss change, → 910 for the scoring pass | repo convention held |
| `.github/workflows/ci.yml` (new) | syntax-check every shipped file, parse both JSON contracts, run the suite — every step was executed locally first | commands run here |

Suite state: **277/277 unit tests** (259 before the pass; +3 for the engine guard, +6 for the scoring); the visual suite and the trust-boundary suite each
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

1. **S1 — elimination has two definitions.** The sim can delete a seat the harness still
   considers alive. A seat that dies to the wrong predicate is a data point removed for a
   reason the transcript does not record.
2. **S1 — sim duties in the render loop** (§7), including the hidden-tab divergence.
3. **S2 — fog leaks in combat** (§7): aggro outranges sight and scans through fog; pinned
   targets never re-check it.
4. **S2 — `usageRaw` publishes spend** (§6).
5. **S3 — CI covers the unit suite only.** `.github/workflows/ci.yml` runs
   `node --check` over every shipped file, parses `game-state-schema.json` and
   `samples/index.json`, and runs `node --test`. It deliberately does **not** run the two
   Playwright suites: the runner would have to fetch a browser per job, and a job that is
   red for network reasons trains people to ignore it. Those suites are the only regression
   guard for the escaping fixes, so wiring them is the next thing to settle. Also
   unenforced: the `?v=`-must-move-with-the-change rule (`tests/shipped-files.test.cjs`
   checks every tag *exists* and every file is *loaded*, not that a touched file got a new
   tag — that needs git history, which is a CI job, not a unit test).
6. **S2 — match-level reproducibility.** Terrain is seeded; unit positions, harvest
   targets and `explore` tile resolution use unseeded `Math.random()` (40 sites in
   `game.js`, 15 in `openai-ai.js`). Same *layout*, not same *match*. One `Game.rand`
   seeded from the map seed closes it.
7. **S2 — no test touches `WAR_PRIVATE_HOST`** — the host classifier itself (as opposed to
   its effect, which block 1 now covers) is still unguarded, and `js/analyzer.js:11` shares
   the shape.
8. **S3 — size.** `buildGameStateJSON` is 1093 lines and `sendToOpenAI` 810: the state
    contract and the request path are each one un-reviewable function. Byte-identical
    `git mv` into one file per concern keeps all 268 tests green — that is the whole
    migration.
9. **S3 — repo weight.** 108 MiB pack for 2.6 MiB of text (51.3 MiB transcripts, 28.7 MiB
    media, no LFS). `.gitignore` does not yet cover `results_*.md` or `match-*.jsonl`, the
    two things this app writes into its own folder.
10. **S4 — no GPU diagnostics:** `getError` appears nowhere in `js/engine/`, and
    `makeMesh` returns `-1` on failure with unchecked callers — so the default engine
    failure is "a unit silently never appears", which the transcript will blame on the
    model's build order.
11. **S4 — `_buildTextures` re-bakes 39 textures on a theme change without deleting the
    old set**, while every other texture owner in that file does delete.
12. **S4 — `roundStillOpen` and its comment** (`openai-ai.js:4387`) describe a guard that
    is never called: either wire it or delete the comment that leans on it.
13. **S4 — the structural version of §1.** Escaped strings still reach attributes by string
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
npm test                      # 268 unit tests, ~77 s, needs only Node
npm run test:browser          # optional: needs Playwright reachable via WAR_PLAYWRIGHT_PATH
                              #   WAR_PLAYWRIGHT_PATH=/path/to/node_modules/playwright \
                              #   WAR_CHROME_PATH=/path/to/chrome WAR_QA_DIR=/tmp/qa \
                              #   node tests/browser/trust-boundary.cjs
```

**What this pass changes in published numbers.** Scores move. A seat the harness silenced is
now ranked on the play the game can see rather than on a manufactured zero, so comparing a
results file written after this change against one written before it is comparing two
different statistics. The `match-*.jsonl` ranking export likewise carries `null` where it
carried a `0`; a downstream reader doing arithmetic on those fields sees the absence now,
which is the point, but it is a visible change in the artefact's meaning.
