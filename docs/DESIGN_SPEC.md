# When Agents Rule — Design Specification

**Purpose.** A technology-agnostic specification of *When Agents Rule*: what the product
is, what it guarantees, and how every part of it behaves. It captures **design and
semantics** — rules, protocols, contracts, invariants, and outcomes — so that an
alternate build on a different tech stack can be designed against it without importing the
choices of the current implementation.

**What this document is not.** Not an API reference, not a build guide, not a statement
about any particular runtime, language, or framework. Where the current build makes a
choice that is *load-bearing for the design* (e.g. "the match must keep running with
nobody looking at it"), the requirement is stated. Where a property is a byproduct of the
current technology (e.g. "no build step", "API keys live in browser localStorage",
"classic scripts with no module system"), it is **flagged as a build constraint**, not a
design law, and each flag names what an alternate stack may decide freely.

Every claim in this document that pins a number was checked against the shipped code or
its tests; the cross-references at the end of each section name the source.

---

## 0. What this product is

**One sentence.** An arena in which two to four large language models run rival
civilizations in a real-time strategy game, with a spectator surface that shows what each
model did, why, and how well — and a recorder that makes every match re-readable,
re-playable, and citable afterwards.

**What it measures.** This is an *agent harness* whose task happens to be an RTS. A
single-turn LLM demo rewards one clever answer; a full match — economy, technology,
military, over dozens of turns, against rivals that move while you think — rewards the
properties people actually care about in deployed agents:

| Property under test | How the match exercises it |
|---|---|
| **Prioritization under a hard budget** | Three commands per turn; the turn does not pause. The model must answer "what are the three things that matter right now", on a board that changes between its own calls. |
| **Long-horizon strategy** | Economy → tech → military → conquest unfolds over half an hour. A model that optimizes forever and never builds an army loses. |
| **Error recovery** | Every rejected action returns with a precise reason. Does the model correct course, or bang on the same locked door? |
| **Format discipline** | Every move must be valid, parseable output — one action, or up to three in one reply, plus an optional plan. Hallucinate a tool, fumble the shape, wrap it in prose: the turn is wasted. |
| **Spatial reasoning under fog** | The map hides itself. Resources and enemies must be discovered before they can be used or attacked. |
| **Response to pressure** | Raided, out-scouted, slipping in the standings — do models switch tactics, or double down? |
| **Latency as a strategic variable** | In real-time mode, a faster model simply acts more often. Turn-based rounds remove that variable when judgement, not speed, is the question. |

**The result is a joint artifact.** A score belongs to *(model × serving stack ×
settings)*. A model that works through one stack and fails through another is one of the
most useful things a match can report; the transcript records the serving identity
accordingly and stores nothing that is not safe to hand to a stranger.

**The three faces of the product:**

1. **Arena (live).** Configure seats, run a match, spectate: the board, a ranked
   leaderboard, a streaming decision log with each model's own stated reasons, per-seat
   advice, and — at the end — an evaluation and exportable evidence.
2. **Analyze Transcript (post-hoc).** Load a recorded match — your own, or one bundled
   with the product — and read it back in the same engine, turn by turn, from any seat's
   point of view, with its plans, its raw reasoning, and the harness's verdicts.
3. **Campaign (human).** A human plays one seat against one to five opponents, each a
   configured model or a rule-based opponent — the same game, the same rules, with the
   model seats falling back to the rule-based brain if their endpoint dies.

---

## 1. The domain model

The vocabulary every other section of this document uses.

| Term | Meaning |
|---|---|
| **Match** | One run of the game: a map, a set of seats, a tempo (real-time or turn-based), and an outcome. |
| **Seat** | A slot in a match. Holds one *controller*: a model agent, a rule-based AI, or (campaign) a human. A seat has a civilization, an age, resources, units, buildings, and a body of knowledge. |
| **Controller** | The thing that decides a seat's turns. For a model: the provider, the model id, the settings, and the standing objective/plan. For a seat, *what decided it* is recorded even after the endpoint dies. |
| **Civilization** | One of four rule sets (Egyptian, Greek, Persian, Yamato): a stat bonus, unique units, a Wonder, and a tech tree. |
| **Age (epoch)** | A seat's progression tier: Stone → Neolithic → Bronze → Iron. The ladder is a *wire format* (see §3.4, §12): it is pinned in the state contract and in every published transcript. |
| **Node** | A finite deposit of one resource type, in a map location, with a remaining amount. Depletes to zero and disappears. |
| **Building** | A placed structure with an owner, type, position, health, construction state, and activity (producing / researching / advancing / idle). |
| **Unit** | A mobile entity with an owner, type, position, health, and an action. Every unit occupies one population slot. |
| **Order** | A command a controller issues: one of the twelve game actions, or a standing order held by a group of units. |
| **Sight / fog** | The per-seat boundary of knowledge. One question — "can this seat see that?" — has exactly one answer, and every consumer (the model's state, the rule AI, auto-defence, the spectator overlay, the replay) reads the same one. |
| **Battle** | A clustered engagement between units/buildings of different owners, reported cumulatively to the seats involved. Controllers never see a fight happen; they receive the report. |
| **State snapshot** | The JSON object handed to a model controller each turn: everything that seat knows, in the shape of the published contract (§4.2). |
| **Turn** | One controller decision: a request goes out (state + history + prompt), a reply comes back (commands and/or a plan update), the commands execute in order, and each one's result is recorded. |
| **Round** | In turn-based tempo only: the shared clock of a match, during which every live seat is asked the same question and the answers are flushed together. |
| **Transcript** | The append-only JSONL record of a match: header, one record per seat-turn, the results, and an economy timeline. Key-free, endpoint-free, safe to hand to anyone. |
| **Soundness** | The 0–100 per-seat evaluation published at match end (§4.5). |

**Identity rules.** Unit and building identifiers are minted once and never reused: a
vanished id *means* the entity died, and a controller may rely on that. Display names
("OR1 opus-5") are cosmetic and distinct from the served model id. A seat's *defeated*
status is public information in the state even when nothing else about that rival is
known.

---

## 2. The game, in rules

Everything a seat may do, and everything that can happen to it. This section states the
rules as the game enforces them; the *contract* by which a model is told those rules is
§4.2.

### 2.1 The map

- A **square world**, 800×800 world units, centred on (0,0); coordinates are (x, z).
  The map is divided into a **7×7 tile grid** for the exploration system — tiles are
  labelled `A1`…`G7` (columns A–G west→east, rows 1–7 north→south). The abundant
  resources are distributed over the same tiling of the *land* area, so every tile
  carries a proportional share (about 8 food nodes and 16 wood nodes per tile in the
  base configuration) — no tile is starved, none is a bonanza.
- **Seeds decide layout.** The same seed produces the identical node layout — verified to
  byte identity — and the same base placement. A seed is a small token string stored in
  the transcript header; the map generator consumes the seeded random stream before any
  other randomness exists, so the layout is deterministic while everything else can still
  draw from the same stream (§3.2).
- **Fair placement.** Each of the up-to-four bases sits in its own sector; the scarce
  resources are placed **identically relative to every seat** (equal counts, equal
  radii from the spawn), so no seat starts richer. Food and wood are the common
  resources: food fills an even grid (8 nodes per cell × 49 cells), wood the same at 16
  per cell. Stone (36 nodes) and gold (18 nodes) are the scarce, contested resources —
  and the binding constraint, because the map carries far more total food and wood than
  a match can spend.
- **Themes.** The same layout is available in three surface themes (summer / winter /
  desert) that change appearance and ground cover, not rules.
- **Land and water.** The map has a land limit; units may not stand in water. The
  coastline is authoritative over everything that pushes units (separation, formation
  slots): the shore clamp gets the last word on where a unit may stand.
- **No naval dimension.** There is no dock and no water unit; the one unit type that
  implies a ship is *declared in a roster and trainable by nothing* — a known, recorded
  exception, not an accident (§12).

### 2.2 Resources and the economy

- **Four resource types:** food, wood, stone, gold. Each seat starts with a small
  stockpile (200/200/100/50 by default).
- **Nodes are finite.** A node holds a fixed amount (food ≈500, wood ≈300, stone 1000,
  gold 2000 per node, as placed); it depletes with each harvest and **disappears at zero**.
  Only farms are renewable, and only while they have a worker on them.
- **Gathering is a round trip.** A worker walks to a node (with a small seeded aim
  jitter), accumulates the visit's harvest into a carried load, then walks to the
  nearest *finished* town center and delivers — only finished town centers are valid
  drop-offs, a construction site is not. A worker is "on wood" for the *whole cycle* —
  walking out, gathering, carrying home — so the economy tally counts them wherever
  they are in the loop. A worker who is carrying and gets a new assignment does **not**
  drop the load: the load is delivered first, and the new job is picked up the instant
  it is banked. A worker whose node drains mid-trip continues at the nearest discovered
  node of the same type (measured from the depleted node, not from base) or goes idle.
- **What a seat is told about resources is deliberately two-layered:**
  - *counts* of nodes it has discovered (per type) beside *total still standing on the
    map* (per type) — the gap between them is the unscouted remainder, and whether to
    close it is the seat's decision;
  - a *shortlist* of node coordinates: the closest food/wood nodes to each of its Town
    Centers, plus every stone and gold node it has found. The shortlist is a convenience,
    not a limit: any discovered node's coordinates may be ordered.
- **Housing is a supply line.** Every unit — villager included — occupies a population
  slot. Town Centers contribute 10 slots, Houses 5, hard ceiling 100. A seat whose Town
  Center and all Houses are destroyed has a cap of **zero**: it cannot field anything,
  however much it is worth, and the elimination rule accounts for that (§2.10).

### 2.3 Ages

- **One ladder, four rungs:** `stone → neolithic → bronze → iron`. It is spelled out in
  several independent copies across the system by design of the current build, and it is
  treated everywhere as a *wire format*, not a tunable: the state contract pins the
  four strings, and every published transcript stores them.
- **Advancing is a hosted, timed action** run at a Town Center (one at a time, with a
  progress report and a countdown). It is not instantaneous, and it competes for the
  building's attention the way research does.
- **Effects of an age:** stronger content unlocks (buildings, units, techs); buildings
  take an era-appropriate appearance; and — the part no one is told about in the state,
  and which is recorded as a live balance question — a seat that advances **re-types its
  fielded veterans for free**, along fixed upgrade paths (e.g. a Bronze warrior becomes
  an Iron champion, unbilled). The paths exist for the shared roster and for the
  civilization whose signature units are standard ids; they do not exist for the other
  civilizations' distinct units. One seat's army can upgrade at an age-up while three
  others' do not. This is *not* disclosed in the model-facing state (see §13, open item:
  the free upgrade).
- **Age costs are a single shared table** — the same four advance costs for every
  civilization.

### 2.4 Technology

- A **per-civilization tech tree**, with a shared core. Each tech: a cost, a required
  age, a host building where it is researched, a research duration, and an effect — a
  stat bonus applied to a unit class (infantry / cavalry / ranged / worker / all
  military / all units), or an unlock (a building, or the stable itself via its
  namesake tech).
- **One research at a time per seat**, hosted at a finished building; the seat is told
  what it is researching, its progress, and its countdown, and is told not to re-issue it.
- **Only one research slot, but many buildings may host different ones** — research at
  the academy and an age-up at the Town Center run concurrently in different buildings.
- Techs can *raise the effective age gate* of a building (a building whose unlock tech
  arrives later than its nominal age is reported at the later of the two).
- Civilization **bonuses** interact: one civ's tech-cost multiplier, one civ's
  building-health multiplier, one civ's worker harvest bonus — each is a global multiplier
  for that seat, applied where the content says, and the state's `bonuses` object shows
  only the non-default ones (an empty object means "none active").

### 2.5 Buildings and units

- **Shared structures:** Town Center, House, Farm, Barracks, Archery Range, Stable,
  Temple, plus per-civ unique buildings and the Wonder.
- **Buildings have a life cycle:** `under_construction` (with build progress and a
  countdown) → `complete`. Construction is a timed, worker-driven affair — a building
  that is being built by a living worker *counts* for what it will become (an unfinished
  Temple with a worker on it already lets its owner field a priest, when affordable).
- **Buildings do three different jobs**, and the state keeps them separate:
  - *produce* units (one unit-type at a time, with a countdown),
  - *host research*,
  - *host an age advance*.
  A building is "busy" while doing any of these; a building under construction does
  none.
- **The unit roster** is nested *host building → earliest age → unit*: Town Centers
  train workers; Barracks the infantry line; the Archery Range the ranged line; the
  Stable the cavalry; the Temple the priest. Units have cost, health, speed, attack,
  range, and a class (worker / infantry / ranged / cavalry / support).
- **Training is refused at the edge** with a precise reason when a structural gate
  stands in the way (wrong age, missing host, no population room, unaffordable) — and
  the state the seat was shown *already said so*: the same list it was shown splits
  every unit it knows into *trainable now* (with the price-only gates shown) and
  *blocked* (with the structural gate named: `age`, `tech`, `host`, `pop`,
  `alreadyBuilt`). The rule: **what a seat is told it may order is what its executor will
  accept, gate for gate** — the two are pinned against each other by test.
- **Demolition and repair** are first-class orders (`destroy_building`,
  `repair_building`): workers repair the most-damaged friendly building by default;
  demolishing is how a seat trades space it no longer wants.
- **Wonders** (§2.10) are the exception to everything: one per seat, revealed to all
  rivals regardless of fog, with a public countdown.

### 2.6 Fog of war and sight

- **Sight is per-seat and per-source.** A seat sees what its *living units* and
  *finished buildings* cover: infantry-class sources see ≈15, cavalry ≈22.5 (a
  multiplier over infantry), buildings ≈20, a Town Center ≈40, a tower ≈80, and
  nothing under construction. Vision techs multiply these. The numbers above are the
  *authority's* numbers — the ones the simulation, the model-facing state, the rule AI,
  and the spectator overlay must all agree on, at every point on the map.
- **What is remembered, and what is not:**
   - *Enemy buildings* are the one kind of knowledge that persists: a building's
     position is remembered *by the simulation* once seen (so the game's own systems,
     and the replay's "last seen at Ns" annotations, keep resolving it) — but the list
     the *model* is handed carries only buildings confirmed visible now, so a seat is
     never steered toward a ghost it was never shown.
   - *Enemy units* move: the state lists only the ones visible right now, and the
     list is deliberately short.
   - *Nodes* appear in the state only where the seat has explored; stone and gold are
     listed in whole once discovered, food and wood as a capped shortlist of nearest.
  - *Rival civilizations and ages are public* (a rival's `discovered` flag gates the
    counts of its units and buildings, but the civ and age are always known).
  - *Wonders ignore fog entirely*, on both sides.
- **Discovery is the exploration grid.** Each tile carries a 0–100 "how much of this
  tile has been swept" percentage; a scout's pass raises a tile by a few percent. This is
  how `explore` works — it takes a tile label — and how the replay can draw a seat's
  knowledge with opacity proportional to coverage.
- **One question, one answer.** "Can seat S see position P?" is asked by at least four
  independent consumers in the system (the state builder, the rule-based AI,
  auto-acquisition, the spectator/replay overlay). The design law — pinned by a test
  that probes the same points through every path and *also* anchors the numbers, so
  that agreement on a wrong value cannot pass — is that all of them get the same answer
  from one authority. A derived consequence is recorded as a rule too: **a dying unit is
  not a scout, in any path.**
- **Consequence, stated to the model:** `enemyUnits` is what you can see *right now*;
  an empty list means "nothing in sight", not "nothing exists".

### 2.7 Combat

- **Fights happen between turns.** A controller never watches a battle; it receives the
  *report* — `battles` in the state: one entry per clustered engagement, cumulative since
  the engagement began, showing both sides' composition by unit type, damage dealt to
  units and to buildings separately (never summed: the counters are different), healing
  done, and losses. Losing produces no error, so the report is the only place a seat
  learns what beat it.
- **The counter triangle** (the rule that decides every fight):
  - cavalry ×1.5 against ranged; ranged ×1.5 against infantry; infantry ×1.5 against
    cavalry — each reversed at ×0.75;
  - against buildings: infantry ×1.5, cavalry ×1.0, ranged ×0.5.
  - This rule is fully implemented and fully symmetric in the engine — and it is, in the
    current build, *not stated anywhere a model reads* (the unit classes appear only as
    tooltip labels in the human UI). It is carried as an open disclosure decision (§13).
- **Engagement is a group property.** When one fighter of a standing order can engage an
  eligible enemy, the capable members of the formation join the same local fight rather
  than leaving the far wing to "hold forever". Enemies are *leashed*: acquisition inside a
  combat radius around the formation, chase bounded, with per-unit "blocked" memory so a
  failed chase is not immediately retried (it re-arms when the target is meaningfully
  closer, or back in striking range).
- **Acquisition is sight-gated.** A unit may not auto-acquire an enemy its seat cannot
  see. Ordered attacks and retaliation are the exception (the seat chose them, or the
  damage is being dealt *to it*); base defence is unaffected because a Town Center sees
  far enough that raiders walk into sight long before the defenders react.
- **Retaliation** (the reaction to incoming damage) is its own clocked window: hits are
  stamped, a short window decides "this is still the same attack", and towers take
  priority over mobile attackers in the threat queue.
- **Support units never fight.** Priests march with an attack order, then tend the
  wounded from the back, holding a patient and standing at the edge of their healing
  range; they do not chase, do not target, and a scout-mode formation never initiates
  contact at all (though it still answers damage, since incoming fire overrides movement
  intent).
- **Idle military auto-defends the home** between turns — repelling raids, never winning
  the game — so a seat need not micro every border incident.
- **A chased target is tracked as the crow flies, within a leash.** An ordered attack
  steers on the target's live position; a brief crossing out of bounds or out of sight
  is granted a short grace, after which a target lost to fog is released — and briefly
  *blocked* for that pursuer, so a failed chase is not immediately retried (one stalled
  pursuer never makes its squadmates abandon a reachable target). Refining the leash —
  last-known position, an age, a give-up rule — is a recorded open item, deliberately
  not implemented as a side effect of the sight fix (§13).

### 2.8 Standing orders

A *standing order* is persistent group intent issued by a controller to a set of units:
it survives across turns, re-forms as members die, and knows what the group is for.

- **Four modes:**
  - `march` — move the group to a point, in formation, at a matched pace;
  - `scout` — move while not initiating combat at all (damage still triggers the
    retaliation of §2.7);
  - `guard` — hold a position (a guard on a target guards the target's *last observed*
    location if it dies between scans);
  - `patrol` — shuttle between two points, with engagement measured by distance to the
    route, not to a single point.
- **A new order replaces the group's previous assignment** (with a generation token, so
  a stale order can never be re-issued over the fresh one); reassigned members leave the
  old formation immediately.
- **The group's mechanics:**
  - *Formation and slots:* the group's destination is a shape, not a point — members get
    distinct resting places (a compact footprint with support in the rear ranks); the
    placer prefers translating the whole shape onto nearby legal ground over flattening
    ranks onto a building or the shore, and falls back to individual placement in a
    cramped village.
  - *Combat state:* when the group is fighting, it anchors; members keep their slots as
    *return positions* for when the fight ends; the group's threat queue (towers first)
    drives who is struck at; and blocked-chase memory prevents a soldier from
    immediately re-chasing a target it already failed.
  - *Reform:* as members die, the formation repacks the survivors to the current
    objective without interrupting live fights.
- **What the model is told:** in-flight orders are echoed back each turn in
  `ordersInProgress` — the command spelled as it was issued, its destination, which unit
  ids it covers, and a countdown — so that *repeating an order is the seat's visible
  mistake, not the harness's silence*.

### 2.9 Threats and events

The state separates *what is happening to you* from *what you know*:

- `threats.underAttack`: your units/buildings that took damage in the last few seconds,
  each with the attacker's position (when known) — "defend now".
- `threats.enemyWonders`: every rival Wonder, complete or under construction, with its
  win-countdown — an always-visible existential threat.
- `recentEvents`: up to eight one-line events (losses, kills, raids) with ages, e.g.
  *"12s ago: LOSS: your house at (140, −80) — destroyed by egyptian"*.
- `recentLosses`: your own buildings destroyed in the last two minutes, with the rival
  responsible when known — because a building simply *disappears* from the friendly list
  when it falls, and without this a structure you were told you had (a Wonder above all)
  would vanish with no explanation.

### 2.10 Winning and losing

**Two, and only two, ways to win:**

1. **By elimination** — every rival out of the match.
2. **By the Wonder** — build your civilization's Wonder and *hold it for 600 seconds*
   (the duration is a match parameter; the current build's stated default is 600). The
   hold runs on the match clock; it resets to the full duration if the Wonder falls; and
   while any Wonder stands, the match is deliberately held at 1× speed so the countdown
   cannot be sped past. A finished or half-built Wonder is visible to **every** rival,
   with coordinates and countdown, regardless of fog — its location is a decision made in
   the open.

**The elimination predicate.** A seat is out of the match when it can do nothing the
game still asks of it. Concretely, a seat is *spared* when, at the moment of checking,
it can still **field a military unit** — which the game decides from its *own training
tables* (the same resolution order the training panel and the model-facing vocabulary
use: host building present — finished, or under construction with a living worker on
it —, unit affordable, age reached, **and a population slot to stand the unit in**) — or
when it still holds **a Town Center, or a worker plus the resources to rebuild one**.
Otherwise it is eliminated: no army, no way to field one, no base, no way to raise one.

Design laws pinned around this predicate:

- *One predicate, one place.* The harness's "is this controller defeated?" delegates to
  the simulation's; the two share one rule so campaign and arena cannot drift apart.
- *The predicate reads the same tables the model reads.* A seat whose last trainer is a
  Temple is not deleted while its own state still lists the priest as trainable; the
  temple and every civ-unique unit count, because the game's tables say so — the
  predicate has no copy of its own.
- *The population cap is part of "can field a unit".* A seat with a razed base and a
  surviving Temple has a cap of zero and cannot stand even the priest the Temple could
  train; that seat is out, however much gold it holds — and it is *told so*, because the
  same list it reads marks every such unit `blockedBy: ["pop"]`.
- *Defeat is public but sparse.* A defeated rival remains listed (civ and age visible) as
  a public true/false status; no locations, no terrain, no counts.
- *The Wonder is a second base.* Losing it is reported in `recentLosses` with a flag,
  because it *is* the win condition and its vanishing must not be silent.

### 2.11 Tempo: real time and turn-based rounds

**Real time.** The match runs on its own clock and *never pauses while a controller
thinks*. Orders take real seconds; the state carries countdowns for anything running,
and work already under way continues on its own and does not occupy the turn (re-issuing
it wastes the turn). A slower model simply acts on older boards; its own
`averageSecondsBetweenTurns` (its thinking time included) is in the state so it can
convert any duration into the number of decisions it will get while that thing runs.
In-flight answers are honored: pausing waits for what is already in flight, so no move
is thrown away.

**Turn-based rounds.** An alternate tempo that removes speed as a variable: each round,
every live seat is shown *the same snapshot* and given a bounded answer window — a
per-match input clamped to 10 s – 900 s (default 90 s). When the window
closes, the answers flush together. The acceptance rule for an answer — the whole
turn-based decision, stated once and pinned — is:

| Case of an arriving answer | Disposition |
|---|---|
| An answer to the round it was asked in | **taken**; staleness zero. |
| An answer to an *earlier* round (the seat's provider was slow) | **taken** — mid-pipeline is not obsolete; a seat on a slow provider must not be silenced every round — but the number of rounds it crossed is **written down**, because that frequency is the only input a future rejection rule could be decided on. |
| A lane cut off for missing its deadline | not taken. |
| An answer after the round has *resolved* (this seat missed it; the others moved on) | **dropped, and counted** — never applied late. |
| Two answers in hand for one seat | **the one built on the fresher board wins**; the loser is counted as dropped rather than quietly overwritten. |

Nothing in the acceptance rule enforces staleness, deliberately: *rejecting a late
answer changes which moves land, i.e. who wins* — a gameplay decision, carried as an
open item with the measurement now recorded per turn (`lateByRounds`) and per seat
(`lateAnswers`, `lateAnswerMax`). A **missed round is recorded, not hidden**: it appears
in the turn list, the filters, and the metrics.

### 2.12 The match, end to end

1. **Setup.** 2–4 seats; each a civilization + controller; difficulty; optional seed;
   tempo and (if turn-based) the answer window; a shared system-prompt template with
   optional per-seat overrides.
2. **The match starts.** `startGame` is synchronous: by the time it returns the world
   exists and has taken exactly one internal step. (That property is what makes two
   runs of a seeded match comparable at all — see §3.2.)
3. **It runs.** The simulation steps on its own clock, sliced into bounded quanta of
   real elapsed time, whether or not anything is looking. Model turns fly in
   asynchronously; orders land and are answered; the world changes between one turn and
   the next.
4. **It ends** when one seat wins (both victory paths above) or the field resolves. The
   outcome is one of a small set of labels (e.g. `last_standing`), the final ranking is
   computed, and the transcript gets its results and its economy timeline.
5. **It is readable afterwards.** Everything said, done, and seen — §5.

## 3. Time, determinism, and reproducibility

### 3.1 Two clocks, and the rule between them

A match is driven by one **simulation clock** — the match's own notion of time,
sliced into bounded quanta of real elapsed time. Everything the game *promises* runs on
that clock: construction, training, research, age advances, the Wonder hold, the
day/night cycle.

The design law this fork codified (and the fix that made it true): **sim duties run on
the simulation clock, never on the render loop.** Unit separation, building clearance,
and the shore clamp are *correctness* passes, not drawing effects — so they execute once
per simulation sub-step, in the same order, whether or not a frame is ever painted.
The observable consequence is the product's headline: **a match keeps running in a
background tab** — the simulation is a first-class process, the viewport is a client of
it, and "nobody is looking" changes nothing about who moves, who dies, or when a
building finishes. A render failure (graphics context lost) stops the *display* — with
a dismissible notice — while the match, the leaderboard, and the decision log carry on;
the display recovers when the context is restored.

A known asymmetry is carried as an open item, not hidden: a handful of combat-adjacent
windows (the retaliation stamp, the "recently damaged" query, the battle clustering)
still read wall time, so at 2× or 4× speed they are proportionally shorter *in game
terms*, and a pause does not freeze them. Routing them onto the simulation clock is a
one-line-each change with gameplay consequences (it would freeze combat timing under
pause for the first time), so it is listed as a decision to be made, not a bug to be
punched (§13).

### 3.2 What a seed guarantees

- **The seed fixes the map** — layout, base positions, scarce-resource placement — to
  byte identity.
- **The seed also fixes the simulation's random stream.** Every draw the simulation
  makes — spawn scatter, where a worker parks on a farm, the angle a trained unit walks
  out at, where a building lands when no coordinates were given, which tile an
  `explore` resolves to, the rule AI's own scout angles — goes through the generator the
  map was built from. Two fresh pages, same seed, same step cadence: identical
  economy, identical forced combat (measured by hashing the unit sets; the pre-fix
  builds diverged, 27 vs 29 survivors of the same forced fight).
- **Unseeded matches are untouched by the change:** with no seed, the generator *is*
  the ordinary random source, so a default match draws exactly the distribution it always
  did.
- **What the seed does not (yet) fix:** the wall-time windows of §3.1. A seeded match
  replays identically **at a fixed step cadence** — which a harness controls and a
  player's frame rate does not. That is the state of "a seed reproduces the match, not
  just the island": closed for the draws, open for the clock.

### 3.3 The properties a rebuild must preserve

1. *One question, one answer, one authority* — for every cross-cutting fact (sight,
   "can field a unit", the age ladder, the action vocabulary, the cost tables).
   The failure mode is not a changed value but a **second copy** of the value that
   drifts, in a code path that feeds a *different consumer* (the model's state, the
   rule AI, the overlay, the executor) than the one that was fixed.
2. *The contract is written in the language of the consumer.* The state a model receives
   and the prompt it is governed by state their own invariants in prose the model can
   read — "do not re-issue", "this list is a shortlist, not a limit", "a zero means
   unscouted, not absent". A number is interpolated from its single definition, never
   re-typed. When the last message of every turn contradicted the system prompt about the
   command budget (measured: small models obeyed the last sentence, big ones ignored it
   — *same rule text, four seats, two different games*), the fix was to the sentence,
   not to a constant.
3. *A refusal is a fact with a cause, in the model's next context.* Every failed
   command names which gate failed and what the answer to it is ("build the stable",
   "advance your age", "save toward the cost").
4. *Nothing the model is not told may be true of it.* If the engine re-types veterans,
   hides a counter rule, or forgives a seat, the state either says so or the item is
   recorded as a live disclosure decision (§13) — silently divergent truth is the bug
   class this design exists to eliminate.

---

## 4. The agent protocol

The contract between the harness and a model. It has three parts: the tools a model may
call, the state it is shown, and the feedback it gets.

### 4.1 The tools

A model acts by **calling tools** — real tool calls on every supported protocol,
extracted from the completion response the same way any agent harness extracts them.
There are exactly **two tools**:

**1. The game-command tools** — twelve named actions forming one budget of **three per
turn**:

| Action | Parameters (only what is nameable) | What it does |
|---|---|---|
| `train_unit` | `unitType` (from the state's unit vocabulary), optional `targetX/Z` | Train a unit at the host building; workers are `unitType: "worker"`; a target places the unit at an exact spot. |
| `research_tech` | `techId` (from `research.available`) | Start the one research a seat may run. |
| `upgrade_age` | — | Begin the advance at the Town Center (never re-issue while in progress). |
| `build_structure` | `buildingType` (from the state's building vocabulary), optional `targetX/Z` | Place a structure; the civ's Wonder is built here, as type `wonder`. |
| `assign_workers` | `resourceType` (food/wood/stone/gold/farm), `count?` (default 3, max 20), `from?` (a worker pool: the resource pools, `farm`, or `idle`), `allowSpill?`, optional `targetX/Z` | Assign workers to gather at the nearest node of that type to the target; `from` + the same value in `resourceType` moves a crew node-to-node; `allowSpill: false` takes only workers not carrying a load (and takes fewer if that is all there are). |
| `repair_building` | `count?` (default 1, max 5), optional `targetX/Z` (omitted = most damaged) | Send workers to repair. |
| `explore` | `tile` (a map label, e.g. `C5`), optional `unitType` | Send a scout to sweep a tile of the exploration grid. |
| `move_units` | `targetX, targetZ` (always together), optional `units` / `unitIds` | Move units to a point — the standing-order layer's `march`/`patrol`/`guard` live here; `unitIds` moves *exactly those* units. |
| `attack_target` | `targetId` (a handle from the state) **or** `targetX, targetZ` (attack-move), optional `units` / `unitIds`, or a class filter | Attack a unit or building by handle, or march-and-attack toward coordinates; a pinned target is steered on its live position (§2.7). |
| `delete_unit` | `unitType?` (default `worker`), `count?` (default 1, max 20) | Deliberately free a unit (and its population slot). |
| `destroy_building` | `buildingType`, optional `targetX/Z` | Demolish one of your own. |
| `wait` | — | A complete, valid, deliberate no-move. |

**2. The `plan` tool** — independent of the command budget, at most **one per turn**:
it saves the seat's standing **objective** (one line) and **plan** (up to ten short
steps). It *uses no command slot*; a **plan-only reply is a successful plan update**;
and saved steps are **never executed automatically** — the harness never plans for the
model. Both persist across turns and are echoed back until rewritten (wholesale-replace
semantics: the model rewrites them when they change); a turn that issues commands without
re-calling `plan` keeps the standing objective.

**Reply shapes.** One action with its parameters and a one-line reason is a complete
reply. Up to three command objects may be issued in one response; they **run in order
against a board each one changes**, and the model does not see between them — so the
prompt teaches the ordering discipline itself (cheap, certain moves first; spending
resources in command one can get command three refused for what command one just used).
Each command is **judged on its own**: one refusal does not cancel its siblings, and the
feedback names *which number* failed and why. A reply whose JSON is broken costs the
*whole turn* — so the penalty for malformed output scales with how much was riding on
it, with no special rule.

**Tool failures are visible failures.** A seat that cannot work the tools — a server
that drops tool calls, a template without a tool section, a model that simply does not
call — fails *loudly, with the fault named*: syntax found in the raw reply means the
model called and the server missed it; no syntax means the model did not call. A harness
that quietly compensates for a broken parser hides the one thing its operator needs to
know.

**The declared softer contract.** For older or smaller models, and for endpoints whose
parser is broken, a seat may be switched to *accept inline JSON* (off by default). It is
a declaration, not a convenience: it is recorded in the transcript, and every turn
records whether it was answered by a tool call or by raw content — a seat allowed to fall
back is scored on a softer contract than one that is not, and the file must be able to
say so.

### 4.2 The state contract

Each turn the seat is shown a single JSON object — the **state snapshot** — whose full
shape is the published schema (shipped beside the game, hand-maintained, and checked
against the newest real transcript on every test run: every required field present, no
emitted field undeclared, every reference resolved, and the nested promises read *from*
the schema so a tightening there becomes a claim about real records).

The design properties of the snapshot:

- **It is fog-limited, completely.** The seat sees only what its own units and buildings
  have discovered, and it is told that a zero and an empty list each mean something
  specific (unscouted; nothing in sight).
- **It separates the four ways a seat can be stuck.** Every unit, building, and tech the
  seat will ever be able to order is listed, split into *what you may order this turn*
  and *what you may not yet* — and in the second list, **each entry names its structural
  gate** (`age` / `tech` / `host` / `alreadyBuilt`, sometimes `cost` or `pop`
  alongside). Price-only and population-only gates keep the entry in the first list: an
  unaffordable unit is a target to save toward, not a refusal. "Host" and "age" are
  answers to questions with named remedies (build the stable; advance). Whether a
  trainer is busy *this instant* is deliberately absent — it changes several times while
  the model thinks, so reporting it would be a lie.
- **It keeps a count from ever being read as an amount.** Population is its own object
  (used / capacity-now / hard-ceiling), kept apart from the resource amounts "because
  one object holding both invites reading a count as an amount"; the subtraction for
  "room left" is *deliberately left to the reader*.
- **It reports the world's scarcity as a trend.** Node counts discovered vs. total
  still standing, both per type, live — "watch it fall to see the world running dry";
  a figure that slides toward zero is the signal to stop prospecting.
- **It is honest about its own staleness.** The match does not pause for the model:
  `clock.matchSeconds` anchors every other "seconds" figure; `averageSecondsBetweenTurns`
  (the seat's own thinking time included, present only once an interval has been
  observed) converts durations into the number of turns it will get while they run;
  in-flight orders are echoed in `ordersInProgress` with ETAs; remembered positions
  are flagged as last-seen, never as live.
- **Its vocabulary is its own interface.** The ids in the snapshot are the exact strings
  the tools accept (`unitType`, `buildingType`, `techId`, tile labels, target handles);
  the snapshot's field descriptions are written in the second person, to the seat, and
  the *system prompt* — not the schema — is the single source of the action
  vocabulary. (A second copy of the vocabulary is a second thing to forget; the test
  that pins vocabulary parity reads the dispatcher's own source rather than re-parsing
  the file.)
- **Its rules are in it.** The win conditions, the population arithmetic, the
  shortlist-is-not-a-limit note, the "do not re-issue while non-null" warnings, the
  distinction between `unlockedContent` (buildings you may now place) and
  `research.researched` (techs you hold — "they are not the same list and neither
  follows from the other by name") — all of it is stated where the model reads it, in
  the seat's own configured language.

The contract's *verification* is part of the design: the schema is checked against the
**newest** shipped sample on every run, and older samples are deliberately **not** held to
today's schema — they were written by earlier builds (renamed fields and all), and
pinning history to the present makes a fixture that can never change. The newest match
emits a field the schema had never declared (`ordersInProgress`, on every turn) — that
is the class of drift the test exists to kill: *a contract verified against one old file
is not verified.*

### 4.3 The per-turn message

**Structure and order** (order is semantic, not cosmetic — the current build states
that the old order, state-first, made the model answer a stale old result):

1. the system prompt (the shared template, or the seat's override — rules, win
   conditions, the tool budget, the action vocabulary, the output format, the standing
   objective and plan echoed from the previous turn);
2. the seat's **history**, in the mode the seat's settings chose:
   - *multi-turn* (the default, richest memory): each past turn replayed as a **compact
     recap** of the state the model was shown that turn (high-signal fields only —
     resources, economy, army, research, known nodes, enemy presence, threats — with
     long per-entity arrays replaced by counts, flagged `pastTurnRecap: true` so it reads
     like the live state it mirrors) plus the model's own reply and its outcome; or
   - *minimize tokens*: each past move as one line (action, one-line reason, outcome),
     kept newest-first, filled to the remaining budget;
3. the **current full state, always the last message** — the thing the turn is decided
   from;
4. any spectator **advice** sent to the seat (appended after the state).

**Budgeting.** History is sized to *each model's context budget*: the configured budget
(default 32768; a per-model "Max" fills in the model's true discovered maximum) is
clamped to the model's real limit, then split with headroom — a pessimistic
~3-chars-per-token estimate, an 80% cap, and a reserve for the fixed parts. A 128K model
therefore remembers more of the match than a 32K one.

**Self-healing history.** The prompt is rebuilt from scratch every turn, so the harness —
not any server's truncation rules — decides exactly what the model sees. Two failure
shapes get first-class handling because they *poison the history*:

- **Context overflow** (the endpoint refuses the request as too large): the budget
  ratchets down (×0.7, floored at 25%) and the next turn retries; the seat is told, in a
  note, that its previous request was dropped and the window trimmed — and the event is
  counted as *the harness's* (context budgeting), never as the model's.
- **Repeated identical endpoint errors** (the server rejects the same request shape over
  and over — the measured incident: one truncated tool call in the replayed history cost
  a seat 39 consecutive rounds): the harness backs the *history* out before it blames
  the model — first stripping tool calls from the recorded history (a string cannot fail
  to parse; dropping just the calls keeps the whole move history and degrades the turn
  into the prose form the harness already supports), then dropping the history itself if
  the error persists. The seat is told what was dropped and that *the game state is
  unchanged; nothing you ordered was undone*. **Transport failures are excluded on
  purpose** — "failed to fetch" means nothing reached the server, so nothing sent can be
  at fault, and throwing away a healthy history for a network blip is how a self-heal
  becomes a new failure.

A further hygiene law: **a tool call whose arguments are not valid JSON must never enter
the replayed history.** The transcript keeps the reply verbatim (the inference happened
and was paid for); but a server in the OpenAI dialect parses the calls in the messages it
*receives*, not just the ones it emits — replaying an unparseable call makes every
later request unparseable. Such calls are dropped from the replay and capped in size.

### 4.4 The provider layer

The harness speaks **four dialects** of the same logical request — named tools, a system
prompt, a message history, an output budget:

- **OpenAI-compatible** — the shape served by OpenAI and by every OpenAI-compatible
  stack (vLLM, llama.cpp, LM Studio, LiteLLM, Groq, OpenRouter, …);
- **Anthropic**; **Ollama**; **Google (Gemini)**.

The *same* tool definitions are translated into each dialect by one builder per
dialect; a provider may be selected explicitly or **auto-detected** from the endpoint.

**Authentication is a property of the connection, in five styles:** none (local
endpoints), API key (Bearer), header secret, Basic, or OAuth2. Keys live in the operator's
own storage on the operator's own machine and go *directly* to the endpoints configured —
never proxied through anything the product owns. (In the current build that storage is
the browser's localStorage — a build constraint, flagged in §11 — and an alternate stack
may decide freely, provided the product's other invariants hold: keys never enter a
transcript, an export, or a request the product makes on anyone's behalf.)

**What a match records about its serving stack — and what it never does:**

- Each seat's **serving identity** (`servedBy`) is *asked once at match start* — what
  the server calls itself — and never guessed from the endpoint.
- The **endpoint is never stored** in the transcript, in any form that identifies it.
- The **operator's bill is redacted at the source**: the raw provider usage object is
  copied into each turn record *minus* the pricing and account fields (cost, cost
  details, BYOK flags, …) — the token detail that field exists for survives, the invoice
  does not. (The audit that found this published $94.62 of one operator's spend across
  the bundled samples; the files were key-free and endpoint-free and *still* carried the
  per-turn bill.)
- The **renderer's identity** (which GPU path actually drew the frames, and its max
  texture size) is read once at context creation and written into the transcript header
  beside the seed — because frame cadence sets how many simulation steps fit inside a
  seat's turn, and two results from 21 fps and 60 fps machines are not the same
  experiment.

**Per-seat settings** (the full field list of a model entry): endpoint; provider
(explicit or auto-detected); auth style and value; the served model id; max output
tokens; context budget (with a "Max" that fills the model's discovered true maximum);
the language the model thinks and answers in (independent of the interface language);
temperature / top-p / top-k; thinking/reasoning settings; a raw request-body passthrough
for anything newer than the harness; and the accept-inline-JSON switch of §4.1. The
library supports adding and **test-connection** entries, and export/import of the whole
catalogue — with an explicit warning that an export carries keys in plain text.

**Lanes.** A seat may keep a small number of *overlapping* requests in flight
(experimental, per-seat): the lanes share one history, one objective, and one plan —
a seat is one agent with one memory, and experiences itself as continuous — but each lane
carries its own request handle, so one lane's abort (a missed deadline) never kills its
siblings, and a lane's answer is *executed as that lane*: the outcome attaches to the
history record and the idle counts that lane's request was judged against.

### 4.5 Evaluation: the soundness score

At match end every seat gets a **0–100 strategy score** — a transparent weighted
composite, no black box:

| Weight | Factor | What it means |
|:---:|---|---|
| 0.34 | **Action success rate** | the share of the commands a seat issued that were valid and accepted — measured over *everything it tried*, so a seat that sends three and gets two right is not out-ranked by one that sends one safe move. |
| 0.20 | **Progression** | age advanced, buildings, military — the shape of the end state. |
| 0.18 | **Format fidelity** | well-formed output the engine could parse. |
| 0.15 | **Reliability** | no timeouts / network errors — *as far as the harness can tell the model caused them.* |
| 0.13 | **Action diversity** | used the toolset rather than looping one move. |

**The law of the score: it does not charge a seat for the harness's own failures.** A
rate with no denominator is **absent, not zero** — `null`, rendered as "—", in both the
on-screen card and every export. A seat the harness never let speak (every turn cut by a
context overflow, which is the harness's budgeting) is scored on *what it did*, with the
unknown terms dropped and the rest re-normalized over what is known — the pre-fix
behavior had it topping out at 33 regardless of play, while a genuinely dead endpoint
scored the *identical* number with a *measured* zero. A measured zero still prints as
0% ("a rate that was answerable and wasn't is the number for answered-and-wrong"); a
rate with no denominator never prints as a number at all, in either export.

**Around the score, per seat:** latency (avg/min/max), decisions and answered count,
the full error breakdown — timeouts, network errors, parse failures, truncation,
no-action replies, context overflows, rate limits (and rate-limit turns *lost*),
missed rounds, invalid actions, rejections, contention — plus commands-per-turn
(reported *beside* the success rate, never inside it), token usage (provider-reported
prompt and completion, per the redaction rule), a reasoning rate (the share of turns
whose reply carried a reason), and **behavior tags** computed from the metrics
(format-faithful, efficient, versatile, economy-focused, …) — with the guard that a tag
conditioning on a rate must skip a rate it cannot see.

**The closing word.** At match end each model seat is asked, in its own language, to
sum up *its own* match — and it is shown **only its own history**: naming what the rivals
had would be omniscience it never scouted, and a post-mortem written from what the
player actually knew is worth more than one written from the recorder's log. The reply,
however long and in whatever shape, is recorded verbatim as the seat's final entry.

### 4.6 The rule-based brain

The non-model controllers (campaign opponents, and the fallback of §7) are a
**rule-based AI with two stated design goals:**

- **FAIR versus model players.** It is fog-limited exactly like the models: it harvests
  only resources it has *discovered*, attacks only enemies it can *currently see* (or
  remembered buildings, or the always-visible Wonders), and must scout to find more. Its
  age-ups and research run through the same timed game systems — no instant ages, no
  double-speed research. It thinks on a fixed cadence (a decision pass every couple of
  seconds).
- **DEADLOCK-FREE.** One priority pass per think; every step gated by its own
  affordability/availability check, so nothing oscillates or spends into deficit;
  building positions are found *before* paying; workers are never stranded (they gather
  the most-needed known resource, and a spare scout goes out when something needed
  isn't discovered).

**The fallback rule:** in a match, a model seat whose endpoint dies mid-game **falls
back to the rule-based brain** — the seat keeps playing, the match keeps running, and
the transcript keeps telling the truth about which controller drove which turns. A seat
that is cut off by *its own round deadline* in a turn-based match is not a dead
endpoint; it simply missed a round, and that is recorded as such.

## 5. Recording and analysis

### 5.1 The transcript is the only artifact

Everything about a match is transient except its **transcript**: the verbatim exchange
with each model. The decision log (§6.3) shows what a model *did*; the transcript
records what it was *shown* (the complete state JSON, unedited), what it *said* (the
reply, and its reasoning where the provider exposes it), and what the *harness answered*
(the numbered outcome lines). It is the complement of the model's own history, which is
lossy *by design* — the reply is collapsed to 600 characters, it keeps content or
reasoning but never both, and its "user" is the compact state, not the full one the
model actually saw.

1. **One append-only line-oriented file per match** — per-seat streams while it
   runs, merged into the single ordered file on export; the contract is that every
   line parses on its own, so a file truncated by a crash still yields every complete
   turn before the truncation (which one large JSON array would not).
- **Lifetime is one match.** The results screen offers the download and says the
  transcripts go when it closes; the recorder also wipes at match *start* (a reload
  cannot be relied on for async cleanup). Nothing accumulates on disk behind the
  user's back.

### 5.2 Record types, and why their order matters

The exported file is a single merged line stream in a **meaningful order**: conditions
first, turns in between, outcome last — "so anyone opening the file learns the
conditions before the turns, and the outcome reads as an ending rather than surfacing
in the middle of one seat's play".

1. **`type:"match"` — the conditions**, written as the first line: match id, start
   stamp, the shared system-prompt template (once, verbatim), and the settings that
   change what a result *means* — seed, map size, difficulty, simulation speed, tempo
   (real-time vs turn-based and the answer window), the wonder hold, the prompt
   version, any resource boost — and the *machine* (the serving stack when the
   endpoint said one, the hardware string in the header, the operator's own label per
   player), plus the players (id, seat, civilization, model, name, and a
   **whitelisted** per-seat settings block: one named field the caller decides what
   is publishable in, so nothing auth- or endpoint-shaped arrives by accident).
   Without it, a folder of transcripts is a folder of numbers with no way to tell
   which ran at 2× or turn-based, or on which machine — cheap to record now,
   unrecoverable later.
2. **Turn lines** — one per turn a seat took: the turn number, the seat's identity
   (civ, seat, model, name), the wall-clock stamp, the full state snapshot it was
   shown, its reply (content and reasoning, or tool calls), the parsed fields (the
   commands; in the older form, objective and plan — the plan is recorded only when
   the model *rewrote* it), the provider's usage (token counts, plus the raw usage in
   a form that reveals no endpoint or key — §5.3), the latencies, *how* it answered
   (tool call vs inline content — it changes what a number means; on pipelined seats,
   which lane asked, which round it was asked in, and how the answer arrived), and
   `harnessResult`: the numbered outcome lines of that turn.
   - **A turn line is held *open* until the harness's answer is stamped on it.** The
     answer only exists once the action has executed; queueing the line at record time
     would let a flush land in the gap and write a result-less line that no later
     amend can reach.
   - **Pipelined seats (more than one in-flight request) key the open slot per lane**,
     or whichever request records last would seal the first and the result would land
     on the wrong line. A single-lane seat behaves exactly as before.
3. **Marker lines** — carry a `type` and are **not** turns, so they never inflate the
   decision count (a skipped round must stay distinguishable from a turn that
   happened). The shipped ones: `round_missed` (the seat *was* asked, the round
   resolved without it — the line that makes a huge gap between two of a seat's
   snapshots readable as "asked, missed" rather than "thought for fifteen
   minutes"), `request_failed` (a model request died; its category is recorded),
   `request_cancelled` (a cancellation, with its reason — e.g. the harness called it
   off), and `final_word` (each seat's closing debrief at the end: the outcome, the
   text, and a final full snapshot). The format is open-ended: any line with a type
   other than match/results/timeline is a marker, and the reader renders an unknown
   kind raw. A marker seals every open turn of that seat first, so it never jumps
   ahead of the turn it follows.
4. **The tail — `type:"results"` and `type:"timeline"`**, appended at a *real* match
   end: the outcome, the conditions restated (seed, difficulty, build, prompt
   version) so the file's two ends agree, the ranking with per-seat metrics —
   including the evaluation (§4.5) and the per-seat behaviour tags — and the
   economy curve with its event arrays (age-ups, wonder built/lost, resource
   exhaustion). Written once, never on a mid-match snapshot — "a second results line
   would leave a reader guessing which one counts". One file then answers
   everything: the conditions, every exchange, the outcome, the graph.

### 5.3 Redaction

- **No key, no endpoint, no cost, ever.** The endpoint is never stored in the first
  place (the published per-seat settings are an explicit whitelist). Usage keeps token
  accounting — prompt/completion/total, provider detail fields — and drops the money
  fields (`cost`, `cost_details`, `total_cost`, `is_byok`, native-statistics blocks)
  across every provider dialect.
- **Values are replaced, not guessed.** Any settings value whose *key name* smells of
  a credential (key, token, secret, password, auth, bearer, credential) is replaced —
  not dropped — unless the name is on a short whitelist of budget-like parameters;
  the value's type is never consulted, because a self-hosted key can be a plain
  number. A parameter that appears later is therefore *missing from the record*,
  rather than a credential leaking into it.
- The redaction filter **copies, never mutates** the provider payload, and it is
  applied *at artifact time* — which is what keeps the shipped sample transcripts clean
  (an audit asserts no shipped turn still prices a turn, while their usage is intact).
- **Results files get shared.** The exported per-seat settings are self-describing on
  purpose — provider, the *public* model id (filesystem-looking paths stripped),
  context budget, language — and deliberately carry no endpoint and no key.

### 5.4 Versioning

- **The state schema is checked against the *latest* shipped transcript sample on
  every test run.** Older samples are deliberately *not* held to today's schema —
  history is not pinned to the present (the oldest sample genuinely carries field
  shapes the current schema has since renamed away, e.g. the old on-map node counts
  and a folded-in population; that drift is legitimate, and the pin is on the newest
  by design — "a contract verified against one old file only is not verified").
- **The prompt version** (a versioned string stamped on the start screen) is recorded
  in every match header; when it bumps, seat prompts that merely copied the previous
  template are re-derived, genuine edits survive.
- **The build number** the UI shows is derived from the main script's cache-busting
  tag; a shipped script whose bytes change without its tag moving fails the push job.
  So "which build produced this result" is a question with a written answer.

### 5.5 Replay: reading a match back

The analyzer turns a finished transcript into something you can scrub: the map with a
playhead, a list of *every turn every seat took*, and for each one what that model was
told, what it decided, why it said it decided that, and what the harness answered.

- **It renders *only* what the file attests to.** No interpolation between snapshots:
  they arrive 8 to 900 seconds apart depending on the seat, and units move ~3
  world-units per second, so a smooth animation would be inventing up to hundreds of
  units of travel per unit per frame. A frame is a moment the transcript vouches for,
  and **the gaps are left visible because they are part of what happened** — a seat that
  was asked twelve times while another answered once is the story, not a rendering
  defect to smooth over.
- **Tolerant on purpose.** A transcript can be truncated mid-write; a bad line is
  counted and skipped, never fatal. An interrupted match with no results/timeline tail
  is a normal thing to open, not an error.
- **One clock for everything.** A turn's time is the match clock inside its state;
  markers carry theirs at the top level; both measure from the timeline's origin, so
  they interleave without conversion. The wall-clock stamp is the tie-break (two
  events in the same second keep the order they happened in). A transcript written
  before the match clock existed still opens: it falls back to the wall-clock stamp,
  offset from the first record so the axis starts at zero.
- **The board is reconstructed from the seed** — the same generator that made the
  original map — so replay needs no second download. The node index is a *first-seen
  union across snapshots*: the per-snapshot nearest-node lists are capped, so no single
  snapshot holds everything a seat knew, but the union does. A node's *disappearance*
  says nothing — it may have been emptied, or simply fallen out of the nearest-N
  window — so **absence is never read as death**; the board says "discovered by now".
- **Fog in replay.** The default is the *union* of all seats — a single seat's fog
  blacks out most of the map for reasons the reader cannot yet infer, and it looks like
  a rendering fault rather than one model's ignorance. One chip puts the reader in one
  seat's own view, at which point the fog "stops being confusing and starts being the
  interesting part". The camera stays where the reader left it (a camera that re-aims
  on every step makes the board lurch while they are still working out what they are
  looking at).
- **Chapters** — what a reader would want to jump to, derived from what the file
  already computed: age-ups, wonders built/lost, resources exhausted, missed rounds,
  battles. A battle spans many turns, so runs of the same kind for the same seat
  collapse into the first (one entry per turn would bury everything else).
- **Workspace**: per-seat and free-text filters over the whole history, saved views
  (corrupt-resilient, clamped), playback that follows the filtered entries one step per
  second and stops at the end (scrubbing stops playback, can still reach filter-hidden
  entries, and clamps to the recording; a hidden tab *stops analyzer playback* — the
  opposite of the live sim, which keeps running), and a camera dock with the same
  bounds as the live game.
- **Trust boundary.** A hostile transcript must still *parse* ("the fix is escaping,
  not rejecting data") and render as *text*: the header line ends up with zero element
  children, a hostile turn number or `<b onmouseover>` in a result row creates no
  handler, nothing executes on open or hover, and the run produces zero page errors.
- **Direct links** resolve a match id through the shipped sample catalogue — *never*
  treated as a path. The catalogue is the provenance record for bundled matches: file,
  id, date, duration, turns, outcome, seed, difficulty, tempo, prompt version, build,
  winner, players, and which is the default.

### 5.6 What a transcript cannot show

Stated for honesty: a snapshot holds what a seat *knew at that moment*. It does not
contain what the seat's units did in the gaps (they were running on the sim clock,
unobserved), what a seat's provider was doing while in flight, or anything about a
request that never reached a server. The recording layer's job is to make those gaps
*visible as gaps* — the missed-round marker, the `lateByRounds` stamp, the cancelled-
request marker — never to fill them.

---

## 6. The spectator surface

### 6.1 Modes, and the gate that decides which ones exist

Four user-facing surfaces sit behind one **host gate**:

| Surface | What it is |
|---|---|
| **Arena** | 2–4 model seats, human spectating + coaching. No human control of the game. |
| **Campaign** | The human is one seat (always seat 0), 1–5 opponents. §7. |
| **Analyze** | Open a finished transcript (own or shipped) and read the match back. §5. |
| **Showcase** | A playable offline preview: pick civilization / terrain theme / age / time of day, play against one opponent on a fixed-seed map. |

The gate is about *where the app is served from*, not about who is using it:

- **Private host** (the file protocol; loopback and private address ranges; a
  single-label hostname) → the full app: start screen with all modes.
- **Public host** → a *viewer*: the body is marked demo-only and boot opens the
  analyzer on a shipped sample (or on `?match=<id>`, resolved through the catalogue,
  never as a path). The four credential-bearing screens cannot be activated by direct
  call.
- **`?full=1` makes the gate *conditional*, not disabled** — it is pinned that on a
  public host all gated screens reopen when it is present, and stay closed without it.
  The stated position: a public host serving a private-IP page is an accepted risk;
  keys still cannot be read back through the viewer.

Boot is defensive: no WebGL at all → a dismissible error box, the menus stay up; a
rendering context lost mid-session → a dismissible overlay while **the simulation keeps
running on its own clock** (§11). The start screen stamps the two version facts —
`Build <script tag>` and `Prompt <version string>` — and an update check (strictly
newer builds only, parsed from the upstream main script's tag, 15-minute TTL, all
failures silent including a corrupt cache that can never announce an update) offers a
selectable, copyable update command with a clipboard fallback.

### 6.2 Setup and the model library

Arena and campaign share one setup screen:

- **Count**: arena 2–4 participants (default 4, clamped); campaign 1–5 opponents
  (default 3) plus the human's own civilization. Slots are always a fixed pool.
- **Difficulty** (global, persisted): a *resource modifier that also picks the visual
  theme* — easy/summer (food ×2.0), medium/winter (food ×0.5), hard/desert (food
  ×0.25, wood ×0.25, stone ×0.5; gold never changes). The rendered table reads the
  *same table* the generator uses.
- **Seed**: free text, optional, separate per mode; a blank field *mints* a seed
  rather than running unseeded.
- **Tempo**: real-time, or turn-based — "all models read the same state
  simultaneously; when the last answer lands, all turns execute together; the game
  keeps running while models think, a round lasts as long as the slowest answer".
  The per-round answer window is a user input clamped to 10 s – 900 s (default 90)
  and published to the models as `clock.secondsToAnswer`.
- **Slots**: each is a civilization + a *controller* — the rule-based brain (`ki`) or
  a model from the library — plus, for model slots, a per-slot system-prompt box
  (diff-against-template, "reset to template", a "modified" badge). The shared
  template has placeholders for the per-match facts and is **versioned**: a version
  bump replaces the template, re-derives slot prompts that merely copied the old one,
  and keeps genuine edits.
- **Validation at start**: a slot whose pointed-at model has no endpoint becomes
  rule-based; a legitimate 0 temperature is kept (not nulled).

The **model library** is the one place an endpoint and its credentials live:

- Per model: name, endpoint (bare `host:port` for private addresses gets a scheme
  added automatically), provider (`auto` or one of the four dialects; auto is a URL
  heuristic), model id, authentication (none / bearer key / named headers / basic /
  OAuth client-credentials), sampling and output parameters (blank = "not sent,
  provider default — here is the default", per provider), a reasoning control
  (effort word, on/off, or token budget, per provider), a raw-body merge field with
  **protected keys** (the request's message-shaped fields are rejected, so the merge
  can never become a second channel into the prompt), and per-parameter "refused by
  this endpoint" tags learned from live rejections.
- **Test connection** (9 s): the provider's model-listing endpoint (Ollama's own
  listing for Ollama); a 404 on a bare local endpoint retries once with the `/v1`
  path — and the *verified* fallback is saved into the library before any further
  probing, while a failed one never is; 401/403 is "the endpoint exists, the
  credential was refused"; 429/500 are not retried (a dead endpoint should fail fast);
  a re-probe with an opaque request distinguishes "the browser blocked the response"
  (CORS) from "unreachable". On success: an empty model id adopts the first listed
  one; an empty context budget is filled with the smaller of the default and what the
  endpoint reports; a best-effort capability probe follows (stack, tool support,
  reasoning mode) — and **a failed probe is not a finding**: the capabilities line is
  only stored when a stack was identified.
- **Context budget**: a default, per-model known-window table (the endpoint's own
  answer wins, from many field spellings across stacks), and a "Max" button that
  fills the model's real window. The budget also hard-caps what is sent.
- **Export/import**: a JSON catalogue download — with a plain-text warning if any
  model carries a secret — and an import that replaces the catalogue, re-keys ids,
  remaps slot controllers, and re-derives template-equal prompts. The learned
  per-endpoint rejection tags are deliberately **excluded** from export: "an
  observation about one endpoint on one machine".
- **Storage is the browser's local storage, in plain text** — flagged as a build
  constraint in §11, not a design law.

### 6.3 The live dashboard

While a match runs, the spectator surface is:

- **A status bar**: the match clock, `alive N/M`, the *leading wonder-hold* progress
  (the 600 s race, with a live countdown when one is close), the speed control, an
  action-camera toggle, a mid-match snapshot, and end.
- **The speed control**: 1× / 1.5× / 2× / 4× and pause. **0 is a pause request, not a
  speed.** While *any* wonder stands, the control is locked to 1× (the hold is 600 s
  of real game time, §3.1).
- **The leaderboard** (refreshed every 1.5 s, skipped while the tab is hidden):
  cards sorted alive-first, then by a **power** score (age ×220 + military ×45 +
  workers ×16 + buildings ×32 + resources ×0.04, ×0.15 without a town center). A card:
  rank, seat badge, civ, age, a status tag (defeated / paused / thinking), the stat
  rows, the model's name, a pause control, and an advice box. Clicking a card flies
  the camera to that seat's home. Its flyout is an **achievements panel**: researched
  techs (descriptions as tips), the current research with a live percentage, unit
  counts by class, buildings (under-construction marked), and the resource-node
  knowledge *as this seat holds it* — a model seat: the snapshot it was last handed
  (zeros shown); an AI seat: its own scouted counts.
- **Advice** is one-shot (§4.4's boundary applies to spectators too): ≤400 characters
  queued onto the seat; a paused seat's queue still grows ("advice survives a pause");
  on the seat's *next* turn the whole queue is appended after the state, tagged "weigh
  it, you still decide", and cleared. It is tagged in the prompt, never a separate
  message, never auto-weighted.
- **Per-seat pause**: pausing asks first, because **a paused model skips turns — a
  real disadvantage** (useful when a model has exhausted its quota); resuming is
  instant; the pause/resume are written as *control* entries in the decision log, not
  as model moves; in turn-based mode a mid-round pause is honored at the round
  boundary.
- **The decision log** (1 s tick; the panel rebuilds only when its signature changes):
  each entry is the action, a detail (localized unit/building/tech/resource names, or
  coordinates), the *model's own quoted reason*, and the rejection flags. A failed
  entry carries a red "rejected" tag plus a warning line in the **model's own
  language** (an English model sees the raw harness string it received, verbatim — no
  translated table can drift). Entries are **clickable into the in-match transcript
  viewer** at that turn when an exchange exists behind them. In *collapsed* mode only
  each seat's latest turn survives — "a fast seat must not displace a slower seat's
  latest response". Filters: per-player chips plus free text over every field of every
  entry; a render cap reports visible/total; scroll anchoring keeps a pinned entry in
  place.
- **The per-model transcript viewer**: one re-targetable panel, paged Older/Newer/
  Latest over the recorder's ring — a small page, never a full reply's worth of DOM.
- **The minimap** doubles as the camera dock: the navigation controls (overview /
  focus-on-selection / zoom / rotate / graphics / a "hand" mode in campaign) live
  *inside the minimap frame*; click jumps the camera (a manual camera move always
  outranks the action camera); right-click orders the selected units. Per-seat fog
  knobs (one per seat, in the gutter beside it) switch the map's overlay between the
  **union of all seats** (the default) and one seat's own exploration — a manual
  choice persists until the next shot-subject change, so the automatic follow never
  stomps a deliberate one.
- **Final words**: at match end each model seat is asked one closing statement (one
  round trip each); a progress card counts the answers as they land (e.g. `n/12`), so a
  stopped board does not read as a hang. All-rule-based matches show nothing.

### 6.4 The action camera (director)

The spectator camera director is **camera-only, with zero gameplay effect** (the
tests pin this: its only outputs are a camera pose and a coverage record).

- **Evaluation** runs on a 100 ms tick over a fixed catalogue of ~14 shot types
  (brawl, imminent, point-of-view, contact, wonder, follow, march, scout, site,
  economy, establish, compare, overview, selection) with base scores (from "decisive
  fight 110+" down to "establishing shot 26"), repeat penalties over the last six
  shots, and a novelty bonus per seat.
- **The priority ladder** is the design: a *decisive siege* (a wonder or a town
  center within twice its remaining damage of falling) can interrupt *anything* —
  "the whole point of the priority system"; active combat of sufficient importance can
  interrupt the same kind or lower, after a combat hold (800 ms at 1×, shrinking with
  sim speed to a 300 ms floor; a near-fall interrupts the hold); *imminent* can
  interrupt non-combat; everything else ranks last.
- **Imminence is a prediction**: a threat with an estimated time-to-attack-range of at
  most ~2 s qualifies, where the estimate accounts for range, the target's radius,
  march speed, target movement, and the *effective* sim speed ("a 20-unit gap closes at
  ~0.05 u/s at 1× but ~0.2 u/s at 4× — only at 4× is the contact imminent"); an
  attack-*move* with no target in range is not yet imminent ("an attack was merely
  ordered"). A new hit on a continuing fight re-triggers evaluation against what is on
  screen *now*; a 1.5 s window of recent damage keeps a fight "hot"; the aftermath of a
  final strike is held for 2000 ms of *viewer* time, independent of sim speed.
- **Cuts are eased, never lurching**: the pose eases toward the director's target each
  frame; a 400 ms settle follows a cut before tracking begins ("moving the instant we
  cut is how a cut turns into a lurch"); shots have a 1.5 s minimum; yaw snaps to
  eight compass bearings; a pan reverses direction only when the *scene* changes; each
  shot carries a slow push.
- **Manual follow is authoritative**: any manual camera operation (e.g. the wheel)
  stops the director's cuts and the camera stays where the user leaves it; a
  timelapse multiplier (1–32×) scales shot durations, but *never* the urgent-combat
  delays.
- **Coverage is measured, not asserted**: over the last 200 ended encounters, the
  first-hit → first-covered latency (both combatants inside the central 90% of the
  viewport) and the count of *stale combat cuts* (cuts to a fight that never landed on
  screen). A single camera cannot cover every simultaneous fight — by design.

### 6.5 The player HUD and the results screen

In campaign the human gets the player HUD: resource counts, population, age, the
production progress bar, the **Build · Train · Research · Upgrade** action bar, the
selection card (errors and confirmations are *rendered into it*), the opponents bar
(per rival: civ, controller, age, and an intel line — or "unscouted" when nothing of
theirs is revealed), the wonder countdown (urgent styling as the 600 s hold runs
down), and the minimap + camera dock.

The **results screen** ends a match: the winner (or, in a mid-match *snapshot* mode,
the current leader — no save or menu buttons while the game runs; ending the match
re-renders it final), the reason, the duration, the seat count, and a card per seat:

- rank, controller, civilization, the ending **power** score, and the **0–100
  strategy-soundness bar** (the §4.5 composite, with its weights visible);
- **behavior tags** derived from the recorded stats (fast/slow, timeouts, format
  loyal/issues, invents actions, efficient / many failures, rounds missed, went
  silent, versatile/monotonous, aggressive / economy-focused);
- the metrics: response times with an early-vs-late comparison (a slowdown row when
  the late median is ≥3× the early), decisions/answered/missed, commands per turn,
  the success rate (contended attempts excluded from the denominator; **null, not
  zero, when nothing was judged**), format fidelity, the reason rate, tokens with the
  prompt/completion split, the error total broken down by *kind* (timeout, network,
  parse, cut, no-action, invalid, rejected, context overflow), lane rescue counts for
  pipelined seats, the top actions, and the final word;
- the end state (age, counts, resources, defeated) and a legend;
- the actions: new match, **save the results** (a markdown file — self-describing,
  secret-free, §5.3), **save the transcripts**, main menu (which purges the
  recorder).

### 6.6 Sound

The audio layer is a *spectator surface of its own* — fully procedural (no
recordings, no music, no voices), with its own random source and its own wall clock:
**it never consumes gameplay randomness and never changes simulation state**; a device
failure mutes it without stopping play; it starts **muted** on every load (the audio
context is not created before a user gesture), with persistent master/ambience/effects
levels and a mute that survives internal navigation.

- **Spatial model**: an audible radius derived from the camera (farther out, wider
  hearing), a gain that falls off with distance *and* zoom, a suppression floor (below
  it, nothing), a pan clamp. **Visibility is the player's gate**: a *player* hears a
  sound only if its position is *currently* visible (fog "seen now", not "seen
  before"); the **spectator** hears everything from living entities. A death removes a
  unit's voice.
- **Budget**: 14 concurrent voices (12 world + 2 reserved for notifications), 18
  world-starts in the past second, per-unit and per-cell cooldowns, and group caps for
  footfalls and worker activity.
- **The catalogue** (why sounds are, or are not, audible is documented and tested):
  footsteps whose *cadence* scales with sim speed (1×/1.5×/2× at 4× too) while pitch
  never does; working sounds for workers who are *actually working* (chopping,
  harvesting, mining, building — walking and fighting workers are silent); combat
  (bow/crossbow on projectile spawn, muffled unit hits, steel for swords, dull stone on
  buildings); accepted commands (a small bell; attack and harvest use a slightly
  higher variant); completions (a short procedural horn with baked-in echo taps for
  building / training / research / age-up / healing); match **fanfares** — start,
  elimination (one per seat), victory, defeat, wonder-warning at 60/30/10 s of hold
  remaining, building lost — where a *completion is a global notification with no
  distance fade* and the spectator hears its own seat's only when that seat is on
  camera; and continuous ambience (seasonal wind, campfire crackle).
- **Diagnostics and captions**: the engine reports what it played, what it suppressed
  and why, and any last error — so "the match is quiet" can be told from "the mix is
  wrong"; spectator-only captions appear only for a horn that *actually played* with
  its sliders above zero.

---

## 7. Campaign: human play

The same game, with the human as one seat.

- **The human is always seat 0**; the opponents are 1–5, each a configured model or
  the rule-based brain; the difficulty picks one of the three maps (and, with it, the
  visual theme — §8.4); the shared prompt template also applies to opponent model
  slots, which may override it.
- **The fallback is the campaign's safety rule** (§4.6's rule, in the player context):
  a controller whose endpoint is unreachable for two consecutive requests is *demoted*
  — its model controller is retired, the rule-based brain drives the seat from then on,
  a `fallback_rule_based` marker is logged, the opponents bar refreshes ("the player
  still faces a real opponent"), and **the model itself is told it was relieved** —
  "or its next turn arrives as a surprise". In arena matches no demotion ever happens
  (the failures are part of what is being measured).

**Human control** is a pointer model with one function that decides what a click means:

- *Select*: left click chooses the nearest of the player's own units (a unit always
  wins over a building at the same spot; clicking one of the player's own buildings
  selects it; empty ground deselects). Left-drag is a box select, in screen space — a
  unit is in the box when its torso-height projection is inside, which holds under any
  camera rotation.
- *Order*: right click issues exactly one order — a move, or an attack when it lands
  on an enemy. Right-*drag* pans instead, even one that returns to its start point (a
  small radial threshold, shared by both drag handlers, is the line between them).
  A right double-click (a short window, same selection) issues one immediate order
  with no formation step; the guard behavior stays active.
- *Build/repair*: workers right-clicked onto one of the player's own buildings that is
  under construction or damaged finish or repair it.
- *Navigate*: keyboard panning; middle-drag rotates (a bounded tilt range) and tilts;
  wheel zoom; the minimap jumps the camera; a "hand" tool turns left-drag into
  navigation while keeping single-click selection; clicking near the screen edge nudges
  the camera toward the action.
- *Touch*: tap selects; a one-finger drag pans in both modes and *never becomes a
  click or order on release*; a stationary hold arms an order, committed on release;
  dragging after the hold, or a second finger, cancels the pending command (pinch then
  zooms; a two-finger twist rotates). Gestures belong to the renderer, which forwards
  only completed taps and holds.

**Order priority** (the one function that resolves an ambiguous click): an own
building (workers go to build/repair it) > the nearest *eligible* enemy (eligibility
includes the sight gate — the undiscovered cannot be attacked) > a resource node
(workers go to harvest) > plain movement. The right-click's expanded hit areas (a few
world units of grace around small units, more around buildings) exist for usability,
but they must never let a *nearby* object steal a more direct click.

---

## 8. Civilization content

### 8.1 The four civilizations

Four, each a package of a bonus, unique units, a wonder, and a complete tech tree,
over a shared core:

| | Egypt | Greece | Persia | Yamato |
|---|---|---|---|---|
| **Bonus** | agriculture +25% harvest, mining +25% stone | — (its tree is the identity) | +20% carried per trip | all tech costs ×0.7 |
| **Identity** | worker economy | infantry + the state | the cavalry *is* the army | cheap, fast, everything +2 |
| **Unique units** | fast priest; slinger; horse carriage (its cavalry line) | hoplite; phalanx (strong vs cavalry) | archer/cavalry overrides (underpriced); Kataphrakt | samurai |
| **Wonder** | the pyramid | the akropolis | the fire temple | the shrine |
| **Tree character** | the only civ with worker-economy techs | no worker techs; falx, philosophy, democracy, phalanx armor | cavalry training/armor, immortals, siege; no infantry techs | bushido, speed, armor, lamellar |

Research hosts: the stone-era techs at the town center, the later gates (academy,
horseback) at a neolithic town center, everything deeper at the *academy* (it was
renamed from "market" because models had been inferring trade from the name; the old
id still resolves *recorded transcripts only*), healing at the temple. One research at
a time per seat; durations of a few tens of seconds; effects are the standard kinds —
stat boosts, unlock a building, unlock a unit, shorten a production time.

### 8.2 The age ladder, and what advances with it

- The ladder is **`stone → neolithic → bronze → iron`**, researched at the town center
  at a cost from one shared table (the single source of truth every consumer reads:
  the human menu, the rule-based brain, the model harness, and the state schema).
  The upgrade takes twice the base research time.
- **A free, silent re-typing of the field army** accompanies each advance (the
  "veteran upgrade"): declared per unit type, one step per age, forward only —
  militia → (bronze) warrior → (iron) champion; scout cavalry → (iron) cavalry →
  (iron) heavy cavalry; archer → (iron) crossbowman. Only *standard* units ride the
  path; civ-unique units are never promoted. **Nothing model-facing mentions it** —
  a free upgrade the participant is never told about (and it is not free in the same
  way for every seat: the civs whose unique units carry standard ids get their
  upgraded, the others don't).
- **Buildings morph at the same moment**: every non-wonder building of the owner is
  re-scaled for the new age — max health ×1.5 per age (rounded, civ multipliers on top,
  e.g. 1.5 and 1.3), the tower's firepower re-read from its per-age table, the mesh
  rebuilt for the new epoch, the current damage ratio preserved through the rescale.
  **Wonders are exempt from all of it** — a wonder's health is its flat value, and the
  wonder is the win condition, so its numbers are a constant.
- The trainable roster of each building per age is a declared table (e.g. the barracks
  fields militia from stone, adds warrior at bronze, champion at iron; the archery
  range fields the archer from neolithic, crossbowman and elite archer at iron), with
  civ uniques appended where their tier is reached and civ exclusions removing shared
  entries (two civs field no standard cavalry line at all).

### 8.3 The shared roster and the combat rule

Eleven shared unit types (worker, militia, warrior, champion, archer, crossbowman,
elite archer, scout cavalry, cavalry, heavy cavalry, priest) with declared cost,
health, speed, attack, range; the priest is a *support* unit — it never attacks, and
every combat sweep skips support units.

The **counter rule** is a pure multiplier function of (attacker class, defender
class): a hard counter triangle of ×1.5 (cavalry > ranged > infantry > cavalry) and
×0.75 in reverse, everything else ×1.0; against buildings: infantry ×1.5, cavalry ×1.0,
ranged ×0.5 (and workers/support ×0.5). It is *a rule of the game* — but **it is
disclosed nowhere to a player**; whether the model should be told is a maintainer
judgement the design deliberately leaves open (§13).

Two roster invariants are pinned by test: a re-typing table can never promote a unit
into one that no building can produce, and a civ-unique unit with no host building is
*unreachable, not upgradable*.

### 8.4 The building table, and the difficulty presets

The shared structures, with cost (food/wood/stone/gold), health, and build time: town
center 100/100/100/100 — 1000 HP, 15 s, +10 population, trains workers and researches;
house 30/20 — 300, 5 s, +5; farm 50/50 — 400, 8 s; barracks 50/150 — 800, 15 s;
stable 100/100/0/50 — 700, 15 s (neolithic); archery range 50/100/50 — 600, 12 s
(neolithic); academy 100/100/100/50 — 700, 15 s (neolithic); temple
100/100/150/100 — 800, 20 s (bronze); tower 50/50/100 — 600, 12 s, with per-age
firepower (2/3/4/5 projectiles, attack 10/12/15/20, a fixed long range — unit range
bonuses cap at the tower's). The **wonder** is a single shared cost vector
(4500/4500/4000/2500 — "one shared vector by design"), iron age, ~60 s, and a flat
1500 HP.

**Population** is computed in one place: 10 per living town center + 5 per house,
hard-capped at 100; losing a building removes its contribution; training is refused at
the cap (the state names each blocked unit), and a seat with no town center and no
house has cap zero — it can afford everything and field nothing.

**Difficulty** (the campaign's map pick; §6.2) is a resource multiplier on the
abundant types (easy: food ×2.0; medium: food ×0.5; hard: food ×0.25, wood ×0.25,
stone ×0.5 — gold never changes) that *also* selects the visual theme (summer /
winter / desert). A theme changes the palette, tree style, grass coverage, the wind
audio, the sky colors, and the day/night *schedule* — **never the rules**, apart from
the multipliers above.

---

## 9. Language

Three independent language dimensions, deliberately never conflated:

1. **The UI language** — one of four (English, German, Spanish, simplified
   Chinese), persisted, chosen on the start/setup/library screens. It re-renders
   *every* interface panel (not just the static tagged nodes) and updates the document
   language. The dictionary is a flat key table per language with placeholder
   interpolation and an English-then-key fallback.
2. **The game content language** — the *data files carry their source strings in
   German*; translation looks them up by the German string itself, falling back to the
   source when a language lacks the entry. A rebuild that changes the source language
   changes this table's keying — stated here so the decision is visible.
3. **Each model's language** — a per-seat setting, *independent of the UI*, with its
   own per-model picker. It appends a language directive to that seat's system prompt
   ("think and write ALL natural-language text — especially every reason field — in
   German (Deutsch). BUT keep the response a valid JSON object and keep all JSON keys,
   action names and enum values EXACTLY as specified (in English)"), and translates the
   civ/bonus strings the prompt carries into that language (the civ is passed as its
   id, so no source-language text leaks in).

**What is never translated, in any of the three:** JSON keys, action names, enum
values.

The *outcome* text shown in the decision log for a rejected or failed entry is
rendered **in that entry's model language** while the headlines around it stay in the
UI language — and the German/Spanish/Chinese tables alone exist for it: an English
model sees the raw harness string it actually received, so no translated table can
drift from the English one. Key parity (identical, non-empty key sets) across the
four UI languages is pinned by test.

---

## 10. Persistence, configuration, and versioning

**What the current build stores in browser local storage** — flagged as a *build
constraint* (§11.3), not a design law, with the design-level note that each is either
preference (fine to keep wherever) or secret (a rebuild must decide what happens to
it):

| Stored | What | Design level |
|---|---|---|
| The model catalogue | endpoints, credentials (plain text — warned at export), models, parameters, per-endpoint rejection tags (local only), sort order (a view key, not part of export) | **secret** — the one place credentials live |
| Arena / campaign config | counts, seeds, slots, civs, per-seat prompt overrides, the shared template + its version | preference |
| UI language, difficulty, view preferences (corrupt-resilient, clamped), audio levels | — | preference |
| Graphics quality | written on change, **never read at boot** (boot is always the default tier; the in-page change is what takes effect) — pinned, so a stale saved value can't silently downgrade a fresh session | preference |
| Update-check cache | 15-minute TTL; all failures silent; a corrupt cache can never announce | preference |

Plus the **transcripts themselves**, whose lifetime is exactly one match (§5.1):
offered for download at the end, wiped at the next start, nothing accumulated behind
the user's back.

**The version surface** (what a rebuild must keep as *one* coherent story):

- the **build tag** on the main script (the on-screen "Build N"; a shipped byte change
  without its tag moving fails the push job);
- the **prompt version** string (the on-screen "Prompt agents-rule-vNNN"; recorded in
  every match header; a bump re-derives template-copied slot prompts);
- the **state schema**, checked against the *latest* shipped sample on every test run,
  with older samples treated as history;
- the **age ladder's 26 spellings, pinned from five directions** (the constant, the
  rule brain's step function, the shipped content's requirements, the schema's enum,
  and two reachability invariants) — the current build refuses a shared constant on
  purpose (most of its test harnesses never load the game's tables at all, so a
  shared reference would be a fifth copy with different failure modes; the realistic
  failure is a fifth age added in one place only, which the spell-check catches). A
  rebuild is free to choose one source of truth with a pin — the *requirement* is
  that the ladder cannot disagree with itself in any consumer.

---

## 11. Non-functional requirements

Each item states the *property*; the bracketed **flag** says whether the current
build's way of achieving it is design or technology.

### 11.1 The match must run unwatched

This is the product's headline property, and every subsystem is shaped by it:

- **In a hidden tab.** Browsers stop rendering and clamp page timers for background
  tabs; the current build answers with a worker-driven clock that steps the simulation
  (capped) while the tab is hidden, with rendering paused and the win-condition checks
  still running. *Requirement: the simulation and the models' turns keep going with no
  one looking; the display recovers when the context comes back.*
- **Through a lost rendering context.** The render loop stops *permanently* and
  cleanly (the first loss event is claimed; a lost loop schedules no further frame and
  touches no graphics state), the simulation continues, and the user gets a dismissible
  notice — not a frozen board, not a crash. *Requirement: no graphics failure may stop
  a match or corrupt its record.*
- **At any frame rate.** Every pass that *mutates positions* (unit separation, building
  clearance, the shore clamp) runs on the **simulation clock** — real elapsed time
  sliced into bounded quanta (≤100 ms), never on the render loop — and is capped (3×)
  so a hidden match is refereed *close to* a visible one, not identically and not
  not at all. *Requirement: the outcome of a match must not depend on how many
  frames a particular display happens to paint.*
- **Pause is a real pause** (zero budget → no quanta → no refereeing), and a
  paused *seat* (spectator convenience, model quota exhausted) is distinct from a
  paused *match*.

### 11.2 Rendering as a capability surface

A rebuild may choose any graphics technology; the *contract* it must meet is:

- **Semantic** capabilities — the things a player *acts on* — must be correct and are
  pinned by test: fog states (unseen / explored / visible), selection, building-preview
  validity, health/food bars, ownership (a color *and* a shape, so two same-civ
  players are distinguishable at unit scale), minimap dots and fog, battle pings (a
  fight is readable through fog; the ground is not).
- **Cosmetic** capabilities may degrade: projectiles, hit flashes, dust, halos,
  carried-goods icons, vegetation, water, light and shadow. The quality tiers
  (no shadows / small / large shadow maps) cross-fade with zoom, a failed shadow
  allocation means *no shadows* (the scene renders, flatter), and the shadow target is
  freed on quality change.
- **Grounding is a requirement, not a style**: every unit and building sits on the
  terrain (contact shadows; only admitted opaque geometry casts; no edge-crawl).
- **The camera is locked and dimetric** (a low fixed field of view; free pan, a
  bounded tilt, free yaw, zoom clamped; the look-at point always has ground under
  it), with the *action camera* (§6.4) overriding by eased cuts and **manual
  operation always winning**, and the minimap dock owning both navigation intent and
  the per-seat fog knobs.
- **The atmosphere is a 12-minute wall-clock day/night cycle** (themed phase
  schedules; continuous lighting; night coolest, dawn/dusk warmest) that changes
  *nothing* in the game: "exploration and unit sight never depend on this clock at
  all". Art direction targets the locked camera at a fixed, noon-like light; the
  cycle is a cosmetic overlay over that.
- **Resilience**: the context-identity line is logged *once at boot* (never per
  frame), handles every deployment form of the graphics API (including masked
  vendor strings and no-API-at-all), and never throws on a strange object.

### 11.3 The current stack's constraints (each named for a rebuild to decide)

- **No build step, no bundler, no dependencies**: the page loads plain scripts; the
  *module graph is the reference list in the entry document*, every shipped file is
  referenced exactly once, and a shipped cache-busting tag must be a positive integer
  that moves when the bytes move (the push job enforces it). *Flag: a product claim
  in the README ("runnable straight from a folder, zero dependencies") — a rebuild
  may build; it must then re-decide what the README claims.*
- **Credentials live in the browser's local storage, in plain text**, with an
  explicit warning at export. *Flag: a consequence of client-side-only. A server-side
  harness can store keys where only it can read them; the design-level requirements
  that survive that choice: no key in any artifact, no endpoint in any transcript,
  the redaction filter at the artifact boundary, and the self-describing
  secret-free results file.*
- **The provider layer is shaped by the browser**: no streaming (a full reply is
  awaited; the only keep-alives are the request timeout and the round deadline),
  cross-origin responses require the endpoint to opt in (a CORS-blocked answer is a
  *named, localized failure*, and an opaque re-probe distinguishes "blocked" from
  "unreachable"), one provider dialect needs a browser-only header a server client
  would never send, and the "ask the endpoint once at match start, never store it"
  served-by design exists *because* the browser is the client. *Flag: all four
  lift for a server client; the logical tool surface (12 commands + plan, four
  dialects, one normalization point) is the part that is design.*
- **Persistence is one origin's local storage** (plus an origin-private file
  directory for the in-flight transcripts). *Flag: a rebuild gets durable storage for
  free; the design-level requirements that survive: transcripts are one-match
  lifetime, offered at the end, never accumulated behind the user's back;
  configuration survives navigation within a session.*

### 11.4 Accessibility, input, and the trust boundary

- Dialogs use the platform's native modal mechanism: focus containment, Escape,
  inert background; menus are keyboard-complete (arrows, Home/End, focus restored to
  the opener); the camera toolbar is a real toolbar and clears its pressed state on
  focus-out.
- **Reduced-motion kills interface animation only** — "simulation timing is
  unaffected".
- Transcript and decision surfaces are *plain selectable text* (no canvas text); the
  update command is a read-only, selectable input.
- **Pointer rules are pinned**, not vibes: a drag never double-fires a click; a hold
  commits on release; a gesture cancelled by window blur or an off-canvas release
  leaves no selection, no order, no stale state.
- **The trust boundary is escaping, not rejection**: a hostile model-listing response
  (a model id shaped to open a handler attribute) must survive *verbatim as data* —
  no attribute created, no script run, no truncation — and a hostile transcript file
  must still parse and render as text, with zero page errors. The gate (§6.1) is
  conditional (`?full=1` reopens what a public host hides).

### 11.5 The test philosophy (the part of "quality" that a rebuild inherits)

- **Tests are the contract.** The suite pins the invariants of §12 by *mutation*:
  a single fact gets several independent spellings, pinned from several directions, so
  that a silent drift anywhere is a failing test. The canonical examples: sight has
  one question and one answer (four consumers, one table); the elimination predicate
  is one function shared by three consumers; the age ladder is spelled 26 times and
  pinned five ways; the state schema is checked against the latest sample; the action
  vocabulary is the one table every consumer reads; unknown metrics are null, never
  zero; the redaction boundary holds on every shipped sample.
- **A claimed guard must be verified before it is trusted.** The project's own
  history contains a comment promising a test that does not exist, and a review pass
  that cited code that was never written. The discipline that replaced it: verify a
  claimed test against the *exact symbol*; record unconfirmed findings as
  *unverified* rather than asserting them; and treat a finding as real only once
  executed against the shipped code (a wrongness that only appears "in context"
  requires reading the caller, not the callee).
- **Browser suites are optional by a documented path** (an environment variable
  pointing at an external install) *precisely because* the game must stay runnable
  from a folder — the test policy and the no-build claim are two faces of one
  constraint.

---

## 12. Invariants and contracts

The consolidated acceptance list for a rebuild. Each line is a property the current
build has a test for; "where" names the section that states it.

1. **One question, one answer, one authority.** "Can seat S see point P / unit X
   right now?" has a single table of radii (infantry-class 15, cavalry 22.5,
   buildings 20 / town center 40 / tower 80 / under construction 0, sight tech
   scaling) that *every* consumer reads: the human fog, the minimap overlays, the
   model-facing enemy list, and the auto-acquisition scan. A build under
   construction grants no vision. *(§2.6, §11.5)*
2. **Elimination is one predicate**, shared by the simulation, the harness, and the UI,
   answering "can this seat still train units?" — resolved through *the same building
   table the model is shown* (affordable + age-valid + a population slot free), plus
   the structural clauses (no living non-worker, no affordable military, no town
   center, no worker + the town-center cost). The model-facing state carries only the
   binary `defeated` flag — "no locations, no terrain" — and **no player is ever told
   which clause fired**. *(§2.10)*
3. **Movement has exactly one owner** (the simulation). Every positional refereeing
   pass runs on the sim clock in bounded quanta, capped, and never from the render
   loop; a presentation layer never mutates a recorded state. *(§3.1, §11.1)*
4. **Pause is real; a hidden tab is not.** Zero budget → no quanta; the worker clock
   keeps a hidden match stepping, capping its refereeing, with win conditions always
   running. *(§11.1)*
5. **The age ladder is four, spelled many times, pinned from several directions**;
   no tier list outruns a definition; no promotion path leads to a unit no building
   can produce; iron is terminal. *(§8.2, §10)*
6. **The veteran upgrade is silent**: a single declared path, one step per age,
   forward only, standard units only, never mentioned to a participant. *(§8.2)*
7. **The counter triangle is a rule, never a disclosure**: combat resolves by the
   multiplier table; a model is shown the fight's *report*, never the rule.
   *(§8.3)*
8. **Budgets are format, not judgement**: up to three commands per turn (excess is
   counted, named, and fed back with the rule); the plan is ten steps, never
   auto-executed, and costs no slot; a plan-only turn is a successful plan update; a
   `wait` with no reason is still a turn; silence forfeits. *(§4.1–4.3)*
9. **The harness never plans.** Every line it writes states a rule or a fact — the
   board, the budget, the win conditions, the feedback — never a tactic; the shape of
   a turn is the model's to find, and "a contact was lost" is reported, not
   interpreted. *(§4.3)*
10. **Late answers are recorded, never discarded.** A mid-pipeline answer is taken
    (and its lag counted); the fresher board wins between two live answers (the loser
    is written as a *superseded* record); a lane cut by its own deadline is recorded as
    missed in three places — the seat's next prompt, the spectator log, the transcript
    — and is never hidden. *(§2.11, §5.2)*
11. **Unknown is null, never 0.** An undecidable metric returns null, the score
    renormalizes over what *is* known, the UI prints "—" for unknown against "0%" for
    a measured zero, and exports print the denominator. *(§4.5)*
12. **Redaction at the artifact boundary.** No key, endpoint, or cost in any
    transcript or results file; the filter copies rather than mutates; every shipped
    sample is audited for the property. *(§5.3)*
13. **The schema is a contract.** Checked against the latest shipped sample on every
    test run; older samples are history; the prompt version is recorded in every match
    header; the build tag gates shipped bytes. *(§5.4, §10)*
14. **A seed reproduces the match, not just the island.** Every gameplay random draw
    goes through the seeded generator; the only exempt sites are id mints (identifiers
    that must *not* be reproducible). *(§3.2, §13.1)*
15. **Resource sets are released, not leaked.** A theme change frees the set it
    replaces (the current build: 39 resident textures per change, then 0), through the
    one clear-then-rebuild path. *(§11.2)*
16. **A claimed guard is verified, or parked as unverified.** *(§11.5)*
17. **The sim's per-frame order is part of the contract** (the fixed sequence of
    accounting, AI, battle pruning, the position sub-step, the shore clamp; the match
    start is synchronous and takes exactly one internal step) — a rebuild that reorders
    them reorders the game. *(§11.5)*
18. **Population is computed in one place**; prompt-side fallbacks are paranoia, not
    logic. *(§8.4)*
19. **The public host is a viewer**: the gate is conditional, credential screens are
    unreachable by direct call without the unlock, hostile data is escaped — never
    truncated, never rejected — and nothing executes on open or hover. *(§6.1,
    §11.4)*
20. **Results are self-describing and shareable**: a public model id (no
    filesystem-shaped strings), the stack and settings that produced the result, no
    endpoint, no key. *(§0, §5.3)*

---

## 13. Open questions for the rebuild

Things the current build deliberately left open — or that its technology forces — that
a new stack must *decide*, with the stated context for each:

1. **The second clock.** Five wall-clock reads inside the simulation (a 4 s
   retaliation window, a 10 s "recently damaged" query, battle clumping, a 1 s combat
   multiplier reset, a 150 ms turn budget) make *full* byte-reproducibility depend on
   wall time, not just the seed. The current build ranks this "still open" rather
   than pretending the fix. A rebuild can close it (route everything through the sim
   clock) — at which point "same seed, same match, bit for bit" becomes a claim it can
   make.
2. **Target memory after lost sight** (last-known position, an age, a give-up rule):
   a unit that was seen and then walked into fog is currently "never lost, yet" —
   chased as the crow flies — and the memory refinement was *deliberately not
   implemented* as a side effect of the sight fix. Design decision, not oversight.
3. **The late-answer rejection rule.** The measurements now exist per turn
   (`lateByRounds`) and per seat (`lateAnswers`, `lateAnswerMax`); *whether* an
   answer to a resolved round should ever be dropped is a gameplay decision (dropping
   changes who moves next) parked for the data.
4. **The refereeing cap and the movement owner** are parked as *balance* decisions
   (raising the cap or moving movement is tuning, i.e. a game-balance decision, not a
   bug fix).
5. **Whether to tell the model the counter triangle** — "a README rule, not a prompt
   disclosure"; the design explicitly declines to make the call.
6. **Tunables with stated rationale** (not laws of physics): the 600 s wonder hold,
   the 90 s round default (10 s floor, 900 s ceiling), the 180 s request timeout, the
   damage windows, the 12-minute day.
7. **The stack boundary.** For each item in §11.3, a rebuild decides: no-build /
   zero-dependency / runnable-from-a-folder (a product claim in the README); plain-text
   browser credentials (a security posture); browser-shaped auth and no streaming (a
   provider-layer shape); single-origin storage (a persistence shape). A server-side
   harness answers four of them differently by construction — the spec records the
   *requirements* (no secret in any artifact; the served identity recorded, never the
   endpoint; the match runs unwatched) so the decision is visible rather than
   absorbed.
8. **One source of truth for shared constants.** The current build's deliberate
   anti-pattern — 26 spellings of the ladder pinned from five directions instead of a
   shared constant — exists because most of its test harnesses never load the game's
   tables. A rebuild with one source *and* the pin is strictly better; the requirement
   is that no consumer can disagree with another.
9. **Both tempos stay.** Real-time (latency as a strategic variable) and turn-based
   (judgement without the variable) are two answers to "what are we measuring"; the
   late-answer semantics exist only because of turn-based, and the live-lane machinery
   only because of real-time.
10. **The provider normalization layer.** Four dialects normalized at one point is
    design; *which* dialects, and how far the send-then-learn parameter adaptation
    (retries that drop a refused parameter rather than fail the seat) goes, are
    rebuild decisions.

---

*End of specification. Sections 0–13 state the product, its rules, its agent
protocol, its records, its surfaces, and its invariants; §11.3 and §13 separate the
design from the choices the current technology made for it.*

