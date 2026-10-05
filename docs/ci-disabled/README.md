# CI, disabled (owner decision, 5 October 2026)

Both workflow files moved here verbatim, out of `.github/workflows/`, by the owner's
decision on 5 October 2026: **no CI runs on this repo.** Nothing else changed — the
gates and the suites still run locally, exactly as they did before.

What each file was:

- **`ci.yml`** — the fork's own CI (the parent never had any; it was created on this
  line before the b1039 merge). Its push job ran the JS suite and the golden
  regeneration on **every push to every branch**; its browser job (the two Playwright
  suites) ran only on schedule (04:17 UTC daily) or manual dispatch.
- **`odin-gates.yml`** — the Odin spike's gates, on pushes to the (now retired)
  `sync/upstream-b1039` branch and on PRs.

Why removal disables everything, mechanically:

- A workflow can only trigger from a workflow file present at the ref the event
  points at. No branch we push carries one now.
- The **default branch is the parent's mirror** (`origin/main` = upstream's tip) and
  has never carried a `.github/` directory at all — so the scheduled browser job
  could not have fired from it anyway, and GitHub's workflow list for this repo is
  populated from it: empty.
- The `share/upstream-contract` branch sits on the parent's tree, which has none
  either.

What this does *not* do, stated honestly: it cannot flip GitHub's server-side
"Disabled" badge for workflow entries that already registered from past runs, and any
run already queued when this lands may still finish. That badge needs the API —
`gh workflow disable ci --repo baristahaus/when-agents-rule` (and the same for
`odin-gates`), or Settings → Actions in the UI — and neither `gh` nor a token exists
on the machine that made this change. The entries' history stays visible in the
Actions tab either way; nothing new will start.

To re-enable: `git mv` both files back to `.github/workflows/` and push. Their `on:`
blocks, pinned runner images and action versions are intact and unedited below — the
pinning rationale (why `ubuntu-24.04`, why the v7 actions) is documented in their
comments and was earned on real runs.

What still checks this repo, and where: `./spike/gates.sh` (the eight Odin gates,
including the no-FMA disassembly count and the corpus gate that regenerates the
states oracle), `npm test` (671 tests as of the b1054 merge), and
`node tools/trace-states-port.cjs` against the canonical fixture. All local; nothing
automated runs the browser suites anywhere now, which is the one real loss — noted
where it matters (`skills/odin-core-port/reference/build.md`).
