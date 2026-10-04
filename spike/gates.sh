#!/usr/bin/env bash
# The spike's gates, in one command. Run it after touching anything under spike/ or golden/,
# and before believing any claim about a core being byte-exact.
#
#   ./spike/gates.sh
#
# Each gate prints what it expected and what it got, and the script's exit code is the answer.
# A gate that cannot run says SKIP and why — it never reports success on an absent tool, because
# a green light from a check that did not execute is the worst kind of green.
set -uo pipefail
cd "$(dirname "$0")/.."
ODIN="${ODIN_BIN:-odin}"
fails=0
say() { printf '%-58s %s\n' "$1" "$2"; }
note() {
	printf '\n'
	while [ $# -gt 0 ]; do printf '  %s\n' "$1"; shift; done
}

# Gate 1 — the language, present and at a known shape.
if ! command -v "$ODIN" >/dev/null 2>&1; then
	say "gate 1  compiler present" "SKIP — set ODIN_BIN=/path/to/odin"
	say "gates 2-5 (they need it)" "SKIP"
	note "Install: https://github.com/odin-lang/Odin/releases — the dev-2026-09 Linux asset is" \
		"odin-linux-amd64-dev-2026-09.tar.gz, about 70 MB. Reference data: skills/odin-core-port."
	exit 2
fi
ver="$("$ODIN" version 2>&1 | head -1)"
say "gate 1  compiler present" "ok — $ver"

mkdir -p spike/bin

# Gate 2 — the keyed vectors: an Odin transcription of js/simulation/rng.js must print the two
# integers the golden pins. This is the smallest possible byte-exact test and the one that earns
# the rest of the port.
if "$ODIN" build spike/odin -out:spike/bin/prng-spike >/tmp/odin-build.log 2>&1; then
	out="$(./spike/bin/prng-spike)"
	if printf '%s' "$out" | grep -q 'SPIKE GREEN'; then
		say "gate 2  keyed vectors #a9b8bccd #9fd153da" "ok"
	else
		say "gate 2  keyed vectors #a9b8bccd #9fd153da" "FAIL"
		printf '%s\n' "$out"
		fails=$((fails + 1))
	fi
else
	say "gate 2  keyed vectors" "FAIL — build failed"
	tail -12 /tmp/odin-build.log
	fails=$((fails + 1))
fi

# Gate 3 — §14.3: no fused multiply-add. Counted, not assumed, and the count of multiplies is
# checked first, so an empty or stale object file cannot pass by containing no FMA.
fma_cfg="-o:aggressive -microarch:x86-64-v4 -target-features:fma"
rm -f spike/bin/probe.o
if "$ODIN" build spike/fma -build-mode:obj $fma_cfg -out:spike/bin/probe.o >/tmp/odin-fma.log 2>&1 \
  && [ -s spike/bin/probe.o ]; then
	muls=$(objdump -d spike/bin/probe.o | grep -cE 'mulsd|vmulsd|mulss|vmulss')
	fmas=$(objdump -d spike/bin/probe.o | grep -cE '\b(vfmadd|vfmsub|vfnmadd|vfnmsub|fmadd|fmsub)[a-z0-9]*\b')
	if [ "$muls" -gt 0 ] && [ "$fmas" -eq 0 ]; then
		say "gate 3  no FMA under $fma_cfg" "ok — $fmas fma, $muls multiplies"
	else
		say "gate 3  no FMA under $fma_cfg" "FAIL — $fmas fma, $muls multiplies"
		note "A nonzero count is spec §14.3's reopen trigger, not a warning: fusion rounds once" \
			"where the reference rounds twice, so the divergence is silent and seed-independent." \
			"Find the flag that zeroes it, record it here and in skills/odin-core-port/reference/build.md," \
			"and if none does, determinism outranks the language preference and the decision reopens."
		fails=$((fails + 1))
	fi
else
	say "gate 3  no FMA" "FAIL — no object file produced"
	tail -12 /tmp/odin-fma.log
	fails=$((fails + 1))
fi

# Gate 4 — the house style, as the compiler defines it. Informational by default: it is the
# cheapest place to learn what an agent's defaults will trip on, and a line to promote to a real
# gate once the flag set is agreed. (These are the flags the compiler lists, not folklore.)
if "$ODIN" check -vet -vet-unused -vet-shadowing -vet-tabs -strict-style spike/odin >/tmp/odin-vet.log 2>&1   && [ ! -s /tmp/odin-vet.log ]; then
	say "gate 4  odin check -vet -strict-style" "ok — no diagnostics"
else
	say "gate 4  odin check -vet -strict-style" "diagnostics — /tmp/odin-vet.log"
	head -8 /tmp/odin-vet.log
fi

# Gate 5 — the corpus itself: pinned hashes, the 942-node map line, the four turn-1 states, and
# the reference still producing the vectors gate 2 compares against. Language-independent on
# purpose, so it keeps guarding the contract even with no core at all.
if node --test tests/golden-fixtures.test.cjs >/tmp/golden-test.log 2>&1; then
	say "gate 5  golden corpus" "ok"
else
	say "gate 5  golden corpus" "FAIL"
	grep -E 'not ok|Error|actual|expected' /tmp/golden-test.log | head -10
	fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
	printf '\nall gates green — the transcription matches the reference and the compiler is honest\n'
else
	printf '\n%d gate(s) red — fix the transcription before writing more of the port\n' "$fails"
fi
exit $fails
