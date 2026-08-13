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

**Important:** When both `clr` and `en` are asserted, the accumulator becomes
`p` alone — it does **not** add `p` to the previous value, and it does **not**
stay at zero. This is "clear-then-accumulate": replace the accumulator with
the new product.

The grading testbench guarantees the accumulator value never exceeds the
signed 28-bit range, so accumulator wrap behavior is unspecified and need
not be handled.

## 4. Readout path

Asserting `rd` in cycle *t* requests a snapshot readout.

### 4.1 Snapshot timing (critical)

The snapshot is the accumulator value as it stood at the **end of cycle
*t−1*** — that is, **before** any accumulator update (`en`/`clr`) occurring
in cycle *t*.

- An `en` asserted in the same cycle as `rd` still updates the accumulator
  normally; it is simply **not** part of that snapshot.
- A `clr` asserted in the same cycle as `rd` clears the accumulator **after**
  the snapshot is taken (the readout returns the pre-clear value).
- All three signals (`rd`, `en`, `clr`) may be asserted simultaneously in
  the same cycle. The snapshot always uses the **old** accumulator value;
  then the accumulator is updated per §3.

**Implementation hint:** In a single `always_ff` block, read `acc` for the
snapshot/rounding computation **before** assigning the new accumulator value.
Nonblocking assignments (`<=`) mean the combinational path uses the pre-edge
value of `acc`.

### 4.2 Rounding — round-half-to-even at the 8 LSBs

Rounding happens **only at readout time**, not during accumulation. The
accumulator stores the full unrounded sum; rounding is applied to the
snapshot value when `rd` is asserted.

Let `snapshot` be the 28-bit signed accumulator value at snapshot time.

Compute:
- `q = floor(snapshot / 256)` — use **arithmetic** right shift by 8
  (`snapshot >>> 8`), not logical shift.
- `r = snapshot − 256·q` — equivalently, the lower 8 bits of `snapshot`
  (`snapshot[7:0]`). This remainder is always in `0..255`, **even for
  negative snapshots**.

Round-half-to-even rules:
- `q` if `r < 128`
- `q + 1` if `r > 128`
- on a tie (`r == 128`): `q` if `q` is even (`q[0] == 0`), else `q + 1`

**Do not** use round-half-up (always round up on tie). **Do not** round
during accumulation — only at readout.

Worked examples (`snapshot → rounded value before saturation`):

| snapshot | q  | r   | rounded | note                              |
|----------|----|-----|---------|-----------------------------------|
| 640      | 2  | 128 | 2       | tie, q even → stays               |
| 896      | 3  | 128 | 4       | tie, q odd → rounds up            |
| −384     | −2 | 128 | −2      | tie, q even → stays               |
| −640     | −3 | 128 | −2      | tie, q odd → rounds toward +inf   |
| 704      | 2  | 176 | 3       | r > 128 → rounds up               |
| 288      | 1  | 32  | 1       | 3 accumulations of 96, not 0      |

### 4.3 Saturation — applied after rounding

The rounded value is then clamped to the signed 16-bit range
`[−32768, +32767]`.

**Order matters:** rounding is performed first and may itself carry the value
out of the 16-bit range; saturation applies to the **rounded** value.

- If rounded > 32767 → `res = 32767`, saturation occurred
- If rounded < −32768 → `res = −32768`, saturation occurred
- Otherwise → `res = rounded` (as 16-bit signed), no saturation

**Boundary case:** A rounded value of exactly −32768 does **not** count as
saturation — `ovf` stays unchanged. Only values **strictly outside**
`[−32768, 32767]` trigger saturation.

Example: accumulator = −8388608 (= −2²³). Snapshot q = −32768, r = 0.
Rounded = −32768 exactly. `res = −32768`, `ovf` does **not** set.

### 4.4 Registration and hold

`res` and `res_valid` are registered outputs.

- In cycle *t* when `rd` is asserted: snapshot is taken, rounding/saturation
  computed, but outputs are **not** yet updated.
- In cycle *t+1*: `res_valid = 1` and `res` carries the rounded, saturated
  snapshot value.
- `res_valid` is exactly **one cycle wide** per `rd` assertion.
- Between readouts, `res` **holds** its last value; it does not clear when
  `res_valid` is low.
- Back-to-back `rd` cycles are permitted; each takes its own snapshot.

## 5. Overflow flag

`ovf` is a registered, sticky flag:

- **Set** whenever a readout saturates (the rounded snapshot fell **strictly
  outside** `[−32768, 32767]`). The flag update lands in the same cycle as
  the corresponding `res_valid`.
- **Cleared** only by `clr` (or `rst`).
- **Sticky:** once set, `ovf` remains 1 until cleared by `clr` or `rst`. A
  non-saturating readout does not clear it.
- **Same-cycle priority:** if a saturating readout coincides with `clr` in
  the same cycle, the **set wins** — `ovf` is 1 in the following cycle.
  `clr` clears the flag only when no saturating readout lands that same cycle.
- A readout that does not saturate leaves `ovf` unchanged. `res` always
  carries the clamped value; saturation is signaled only via `ovf`.

**ovf update pseudocode** (per clock edge, when `rst = 0`):
```
if (rd && saturates)  ovf <= 1;        // saturating readout sets (priority)
else if (clr)          ovf <= 0;        // clr clears only if no sat set
// otherwise ovf holds
```

## 6. Reset

`rst` is synchronous and active-high, and overrides `en`/`clr`/`rd`. On a
rising edge with `rst = 1`: `acc`, `res`, `res_valid`, and `ovf` all clear
to 0.

## 7. Per-cycle update order (reference pseudocode)

On each rising clock edge (when `rst = 0`), process in this order:

```
1. snapshot = acc                          // OLD value, before any update
2. Compute rounded + saturated result from snapshot
3. res_valid <= rd                           // registered, 1 cycle after rd
4. if (rd) res <= saturated_result
5. Update ovf per §5 pseudocode
6. Update acc per §3 table (clr/en priority)
```

This ordering ensures snapshot timing, rounding-at-readout-only, and
correct `ovf`/`clr` priority.

## 8. Implementation constraints

- Synthesizable SystemVerilog, compatible with Icarus Verilog (`-g2012`).
- No SystemVerilog Assertions (SVA).
- Do not change the module name, port names, directions, or widths.
- Single clock domain. No latches.
