#!/usr/bin/env node
// Where is the parent, really? Run this BEFORE prepping a PR, not after the conflict.
//
// It exists because we opened one against a parent we had not looked at in an hour: our
// branch was based on b1039 while `upstream/main` had shipped fifteen more builds, and the
// entry we wrote claimed "Build 1040" — a number the parent had already used three days
// earlier for a fight-card fix. Neither problem shows up in a green local suite. Both are
// one command to predict.
//
//   node tools/upstream-check.cjs --branch=share/upstream-contract --claim-build=1055 \
//        --files=game-state-schema.json,tests/lib/schema-check.cjs
//
// Exit 0 = the proposal is current. Exit 1 = fix the base or the build number first.
// Exit 2 = the fetch failed, so anything it says is stale; it declines to guess.
'use strict';
const { execFileSync, spawnSync } = require('node:child_process');

const arg = (name, dflt) => {
    const hit = process.argv.slice(2).find(a => a.startsWith(`--${name}=`));
    return hit ? hit.slice(name.length + 3) : dflt;
};
const flag = name => process.argv.slice(2).includes(`--${name}`);
const REMOTE = arg('remote', 'upstream');
const BRANCH = arg('branch', 'HEAD');
const FILES = (arg('files', '') || '').split(',').filter(Boolean);

const g = (args, optional) => {
    const r = spawnSync('git', args, { encoding: 'utf8' });
    if (r.status !== 0) {
        if (optional) return null;
        console.error(`git ${args.join(' ')}: ${r.stderr.trim()}`);
        process.exit(2);
    }
    return r.stdout.trim();
};

if (!flag('no-fetch')) {
    const fetched = spawnSync('git', ['fetch', '--quiet', REMOTE], { encoding: 'utf8' });
    if (fetched.status !== 0) {
        console.error(`upstream-check: cannot fetch ${REMOTE} (${fetched.stderr.trim().split('\n')[0] || 'see git'})`);
        console.error("Refusing to call a stale answer current: fetch by hand and re-run, or pass --no-fetch to see how stale.");
        process.exit(2);
    }
}

const TIP = `${REMOTE}/main`;
const tipBuild = (g(['show', `${TIP}:index.html`]).match(/js\/game\.js\?v=(\d+)/) || [, '?'])[1];
const tipSubject = g(['log', '--format=%h %s', '-1', TIP]);
const base = g(['merge-base', BRANCH, TIP]);
const baseBuild = (g(['show', `${base}:index.html`]).match(/js\/game\.js\?v=(\d+)/) || [, '?'])[1];
const behind = Number(g(['rev-list', '--count', `${base}..${TIP}`]));

// Which build numbers are already written down, so "Build 1040" cannot be promised twice.
const ledger = g(['show', `${TIP}:docs/RULES-CHANGES.md`]);
const used = [...ledger.matchAll(/^## Build (\d+)/gm)].map(m => Number(m[1]));
const nextFree = used.length ? Math.max(...used) + 1 : Number(tipBuild) + 1;

const problems = [];
console.log(`parent   ${TIP} = ${tipSubject}  (build ${tipBuild})`);
console.log(`our base ${base.slice(0, 7)} (build ${baseBuild}), ${behind} upstream commits behind the parent's tip`);

if (behind > 0) console.log(`         the parent shipped ${behind} commit(s) since we branched: ${g(['log', '--format=%h %s', `${base}..${TIP}`]).split('\n').slice(0, 3).join(' | ')}${behind > 3 ? ' …' : ''}`);

for (const f of FILES) {
    const touched = behind > 0 ? g(['log', '--format=%h %s', `${base}..${TIP}`, '--', f], true) : '';
    if (touched) {
        console.log(`MOVED    ${f} changed upstream since our base:`);
        touched.split('\n').forEach(l => console.log(`           ${l}`));
        problems.push(`${f} needs a rebase, not a patch`);
    }
}

const claim = Number(arg('claim-build', '0'));
if (claim) {
    if (used.includes(claim)) {
        const title = (ledger.match(new RegExp(`^## Build ${claim}: (.+)$`, 'm')) || [, '?'])[1];
        console.log(`TAKEN    build ${claim} is already used upstream: "${title}"`);
        problems.push(`build ${claim} is taken; use ${nextFree}`);
    } else if (claim <= Number(tipBuild)) {
        console.log(`LOW      build ${claim} is at or below the parent's current ${tipBuild}`);
        problems.push(`build ${claim} is not ahead of the parent; use ${nextFree}`);
    } else {
        console.log(`FREE     build ${claim} (parent is at ${tipBuild}, next free is ${nextFree})`);
    }
}

if (problems.length) {
    console.log('\nDo not open this PR yet:');
    problems.forEach(p => console.log(` - ${p}`));
    console.log(`\nRebase: git rebase --onto ${TIP} ${base} ${BRANCH}   (then fix the build stamp and the RULES-CHANGES heading)`);
    process.exit(1);
}
console.log(behind === 0 ? '\nCurrent: based on the parent tip, and the build number is free.'
    : `\nCurrent enough: nothing you touch moved, though the parent is ${behind} commit(s) ahead — consider rebasing anyway.`);
