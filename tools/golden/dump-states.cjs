#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// Per-seat state fixtures, from the reference.
//
// The map line proves a port can reproduce the seeded world. The next gate is the world
// *after the game has started*, which is what `golden/turn1-b1040.jsonl` was: the per-seat
// observation the model harness is handed. Until this script existed there was no way to
// make more of those — the only fixture was a capture of unknown provenance, and a fixture
// you cannot regenerate is a rumour, not a gate.
//
// So this drives the reference the way the bench and the replay tool do — `tools/bench/realm.cjs`
// starts a real match in a vm and advances it in whole 50 ms steps — and writes the state view at
// the steps that matter: before any simulation (t=0, pure setup) and after one second of it
// (t=1, the first tick: economy, the three workers, the clock reading 1 and not 0).
//
//   node tools/golden/dump-states.cjs -seed golden -difficulty medium -civs ... -at 0,1000 -out f.jsonl
//
// Output is one JSON line per seat per step: {seat, playerId, step, state}. Seat ids are v1's
// session-random ones, so pipe it through `tools/golden/canonicalize-states.cjs` before pinning a
// hash. Nothing here decides what the state *is*: `observe()` on the openai manager owns that, and
// this file exists so a port can be diffed against it instead of argued about.
// ---------------------------------------------------------------------------
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ROOT = path.join(__dirname, '..', '..');
const { createMatch } = require(path.join(__dirname, '..', 'bench', 'realm.cjs'));

function arg(name, dflt = null) {
  const i = process.argv.indexOf('-' + name);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

const seed = arg('seed', 'golden');
const difficulty = arg('difficulty', 'medium');
const civs = String(arg('civs', 'egyptian,greek,maurspec,shongfu')).split(',');
const out = arg('out');
// Time is in milliseconds of simulation, because that is what the game counts and what a
// fixture has to name to be reproducible: "turn 1" is not a moment, "t=1000 ms" is.
const times = String(arg('at', arg('steps', '0,1000'))).split(',').map(s => Number(s.trim())).filter(n => Number.isFinite(n));

(async () => {
  const realm = await createMatch({
    kind: 'arena',
    seats: civs.map(c => ({ civ: c, type: 'ki' })),
    seed, difficulty,
  });
  // Pin the UI language, and then PROVE it stuck. The game's source strings are German (the
  // data files are the original), so a dumper that inherits the host locale writes a fixture
  // that differs in every human-readable field — my first run produced civilizationName
  // "Ägypter" where the capture says "Egyptians", and it looked like a stale fixture. The state
  // view carries translated strings, so language is part of the fixture's definition, not a
  // display detail.
  // The bench harness loads only the rule files named by js/manifest.js, and i18n is deliberately
  // not one of them — it is not a rule. So in a bare realm every human-readable field of the state
  // view is in the game's source language, which is German: my first dump said civilizationName
  // "Ägypter" where the capture says "Egyptians", and I nearly wrote it up as a stale fixture.
  // The page and the recorder both load i18n and set the language, so a dumper that means to
  // reproduce a fixture has to do the same. Loading it is not enough on its own, and loading it
  // silently is worse: hence the assertion below, which reads a translated field.
  vm.runInContext(fs.readFileSync(path.join(ROOT, 'js/i18n.js'), 'utf8'), realm.context, { filename: 'js/i18n.js' });
  const setLang = realm.context.setUiLang || (realm.context.window && realm.context.window.setUiLang);
  if (typeof setLang !== 'function') throw new Error('no setUiLang after loading i18n — refusing to dump a locale-dependent fixture');
  setLang('en');

  const game = realm.game;
  const mgr = game.openAIAIManager;
  if (!mgr || typeof mgr.buildGameStateJSON !== 'function') {
    throw new Error('no buildGameStateJSON on game.openAIAIManager — the harness changed, fix this tool, not the fixture');
  }

  // One controller per seat, the scripted kind the re-simulator uses: the rule brain still
  // plays, this only gives the harness somewhere to stand to describe the seat's view.
  const controllers = realm.seats.map(ai => realm.scripted(ai));

  const CIV_EN = { egyptian: 'Egyptians', greek: 'Greeks', persian: 'Persians', yamato: 'Yamato' };
  const lines = [];
  const observe = (atMs) => {
    realm.seats.forEach((ai, i) => {
      const built = mgr.buildGameStateJSON(controllers[i]);
      const state = typeof built === 'string' ? JSON.parse(built) : built;
      if (!state.player || state.player.civilizationName !== CIV_EN[ai.civilization]) {
        throw new Error(`seat ${i}: civilizationName is ${JSON.stringify(state.player && state.player.civilizationName)} — the language pin did not hold`);
      }
      lines.push(JSON.stringify({ seat: i, playerId: ai.id, t: atMs, state }));
    });
  };

  // stepMs is 1000 in the golden's header, so "step 1" means advancing exactly one second of
  // simulation. advance() takes whole 50 ms units and the realm drives the game's own clock.
  let now = 0;
  for (const t of times.sort((a, b) => a - b)) {
    if (t < now) throw new Error(`-at times must ascend (got ${t} after ${now})`);
    if (t > now) { realm.advance(t - now); now = t; }
    observe(t);
  }

  const text = lines.join('\n') + '\n';
  if (out) { fs.writeFileSync(out, text); console.error(`${lines.length} state lines -> ${out}`); }
  else process.stdout.write(text);
})().catch(e => { console.error('dump-states failed: ' + e.stack); process.exit(1); });
