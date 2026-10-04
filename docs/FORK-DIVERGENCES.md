# Fork divergences — where we differ from the parent, and why

`baristahaus/when-agents-rule` tracks `asp67/when-agents-rule` (the parent). The JS layer is
the parent's to own: we take its structure and re-apply only our own hunks. This file lists
every place where the merged tree deliberately does **not** do what the parent's build does,
or where it still owes a fix. One entry per behaviour, never one entry per file.

Why a file for this instead of comments in the code: the sync happens again. At the next
merge, whoever resolves it needs to know which of our lines are ours on purpose and which
were accidents of resolution — and needs to know which parent fixes we still believe in. A
`grep -rn 'DIVERGENCE'` finds the markers; this file holds the reasoning, the evidence and
the status, and is the thing to read before re-applying anything.

**Reading an entry.** *Status* is `open` (we should fix it, upstream or us, and the tree
currently does not), `applied` (our fix is in our tree and differs from the parent), or
`superseded` (the parent solved it another way; ours is gone and that is correct). *Rule
impact* means the change moves simulated state — it moves `coreHash`, the transcript's
fingerprints and every golden trace, so it must be re-derived, not just merged.

The two forks solved the same problems repeatedly and independently; where the parent's
solution was stronger, ours is gone and `superseded` says so. That cross-checking is the
point of keeping a parallel line, and `D5` is its one finding against us.

---

## Index

| # | Subject | Status | Rule impact | Where |
|---|---|---|---|---|
| D1 | Coincident units never separate | **applied** | yes | `js/simulation/position-rules.js` |
| D2 | A unit standing on a building's origin escapes to one fixed point | **applied** | yes | `js/simulation/position-rules.js` |
| D3 | A temple trains nothing, so a temple-only seat is eliminated while being offered priests | **applied** | yes | `js/game.js` `trainOptionsFor` |
| D4 | `storedDifficulty` reads `DIFFICULTY_MODS` bare in a VM without `terrain.js` | **applied** | no | `js/game.js` `storedDifficulty` |
| D5 | Replay fog reveals dead owned units | open | no | `js/ui.js` `anApplyFog` |
| D6 | `ordersInProgress.to/.from` lost their `minItems`/`maxItems: 2` | open | no | `game-state-schema.json` |
| S1 | Seeded randomness: our one stream replaced by keyed draws | superseded | yes | `js/simulation/rng.js` |
| S2 | Unit refereeing off the render loop | superseded | yes | `js/simulation/position-rules.js` |
| S3 | Boot split: `WAR_PRIVATE_HOST` and the `load` handler left `game.js` | superseded | no | `js/boot.js` |
| S4 | An unfinished site counts only while a worker is ASSIGNED to it | superseded | yes | `js/game.js` `isPlayerEliminated` |

---

## D1 — Coincident units never separate

**The parent's build.** `WarPositionRules.apply` skips a pair unless `dist > 0.01`:

```js
if (dist < SEPARATION_DIST && dist > 0.01) { /* push apart */ }
```

**What we had** (`33a1f11`, `js/engine/gamerenderer.js`): when `dist <= 0.01` there is no
direction between the two, so take one — a fan angle by index, `FAN(i + j * 5)` — and push
along it.

**Why it matters.** The `dist > 0.01` guard was written to avoid dividing by zero. The case it
silently drops is not rare: a move command snaps every unit aimed at the same destination onto
one coordinate. Measured in a running match before our fix: eight units at one point, seven
seconds later, minimum separation still 0.000 — a pillar that separation could never reach,
and since D2 drops building escapes onto one point too, the two bugs compound.

**Where it went.** Our fix moved with the code into `js/simulation/position-rules.js` when the
parent lifted the positional passes out of the renderer (`docs/RULES-CHANGES.md`, build 933) —
the parent's extraction kept its own guard, so the fix is absent from the merged tree.

**Fix on re-apply.** Compute `nx, nz` from `dx/dist` when `dist > 0.01`, otherwise from a fan
angle keyed on the pair's indices, and keep the push itself unchanged.

**Rule impact.** Yes — unit positions feed reach, so fights and `coreHash` move.
**Applied.** In this tree, as `FAN(k)` in `js/simulation/position-rules.js`, with the trig
through `WarMath` (rule code may not depend on how an engine rounds) and the quarter turn
written as a literal since `WarMath` has no `PI`.
**Coverage.** `tests/ui-workspace.test.cjs`, "units standing on the identical point still come
apart" (three units on one coordinate, all three gaps must exceed 0.05).

## D2 — A unit standing on a building's origin escapes to one fixed point

**The parent's build.**

```js
if (dist <= 0.01) { unit.x = building.x + clr; }        // "dead centre: any direction out"
else if (dist < clr) { /* radial push */ }
```

The comment in the same file names our exact bug — a unit standing on a building's origin was
never pushed because the guard skipped it — and then fixes it by teleporting the unit to a
fixed point on the ring. Every unit that lands on a building's origin therefore arrives at the
same point, where separation (D1) cannot reach it.

**What we had:** the escape keeps a per-unit direction, `building.x + clr * cos(FAN(unitIndex))`,
so the ring is filled rather than punctured.

**Fix on re-apply.** Give the dead-centre branch the same fan angle by unit index, and assert
both the ring distance and the fan-out (the parent's test asserts `units[2].x === 54.5`, i.e.
asserts the fixed point; ours asserts the radius and that the escape direction differs per
unit).

**Rule impact.** Yes.
**Applied.** In this tree, `FAN(unitIndex)` on the dead-centre branch. The parent's assertion
that pinned the fixed point (`units[2].x === 54.5`) is now an assertion about the ring radius
and the spoke, in `tests/ui-workspace.test.cjs`.
**Coverage.** `tests/ui-workspace.test.cjs`, "the positional rules push friends apart and clear
buildings" (on the ring *and* fanned along its own spoke).

## D3 — A temple trains nothing, so a temple-only seat is eliminated while being offered priests

`BUILDING_TRAIN_TIERS` names only `barracks`, `archery_range` and `stable`, so
`getTrainOptionsForBuilding('temple', …)` returns `[]`. The parent's `Game.militaryOptions`
reads that table only, and `isPlayerEliminated` uses `militaryOptions` twice (the trainable
test and the `producer` of an unfinished site).

The parent's *other* path disagrees with it. `OpenAIAIManager.trainableUnitsFor` lists `temple`
among its hosts and falls back to the building def: `if (!opts || !opts.length) opts =
(def && def.trainOptions) || []`. So a seat whose last trainer is a temple is told priests are
available, and is simultaneously deleted from the match by the survival rule. Our side had the
fallback in the predicate (`trainOptionsFor`, which resolved tier table → building def, the
same order as the training panel and the vocabulary); the parent's rewrite dropped it.

**Why this is a fix and not a preference:** it does not make our rules beat the parent's, it
makes the parent's two paths agree with each other. **Fix on re-apply:** in `militaryOptions`,
fall back to `getBuildingDef(type).trainOptions` when the tier table answers empty, and mirror
`trainableUnitsFor`'s `requiresTech`/`requiredAge` filters so the predicate cannot advertise a
unit the civ can never field.

**Rule impact.** Yes — who is eliminated, and when.
**Applied.** In this tree as `Game.trainOptionsFor`, which `militaryOptions` now delegates to,
so the predicate and the vocabulary resolve a building's units in one place.
**Coverage.** `tests/elimination-predicate.test.cjs` (all four cases).

## D4 — `storedDifficulty` reads `DIFFICULTY_MODS` bare

Our `Game.storedDifficulty()` validates the stored key against `DIFFICULTY_MODS` (from
`js/terrain.js`) to turn a stale key into a sane difficulty instead of `NaN` multipliers. In a
browser that is fine: `terrain.js` loads first. In a bare VM that loads `js/manifest.js`'s `vm`
list — which contains `terrain.js` — it is fine too; in a harness that loads `game.js` alone it
is a `ReferenceError` the moment a difficulty is read.

**Fix on re-apply:** `typeof DIFFICULTY_MODS !== 'undefined' &&` on the validation, or read it
through the same `typeof` guard the neighbouring table reads use.

**Rule impact.** No (it guards a read). **Applied.** In this tree, as a `typeof` guard that
says why in the comment above it.

## D5 — Replay fog reveals dead owned units

`UIManager.anApplyFog` (`js/ui.js:8175`, our 081dd22) walks the owner's units and buildings to
unveil remembered tiles with no `health > 0` guard, while the parent's live-fog path
(`js/game.js:4371`, `:4587`) filters dead ones. Present on our side before the merge; found
while resolving it, and left alone rather than widened into a presentation change unnoticed.

**Rule impact.** No — replay presentation only. Worth fixing upstream or here, not both.

## D6 — `ordersInProgress.to/.from` lost their arity

`game-state-schema.json` carried `minItems`/`maxItems: 2` on those two coordinate arrays on our
side; the parent's block for the same field does not, and taking the parent's structure dropped
them. The arity is still stated in the field's prose (`"[x, z]"`), so a reader is informed and
a validator is not. Restoring two numbers is a one-line diff; it waits here so the schema stays
byte-comparable to the parent's during syncs.

**Rule impact.** No.

---

## Superseded — the parent solved it better, and our code is gone on purpose

### S1 — Seeded randomness

Our 1cb0d2b made one match reproduce from one seed by routing every rule-code draw through
`Game.rand()` / `Game.randJitter(k)`, off the terrain stream. The parent reached the same goal
with a stronger mechanism: `js/simulation/rng.js` keyed draws, where a value depends on the
match seed, the key (seat + purpose) and how many times **that key** has drawn — never on the
global draw order. Two of our 33 commits (`733be39`, `1cb0d2b`) are therefore superseded, not
lost: `tests/match-determinism.test.cjs` now asserts the keyed properties, including the one a
single stream cannot pass (a draw on another key must not move mine). The parent also fixed a
typo our side carried (`b.z - b.z` in a distance expression).

### S2 — Unit refereeing off the render loop

Our 5d16075 moved separation and building clearance from `animate()` to the simulation clock so
a backgrounded tab kept refereeing. The parent moved them further: out of the renderer entirely,
into `js/simulation/position-rules.js`, run from `Game.tick` in sub-steps of at most 50 ms, with
interpolation so a frame is drawn between two steps. Our renderer-side copies are gone; the two
fixes the extraction lost are D1 and D2.

### S4 — An unfinished building site counts while ANY living worker is alive

Our `d6ee953` required a living worker **assigned** to the foundation
(`u.task === 'building' && u.buildTarget === b`) before an unfinished barracks counted as a
producer in `isPlayerEliminated` and `canAffordAnyMilitary`. The intent was sound — a seat
behind an abandoned foundation was staying in the match indefinitely — but the parent reached
the same goal with a looser and better-read rule: any living worker may walk onto the site, and
the rule-based brain does exactly that. Their `tests/elimination.test.cjs` pins it ("its builder
idle: it can still finish it"); the pathology we were guarding against is already covered by the
clause several lines earlier, which ends any seat with no living worker.

Applied for a while in this tree, and withdrawn when their test said so. Our
`tests/elimination-predicate.test.cjs` now asserts the parent's reading **and** the case that
matters to both of us: no worker alive, foundation standing, seat out.

### S3 — The boot split

`WAR_PRIVATE_HOST`, `WAR_LOCAL`, `WAR_DEMO_ONLY`, `warNoWebGL` and the window `load` handler left
`js/game.js` for `js/boot.js` (the parent's review #6 step 8). Our trust-boundary tests follow
the constant rather than the file: `tests/host-classifier.test.cjs` now reads `js/boot.js`, and
`tests/boot-manifest.test.cjs` asserts `game.js` carries no start-up code at all. One function
stayed behind in `game.js` — `warContextLost`, ours, called by the GPU-context listener the
parent does not have — and `js/i18n.js` carries its two keys in all four languages.

---

## Re-applying at the next sync

1. `git merge upstream/main`; resolve structurally, taking the parent's shape as usual.
2. `git log --oneline docs/FORK-DIVERGENCES.md` is the list of what must survive; re-apply the
   entries marked `applied`, and re-read the `open` ones — if the parent fixed one upstream,
   move it to `superseded` instead of re-applying it.
3. Anything whose rule impact is `yes`: re-derive the golden traces (`tools/golden/record.cjs`,
   see `MERGE-STATE.MD`) and say so in `docs/RULES-CHANGES.md`, which is the parent's own ledger
   of rule changes and should carry ours once they are applied.
