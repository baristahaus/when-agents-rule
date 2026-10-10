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
rm -f spike/bin/prng-spike spike/bin/counts spike/bin/coast spike/bin/map spike/bin/probe.o

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

# Gate 2b — the map's node counts, from js/terrain.js's difficulty table and scatter rules. Cheap,
# and not a warm-up: the counts match the base only if no node was dropped, so this catches a
# wrong table or a dropped node long before a thousand-line byte-diff can be localized. The base
# counts are PRE-clearance: the fixtures carry the base minus what the Town Centers clear (golden
# loses one wood node of 784; the map port's clearance step is what gate 2e verifies).
if "$ODIN" build spike/counts -out:spike/bin/counts >/tmp/odin-counts.log 2>&1 \
  && ./spike/bin/counts | grep -q 'COUNTS GREEN'; then
	say "gate 2b node counts 98/784/40/20 (the base, pre-clearance)" "ok"
else
	say "gate 2b node counts 98/784/40/20" "FAIL"
	tail -6 /tmp/odin-counts.log
	fails=$((fails + 1))
fi

# Gate 2d — the coastline. terrain.js bisects a noise field owned by the texture generator to find
# where land ends, and node placement is clipped to it, so this is the machinery that could have
# dropped nodes between the counts gate and the byte-diff. Asserted as f32 bit patterns, because the
# reference's lattice and table are Float32Array and a six-digit decimal compare is exactly the slop
# that lets a wrong-coastline port look fine until positions drift.
if "$ODIN" build spike/coast -out:spike/bin/coast >/tmp/odin-coast.log 2>&1 \
  && [ -x spike/bin/coast ] && ./spike/bin/coast | grep -q 'COAST GREEN'; then
	say "gate 2d coast table, f32 bits match" "ok"
else
	say "gate 2d coast table" "FAIL"
	tail -8 /tmp/odin-coast.log
	fails=$((fails + 1))
fi

# Gate 2e — the map line, the whole record, byte for byte: the seeded layout as the match starts,
# post Town Center clearance (golden/medium: 941 nodes — the scatter's 942 minus one wood node the
# clearance removed). The four scatters consume one stream in call order, so this single comparison
# also proves the RNG's draw sequence, the difficulty table, the recorder's round-to-millimetres
# and the clearance step itself. Nothing about the map is "approximately right" here; cmp either
# says nothing or the gate is red.
if "$ODIN" build spike/map -out:spike/bin/map >/tmp/odin-map.log 2>&1 && [ -x spike/bin/map ]; then
	map_fails=0
	for cond in "golden medium 4:map-line-b1040" "alpha easy 2:map-alpha-easy-2" \
	            "alpha hard 3:map-alpha-hard-3" "beta medium 4:map-beta-medium-4"; do
		args=${cond%%:*}; file=${cond##*:}
		if ./spike/bin/map $args > /tmp/map-odin.json && cmp -s /tmp/map-odin.json golden/$file.json; then
			printf '       map %-18s %6s bytes, byte-identical\n' "$args" "$(wc -c < /tmp/map-odin.json)"
		else
			printf '       map %-18s FAIL\n' "$args"
			cmp /tmp/map-odin.json golden/$file.json 2>&1 | head -1
			map_fails=$((map_fails + 1))
		fi
	done
	if [ "$map_fails" -eq 0 ]; then
		say "gate 2e map lines, 4 conditions byte-identical" "ok"
	else
		say "gate 2e map lines" "FAIL — $map_fails condition(s)"
		fails=$((fails + 1))
	fi
else
	say "gate 2e map lines" "FAIL — build failed"
	tail -6 /tmp/odin-map.log
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

# Gate 5 — the corpus itself: pinned hashes, the map line (941 nodes post-clearance), the four turn-1
# states, and
# the reference still producing the vectors gate 2 compares against. Language-independent on
# purpose, so it keeps guarding the contract even with no core at all.
if node --test tests/golden-fixtures.test.cjs >/tmp/golden-test.log 2>&1; then
	say "gate 5  golden corpus" "ok"
else
	say "gate 5  golden corpus" "FAIL"
	grep -E 'not ok|Error|actual|expected' /tmp/golden-test.log | head -10
	fails=$((fails + 1))
fi

# Gate 6 — the turn-1 state view, the whole record, byte for byte: 8 lines (4 seats x
# the two moments t=0 and t=1000), 45,840 bytes. The single-file port is spike/turn1/main.odin;
# its driver takes one argument, the output path, and writes the fixture the golden holds.
if "$ODIN" build spike/turn1/main.odin -file -out:/tmp/gate-turn1 >/dev/null 2>&1; then
	if /tmp/gate-turn1 /tmp/gate-turn1-out.jsonl >/dev/null 2>&1 \
	   && cmp -s /tmp/gate-turn1-out.jsonl golden/states-b1040-t0-t1.canonical.jsonl; then
		say "gate 6  turn-1 state view (8 lines)" "ok — byte-identical"
	else
		say "gate 6  turn-1 state view (8 lines)" "FAIL"
		cmp /tmp/gate-turn1-out.jsonl golden/states-b1040-t0-t1.canonical.jsonl 2>&1 | head -2
		note "The HANDOVER §4 loop: diff the first divergent line, find the section," \
"read that section's port function in tools/trace-states-port.cjs (the line map" \
"is spike/turn1/HANDOVER.md §2), fix the Odin to match. The port is the spec."
		fails=$((fails + 1))
	fi
else
	say "gate 6  turn-1 state view (8 lines)" "FAIL — the build"
	"$ODIN" build spike/turn1/main.odin -file -out:/tmp/gate-turn1 2>&1 | head -8
	fails=$((fails + 1))
fi

# Gate 7 — the leak tracker, named and proven (CORE-REPLAN §13's second owed item).
# mem.Tracking_Allocator over core:mem/tracking_allocator.odin: a balanced context, a leak
# that is seen and named, and the one-arena-per-match shape balancing after a match ends.
# Infrastructure, not game bytes — it is the check the daemon's arena shape will rest on.
if "$ODIN" build spike/mem -out:spike/bin/mem-track >/tmp/odin-mem.log 2>&1 \
   && ./spike/bin/mem-track | grep -q 'MEM TRACK GREEN'; then
	say "gate 7  leak tracker (mem.Tracking_Allocator)" "ok — named and proven"
else
	say "gate 7  leak tracker (mem.Tracking_Allocator)" "FAIL"
	tail -8 /tmp/odin-mem.log
	fails=$((fails + 1))
fi

# Gate 8 — P1's determinism, the first folder gate (docs/REBUILD_PROPOSAL.md,
# "the match folder"): two one-minute folder runs of one seed. The transcripts
# must be byte-identical to each other AND to the pinned golden stream (the
# folder's transcript IS the v1 contract); the events files must diff to empty.
if "$ODIN" build spike/match -out:spike/bin/match >/tmp/odin-match.log 2>&1; then
	rm -rf /tmp/gate-p1-a /tmp/gate-p1-b
	if ./spike/bin/match /tmp/gate-p1-a 600 golden 4 medium folder >/dev/null 2>&1 \
	   && ./spike/bin/match /tmp/gate-p1-b 600 golden 4 medium folder >/dev/null 2>&1 \
	   && cmp -s /tmp/gate-p1-a/transcript.jsonl /tmp/gate-p1-b/transcript.jsonl \
	   && cmp -s /tmp/gate-p1-a/events.jsonl /tmp/gate-p1-b/events.jsonl \
	   && cmp -s /tmp/gate-p1-a/traces/seat-0.jsonl /tmp/gate-p1-b/traces/seat-0.jsonl \
	   && cmp -s /tmp/gate-p1-a/traces/seat-3.jsonl /tmp/gate-p1-b/traces/seat-3.jsonl \
	   && cmp -s /tmp/gate-p1-a/transcript.jsonl golden/stream-1m.jsonl \
	   && node -e 'let ok=0,bad=0;require("readline").createInterface({input:require("fs").createReadStream("/tmp/gate-p1-a/events.jsonl")}).on("line",l=>{try{JSON.parse(l);ok++}catch(e){bad++}}).on("close",()=>process.exit(bad?1:0))' \
	   && ! grep -riEq "api[_-]?key|endpoint|usageRaw" /tmp/gate-p1-a; then
		say "gate 8  the match folder: two runs, empty diff" "ok — transcript = the golden stream, events deterministic ($(wc -l < /tmp/gate-p1-a/events.jsonl) lines), traces clean, export redacted"
	else
		say "gate 8  the match folder: two runs, empty diff" "FAIL"
		diff <(head -5 /tmp/gate-p1-a/events.jsonl) <(head -5 /tmp/gate-p1-b/events.jsonl) | head -6
		fails=$((fails + 1))
	fi
else
	say "gate 8  the match folder: two runs, empty diff" "FAIL — the build"
	grep Error /tmp/odin-match.log | head -5
	fails=$((fails + 1))
fi

# Gate 9 - the serve mode: a hosted match with attached seats. The core listens,
# four seats attach (the checked-in client), each receives its state record per
# turn and answers; seat 0 trains a worker at turn 3. The gate holds when every
# round-trip completes and the match folder at the end shows the client's order
# in its events and traces - the seat slot an LLM will sit in.
if "$ODIN" build spike/match -out:spike/bin/match >/tmp/odin-match.log 2>&1; then
	rm -rf /tmp/gate-serve
	(timeout 120 ./spike/bin/match /tmp/gate-serve 30 golden 4 medium serve 7891 >/dev/null 2>/tmp/gate-serve.log &)
	sleep 1
	if node tools/serve-client.cjs 4 8 train 7891 >/tmp/gate-serve-client.log 2>&1 \
	   && node -e 'let ok=0,bad=0;require("readline").createInterface({input:require("fs").createReadStream("/tmp/gate-serve/transcript.jsonl")}).on("line",l=>{if(!l.trim())return;try{JSON.parse(l);ok++}catch(e){bad++;console.log("bad:",l.slice(0,60))}}).on("close",()=>process.exit(bad?1:0))' \
	   && grep -q '"order":"train"' /tmp/gate-serve/events.jsonl \
	   && grep -q '"order":"train"' /tmp/gate-serve/traces/seat-0.jsonl; then
		say "gate 9  serve: seats attach, commands execute" "ok - 4 seats round-trip a hosted match; the client's train order lands in events and traces"
	else
		say "gate 9  serve: seats attach, commands execute" "FAIL"
		head -4 /tmp/gate-serve-client.log /tmp/gate-serve.log 2>/dev/null
		fails=$((fails + 1))
	fi
else
	say "gate 9  serve: seats attach, commands execute" "FAIL - the build"
	grep Error /tmp/odin-match.log | head -5
	fails=$((fails + 1))
fi

# Gate 10 - the LLM seat slot: four seats played by tools/llm-seat.cjs in its
# scripted mode (the model the gate can afford: deterministic on the state, so
# two served matches of fake seats diff to empty). The gate holds when the
# model seats' orders land in the events AND the traces carry the model tier
# (the model's name and its reply record), both runs identical.
if "$ODIN" build spike/match -out:spike/bin/match >/tmp/odin-match.log 2>&1; then
	rm -rf /tmp/gate-llm-a /tmp/gate-llm-b
	for run in a b; do
		(timeout 150 ./spike/bin/match /tmp/gate-llm-$run 60 golden 4 medium serve 7896 >/dev/null 2>/dev/null &)
		sleep 1
		for i in 0 1 2 3; do (node tools/llm-seat.cjs $i 7896 >/dev/null 2>&1 &); done
		sleep 9
	done
	if cmp -s /tmp/gate-llm-a/transcript.jsonl /tmp/gate-llm-b/transcript.jsonl \
	   && cmp -s /tmp/gate-llm-a/events.jsonl /tmp/gate-llm-b/events.jsonl \
	   && cmp -s /tmp/gate-llm-a/traces/seat-0.jsonl /tmp/gate-llm-b/traces/seat-0.jsonl \
	   && grep -q '"order":"train"' /tmp/gate-llm-a/events.jsonl \
	   && node -e 'const fs=require("fs");const lines=fs.readFileSync("/tmp/gate-llm-a/traces/seat-0.jsonl","utf8").split("\n").filter(l=>l.trim());const withModel=lines.filter(l=>{try{const j=JSON.parse(l);return j.model==="fake-policy"&&j.reply}catch(e){return false}}).length;process.exit(withModel>3?0:1)'; then
		say "gate 10  LLM seats: four model seats, deterministic" "ok - the seats play, their orders land in events, traces carry the model and reply tier, two runs diff empty"
	else
		say "gate 10  LLM seats: four model seats, deterministic" "FAIL"
		fails=$((fails + 1))
	fi
else
	say "gate 10  LLM seats: four model seats, deterministic" "FAIL - the build"
	fails=$((fails + 1))
fi

# Gate 11 - P2's first face: the replay viewer. spike/face replays the pinned
# one-minute corpus through a Vulkan renderer offscreen (no window, no SDL) and
# prints a per-frame FNV-1a digest of the rendered pixels. The gate holds when
# the shaders compile, the frames render, and two runs produce identical
# digests - the pixels ARE deterministic, which is the property every later
# increment (the SDL window, the live camera, the model-facing HUD) inherits.
if "$ODIN" build spike/face -file -out:spike/bin/face >/tmp/odin-face.log 2>&1; then
	if glslc spike/face/shader.vert -o spike/face/shader.vert.spv 2>>/tmp/odin-face.log \
	   && glslc spike/face/shader.frag -o spike/face/shader.frag.spv 2>>/tmp/odin-face.log \
	   && timeout 240 ./spike/bin/face golden/stream-1m.jsonl >/tmp/gate-face-a.txt 2>&1 \
	   && timeout 240 ./spike/bin/face golden/stream-1m.jsonl >/tmp/gate-face-b.txt 2>&1 \
	   && cmp -s /tmp/gate-face-a.txt /tmp/gate-face-b.txt \
	   && timeout 280 ./spike/bin/face golden/stream-10m.jsonl --turn 1181 --zoom 3 --cx 24 --cz -321 >>/tmp/gate-face-a.txt 2>&1 \
	   && grep -o 'fnv1a [0-9]*' /tmp/gate-face-a.txt > /tmp/gate-face-pins.txt \
	   && grep -o 'fnv1a [0-9]*' golden/face-digests.txt > /tmp/gate-face-want.txt \
	   && cmp -s /tmp/gate-face-pins.txt /tmp/gate-face-want.txt; then
		say "gate 11  the replay viewer: 13 frames, pixels pinned" "ok - Vulkan renders the recorded match; the digests match golden/face-digests.txt"
	else
		say "gate 11  the replay viewer: 13 frames, pixels pinned" "FAIL"
		grep -E "Error|face:" /tmp/odin-face.log /tmp/gate-face-a.txt 2>/dev/null | head -6
		fails=$((fails + 1))
	fi
else
	say "gate 11  the replay viewer: 13 frames, pixels pinned" "FAIL - the build"
	grep Error /tmp/odin-face.log | head -5
	fails=$((fails + 1))
fi

# Gate 12 - the hosted folder: the core serves a match folder over HTTP
# (REBUILD_PROPOSAL P4's seed - the analyzer reads a folder over exactly this).
# The gate holds when meta.json and the transcript answer 200 with the right
# bytes and the traversal and missing-file requests refuse.
if "$ODIN" build spike/match -out:spike/bin/match >/tmp/odin-match.log 2>&1; then
	(timeout 30 ./spike/bin/match /tmp/gate-p1-a 600 golden 4 medium host 7901 >/dev/null 2>&1 &)
	sleep 1
	if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7901/meta.json)" = "200" ] \
	   && cmp -s <(curl -s http://127.0.0.1:7901/transcript.jsonl) /tmp/gate-p1-a/transcript.jsonl \
	   && [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7901/../etc/passwd)" = "404" ] \
	   && [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7901/nope.json)" = "404" ]; then
		say "gate 12  the hosted folder: HTTP answers the match" "ok - meta and transcript served byte-identical, traversal and 404s refuse"
	else
		say "gate 12  the hosted folder: HTTP answers the match" "FAIL"
		fails=$((fails + 1))
	fi
else
	say "gate 12  the hosted folder: HTTP answers the match" "FAIL - the build"
	fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
	printf '\nall gates green — the transcription matches the reference and the compiler is honest\n'
else
	printf '\n%d gate(s) red — fix the transcription before writing more of the port\n' "$fails"
fi
exit $fails
