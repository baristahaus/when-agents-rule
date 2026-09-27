//! Golden diff: compare this crate's map fingerprint against the line the
//! reference recorder wrote.
//!
//! Usage: `golden-diff <recorded.jsonl>`
//!
//! The recorded file carries one `{"playerId":"__map__","type":"map",...}`
//! line: the seeded resource layout after Town Center clearance, positions in
//! integer millimetres. This binary rebuilds the same map from the line's own
//! seed/difficulty/seats and requires the rebuilt line to be byte-identical —
//! the first gate of the golden-diff port: PRNG + map generation.

use std::env;
use std::process::exit;

fn main() {
    let path = match env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: golden-diff <recorded.jsonl>");
            exit(2);
        }
    };
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("golden-diff: cannot read {path}: {e}");
            exit(2);
        }
    };
    let recorded = match content.lines().find(|l| l.contains("\"type\":\"map\"")) {
        Some(l) => l.trim_end_matches('\n').to_string(),
        None => {
            eprintln!("golden-diff: no map fingerprint line in {path}");
            exit(2);
        }
    };
    let parsed: serde_json::Value = match serde_json::from_str(&recorded) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("golden-diff: map line is not valid JSON: {e}");
            exit(2);
        }
    };
    let seed = parsed.get("seed").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let difficulty = parsed.get("difficulty").and_then(|v| v.as_str()).unwrap_or("easy").to_string();
    let seats = parsed.get("seats").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
    // The terrain's own size: the recorder's headless game runs the default 200,
    // the arena 800. The line carries it; a pre-size line means the recorder
    // predates the field and the map is the 800 arena.
    let size = match parsed.get("size").and_then(|v| v.as_u64()) {
        Some(s) => s as i64,
        None => 800,
    };
    if seed.is_empty() || seats == 0 {
        eprintln!("golden-diff: map line missing seed/seats");
        exit(2);
    }

    let map = war_core::mapgen::build_map(&seed, &difficulty, seats, size);
    let rebuilt = war_core::mapgen::fingerprint_line(&map);

    if rebuilt == recorded {
        println!("map: PASS — {} nodes, {} bytes, byte-identical to the reference", map.resources.len(), rebuilt.len());
        let mut by_type = std::collections::BTreeMap::new();
        for r in &map.resources {
            *by_type.entry(r.r#type.clone()).or_insert(0) += 1;
        }
        for (t, n) in &by_type {
            println!("  {t}: {n}");
        }
        return;
    }

    // Divergence: locate the first differing byte and show context from both sides.
    let cut = rebuilt
        .as_bytes()
        .iter()
        .zip(recorded.as_bytes())
        .position(|(a, b)| a != b)
        .unwrap_or_else(|| rebuilt.len().min(recorded.len()));
    let ctx = |s: &String| {
        let b = s.as_bytes();
        let lo = cut.saturating_sub(40);
        let hi = (cut + 60).min(b.len());
        String::from_utf8_lossy(&b[lo..hi]).into_owned()
    };
    eprintln!("map: FAIL — first difference at byte {cut} of {} (rebuilt) vs {} (recorded)", rebuilt.len(), recorded.len());
    eprintln!("  rebuilt:  …{}…", ctx(&rebuilt));
    eprintln!("  recorded: …{}…", ctx(&recorded));
    let n_reb = rebuilt.matches("t\":\"").count();
    let n_rec = recorded.matches("t\":\"").count();
    if n_reb != n_rec {
        eprintln!("  node count differs: rebuilt={n_reb} recorded={n_rec}");
    }
    exit(1);
}
