
## beads is enabled, and it can file work but never finish it (2026-10-04)

`bd` 1.3.1, embedded backend. Measured, not guessed: **`bd create` succeeds** (18 issues filed,
including the map-port ladder) and **every update or delete is refused** — `bd close` says
`embeddeddolt: store is read-only` on six week-old duplicates *and* on an issue created seconds
earlier, after `chmod -R u+w .beads`, with `BD_NO_REMOTE_ADOPT=1`, after `bd init --reinit-local`,
and `bd doctor` replies that it "is not yet supported in embedded mode" while pointing at an empty
`.beads/embeddeddolt/`. `bd export` reports "Exported 0 issues" while `bd list` reports 13 open, so
the read path and the write path are not looking at the same store. A tracker you can append to but
never close is worse than no tracker: the ledger drifts and still looks authoritative. Until the
backend is fixed (server mode, or a version where embedded writes work), the commitments below and
in `skills/odin-core-port/reference/golden.md` are the ledger.

