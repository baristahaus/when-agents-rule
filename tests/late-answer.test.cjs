// Who gets to move this round, and what the harness knows about how stale that answer was.
//
// takeTurnAnswer is the whole turn-based decision, and until now it lived inline in startTurn's
// promise chain, which meant exercising it needed a network call, a round clock and four lanes.
// It is a method now (moved verbatim — the 81 lines were checked byte-for-byte against the
// original after dedenting), so the rules the author chose can be pinned:
//
//   - an answer for the current round is taken, staleness 0
//   - an answer asked in an earlier round is TAKEN — mid-pipeline is not obsolete, and a seat on a
//     36-second provider would otherwise be silenced every round — but the number of rounds it
//     crossed is written down, because that frequency is what any rejection rule would have to be
//     decided on and `askedInRound` had been stamped and ignored since it was introduced
//   - a lane cut for missing its deadline is not taken
//   - when the round has already moved on, the answer is dropped and counted as dropped
//   - between two answers in hand, the one built on the fresher board wins, and the loser is
//     counted as dropped rather than quietly overwritten
//
// Nothing here enforces staleness. Rejecting a late answer would change which moves land, i.e.
// who wins — a gameplay call, left where it belongs (docs/QUALITY_REVIEW.md, open item 7).
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
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'game.js'), 'utf8')
  .split('\nconst WAR_PRIVATE_HOST')[0], scope, { filename: 'js/game.js' });
vm.runInContext(fs.readFileSync(path.join(ROOT, 'js', 'openai-ai.js'), 'utf8'), scope, { filename: 'js/openai-ai.js' });

const OpenAIAIManager = vm.runInContext('OpenAIAIManager', scope);

const harness = (roundNo) => {
  const m = Object.create(OpenAIAIManager.prototype);
  m.turnBased = true;
  m._roundNo = roundNo;
  m._roundPhase = 'wait';
  m.dropped = [];
  m.noteLaneDropped = (lane, action, logTurn) => { m.dropped.push({ lane: lane && lane.laneNo, logTurn }); };
  return m;
};
const lane = (over) => Object.assign({ laneNo: 0, askedInRound: 40, askedAt: 1000, _moveNo: 7, _moveMs: 250, _logTurn: 12 }, over);
const seat = () => ({ answeredRound: null, queuedAction: null, answeringLane: null, answerContext: null, seat: {}, lanes: [] });

test('an answer from the round it was asked in is taken, and is not stale', () => {
  const m = harness(40), c = seat();
  m.takeTurnAnswer(c, lane({ askedInRound: 40 }), { category: 'act', actions: [] });
  assert.equal(c.queuedAction !== null, true, 'the move should be queued for the round flush');
  assert.equal(c.answeredRound, 40);
  assert.equal(c.answeringLane.laneNo, 0, 'the answer has to remember WHICH lane carried it');
  assert.equal(c.answerContext._lateByRounds, 0);
  assert.equal(c.seat.lateAnswers, undefined, 'a fresh answer must not inflate the stale tally');
  assert.deepEqual([...m.dropped], []);
});

test('an answer from an earlier round is taken, and how stale it was is written down', () => {
  const m = harness(43), c = seat();
  m.takeTurnAnswer(c, lane({ askedInRound: 40 }), { category: 'act' });
  assert.equal(c.answeredRound, 43, 'the seat is credited with THIS round, whose move it is');
  assert.equal(c.answerContext._lateByRounds, 3, 'three rounds between being shown a board and moving on it');
  assert.equal(c.seat.lateAnswers, 1);
  assert.equal(c.seat.lateAnswerMax, 3);
  // and the tally accumulates rather than being overwritten by the next one
  const c2 = Object.assign(seat(), { seat: { lateAnswers: 4, lateAnswerMax: 9 } });
  m.takeTurnAnswer(c2, lane({ askedInRound: 42 }), { category: 'act' });
  assert.equal(c2.seat.lateAnswers, 5);
  assert.equal(c2.seat.lateAnswerMax, 9, 'a shorter crossing must not lower the worst one on record');
});

test('a lane cut for missing its deadline is not taken', () => {
  const m = harness(41), c = seat();
  m.takeTurnAnswer(c, lane({ askedInRound: 40, missed: true }), { category: 'act' });
  assert.equal(c.queuedAction, null, 'the seat was already marked absent for this board');
  assert.equal(c.answeredRound, null);
  assert.equal(m.dropped.length, 1, 'the discarded inference still has to appear in the log');
});

test('when the round has already moved on, the answer is dropped, not applied late', () => {
  const m = harness(41); m._roundPhase = 'flush';
  const c = seat();
  m.takeTurnAnswer(c, lane({ askedInRound: 41 }), { category: 'act' });
  assert.equal(c.queuedAction, null);
  assert.equal(m.dropped.length, 1);
});

test('the fresher board wins between two answers in hand, and the loser is counted', () => {
  const m = harness(41), c = seat();
  // The seat already answered this round, from a board sent at t=2000.
  m.takeTurnAnswer(c, lane({ askedInRound: 41, askedAt: 2000, laneNo: 1, _logTurn: 20 }), { category: 'first' });
  assert.equal(c.queuedAction.category, 'first');
  // A second lane answers later, built on a board sent at t=1000 — older, so it loses.
  m.takeTurnAnswer(c, lane({ askedInRound: 41, askedAt: 1000, laneNo: 0, _logTurn: 21 }), { category: 'older' });
  assert.equal(c.queuedAction.category, 'first', 'the answer built on the older board must not displace the newer one');
  assert.equal(m.dropped.length, 1, '…but it must be recorded as dropped, not vanish');
  // And now the case the rule exists for: a third lane, freshest of all, wins and the previous
  // winner is the one counted as dropped.
  m.takeTurnAnswer(c, lane({ askedInRound: 41, askedAt: 3000, laneNo: 2, _logTurn: 22 }), { category: 'freshest' });
  assert.equal(c.queuedAction.category, 'freshest');
  assert.equal(m.dropped.length, 2);
  assert.equal(m.dropped[1].logTurn, 20, 'the superseded record is the one the winning lane had written');
});
