// What a transcript is allowed to know about the operator.
//
// usageRaw is copied into EVERY turn of the match transcript, and the transcript is the
// artefact this project hands to other people (samples/ ships seven; README calls them safe
// to share). An OpenAI-compatible `usage` block — OpenRouter in particular — carries `cost`,
// `cost_details` and `is_byok` alongside the token counts, so the shipped samples published
// 2,836 turns priced to the fifth of a cent, and whether the operator was bringing their own
// key. The token accounting is what a reader of a transcript needs; the bill is derived from
// those same counts and says nothing about the reply.
//
// Two kinds of assertion: the filter itself, and the artefact — because a filter that only
// applies to future matches leaves the published ones leaking.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const scope = {
  console: { log() {}, warn() {}, error() {} },
  Math, JSON, Date, Object, Array, String, Number, Boolean, Set, Map, RegExp, Error, Promise,
  isNaN, parseInt, parseFloat, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
  performance: { now: () => Date.now() },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, document: undefined,
};
vm.createContext(scope);
for (const f of ['js/civilizations.js', 'js/units.js', 'js/buildings.js', 'js/resources.js', 'js/i18n.js'])
  vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), scope, { filename: f });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'openai-ai.js'), 'utf8'), scope, { filename: 'js/openai-ai.js' });
const M = vm.runInContext('OpenAIAIManager', scope);

test('the token accounting survives and the bill does not', () => {
  const data = { usage: {
    prompt_tokens: 6414, completion_tokens: 510, total_tokens: 6924,
    prompt_tokens_details: { cached_tokens: 0, audio_tokens: 0 },
    cost: 0.04482, is_byok: false, cost_details: { upstream_inference_cost: 0.04482 },
  } };
  const keys = Object.keys(M.rawUsage('openai', data));
  assert.deepEqual(keys.sort(), ['completion_tokens', 'prompt_tokens', 'prompt_tokens_details', 'total_tokens'],
    'reasoning/cached-token detail is the whole point of keeping usageRaw; pricing is not');
  // The parsed response belongs to the caller. A filter that mutated it in place would make
  // the number disappear from the live session too, which is not what anyone asked for.
  assert.equal(data.usage.cost, 0.04482, 'rawUsage must copy, not edit the provider payload');
});

test('providers that name their fields differently are handled the same way', () => {
  // Objects built inside the vm carry that realm's Object.prototype, and assert/strict
  // compares prototypes — so spread them into host objects before matching them.
  const plain = (o) => ({ ...o });
  assert.deepEqual(plain(M.rawUsage('google', { usageMetadata: {
    promptTokenCount: 1200, candidatesTokenCount: 60, totalTokenCount: 1260,
    trafficType: 'PROVISIONED_TRAFFIC', costDetails: { currencyCode: 'USD' },
  } })), { promptTokenCount: 1200, candidatesTokenCount: 60, totalTokenCount: 1260, trafficType: 'PROVISIONED_TRAFFIC' });

  assert.deepEqual(plain(M.rawUsage('ollama', { prompt_eval_count: 900, eval_count: 41, done_reason: 'stop', credits_used: 3 })),
    { prompt_eval_count: 900, eval_count: 41, done_reason: 'stop' },
    'the ollama branch picks its three fields, so nothing else can ride along');

  assert.equal(M.rawUsage('openai', { choices: [] }), null, 'a reply with no usage stays no usage');
});

test('no shipped transcript prices a turn', () => {
  // Textual, not parsed: 3,400 records cost real time to JSON.parse in a suite that is meant
  // to run on every push, and the property is a property of the serialised form anyway.
  const pricing = /"(cost|total_cost|cost_details|costDetails|totalCost|is_byok|native_statistics)"\s*:/;
  let priced = 0, withUsage = 0;
  for (const f of fs.readdirSync(path.join(ROOT, 'samples')).filter((n) => n.endsWith('.jsonl'))) {
    for (const line of fs.readFileSync(path.join(ROOT, 'samples', f), 'utf8').split('\n')) {
      const at = line.indexOf('"usageRaw":{');
      if (at < 0) continue;
      let depth = 0, end = at;
      // at+11 is the opening brace; starting past it would never close the region and the
      // assertion would pass on an empty slice.
      for (let i = at + 11; i < line.length; i++) {
        if (line[i] === '{') depth++;
        else if (line[i] === '}' && --depth === 0) { end = i + 1; break; }
      }
      withUsage++;
      if (pricing.test(line.slice(at, end))) priced++;
    }
  }
  assert.ok(withUsage > 1000, 'the assertion is worthless if usageRaw stopped being recorded: saw ' + withUsage);
  assert.equal(priced, 0, priced + ' turns in samples/ still carry the operator\'s pricing');
});
