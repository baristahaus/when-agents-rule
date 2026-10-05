# Merge state — the running ledger

One page that is always true about where this fork stands against the parent, written so
that whoever picks it up next (including a future me with no memory) can rebuild the whole
picture from measurements instead of trust. Update it **as you work**, not at the end.

Last updated: 5 October 2026, at HEAD `f9dc0c3` on `sync/upstream-b1039` — the v2 line
has moved past `rebuild/v2`; see *Branch and remote state* below.

## The one-paragraph version

We are a fork of `https://github.com/asp67/when-agents-rule` (the parent, which ships the
game). Our line keeps a handful of simulation fixes and a **byte-exact golden corpus**
(`golden/`) that holds any core to the shipped JS; the parallel Rust core that proved the
porting method is **retired** (tag `rust-core-final-b1040`), and the v2 core is being
rebuilt in **Odin** against the same corpus — its record is `docs/REBUILD-EFFORT.md`. We
merged the parent through **build 1039** (`43ac04a`), re-applied our fixes on top, and
**re-derived the golden** so any port is measured against the current rules instead of a
year-old recording; the parent has since shipped 15 more builds (tip b1054), unmerged.
`main` stays shippable v1 (the parent's JS); v2 work lives on `rebuild/v2` (reconciled
and pushed 5 October — see *Branch and remote state*).

## Commands that answer every question here

| Question | Command | Last measured |
|---|---|---|
| Do the Odin gates still pass (vectors, counts, coast, four map lines, no FMA, vet, corpus)? | `./spike/gates.sh` | 8/8 green, 5 Oct 2026 — four map conditions byte-identical |
| Does the frozen JS port reproduce the state view? | `node tools/trace-states-port.cjs golden/states-b1040-t0-t1.canonical.jsonl` | GATE PASS, 8 lines byte-identical, 5 Oct 2026 |
| Does the Odin core reproduce turn 1? | *(in flight — `spike/turn1/main.odin` ~70%, does not compile yet; the map is `spike/turn1/HANDOVER.md`)* | not green yet |
| Do the golden files regenerate? | `node tools/golden/record.cjs -seed golden -seats 4 -minutes 1 -difficulty medium -out /tmp/x.jsonl && cmp /tmp/x.jsonl golden/stream-b1040-1m.jsonl` | byte-identical, 2,722,912 bytes (CI runs it) |
| Is the game green? | `npm test` | 628/628, 5 Oct 2026 |
| How far behind the parent are we? | `git log --oneline HEAD..upstream/main \| wc -l` | 15 (parent tip b1054; last merged b1039) |
| What did we change that they did not? | `git log --oneline $(git merge-base HEAD upstream/main)..HEAD` | 65 commits, 5 Oct 2026 |
| Does the state still honour its contract? | `node --test tests/contract.test.cjs` | 7/7, 5 Oct 2026 |

## Branch and remote state

    origin   git@github.com-war:baristahaus/when-agents-rule   (our fork)
    upstream https://github.com/asp67/when-agents-rule         (the parent, read-only for us)

- `origin/main` = `c7fafd7`, the parent's b1054 tip (identical to `upstream/main`) —
  **decided 5 October: it stays the parent's mirror.** The upstream path owns that
  branch; we do not push our line to it. All our work lives on our branches below, and
  `main` locally (`33a1f11`) remains our v1 snapshot.
- `rebuild/v2` = **HEAD** (pushed; `origin/rebuild/v2` = `1dae26a`) — the v2 line,
  reconciled 5 October: fast-forwarded from `c4a32da` over the seventeen commits that had
  drifted onto the sync branch (the Rust retirement, the Odin spike and its gates, the
  state dumper, the CI workflows, the frozen JS port, the turn-1 WIP, the effort record).
- `sync/upstream-b1039` — **retired 5 October**, deleted locally and on origin; its tip
  was an ancestor of the reconciled `rebuild/v2`. `work/v2-core` (a stale duplicate of
  the pre-merge snapshot) went with it.
- `save/pre-upstream-sync` = `33a1f11` — the exact pre-merge tree, kept as the undo button.
  `git reset --hard save/pre-upstream-sync` is the documented abort path.
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
  `tests/{boot-manifest,usage-redaction,contract}.test.cjs`, `tests/lib/schema-check.cjs`
  and `rust/core/src/bin/golden-diff`. The same bad list also named
  `tests/version-consistency.test.cjs` and `tools/version.cjs`, which are absent too;
  `tests/shipped-files.test.cjs` is the file that really gates the build stamps. If a
  file-list audit gate is wanted, it has to be written — and note that `npm test`'s glob
  (`tests/*.test.cjs tests/sim/*.test.cjs`) is where that gap bites.
- The 622 number needs one caveat noted honestly: `npm test` runs
  `tests/*.test.cjs tests/sim/*.test.cjs`. Files under `js/` that carry their own
  `*.test.cjs` siblings are **not** in that glob.

## Back toward the parent: what we could share

Asked whether anything here fits the parent's own design well enough to give back, the
answer was measured rather than judged: every test our line has that they lack was copied
**unmodified into a worktree of `upstream/main`** and run there. That distinguishes "aligns
with their rules" from "only works on our fork".

Clean on their tree, and shipped as a shareable branch: `host-classifier` 4/4,
`shipped-files` 5/5, `roster-advancement` 6/6, `state-contract` 5/5, `match-determinism`
4/4. Failing there for structural reasons, so not offered: `gl-identity` 0/4 (needs our
`glcore` change), `late-answer` 0/5, `usage-redaction` 0/3 (scans our paths). Partly:
`soundness-scoring` 2/6 — their `seatMetrics` answers `0` where there is no sample
(`latEarly`, `latLate`, `minLatency`, `maxLatency`, `avg`, `med`), which reads as a seat
that answered instantly and never failed rather than a seat that never answered; worth a
joint look, not a drive-by patch. `tests/sim/rng-seats.test.cjs` already pins the per-seat
draw invariance we ported, so nothing was offered there.

The branch is `share/upstream-contract`, two commits off `upstream/main`, in a worktree at
`/tmp/share-branch` while the DNS is out:

1. `838845f` — declare `ordersInProgress.from`, which `js/standing-orders.js` emits in
   patrol mode and their schema never named, and give `tests/lib/schema-check.cjs` the
   `minItems`/`maxItems` the constraint needs. Their checker implements exactly the keywords
   the schema uses and throws on the rest, so the schema edit and the checker edit have to
   be one commit: the schema change alone fails loudly on every recorded state, which is
   the design working. Plus a `contract.test.cjs` case proving the arity bites, a
   RULES-CHANGES entry in their voice under build 1040, and `js/game.js?v=1040` (their
   convention: the build is that one number; `audio.js` stays at 1039 because this does not
   touch it).
2. `f9be2e6` — the five tests above, 590 lines, unmodified.

Measured on their tree: baseline `node --test tests/*.test.cjs tests/sim/*.test.cjs`
**592 tests, 0 failures** at b1054; with both commits **616, 0 failures** — exactly the 24
cases the five files add, so nothing existing moved. `contract.test.cjs` 7/7, and a two-long
`{to,from}` validates clean while `[10]` reports `1 items < minItems 2` and `[1,2,3]`
reports `3 items > maxItems 2`.

**The first version of this branch was wrong, and the fix is now a command.** It was prepped
against `43ac04a` (b1039) because that was the parent as of the merge — but the parent had
shipped 15 more builds in the six hours since, and our entry claimed **Build 1040**, which
they had used three days earlier for a fight-card fix. A green local suite cannot see either
problem: the diff looked fine, only the base and the number were stale. The branch is now
rebased onto `c7fafd7` (b1054), re-stamped `js/game.js?v=1055`, renumbered in
`docs/RULES-CHANGES.md`, and re-verified at 616/616 above.

The rule that came out of it — **before prepping or pushing a PR, ask the parent where it
actually is** — is a gate rather than an intention: `tools/upstream-check.cjs` fetches the
parent, prints its tip and build, how far behind our base is, which of the files we propose
to touch moved upstream, and whether the build number we mean to claim is already in their
ledger; exit 1 means do not open the PR, exit 2 means the fetch failed so it refuses to call
a stale answer current. Self-tested by running it on the actual mistake:

**Published.** The first attempt failed on DNS alone — `ssh: Could not resolve hostname
github.com`, four retries, while other names still resolved, and no more a mystery an hour
later when it resolved and the same push went straight through. Both branches are on
`origin` now: `share/upstream-contract` = `f9be2e6`, `rebuild/v2` = `b4cf4bc`, `main` =
`33a1f11`. To open it:
`https://github.com/asp67/when-agents-rule/compare/main...baristahaus:when-agents-rule:share/upstream-contract`.
Note the branch is deliberately based on `upstream/main`, not on our `main`, so their diff
shows two commits and nothing fork-shaped.

## Next, in order

1. **Still open** — D5, the replay fog that reveals dead owned units. `anApplyFog` should
   key off the same alive test the live fog does.
2. **Answered 4 October (spec §14.1, decision 5)** — what `js/resim.js` (theirs) and our
   port should be to each other: the golden is the treaty between engines. The Rust core
   is retired (tag `rust-core-final-b1040`); the parent's JS stays authoritative in the
   browser; our Odin core is authoritative for native and headless; `js/resim.js` remains
   the parent's replay engine, on their side of the treaty.
3. **Resolved by the retirement** — park-and-spread and the two unwired Rust drafts: the
   drafts are deleted with the port (the tag preserves them), and the keyed worker spread
   is transcribed and verified in the turn-1 work in flight (`spike/turn1/`, checked
   against the golden's raw bytes).
4. **Still open** — the replay's own build check: our line should refuse to re-simulate a
   recording whose `coreHash` it cannot reproduce, and say so, rather than replaying a
   match it cannot explain.
5. **Still open** — a real file-list audit gate (recorder ↔ `js/manifest.js` ↔
   `index.html`), since the ledger keeps finding drift in exactly that seam.

The rebuild's own next steps — the turn-1 gate, the uncommitted tree, the branch
reconciliation — are ordered in `docs/REBUILD-EFFORT.md` §5.

```
$ node tools/upstream-check.cjs --branch=share/upstream-contract --claim-build=1040
TAKEN    build 1040 is already used upstream: "A fight's card no longer says \"lost 3 of 0\" (3 October 2026)"
Do not open this PR yet:
 - build 1040 is taken; use 1055
```

## Rules of engagement for anything upstream

1. `git fetch upstream`, then `node tools/upstream-check.cjs --branch=<the branch>
   --files=<every file the PR touches> --claim-build=<the number you mean to write>`. Exit
   0 or no PR. Re-run it immediately before pushing, not only before branching: the parent
   ships several builds a day, and "we checked" means nothing at PR time if it meant
   morning.
2. Base the branch on `upstream/main`, never on our `main`, so their diff shows the change
   and nothing fork-shaped.
3. A schema or contract change carries its checker in the same commit: their
   `tests/lib/schema-check.cjs` throws on keywords it has not met, so half the change fails
   loudly on every recorded state.
4. Never renumber their builds locally. Ask them what number to use if it matters; the
   `RULES-CHANGES.md` heading and the `js/game.js?v=` stamp are the same number, in their
   convention.
