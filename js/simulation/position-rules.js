// ---------------------------------------------------------------------------
// Positional rules: same-owner separation and building clearance.
//
// These decide where units stand, so they decide fights: who reaches whom, who is
// inside a building's reach. They ran in the renderer once per drawn frame, which
// made the frame rate and the tab's visibility rules inputs -- a hidden tab drew
// (Two of this file's fixes came from the other half of this fork and were lost by the
//  extraction that lifted it out of the renderer; see docs/FORK-DIVERGENCES.md D1 and D2.)
// nothing, so its units did not separate at all. They run in the simulation step now,
// once per sub-step of at most 50 ms (Game.tick), and freeze with the simulation on a
// pause. Moved unchanged from js/engine/gamerenderer.js; recorded in
// docs/RULES-CHANGES.md.
//
// deltaTime is in SECONDS. sepK caps at 3 (a 50 ms step), which is why the step that
// calls this must not be longer: a 100 ms step would get the push of 50.
//
// The renderer's own account, kept with the code it explains:
//
// NOTE: no unit MOVEMENT happens here. An earlier "kept bit-identical"
// port carried over a legacy mover that advanced every non-player unit
// a SECOND time (game.js integrates at 3×speed/s, this added 1× more),
// so AI armies ran 33% hot on plain moves and — because it steered
// toward a STALE targetX/Z during attack-marches — dragged them 33%
// slow. Infantry visibly outpaced cavalry. game.js (updateUnitMovement /
// updateWorkerTasks / updateCombat) is the single source of movement.
// Separation stops an army stacking into one pillar. It applies ONLY
// between units of the SAME owner — an enemy is not a wall. All-pairs
// separation meant a charging unit had to out-shove the entire enemy
// front to reach anything: the mover advances ~0.072/frame at speed
// 1.5 while each neighbour pushes ~0.018 back, so six defenders
// (0.108) simply repelled it and it never landed a blow, however the
// LLM ordered it. Enemies interpenetrate now and melee always
// connects; the cost is that opposing armies merge instead of holding
// a front line, which is the deliberate trade.
//
// dt-SCALED: the push used to be a flat per-FRAME amount, so a 144Hz
// display separated ~2.4x harder than a 60Hz one — the framerate
// silently tuned the combat. Normalised to 60Hz so the constants keep
// their old meaning; clamped so one long frame can't fling anyone.
// A transcript is a snapshot: presentation must not push its recorded
// entities apart or out of buildings between turns.
// ---------------------------------------------------------------------------
// No direction between two things means no direction OUT, and both passes below need one.
// Index-derived, never random: a replayed, headless or backgrounded match has to referee
// identically to a watched one, so this cannot draw from WarRng. Eight spokes, so a stack of
// eight fans out and the ninth lands where the first did -- enough for the case that matters,
// which is a move command snapping a squad onto one coordinate (docs/FORK-DIVERGENCES.md D1).
// Cosine and sine through WarMath, not Math: this decides where units stand, so it is rule
// code, and rule code may not depend on how a given engine rounds
// (tests/portable-math.test.cjs). PI is not in WarMath -- the quarter turn is written as the
// double it is, so the angle itself cannot vary by engine either.
const QUARTER_TURN = 0.7853981633974483;   // pi / 4, the nearest double
const FAN = (k) => (k % 8) * QUARTER_TURN;

var WarPositionRules = Object.freeze({
    apply(units, buildings, deltaTime) {
        const SEPARATION_DIST = 1.2, SEPARATION_FORCE = 0.03;
        const sepK = Math.min(3, Math.max(0, deltaTime) * 60);
        for (let i = 0; i < units.length; i++) {
            for (let j = i + 1; j < units.length; j++) {
                const a = units[i], b = units[j];
                if (a.owner !== b.owner) continue; // an enemy is not a wall
                const dx = b.x - a.x, dz = b.z - a.z;
                const dist = Math.sqrt(dx * dx + dz * dz);
                if (dist < SEPARATION_DIST) {
                    // `dist > 0.01` used to sit in the guard above, to keep the divide finite.
                    // The case it silently dropped is the common one: a move command snaps
                    // every unit aimed at the same destination onto ONE coordinate, and such a
                    // stack then stays welded forever -- eight units at one point, seven seconds
                    // of a running match, minimum separation still 0.000. With no direction
                    // between them, take one.
                    let nx, nz;
                    if (dist > 0.01) { nx = dx / dist; nz = dz / dist; }
                    else { const ang = FAN(i + j * 5); nx = WarMath.cos(ang); nz = WarMath.sin(ang); }
                    const push = (SEPARATION_DIST - dist) * SEPARATION_FORCE * sepK;
                    a.x -= nx * push; a.z -= nz * push;
                    b.x += nx * push; b.z += nz * push;
                }
            }
        }
        const UNIT_BUILDING_CLEARANCE = 4.5;
        // Wonders are far bigger than ordinary buildings (largest footprint:
        // the 13×13 pyramid — faces at 5.07, corners at 7.17 world units), so
        // the flat 4.5 let units walk straight THROUGH them. One uniform
        // radius for ALL wonders keeps the four civs balanced. Attackability
        // is unaffected: combatants are exempt from the push below, and
        // ranged reach (7.5+) out-ranges the zone anyway.
        // x1.5 with the Wonder itself (28 Sep 2026, Game.WONDER_SCALE): the pyramid's
        // corners now stand at ~10.75, so the ring grows with it.
        const WONDER_CLEARANCE = 10.5;
        units.forEach((unit, unitIndex) => {
            // A marcher that has NOT yet acquired a target still ghosts every
            // building: the radial clearance rings around a packed base overlap
            // into channels it cannot thread, and it used to pin against them
            // and slide along the walls forever instead of closing in —
            // "can't reach the barracks from the side".
            if (unit.isAttacking && !unit.attackTarget && unit.attackMove) return;
            buildings.forEach(building => {
                if (building.type === 'farm') return;
                if (unit.task === 'building' && unit.buildTarget === building) return;
                if (unit.task === 'repairing' && unit.repairTarget === building) return;
                // Ghost through the ONE building you're attacking, so melee can
                // close on it — the same per-target shape as the build/repair
                // exemptions above. This used to exempt a combatant from EVERY
                // building on the map, so the instant a unit retaliated it lost
                // all clearance and its own squadmates' separation shoved it
                // bodily THROUGH the nearest wall. Two pushes, one exempting
                // fighters and one exempting nobody, disagreeing.
                if (unit.isAttacking && unit.attackTarget === building) return;
                const clr = building.isWonder ? WONDER_CLEARANCE : UNIT_BUILDING_CLEARANCE;
                const dx = unit.x - building.x, dz = unit.z - building.z;
                const dist = Math.sqrt(dx * dx + dz * dz);
                // DEAD CENTRE is the one place this push could not reach. The old
                // guard was `dist > 0.01`, meant to avoid dividing by zero, and it
                // meant a unit standing exactly on a building's origin was left
                // there forever — inside the mesh, permanently. Not a rare spot: a
                // plain move snaps onto its destination exactly, so anything aimed
                // at a building's coordinates lands on 0.00 and stops being pushed
                // at the instant it most needs to be. game.clampSlot has always
                // handled this case ("dead centre: any direction out"); the
                // continuous push simply never learned it.
                if (dist <= 0.01) {
                    // "Dead centre: any direction out" -- but ANY direction must not be the
                    // SAME direction. Sending every unit that lands on a building's origin to
                    // building.x + clr parks them all on one point of the ring, where the
                    // separation pass above can no longer reach them: the escape hand builds
                    // the stack the other hand cannot unmake. Each unit takes its own spoke.
                    const ang = FAN(unitIndex);
                    unit.x = building.x + WarMath.cos(ang) * clr;
                    unit.z = building.z + WarMath.sin(ang) * clr;
                } else if (dist < clr) {
                    const push = (clr - dist) * 0.05 * sepK; // dt-scaled, like the pass above
                    unit.x += (dx / dist) * push;
                    unit.z += (dz / dist) * push;
                }
            });
        });
    }
});
if (typeof module !== 'undefined' && module.exports) module.exports = WarPositionRules;
