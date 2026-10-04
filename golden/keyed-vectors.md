# The first test of any core

Two keyed draws from the reference `js/simulation/rng.js`, seed `golden`, key `s0:start-workers` —
the numbers a new core must print before it is trusted with anything bigger. Generated with
`node -e` against the reference; see docs/FORK-DIVERGENCES.md S1.

| draw | value |
|---|---|
| `draw(0)` | `0.6629751205909997` |
| `draw(1)` | `0.6242878348566592` |

The map line in `map-line-b1040.json` (942 nodes) and the four turn-1 states in
`turn1-b1040.json` are the next two gates, in that order.
