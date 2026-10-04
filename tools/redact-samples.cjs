#!/usr/bin/env node
// ---------------------------------------------------------------------------
// Take the operator's bill out of a folder of transcripts.
//
// OpenRouter puts `cost`, `cost_details` and `is_byok` beside the token counts of every
// reply, and the game copies that block into EVERY turn of the transcript (js/openai-ai.js's
// rawUsage strips it on the way in — PRICING_FIELDS is the list it uses). Samples recorded
// before that strip, or recorded by another build of the recorder, still carry it. Those
// files are published: samples/ is what the README offers as "safe to hand on", and 200+
// priced turns in it says what the operator's key cost, turn by turn.
//
// This is the tool for the case the strip cannot cover — a file that already exists. Run it
// after every upstream sync that brings new samples:
//
//     node tools/redact-samples.cjs           # rewrite samples/ and fix index.json sizes
//     node tools/redact-samples.cjs --check   # report only, write nothing (CI-clean)
//
// tests/usage-redaction.test.cjs holds the property this tool restores, so a run that misses
// a file fails the suite instead of being forgotten.
//
// Only the `"usageRaw":{...}` region of a line is touched, and it is rewritten by splicing
// the re-serialised region back into the original string: 3,400-record files keep their
// bytes everywhere else, so a re-run of a clean file is a diff of zero lines.
// ---------------------------------------------------------------------------
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SAMPLES = path.join(ROOT, 'samples');
const CHECK = process.argv.includes('--check');

// Read the canonical list out of the recorder rather than duplicating it, so a field added
// there is stripped here on the same day it is added. If the line ever changes shape, this
// fails loudly instead of quietly redacting less than the game does.
const recorder = fs.readFileSync(path.join(ROOT, 'js', 'openai-ai.js'), 'utf8');
const m = recorder.match(/static PRICING_FIELDS\s*=\s*\[([^\]]+)\]/);
if (!m) throw new Error('js/openai-ai.js no longer declares PRICING_FIELDS in the shape this tool reads');
const PRICING = m[1].split(',').map(s => s.trim().replace(/^'|'$/g, '')).filter(Boolean);
const KEY = new RegExp('^(' + PRICING.join('|') + ')$', 'i');

// The same brace walk the test uses: a record is one line, usageRaw is one object in it.
function region(line) {
    const at = line.indexOf('"usageRaw":{');
    if (at < 0) return null;
    let depth = 0;
    for (let i = at + 11; i < line.length; i++) {
        if (line[i] === '{') depth++;
        else if (line[i] === '}' && --depth === 0) return { start: at + 11, end: i + 1 };
    }
    return { start: at + 11, end: line.length };   // unterminated: the test would have flagged it first
}

let filesTouched = 0, turnsRedacted = 0, unparseable = [];
for (const name of fs.readdirSync(SAMPLES).filter(n => n.endsWith('.jsonl')).sort()) {
    const file = path.join(SAMPLES, name);
    const text = fs.readFileSync(file, 'utf8');
    const lines = text.split('\n');
    let changedInFile = 0;
    for (let li = 0; li < lines.length; li++) {
        const r = region(lines[li]);
        if (!r) continue;
        const body = lines[li].slice(r.start, r.end);
        let usage;
        try { usage = JSON.parse(body); }
        catch (e) { unparseable.push(`${name}:${li + 1}`); continue; }
        if (!usage || typeof usage !== 'object') continue;
        const kept = {};
        let dropped = 0;
        for (const key of Object.keys(usage)) {
            if (KEY.test(key)) { dropped++; continue; }
            kept[key] = usage[key];
        }
        if (!dropped) continue;
        lines[li] = lines[li].slice(0, r.start) + JSON.stringify(kept) + lines[li].slice(r.end);
        changedInFile += dropped;
    }
    if (!changedInFile) continue;
    filesTouched++; turnsRedacted += changedInFile;
    console.log(`${CHECK ? 'would strip' : 'stripped'} ${String(changedInFile).padStart(5)} pricing fields from ${name}`);
    if (!CHECK) fs.writeFileSync(file, lines.join('\n'));
}

// samples/index.json records each file's size; the analyser reads it as the catalogue, so a
// redaction that leaves `bytes` stale is a catalogue that lies about the file it points at.
const indexFile = path.join(SAMPLES, 'index.json');
if (fs.existsSync(indexFile) && !CHECK) {
    const index = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
    let fixed = 0;
    for (const match of index.matches || []) {
        const p = path.join(SAMPLES, match.file);
        if (match.bytes == null || !fs.existsSync(p)) continue;
        const size = fs.statSync(p).size;
        if (size !== match.bytes) { match.bytes = size; fixed++; }
    }
    if (fixed) fs.writeFileSync(indexFile, JSON.stringify(index, null, 1) + '\n');
    if (fixed) console.log(`samples/index.json: ${fixed} byte counts refreshed`);
}

if (unparseable.length)
    console.log(`\n${unparseable.length} usageRaw blocks could not be parsed and were left alone:` +
        unparseable.slice(0, 5).map(s => '\n  ' + s).join(''));
console.log(`${filesTouched} file(s), ${turnsRedacted} pricing field(s)${CHECK ? ' [check only]' : ''}.`);
process.exit(CHECK && turnsRedacted ? 1 : 0);
