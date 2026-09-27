//! The seeded PRNG: the exact hash and mulberry32 step the reference uses
//! (terrain.js `_initRand`, lines 88-101).
//!
//! The state is a signed 32-bit word. Every JS operation in the source is a
//! 32-bit operation, and each is mapped to its wrapping Rust counterpart;
//! `>>>` (logical shift) needs the unsigned reinterpretation because Rust's
//! `>>` on `i32` is arithmetic.

/// One mulberry32 state, seeded from a map seed string.
pub struct Mulberry32 {
    a: i32,
}

impl Mulberry32 {
    /// terrain.js:88-95:
    /// ```js
    /// let h = 1779033703 ^ String(this.seed).length;
    /// for (const ch of String(this.seed)) {
    ///     h = Math.imul(h ^ ch.charCodeAt(0), 3432918353);
    ///     h = (h << 13) | (h >>> 19);
    /// }
    /// let a = (h >>> 0) || 42;
    /// ```
    /// The reference reads `ch.charCodeAt(0)` over a code-point iteration, i.e. the
    /// first UTF-16 unit: a plain unit, or the high surrogate of a pair.
    pub fn from_seed(seed: &str) -> Self {
        let mut h: i32 = 1779033703 ^ (seed.len() as i32);
        for cp in seed.chars() {
            let cp32 = cp as u32;
            let u16 = if cp32 > 0xFFFF { 0xD800 + ((cp32 - 0x10000) >> 10) } else { cp32 };
            h = (h ^ (u16 as i32)).wrapping_mul(3432918353u32 as i32); // Math.imul coerces both args to int32
            let lhs = h.wrapping_shl(13);
            let rhs = ((h as u32).wrapping_shr(19)) as i32; // `h >>> 19`
            h = lhs | rhs;
        }
        let a = h as u32; // `h >>> 0`
        let a = if a == 0 { 42 } else { a }; // `|| 42`
        Mulberry32 { a: a as i32 }
    }

    /// terrain.js:96-100: one draw in [0, 1).
    pub fn next_f64(&mut self) -> f64 {
        self.a = self.a.wrapping_add(0x6D2B79F5);
        let a = self.a;
        let u = a as u32;
        let t1 = (a ^ ((u >> 15) as i32)).wrapping_mul(1 | a); // Math.imul(a ^ (a >>> 15), 1 | a)
        let u7 = t1 as u32;
        let t2 = (t1.wrapping_add((t1 ^ ((u7 >> 7) as i32)).wrapping_mul(61 | t1))) ^ t1; // (t + imul(t ^ (t >>> 7), 61 | t)) ^ t
        let u14 = t2 as u32;
        ((t2 ^ ((u14 >> 14) as i32)) as u32) as f64 / 4294967296.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors generated from the reference: `node` running terrain.js's own
    // `_initRand` for each seed. The i32 is the hash final (`h >>> 0` before the
    // first draw; `|| 42` not triggered for any of these) plus the first 12 draws.
    fn vectors(seed: &str) -> (i32, Vec<f64>) {
        match seed {
            "smoke" => (
                -113379075,
                vec![
                    0.8549525823909789, 0.16367686376906931, 0.6803284124471247,
                    0.1475617482792586, 0.3161956344265491, 0.9671087390743196,
                    0.8535700007341802, 0.4702087021432817, 0.22395839053206146,
                    0.1457628053613007, 0.4706913447007537, 0.07493021921254694,
                ],
            ),
            "abc" => (
                50696745,
                vec![
                    0.8397557286079973, 0.370647334959358, 0.20023633493110538,
                    0.12240628199651837, 0.10869051772169769, 0.9811068617273122,
                    0.5762185680214316, 0.6825795210897923, 0.8241695065516979,
                    0.25729950703680515, 0.2687093496788293, 0.9866319899447262,
                ],
            ),
            "x" => (
                581945123,
                vec![
                    0.47333607729524374, 0.44358906359411776, 0.3202284653671086,
                    0.1284702366683632, 0.5373984773177654, 0.11521552852354944,
                    0.25203532190062106, 0.7060008472763002, 0.35356406425125897,
                    0.5006974330171943, 0.7073167581111193, 0.9520366308279335,
                ],
            ),
            _ => panic!("no vector for {seed}"),
        }
    }

    #[test]
    fn hash_state_matches_reference() {
        for seed in ["smoke", "abc", "x"] {
            let (a, _) = vectors(seed);
            let m = Mulberry32::from_seed(seed);
            assert_eq!(m.a, a, "seed {seed}");
        }
    }

    #[test]
    fn draw_stream_matches_reference() {
        for seed in ["smoke", "abc", "x"] {
            let (_, want) = vectors(seed);
            let mut m = Mulberry32::from_seed(seed);
            for (i, w) in want.iter().enumerate() {
                let got = m.next_f64();
                assert_eq!(
                    got.to_bits(),
                    w.to_bits(),
                    "seed {seed} draw {i}: {got} != {w}"
                );
            }
        }
    }
}
