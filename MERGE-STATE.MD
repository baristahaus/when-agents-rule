# Merge state — live tracking doc

**Purpose:** if this session dies, a fresh one resumes from this file alone. Update it at
every step. It is the only live status; `baristahaus-merge.MD` is the stale handoff from the
previous session (kept for its analysis, do not trust its paths — the repo moved).

Repo: `/home/barista/zmodern/when-agents-rule` (NOT `/home/barista/code/...`)

## Snapshot

| thing | value |
|---|---|
| Branch carrying the merge | `sync/upstream-b1039` (HEAD) |
| parent1 (ours) | `33a1f11` = `main` = `work/v2-core` = `save/pre-upstream-sync` |
| parent2 (theirs) | `43ac04a` = `upstream/main` (parent build b1039) |
| Merge started by | `git merge --no-edit upstream/main` in the previous session — **never re-run it** |
| Fork point | `ffe9e346` (ours-only 33 commits, upstream-only 156) |
| Divergence ledger | `docs/FORK-DIVERGENCES.md` |
| Worker scratch (outside repo) | `/home/barista/zmodern/merge-work/` |

Branch intent, as decided by the human: `work/v2-core` is **our** line (the Rust
re-implementation and its docs). `sync/upstream-b1039` is the **parent mirror plus what our
hunks need to survive it**. `main` stays at our tip until the gates are green, then is
promoted (that promotion is a human call, never automatic).

## Resolutions done (staged)

| file | resolution |
|---|---|
| `.gitignore` | union: our run-artifact block + their WAR Bench block |
| `package.json` | their `serve.cjs` start/dev, their `test` incl. `tests/sim`, our `test:browser` + `_comment` |
| `tests/build-coordinates.test.cjs` | our stub (pins `rand` **and** `randJitter`) |
| `tests/elimination.test.cjs` | our loader (real training tables, not stubs) |
| `js/analyzer.js` | fused: their `header.startedAt` preference + our loop-instead-of-`Math.min(...)` |
| `ENGINE.md` | both intents: their `RULES-CHANGES.md` build 933 citation, our `QUALITY_REVIEW.md` §7 citation, and the fact that both positional passes now live in `js/simulation/position-rules.js` |
| `tests/ui-workspace.test.cjs` | theirs (their `smoothFrame` + 3 tests supersede our 4). Our two unique cases — coincident units, per-unit building-escape direction — are deferred to the divergence commit, because upstream's module currently fails both. See ledger D1/D2. |

## Open conflicts and who owns them

Four detached `pi -p` workers, one file-set each, briefed from
`/home/barista/zmodern/merge-work/BRIEF.md` (read it before taking over a file).

| worker | files | report |
|---|---|---|
| W1 | `js/game.js` (29 markers) | `merge-work/LOG.w1.md` |
| W2 | `js/openai-ai.js` (9), `js/ai.js` (5) | `merge-work/LOG.w2.md` |
| W3 | `js/i18n.js` (12), `index.html` (2), `js/ui.js` (2) | `merge-work/LOG.w3.md` |
| W4 | `game-state-schema.json` (17), `js/engine/gamerenderer.js` (2) | `merge-work/LOG.w4.md` |

```
/home/barista/zmodern/merge-work/drive.sh status   # alive/dead, exit code, marker counts
/home/barista/zmodern/merge-work/drive.sh start 3  # re-spawn one worker (idempotent guard built in)
```

Gotcha found the hard way: `pi -p` buffers stdout until it finishes, so an empty log means
*unfinished*, not *dead* — trust `pid.N`/`exit.N`, not the log. Plain `setsid` (no `-f`)
fails silently from a background shell and leaves the child in the harness's process group,
where it gets killed at the end of the tool call. `drive.sh` uses `setsid -f` for that reason.

**Never run `git checkout -b` (or any checkout/switch) while the merge is in progress** — it
silently drops `MERGE_HEAD` and `MERGE_MSG`. This already happened once; recovery was
`echo 43ac04a... > .git/MERGE_HEAD`, rewrite `MERGE_MSG`, `git symbolic-ref HEAD
refs/heads/<branch>`. To move HEAD mid-merge use `git symbolic-ref`, never `checkout`.

## Decisions taken (human-approved)

1. **Branch for our work** — `work/v2-core` holds our parallel line; the merge lands on
   `sync/upstream-b1039`; `main` is promoted later, by a human.
2. **Divergences** — where our side holds a real fix upstream's rewrite lost, keep
   upstream's code in the merge commit, then re-apply ours in a separate documented commit,
   one entry per divergence in `docs/FORK-DIVERGENCES.md`. The JS mirror stays re-syncable.
3. **The golden moves to the merged build once, then freezes** — re-derive from the merged
   recorder (b1039 + our divergences), label it by build and coreHash, and do not re-derive
   on every upstream sync. The old b908 fixtures are kept, labelled, and no longer chased.
4. **Push policy** — fork only: branches to `origin`, no PR to the parent, `origin/main`
   is not moved without the human.

## Verification checklist (before the merge commit)

- [ ] `grep -rn '^<<<<<<<' --include='*' .` → nothing (excluding `.git`)
- [ ] `node --check` on every changed `.js`; `JSON.parse` on `game-state-schema.json`
- [ ] worker reports read, and their `DIVERGENCE CANDIDATES`/`UNRESOLVED` lists folded into the ledger
- [ ] `npm test` (now includes `tests/sim/*.test.cjs`) — green except known-divergence assertions
- [ ] `node --test tests/shipped-files.test.cjs` — the module graph in `index.html` is complete, no duplicates
- [ ] `cargo test` in `rust/core` — our parallel core still reproduces the **old** golden (it must stay green on `work/v2-core` semantics)
- [ ] merge commit on `sync/upstream-b1039`, parents `33a1f11` + `43ac04a`
- [ ] divergence commit(s) + ledger
- [ ] golden re-derived once, labelled, committed
- [ ] `git push origin sync/upstream-b1039 work/v2-core main save/pre-upstream-sync` (main push = human call)

## Log

- `Oct 3 11:38` previous session started the merge, wrote `baristahaus-merge.MD`.
- `Oct 3 12:40` verified on-disk state: 15 unmerged, `MERGE_HEAD` = `43ac04a`, nothing lost.
- `Oct 3 12:44` incident: a `git checkout -b` probe dropped `MERGE_HEAD`/`MERGE_MSG`. Recovered, verified, documented above.
- `Oct 3 12:52` `work/v2-core` and `sync/upstream-b1039` created at `33a1f11`; HEAD moved by `symbolic-ref`; merge intact.
- `Oct 3 12:53` 5 files resolved and staged (`.gitignore`, `package.json`, 2 tests, `js/analyzer.js`).
- `Oct 3 13:00` W1–W4 spawned with `setsid -f`, pids recorded in `merge-work/pid.N`.
- `Oct 3 13:05` `ENGINE.md` + `tests/ui-workspace.test.cjs` resolved and staged. 8 files left, all with workers.
