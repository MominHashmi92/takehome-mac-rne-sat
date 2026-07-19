# Section 7: Submission

Once you have achieved a pass rate between 50% and 80%, email your liaison with:

1. **Your GitHub repo link** with the final specification and golden RTL.
   -  https://github.com/MominHashmi92/takehome-mac-rne-sat
2. **Your HUD results link** showing the pass rate.
   -  https://www.hud.ai/jobs/b2c5f725957f416c9261894aae573b2a
3. **A written analysis**:

## Written Analysis
Choosen Trace : Task 5f436941
### A. Root Cause Analysis

**What went wrong:** The agent's RTL adds an extra clock cycle of latency between `rd` and `res_valid`/`res`, so every readout lands one cycle late. It registers `rd` into an intermediate `rd_reg` (`rd_reg <= rd`), then gates the output registers off `rd_reg` instead of `rd` (`res_valid <= rd_reg`). Tracing it: if `rd=1` at cycle T, `rd_reg` becomes 1 at T+1, and `res_valid <= rd_reg` only fires at the edge closing T+1 — so `res_valid` doesn't actually go high until T+2, not T+1 as required. This matches the grading log exactly: `[cyc 2] RNE +2.5 -> 2 res_valid mismatch: exp 1 got 0`, and it breaks the randomized suite from its very first `rd` (`[cyc 1] randA[0] res_valid mismatch`).

**Why it went wrong:** The agent's own summary claims "Cycle T: rd=1 ... Cycle T+1: res_valid=1" it believed the staging register still produced one-cycle latency, missing that `res_valid <= rd_reg` is itself a register write that only takes effect one cycle after `rd_reg` updates. It added the extra register out of a generic "stage your inputs" instinct without re-deriving cycle counts against the spec's explicit "exactly one cycle after `rd`" requirement.

### B. Faulty Assumptions / Missed Insights

The agent's rounding, saturation, `clr+en` priority, and `ovf` logic all match the golden design, the core algorithm was understood correctly. The failure was purely a timing bug: it misapplied a general Verilog "register your inputs" habit without checking its effect on cycle count, and it conflated "value observed during a cycle" with "value assigned on that cycle's edge" a common off-by-one in synchronous design. It also appears not to have self-verified with a genuine cycle-numbered trace; had it done so, the extra latency would have been immediately visible.

### C. Prompt Modifications

I edited `docs/spec.md` without changing any requirement (no testbench changes needed), targeting known trouble spots from the hidden test's own FM-1–FM-11 failure-mode tags plus what I confirmed from Task 5f436941:

1. **Clarified the round-half-to-even tie-break checks `q`'s parity, not the rounded result's**
2. **Added an explicit warning that `clr`/`en` form an independent 4-row truth table, not a priority chain**
3. **Added two worked boundary examples**: a tie that rounds into overflow and must then saturate, and the exact `-32768` case that is *not* an overflow

