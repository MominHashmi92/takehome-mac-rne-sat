# `mac_rne_sat` — Functional Specification

## 1. Overview

`mac_rne_sat` is a signed 8×8 multiply-accumulate unit with a rounded,
saturated readout port and a sticky overflow flag. All behavior is
synchronous to the rising edge of `clk`. Reset is synchronous and
active-high.

## 2. Interface

| Port        | Dir | Type              | Description                                      |
|-------------|-----|-------------------|--------------------------------------------------|
| `clk`       | in  | `logic`           | Clock. All sequential behavior on the rising edge. |
| `rst`       | in  | `logic`           | Synchronous, active-high reset.                  |
| `en`        | in  | `logic`           | Accumulate `a*b` this cycle.                     |
| `clr`       | in  | `logic`           | Clear the accumulator this cycle.                |
| `rd`        | in  | `logic`           | Request a readout snapshot this cycle.           |
| `a`         | in  | `logic signed [7:0]`  | Multiplicand.                                |
| `b`         | in  | `logic signed [7:0]`  | Multiplier.                                  |
| `res`       | out | `logic signed [15:0]` | Rounded + saturated readout result (registered). |
| `res_valid` | out | `logic`           | One-cycle pulse, exactly one cycle after each `rd`. |
| `ovf`       | out | `logic`           | Sticky saturation flag (registered).             |

All control inputs (`en`, `clr`, `rd`) are sampled on every rising edge and
may be asserted in any combination. `a` and `b` are consumed only on cycles
where the accumulator takes a product (see §3).

## 3. Accumulator

The internal accumulator `acc` is a 28-bit signed two's-complement register.
The product `p = a * b` is a signed 16-bit value, sign-extended to 28 bits
before use.

Accumulator update at each rising edge (with `rst = 0`):

| `clr` | `en` | `acc` next value |
|-------|------|------------------|
| 0     | 0    | `acc` (hold)     |
| 0     | 1    | `acc + p`        |
| 1     | 0    | `0`              |
| 1     | 1    | `p` — clear-then-accumulate: the accumulator becomes the new product alone |

The grading testbench guarantees the accumulator value never exceeds the
signed 28-bit range, so accumulator wrap behavior is unspecified and need
not be handled.

**`clr` and `en` are independent bits, not a priority-encoded pair.** Do not
implement this as "if clr then clear, else if en then accumulate" — that
gives the wrong result on row `1 1`. All four rows of the table above must
be handled distinctly; the `clr=1,en=1` row is *not* the same as `clr=1`
alone.

## 4. Readout path

Asserting `rd` in cycle *t* requests a snapshot readout. The value snapshot,
rounding, and saturation together determine the `res`/`res_valid`/`ovf`
values that appear in registered outputs at cycle *t+1*.

### 4.1 Reference algorithm (authoritative)

The pseudocode below is the exact, authoritative definition of the readout
computation for one cycle. Treat it as ground truth: if any prose elsewhere
in this document seems to conflict with it, this pseudocode wins. It is not
RTL — you still have to decide what is combinational vs. registered and
write synthesizable SystemVerilog — but the *arithmetic and sequencing* are
fully pinned down here so there is no room for interpretation.

```
# Called once per rising clock edge, after sampling en/clr/rd/a/b for
# cycle t. `acc` on entry is its value from the END of cycle t-1, i.e.
# BEFORE this cycle's update is applied.

def step(acc, en, clr, rd, a, b):
    snapshot = acc                       # <-- taken BEFORE this cycle's update, always

    q   = floor(snapshot / 256)          # arithmetic shift right by 8, NOT truncation toward zero
    r   = snapshot - 256 * q             # always in [0, 255], even for negative snapshot

    if r < 128:
        rounded = q
    elif r > 128:
        rounded = q + 1
    else:                                # r == 128, an exact tie
        rounded = q if (q % 2 == 0) else q + 1   # round to EVEN q, not "round half up"

    saturates = (rounded > 32767) or (rounded < -32768)
    if rounded > 32767:
        clamped = 32767
    elif rounded < -32768:
        clamped = -32768
    else:
        clamped = rounded                # rounding first, saturation second -- always in this order

    # Registered outputs, effective next cycle (t+1):
    res_valid_next = 1 if rd else 0
    res_next       = clamped if rd else res            # res HOLDS when rd==0 -- do not clear it
    ovf_next       = 1 if (rd and saturates) else (0 if clr else ovf)
    #                 ^ a saturating readout sets ovf, and WINS over a same-cycle clr.
    #                 clr only clears ovf when no saturating readout lands this same cycle.

    # Accumulator update happens independently of the readout, using the
    # SAME pre-update acc value read at the top of this function:
    if clr and en:
        acc_next = p_signextended(a, b)
    elif clr:
        acc_next = 0
    elif en:
        acc_next = acc + p_signextended(a, b)
    else:
        acc_next = acc

    return res_next, res_valid_next, ovf_next, acc_next
```

Two details worth calling out explicitly because they are easy to miss on a
first read:

- **The tie-break parity check is on `q`, not on `rounded`.** "Round to
  even" means: on an exact tie, pick whichever of `q` or `q+1` is even.
  Since `q` and `q+1` always have opposite parity, checking `q % 2 == 0` is
  sufficient and is the only check you need.
- **Rounding happens first, saturation second, always** — including when
  rounding itself is what pushes the value out of range (see the FM-7-style
  example in §4.3: a snapshot that is exactly `32767.5` in fixed-point
  terms rounds up to `32768` *before* being clamped to `32767`).

### 4.2 Snapshot timing — worked cycle-by-cycle example

The snapshot always reflects `acc` as it stood **before** the current
cycle's `en`/`clr` update, regardless of what else fires in the same cycle.
Concretely, for a cycle where `acc` enters at value `A`:

| This cycle's inputs      | Snapshot used for `rd` (if asserted) | `acc` after this cycle |
|---------------------------|----------------------------------------|--------------------------|
| `rd=1`, `en=0`, `clr=0`   | `A`                                     | `A` (unchanged)          |
| `rd=1`, `en=1`, `clr=0`   | `A` (NOT `A + p`)                       | `A + p`                  |
| `rd=1`, `en=0`, `clr=1`   | `A` (NOT `0`)                           | `0`                       |
| `rd=1`, `en=1`, `clr=1`   | `A` (NOT `p`)                           | `p`                       |

In every row, the snapshot is `A` — what changes is only what `acc` becomes
*after* this cycle. The readout and the accumulator update both read the
same pre-update `A`, they just produce different results (one goes to
`res` next cycle, the other becomes the new `acc`).

### 4.3 Worked rounding/saturation examples (`snapshot → res`)

| snapshot   | q      | r   | rounded | saturates? | res    | note                                          |
|------------|--------|-----|---------|------------|--------|------------------------------------------------|
| 640        | 2      | 128 | 2       | no         | 2      | tie, q even → stays                           |
| 896        | 3      | 128 | 4       | no         | 4      | tie, q odd → rounds up                        |
| −384       | −2     | 128 | −2      | no         | −2     | tie, q even → stays (works the same way for negative snapshots) |
| 8388480    | 32767  | 128 | 32768   | **yes**    | 32767, `ovf`→1 | tie, q odd → rounds up to 32768, THEN saturates to 32767 |
| −8388608   | −32768 | 0   | −32768  | **no**     | −32768 | exactly the minimum representable value — this is NOT an overflow, `ovf` stays unchanged |

The last two rows are the ones worth double-checking your implementation
against: `+32768` after rounding is out of range and must saturate with
`ovf` set, while `−32768` after rounding is exactly in range and must NOT
set `ovf`, even though it's the extreme boundary value.

### 4.4 Registration and hold

`res` and `res_valid` are registered outputs. In cycle *t+1*, `res_valid`
is 1 and `res` carries the rounded, saturated snapshot from cycle *t*.
`res_valid` is exactly one cycle wide per `rd`. **Between readouts, `res`
holds its last value — it must never reset or clear on cycles where
`rd` is low.** Back-to-back `rd` cycles are permitted and each takes its
own independent snapshot.

## 5. Overflow flag

`ovf` is a registered, sticky flag. Restated from §4.1's reference
algorithm for clarity:

- **Set** whenever a readout saturates (the rounded snapshot fell outside
  `[−32768, 32767]`). The flag update lands in the same cycle as the
  corresponding `res_valid`.
- **Cleared** only by `clr` (or `rst`).
- **Same-cycle priority:** if a saturating readout coincides with `clr` in
  the same cycle, the *set* wins — `ovf` is 1 in the following cycle. `clr`
  clears the flag only when no saturating readout lands that same cycle.
  (This is the `ovf_next` line in §4.1 — check that line's if/elif/else
  order matches your implementation's priority exactly.)
- A readout that does not saturate leaves `ovf` unchanged. `res` always
  carries the clamped value; saturation is signaled only via `ovf`.

## 6. Reset

`rst` is synchronous and active-high, and overrides `en`/`clr`/`rd`. On a
rising edge with `rst = 1`: `acc`, `res`, `res_valid`, and `ovf` all clear
to 0.

## 7. Implementation constraints

- Synthesizable SystemVerilog, compatible with Icarus Verilog (`-g2012`).
- No SystemVerilog Assertions (SVA).
- Do not change the module name, port names, directions, or widths.
- Single clock domain. No latches.
- A useful implementation note: `q = acc >>> 8` (arithmetic right shift)
  computes `floor(acc/256)` directly for a two's-complement value,
  including negative `acc`, and `r = acc[7:0]` (the low 8 bits, read as
  unsigned) always equals `acc mod 256` in the sense used in §4.1 — you do
  not need a separate negative-number code path for either.