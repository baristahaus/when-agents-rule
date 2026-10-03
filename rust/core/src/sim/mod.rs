//! The live simulation: the match's objects, its sight authority, and the
//! systems that step them.
//!
//! The v2 core's heart (rebuild proposal §4): single-threaded,
//! fixed-timestep, with the rule-based brain *inside* it (spec §4.6), not
//! beside it. What the spec pins, this module keeps: one question, one
//! answer, one authority for sight (§12.1); the elimination predicate read
//! from the same tables the model reads (§12.2); movement with exactly one
//! owner — this module (§12.3).
//!
//! The reference implementation is the oracle for this port: the P0 gate is
//! a byte-identical state sequence against the shipped recorder, so exact
//! numbers and orderings are read from `js/`, and the spec is what they are
//! held to.

pub mod model;
pub mod vision;
