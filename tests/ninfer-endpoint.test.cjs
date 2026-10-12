// The Ninfer case (found 2026-10-11): the server answers /v1/models fine, yet the
// arena "denies its existence". Two nuances:
//   1. a FULL models URL pasted as the endpoint (…/v1/models) makes the test ask
//      for /v1/models/models -> 404, and localV1Fallback refuses (the path is
//      non-empty), so a healthy endpoint reads as nonexistent;
//   2. the fix mirrors what the bare-host fallback already does: strip the
//      /models (or /chat/completions) suffix a user pasted, remember the base,
//      and return the verified base so the seat plays the right address.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
function setup() {
    const scope = vm.createContext({ URL, console, document: { getElementById: () => null }, t: k => k });
    vm.runInContext(fs.readFileSync(path.join(root, 'js/openai-ai.js'), 'utf8') + '\nthis.Manager=OpenAIAIManager;', scope);
    const manager = scope.Manager;
    manager.buildAuthHeaders = async () => ({ Authorization: 'Bearer test-only' });
    return { manager, scope };
}
const response = (status, data = { data: [{ id: 'qwen3.8-27b', owned_by: 'ninfer' }] }) =>
    ({ ok: status === 200, status, statusText: status === 200 ? 'OK' : 'Not Found', json: async () => data });

test('a pasted full /v1/models URL is stripped to the base and the endpoint is found', async () => {
    const { manager: m } = setup();
    const urls = [];
    m.fetchWithTimeout = async (url) => { urls.push(url); return response(urls.length === 1 ? 404 : 200); };
    const r = await m.testConnection('http://172.30.30.16:8010/v1/models', {}, 'openai');
    // the first ask goes to the stripped base; the second is the /v1 fallback
    assert.deepEqual(urls, ['http://172.30.30.16:8010/models', 'http://172.30.30.16:8010/v1/models']);
    assert.equal(r.ok, true);
    assert.equal(r.endpoint, 'http://172.30.30.16:8010/v1');
    assert.deepEqual(r.models, ['qwen3.8-27b']);
});

test('a pasted bare-host URL still falls back to /v1 (the Ninfer shape, no CORS in scope)', async () => {
    const { manager: m } = setup();
    const urls = [];
    m.fetchWithTimeout = async (url) => { urls.push(url); return response(urls.length === 1 ? 404 : 200); };
    const r = await m.testConnection('http://172.30.30.16:8010', {}, 'openai');
    assert.deepEqual(urls, ['http://172.30.30.16:8010/models', 'http://172.30.30.16:8010/v1/models']);
    assert.equal(r.ok, true);
    assert.equal(r.endpoint, 'http://172.30.30.16:8010/v1');
});

test('a pasted /v1 base is asked directly and answers', async () => {
    const { manager: m } = setup();
    const urls = [];
    m.fetchWithTimeout = async (url) => { urls.push(url); return response(200); };
    const r = await m.testConnection('http://172.30.30.16:8010/v1', {}, 'openai');
    assert.deepEqual(urls, ['http://172.30.30.16:8010/v1/models']);
    assert.equal(r.ok, true);
    assert.equal(r.servedBy, 'ninfer');
});
