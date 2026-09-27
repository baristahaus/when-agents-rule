//! The turn-1 state, golden-diffed, for all four seats.
//!
//! The reference recorder (`tools/golden/record.cjs`) runs the shipping v1
//! simulation headlessly: a fixed seed, four rule-brain seats, no providers.
//! Its stream is a `match` header line, a `map` fingerprint line, then per
//! beat a world-pulse line and one line per seat, each carrying the full
//! `state` object `buildGameStateJSON` hands that seat. The first such line of
//! a seat is its turn-1 state.
//!
//! `rust/core/tests/goldens/initial-states.jsonl` holds exactly those four
//! lines, extracted verbatim from the recorded run:
//!
//! ```sh
//! jq -c 'select(.state != null and .seat != null and .turn != null)
//!        | {seat, playerId, state}' \
//!    samples/golden/initial/golden-initial.jsonl \
//!   > rust/core/tests/goldens/initial-states.jsonl
//! ```
//!
//! The test rebuilds each of the four states from the header's own seed,
//! difficulty, roster and map size, and requires a deep match. The one field
//! a seed cannot decide is the seat's player id, which the reference mints
//! from `Math.random` (js/ai.js:34) so a reloaded page can never confuse this
//! match's transcript with the last match's; the golden carries the recorded id.

use std::path::Path;

use war_core::data::WorldData;
use war_core::state::{build_initial_state, InitialConfig};

#[test]
fn initial_states_match_recorded_transcript() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    // rust/core -> rust -> repo root.
    let repo = root
        .parent()
        .and_then(|p| p.parent())
        .expect("rust/core is two levels under the repo root");

    let world = WorldData::load();

    let golden_raw = std::fs::read_to_string(root.join("tests/goldens/initial-states.jsonl"))
        .expect("the extracted golden states are committed");
    let golden: Vec<serde_json::Value> = golden_raw
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            serde_json::from_str(l)
                .unwrap_or_else(|e| panic!("golden state line is not valid JSON: {e}"))
        })
        .collect();
    assert_eq!(golden.len(), 4, "four seats, one extracted turn-1 state each");

    // The recorded run the golden came from: header + map line.
    let recorded_raw = std::fs::read_to_string(
        repo.join("samples/golden/initial/golden-initial.jsonl"),
    )
    .expect("the recorded golden match is committed");
    let lines: Vec<&str> = recorded_raw.lines().collect();
    let header: serde_json::Value = lines
        .first()
        .map(|l| serde_json::from_str(l).expect("match header is valid JSON"))
        .expect("the recorded match has a header line");
    let map_line = lines
        .iter()
        .find(|l| l.contains("\"type\":\"map\""))
        .and_then(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .expect("the recorded match has a map fingerprint line");

    let seed = header["seed"].as_str().expect("seed").to_string();
    let difficulty = header["difficulty"].as_str().expect("difficulty").to_string();
    let seats = header["seats"].as_u64().expect("seats") as usize;
    let map_size = map_line["size"].as_u64().expect("map size") as u32;

    let players = header["players"].as_array().expect("players");
    assert_eq!(players.len(), seats);
    let mut by_seat: Vec<&serde_json::Value> = (0..seats).map(|_| &serde_json::Value::Null).collect();
    for p in players {
        by_seat[p["seat"].as_u64().expect("seat") as usize] = p;
    }
    assert!(
        by_seat.iter().all(|p| !p.is_null()),
        "every seat is named in the header"
    );
    let civs: Vec<String> = by_seat
        .iter()
        .map(|p| p["civ"].as_str().expect("civ").to_string())
        .collect();

    for rec in &golden {
        let seat = rec["seat"].as_u64().expect("seat") as usize;
        let player_id = rec["playerId"].as_str().expect("playerId");
        // The golden's id is the header's id for that seat: same minting,
        // same run.
        assert_eq!(
            player_id,
            by_seat[seat]["id"].as_str().expect("header player id"),
            "golden player id disagrees with the recorded header"
        );
        let recorded_state = &rec["state"];
        assert_eq!(
            recorded_state["player"]["civilization"],
            serde_json::Value::String(civs[seat].clone()),
            "golden seat {seat} has an unexpected civ"
        );

        let built = build_initial_state(&InitialConfig {
            world: &world,
            seed: &seed,
            difficulty: &difficulty,
            seats,
            civs: &civs,
            seat,
            player_id,
            map_size,
        });

        if built != *recorded_state {
            let built_str = serde_json::to_string_pretty(&built).unwrap();
            let rec_str = serde_json::to_string_pretty(recorded_state).unwrap();
            eprintln!("--- built (seat {seat}, {}) ---\n{built_str}", civs[seat]);
            eprintln!("--- recorded ---\n{rec_str}");
            panic!("turn-1 state for seat {seat} does not match the recorded transcript");
        }
        eprintln!("seat {seat} ({}): turn-1 state matches the recorded transcript exactly", civs[seat]);
    }
}
