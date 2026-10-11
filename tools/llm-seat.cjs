#!/usr/bin/env node
'use strict';
// ---------------------------------------------------------------------------
// An LLM seat, the client side of the serve protocol (tools/serve-client.cjs
// is the dumb plumbing; this one plays).
//
// One process per seat. It attaches to the core's serve port, reads its state
// record each turn, asks its model what to do, and answers with the actions
// line the executor codes. The full request/reply/usage goes back to the core
// in the actions line, so the folder's traces/seat-N.jsonl carries the model
// tier without a second writer.
//
//   node tools/llm-seat.cjs <seatIndex> [port]
//
// The model comes from the environment:
//   WAR_ENDPOINT  an OpenAI-compatible chat-completions URL (default: none)
//   WAR_API_KEY   the bearer token (never written anywhere; see §5.3)
//   WAR_MODEL     the model name (default "fake-policy")
// With no endpoint (or on any fetch error) the seat plays the scripted
// policy: the same opening a weak model plays — workers while there is room,
// a house near the cap. It is deterministic, so a served match of fake seats
// is byte-for-byte reproducible, which is what gate 10 pins.
// ---------------------------------------------------------------------------
const net = require('net');
const fs = require('fs');

const seat = Number(process.argv[2] || 0);
const port = Number(process.argv[3] || 7777);
const endpoint = process.env.WAR_ENDPOINT || '';
const apiKey = process.env.WAR_API_KEY || '';
const model = process.env.WAR_MODEL || 'fake-policy';

const tools = [
  { type: 'function', function: { name: 'train_unit', description: 'Train a unit at the building that makes it.', parameters: { type: 'object', properties: { unitType: { type: 'string' } }, required: ['unitType'] } } },
  { type: 'function', function: { name: 'build_structure', description: 'Place a building site near your Town Center.', parameters: { type: 'object', properties: { buildingType: { type: 'string' } }, required: ['buildingType'] } } },
  { type: 'function', function: { name: 'research_tech', description: 'Research a tech from research.available.', parameters: { type: 'object', properties: { techId: { type: 'string' } }, required: ['techId'] } } },
  { type: 'function', function: { name: 'explore', description: 'Send a spare unit to scout the least-explored tile.', parameters: { type: 'object', properties: {} } } },
];

// The scripted opening: workers while there is room, a house near the cap,
// research the first available tech after the third turn. Deterministic on
// the state alone, so two served matches of fake seats diff to empty.
function fakePolicy(state, turn) {
  const actions = [];
  const pop = state.population || {};
  if (pop.used !== undefined && pop.capacityNow !== undefined && pop.capacityNow - pop.used >= 2) {
    actions.push({ action: 'train_unit', params: { unitType: 'worker' } });
  }
  if (pop.capacityNow - pop.used <= 1 && state.resources && state.resources.wood >= 30) {
    actions.push({ action: 'build_structure', params: { buildingType: 'house' } });
  }
  if (turn >= 3 && state.research && state.research.available) {
    const first = state.research.available.find(t => t.blockedBy && t.blockedBy.length === 0);
    if (first) actions.push({ action: 'research_tech', params: { techId: first.id } });
  }
  return actions;
}

async function askModel(state) {
  const body = {
    model,
    messages: [
      { role: 'system', content: 'You command one seat of a real-time strategy match. Call the provided tools to act. Choose a few actions per turn.' },
      { role: 'user', content: JSON.stringify(state) },
    ],
    tools,
    tool_choice: 'required',
    max_tokens: 1500,
    chat_template_kwargs: { enable_thinking: false },
  };
  const started = Date.now();
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer ' + apiKey },
    body: JSON.stringify(body),
  });
  const j = await res.json();
  const latency = Date.now() - started;
  const msg = j.choices && j.choices[0] && j.choices[0].message;
  const actions = (msg && msg.tool_calls ? msg.tool_calls : []).map(tc => {
    let params = {};
    try { params = JSON.parse(tc.function.arguments || '{}'); } catch (e) {}
    return { action: tc.function.name, params };
  });
  const usage = j.usage ? { prompt_tokens: j.usage.prompt_tokens, completion_tokens: j.usage.completion_tokens } : null;
  if (!actions.length) console.error(`seat ${seat} raw: ${JSON.stringify(msg).slice(0,180)} finish: ${j.choices[0].finish_reason}`);
  return { actions, usage, text: (msg && msg.content) || '', latency };
}

let buf = '';
const sock = net.connect(port, '127.0.0.1', () => {
  sock.write(JSON.stringify({ model }) + '\n');
  console.log(`seat ${seat}: attached as ${model}`);
});
sock.on('data', d => {
  buf += d.toString();
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    if (!line) continue;
    let rec; try { rec = JSON.parse(line); } catch (e) { continue; }
    if (rec.type === 'results') { console.log(`seat ${seat}: match over`); process.exit(0); }
    if (rec.turn === undefined) continue;
    const respond = answer => sock.write(JSON.stringify(answer) + '\n');
    if (endpoint) {
      askModel(rec).then(r => respond({
        actions: r.actions,
        usage: r.usage ? { prompt_tokens: r.usage.prompt_tokens, completion_tokens: r.usage.completion_tokens, latencyMs: r.latency } : null,
        replyText: r.text || '',
      })).catch(e => { console.log(`seat ${seat}: model error ${e.message}; passing`); respond({ actions: [] }); });
    } else {
      respond({ actions: fakePolicy(rec.state, rec.turn), usage: null, replyText: '' });
    }
  }
});
sock.on('error', e => { console.log(`seat ${seat}: ${e.message}`); process.exit(1); });
setTimeout(() => { console.log(`seat ${seat}: timeout`); process.exit(1); }, 2400000);
