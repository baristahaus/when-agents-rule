# Merge state — the running ledger

One page that is always true about where this fork stands against the parent, written so
that whoever picks it up next (including a future me with no memory) can rebuild the whole
picture from measurements instead of trust. Update it **as you work**, not at the end.

Last updated: build 1040, 4 October 2026, commit `1a10366`-ish (see `git log --oneline -6`).

## The one-paragraph version

We are a fork of `https://github.com/asp67/when-agents-rule` (the parent, which ships the
game). Our line keeps a **parallel Rust core** (`rust/core`) held to the shipped JS by
byte-exact golden traces, plus a handful of simulation fixes. The parent has moved 156
builds since we forked. We have now merged the parent through **build 1039**
(`43ac04a`), re-applied our fixes on top, and **re-derived the golden** so the port is
measured against the current rules instead of a year-old recording. `main` stays shippable
v1 (the parent's JS); v2 work lives on `rebuild/v2`.

## Commands that answer every question here

| Question | Command | Last measured |
|---|---|---|
| Does the map still match the reference byte for byte? | `cd rust/core && cargo run --release --offline --bin golden-diff -- golden/stream-1m.jsonl` | PASS, 942 nodes, 47,097 bytes |
| Does the core reproduce turn 1? | `cd rust/core && cargo test --offline` | 5 lib + 1 gate, 0 failed |
| Do the golden files regenerate? | `node tools/golden/record.cjs -seed golden -seats 4 -minutes 1 -difficulty medium -out /tmp/x.jsonl && cmp /tmp/x.jsonl rust/core/golden/stream-1m.jsonl` | byte-identical, 2,722,912 bytes |
| Is the game green? | `npm test` | 622/622 |
| How far behind the parent are we? | `git log --oneline HEAD..upstream/main \| wc -l` | 0 (merged through b1039) |
| What did we change that they did not? | `git log --oneline $(git merge-base HEAD upstream/main)..HEAD` | our 33 + the 3 sync commits |
| Does the state still honour its contract? | `node --test tests/contract.test.cjs` | 7/7 |

## Branch and remote state

    origin   git@github.com-war:baristahaus/when-agents-rule   (our fork)
    upstream https://github.com/asp67/when-agents-rule         (the parent, read-only for us)

- `main` — our **v1** line: 33 fork commits including the pre-sync WIP snapshot. Pushed.
- `rebuild/v2` — this merge plus the divergence fixes and the re-derived golden. Pushed.
- `save/pre-upstream-sync` = `33a1f11` — the exact pre-merge tree, kept as the undo button.
  `git reset --hard save/pre-upstream-sync` is the documented abort path.
- `sync/upstream-b1039` — the same commits as `rebuild/v2` under the name the sync work
  used. Delete once `rebuild/v2` is merged or the choice is recorded.
- The parent also has a branch `upstream/next-level`; we do not track it. Ask before
  merging it — it is not in this ledger's history.

## What this sync actually was

`git merge upstream/main` at parent `43ac04a`: 150 files auto-merged, **15 conflicted**.
Fork point `ffe9e346`. Since then: ours 33 commits, theirs 156 (b908 → b1039).

The parent's big move was to **rewrite the JS simulation layer** and split the rules into
`js/simulation/{rng,math,position-rules}.js`, `js/conditions.js`, `js/standing-orders.js`,
`js/identity.js`, `js/manifest.js`, `js/boot.js`, plus `js/resim.js` — a **JavaScript**
re-sim of a recorded match, which is the same problem our Rust core solves. That is the
standing architectural tension of this fork: two re-simulators in one repository. We keep
both and say so; the JS one is the parent's and drives the replay UI, ours is the porting
target and drives nothing yet.

### The 15 conflicts, and how they went

`package.json` (took theirs' `start`/`dev`/`test`, kept our `test:browser`), `.gitignore`
(union), `ENGINE.md`, `index.html`, `js/analyzer.js`, `js/ai.js`, `js/game.js` (87 markers),
`js/gamerenderer.js`, `js/i18n.js`, `js/openai-ai.js`, `js/ui.js`,
`tests/build-coordinates.test.cjs`, `tests/elimination.test.cjs`, `tests/ui-workspace.test.cjs`,
`game-state-schema.json`.

A fleet of four parallel workers resolved part of this before the line stalled; their raw
reports are at `/home/barista/zmodern/merge-work/LOG.w*.md` and the brief at
`BRIEF.md`. They are worth reading — two of their repairs were silent (no conflict
markers), so I re-verified each against the committed tree:

- **W5, `game-state-schema.json`** — the file held `ordersInProgress` **twice** (our block
  and theirs). `JSON.parse` keeps the last, so ours looked present and was inert. Their
  repair kept upstream's block and re-added our `from`. Verified: one occurrence now, and
  `from` is in it.
- **W6, `js/ui.js`** — our "a metric with no denominator is `null`, not 0" repair had been
  reverted by a stalled worker; repaired, and `tests/soundness-scoring.test.cjs` covers it.
  Their `esc(build)` escaping repair is at `js/ui.js:7458`. Verified: both present.
- **W8, `js/i18n.js`** — `boot.gpuLost`/`boot.gpuLostWhy` were missing from all four
  language objects while `js/game.js` asked for them. Verified: 4 occurrences present.
- **W1, `js/game.js`** — kept upstream's difficulty leg, routed through our
  `storedDifficulty()` so the `DIFFICULTY_MODS` validation survives. Verified present.
- **W9, `tests/vision-index.test.cjs`** — diagnosed a vision index that let a **corpse's**
  sight disc answer "visible". Resolved upstream of this ledger: our
  `if (u.health <= 0) continue;` is in `js/ai.js:49`, and the test passes.

## Our fixes, after the merge

`docs/FORK-DIVERGENCES.md` is the real ledger (index table + one section each). Summary:
**applied** D1 (coincident units separate), D2 (a unit on a building's origin escapes by
its own bearing, not one fixed southeast vector), D3 (a temple trains nothing, so stop
offering priests — and stop listing them), D4 (`storedDifficulty` read `DIFFICULTY_MODS`
bare in a VM that never loads `terrain.js`, so a stale localStorage difficulty poisoned
every gather rate), D6 (the order-endpoint arity, below); **superseded** S1 (keyed
draws), S2 (refereeing off the render loop), S3 (boot split), S4 (elimination by assignment
rather than intent) — the parent solved each better, and we re-ported S1 into the core;
**open** D5 (replay fog reveals dead owned units — an `anApplyFog` bug we have carried, in
a renderer area the parent rewrote twice).

D6 is worth repeating because it is the pattern: our side's schema said
`ordersInProgress.to/.from` are `minItems/maxItems: 2`; the merge kept upstream's looser
version. Restoring the constraint **broke `tests/contract.test.cjs`** first, because
`tests/lib/schema-check.cjs` throws on any keyword it has to guess at — and it did not know
those two. So the keyword is now implemented (length, then elements) and a 1- or 3-element
`to` is reported, which is what makes a contract that says `[x, z]` mean it.

## The golden, and the one time we move it

`samples/golden/initial/golden-initial.jsonl` (26,629,752 bytes, 10 min) and
`rust/core/golden/stream-1m.jsonl` (2,722,912 bytes, 1 min, a byte-prefix of the same
match) were **re-recorded at build 1040**, the first re-derivation since the split. Plan
from here: never again, so "it fails" always means "the port is wrong", never "the
fixtures are stale".

Two surprises, both documented in `docs/FORK-DIVERGENCES.md` § "Following the golden down":

1. `tools/golden/record.cjs` loaded **12 files by hand**, a list that predates
   `js/simulation/*`. It now loads `js/manifest.js`'s `vm` list — the same 16 files
   `index.html` loads and `tests/boot-manifest.test.cjs` gates. The map line did not move
   (47,098 bytes, identical), which is the check that adding `rng.js` to the load order
   drew nothing ahead of the map.
2. The turn-1 gate went red in six paths: three worker coordinates and `matchSeconds`. The
   coordinates needed **keyed draws** ported to `rust/core/src/prng.rs` (`KeyedRng`, with
   vectors from `js/simulation/rng.js`), and `matchSeconds` was **our spec being wrong** —
   §3.4 called a frozen clock a degenerate invariant when it was really the build 934–949
   bug that build 950 fixed. §3.4, §13 and the proposal's §9 now say the clock advances.

The golden's other degeneracies survived 131 builds intact, which is the good news: every
seat ends in the stone age, discovers nothing, names no winner, opens 200/200/100/50 and
ends 0/50/100/50 after exactly `house` and `farm`.

## Things this ledger used to get wrong (so nobody repeats them)

- **I reported 6,074 tests.** The suite is 622 (621 before the merge). The larger number
  was never measured; it came from a summary of a summary. Quote `npm test`, not prose.
- **I reported tooling that does not exist**: `test/manifest.cjs`, an `npm run audit`
  script, `tools/gate-selftest.cjs`, `tests/golden-manifest.test.cjs`,
  `tools/check-fork-sync.cjs`. Nothing in this repository ever held them. The tools that
  exist are `js/manifest.js`, `tools/golden/{record,compare}.cjs`,
  `tests/{boot-manifest,usage-redaction,contract,version-consistency}.test.cjs`,
  `tests/lib/schema-check.cjs` and `rust/core/src/bin/golden-diff`. If a file-list audit
  gate is wanted, it has to be written.
- The 622 number needs one caveat noted honestly: `npm test` runs
  `tests/*.test.cjs tests/sim/*.test.cjs`. Files under `js/` that carry their own
  `*.test.cjs` siblings are **not** in that glob.

## Next, in order

1. D5 — the replay fog that reveals dead owned units. `anApplyFog` should key off the
   same alive test the live fog does.
2. Decide what `js/resim.js` (theirs) and `rust/core` (ours) should be to each other before
   either grows more. Today they are two answers to one question, in one repo.
3. The replay's own build check: our line should refuse to re-simulate a recording whose
   `coreHash` it cannot reproduce, and say so, rather than replaying a match it cannot
   explain.
4. Consider a real file-list audit gate (recorder ↔ `js/manifest.js` ↔ `index.html`), since
   the ledger keeps finding drift in exactly that seam.
