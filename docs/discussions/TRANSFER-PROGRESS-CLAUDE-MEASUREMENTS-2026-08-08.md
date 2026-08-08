# Transfer progress — measured on the fleet, not assumed

Answer to `TRANSFER-PROGRESS-SYNCOID-2026-08-08.md`. §2 and §5 both say: verify
current OpenZFS behaviour on the actual hosts rather than assuming it. Done,
on metropolis pve1, 2026-08-08. Scratch datasets destroyed afterwards.

**Fleet:** `zfs-2.1.9-pve1` on all four hosts. **`pv` is installed on none.**

## 1. Every send shape estimates, and the numbers are usable

`zfs send -nP` returned `rc=0` and a `size` line for every shape the engines
produce:

| shape | `size` |
|---|---|
| full | 210 131 056 |
| incremental `-i` | 105 070 960 |
| incremental `-I` | 105 070 960 |
| recursive `-R` | 378 269 632 |
| raw `-w` | 210 131 056 |
| compressed `-c` | 210 131 056 |
| recursive incremental `-R -i` | 105 071 584 |

For `-R` the `size` line is the **total across the subtree**, not the first
stream — the per-stream lines come first and `size` sums them. Any parser must
take the `^size` line, not the first line.

## 2. `-c` is estimated correctly — measured on compressible data

The table above used random data, where `-c` cannot help and proves nothing. On
a `compression=lz4` dataset holding 200 MB of repeating text:

| | estimate | actual bytes |
|---|---|---|
| without `-c` | 200 364 864 | 200 538 048 |
| with `-c` | **6 599 488** | 6 772 672 |

So the dry run does reflect compressed send. A denominator taken without `-c`
when the transfer uses `-c` would be **30× too large**.

**The estimate is consistently LOW.** Both rows are short by exactly 173 184
bytes — a fixed trailer, not a proportion. A progress bar built on it reaches
100% slightly before the stream ends.

## 3. Resume CAN be estimated on this fleet — §5 option 1 is available

This is the question the note flagged as decisive.

```
zfs send -nP -t <token>   ->  rc=0,  size = 150 172 888
zfs send    -t <token> | wc -c      = 150 436 512
```

The original full stream was 210 131 056 and 60 000 000 bytes had been
received. So **the estimate is the REMAINING bytes**, not the original total.
That is exactly what a resumed progress bar needs, and it removes the need for
the "no ETA on resume" fallback.

Two cautions:

- the delta here is **263 624** bytes, not the 173 184 seen in §2, so the
  shortfall is **not a constant** that can be corrected away. Treat the estimate
  as approximate and never let a counter exceeding it look like an error;
- `zfs send -nP -t` prints the **decoded resume token as an nvlist first**
  (`resume token contents:`, `nvlist version:`, `object =`, …) before the machine
  lines. A parser reading the first line, or grepping loosely for a number, gets
  garbage. Take `^size<TAB>`.

## 4. My position on the strategy

**Agree with B, reject A, defer C** — with one refinement.

A is rejected for the reason given: a wrapper that re-derives full / `-i` / `-I`
/ bookmark / recursive / resume becomes a second planner and will drift. This
project already has a name for that failure — the recursion declaration lived in
three places and the generator disagreed with the engines.

The refinement to B: the estimate must be taken **from the same variable that
builds the real command**, not from a re-assembled copy of it. If the code that
computes the denominator is a separate expression that "should" match, it is A
again, hidden inside the engine.

**`pv` is not installed on any host.** So the `interactive + pv` gate means the
feature is dormant everywhere until someone installs it, which is a fine
property for a v1 but should be stated rather than discovered. I would not make
`pv` a package dependency for a cron-only fleet.

## 5. On timing

I agree with §6: not now. My reasons are narrower than "the engines are frozen".

The freeze is not the obstacle — it is a procedure, and it exists to be used
when a change is justified. The real argument is that this is **telemetry**, and
telemetry that fails must never turn a valid backup into a failed one. The
fallback path (`estimation fails -> today's exact pipeline`) is the part that
needs the care, and it deserves an implementation window where nothing else in
the engines is moving.

There is also a cheaper thing worth knowing first: nobody has said the **cron**
runs need progress. The owner's question was about visible progress and ETA,
which is an interactive-use property. If the only real consumer is a human
watching a manual seed or restore, then the interactive-only v1 is not a
compromise — it is the whole feature.
