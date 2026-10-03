//! The deterministic core of When Agents Rule.
//!
//! This crate reimplements the match simulation of the `js/` reference: the
//! seeded PRNG, map generation (fairness scatters plus Town Center clearance),
//! and the initial match state. Every output is pinned against the JSONL the
//! reference recorder (`tools/golden/record.cjs`) writes: the `golden-diff`
//! binary diffs this crate's map fingerprint line against the recorded one, and
//! the state module does the same for the per-seat turn-1 state.
//!
//! Invariants, from the design spec:
//! - A seed reproduces the match: same seed in, byte-identical transcript out.
//! - What is recorded is what is diffed: the fingerprint is the raw data, not a
//!   summary of it.
pub mod data;
pub mod mapgen;
pub mod prng;
pub mod sim;
pub mod state;
