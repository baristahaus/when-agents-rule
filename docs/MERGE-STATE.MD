
## beads is enabled but cannot write here (2026-10-04)

`bd` 1.3.1, embedded backend, `--stealth` init: **reads work** (`bd list` shows all 12) and **every
write is refused** — `bd close` says `embeddeddolt: store is read-only`, after `chmod -R u+w .beads`,
with `BD_NO_REMOTE_ADOPT=1`, and again after `bd init --reinit-local`. `bd export` then reports
"Exported 0 issues" while `bd list` reports 12 open, so the read path and the write path are not
looking at the same store; `bd doctor` says it is "not yet supported in embedded mode" and points
at the empty `.beads/embeddeddolt/` directory. Six of the twelve are duplicates I created by
running my own create-loop twice without reading its output, and they cannot be closed. Treat
`bd list` as an unreliable ledger on this machine until someone fixes the backend; the commitments
themselves are in this file and in `skills/odin-core-port/reference/golden.md`, which is boring
and works.
