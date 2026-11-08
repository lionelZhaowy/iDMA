# Accepted-read permits for the deadlock-free coupled AXI backend

This candidate extends Georg Rutishauser's [PR 227](https://github.com/pulp-platform/iDMA/pull/227),
fixed author head `ac6a0d088904264fa5be17bd6d774e9c935d1d68`. Official `devel`
was `a6b1d6657c03998b6df0baf905d7babd006ba614` at the check. The proposal's
buffer reservation and burst sizing remain unchanged.

## Trigger and change

A shared memory port can accept AW, then hold the port until W finishes. In
`deadlock_free=1`, `decouple_rw=0`, `decouple_aw=1`, PR 227 can send the next AW
before the corresponding AR is accepted. W then needs read data while the
shared port cannot accept that read. The frozen test reaches AR=1, AW=2,
R=2, W=2, B=1 and never completes.

For the single-pair AXI backend, add a bounded accepted-read permit count.
Eligibility is `deadlock_free && !decouple_rw` from each legalized request.
Read metadata carries it through the AR register. An AW packet carries it
through the existing coupler FIFO. A later input job cannot change a queued
packet's eligibility.

An eligible **external AR handshake** adds one permit. An eligible **external
AW handshake** consumes one permit. AW needs a permit that was already
registered before that edge. A same-edge AR cannot supply its first permit.
When the count equals NumAxInFlight, another eligible AR waits. The count
persists across jobs and resets with rst_ni.

These are extra rules for the selected deadlock-free mode. AXI itself permits
independent AR and AW channels, including same-edge handshakes. The candidate
does not impose this ordering on `deadlock_free=0`, `decouple_rw=1`, or
`RAWCouplingAvail=0`. HardwareLegalizer=0 keeps eligibility off, as this author
version already does not support deadlock-free mode without legalization.
Other generated protocol topologies are unchanged.

A stalled AR cannot lose VALID through the new bound: while that AR has not
handshaked, it cannot increment the count. An AW can only lower the count and
make read admission easier. A stalled AW similarly cannot consume its own
permit. Both admission decisions use only the registered count.

## Actual results

The original and candidate use the same frozen shared-port reproduction test
and coupled-order test. They instantiate the real generated idma_backend_rw_axi.
The independent memory fabric has registered AW-priority arbitration for its
shared-port mode.
It does not replace the DMA. Each completed test compares every one of 4096
memory bytes, including all source bytes, destination bytes, and guards.

| Input | Author head | Candidate |
| --- | --- | --- |
| Frozen 64-byte copy, independent ports, AW=0 or 1 | PASS | PASS |
| Same copy, shared port, AW=0 | PASS | PASS |
| Same copy, shared port, AW=1 | Original wait cycle at 100 us | PASS |
| deadlock_free=0, independent ports, AW=0 or 1 | PASS | Same result |
| deadlock_free=0, shared port, AW=0 or 1 | Original capacity wait cycle | Same wait cycle; not PASS |
| Queued RW mode and queued deadlock-free mode changes, NumAx=2/3 | All data correct | All data correct; every accepted packet's eligibility matches its original job |
| Lengths 1/7/8/9/15/16/17/33 with different byte offsets | All data correct | All data correct |
| AR/AW ready open together with no earlier permit | Data correct; extra ORDER_POLICY rejected | Data correct; AR accepted one cycle before AW |
| NumAx=1 | Rejected at time zero | Same rejection |

The coupled-order tests also reach permit peaks 2 and 3, exercise AR/AW/W backpressure,
and check known channel controls and stable VALID/payload while stalled. The
queued tests observe packets whose eligibility differs from the current input
job. They check the candidate's actual registered permit count and packet tags
passively. No observer drives or forces the DMA.

Separate the results:

- DATA: full 4096-byte comparison and exact completion/idle/write-byte checks.
- PROTOCOL checks: known controls, basic burst/WLAST checks, and stalled
  AR/AW/W VALID/payload stability. This is not a full AXI VIP coverage claim.
- ORDER_POLICY: previously registered permits, bounded count, and per-job
  read/write ordering, only for eligible requests.

The final input versions give 51 calls: 38 complete passes, 6 identified wait
cycles at the finite limit, 2 DATA_PASS/ORDER_POLICY rejection controls,
2 unsupported-parameter rejection controls, and 3 one-byte data-check rejection
controls. Each one-byte control has exactly one mismatch and DATA_FAILURE.
The NumAx=1 first fatal is from locked common_cells cc_stream_fifo_optimal_wrap:
`FIFO of depth 1 does not make any sense!`. Support was not extended to depth 1.
VCS returns zero for these fatal controls too. A zero host return is insufficient.

All final runs have a 100 us HDL limit and a 60-second wall limit. A timeout is
not PASS. The shared-port wait diagnoses keep the same transaction counts at
90 and 100 us. [results.json](results.json) records every final call and log SHA.
Earlier preparation failures remain separate and are not relabelled as passes.
The result groups and case labels use `shared_axi` for the shared-port reproduction
and `coupled_order` for the queued-order regression. These labels identify the
recorded runs; their log SHA256 values, arguments, summaries, counts and result
classifications are unchanged.

The public TB copies remove one final empty line from each recorded TB.
All non-whitespace bytes are identical. The recorded input SHA256 values remain
the actual run inputs; results.json maps them to the public file SHA256 values.
The 51-call table refers to the recorded TB bytes.

## Generation, lint, and implementation

Run the official `make idma_hw_all` target in both checkouts. It completed with
Python 3.13.5 and uv.lock-matching packages. For this check, the actual invocation
set `IDMA_ROOT` explicitly, used `PYTHON=python3`,
`PEAKRDL='python3 -m peakrdl'`, and `BENDER=true`. A task-local PYTHONPATH supplied
the locked packages; dependency discovery is not needed for pure generation.
Hardware compilation used the unchanged Bender.lock commits in results.json.
No dependency was upgraded. Of 77 corresponding files in the generated target/rtl tree, only
rw_axi backend, rw_axi legalizer, and the combined idma_generated.sv differ.
The other 74 outputs are byte-identical.

VCS `+lint=all` reports the same 245 normalized diagnostics before and after.
Only paths and source-line metadata are normalized. Existing diagnostics and
the locked deprecated delta_counter warning remain. The new assertions are
named; no assertion or warning check is disabled.

DC analyzes, elaborates and links the real official generated synthesis wrapper
with the tested 64-bit data, 32-bit address, NumAx=3, BufferDepth=3 configuration.
Both versions complete `compile -no_map`, design and loop checks. Actual cell
attributes show 1528 versus 1534 flip-flops, zero latches, and zero post-compile
blackboxes or unexplained references. Generic operators are classified from
actual attributes. This is not mapped timing or area signoff.

## Reproduction

Keep two independent source/build directories. Start the author checkout at
`ac6a0d088904264fa5be17bd6d774e9c935d1d68`; use this contribution checkout for
the candidate. Resolve each unchanged Bender.lock and use its uv.lock environment.
Generate each checkout with `make idma_hw_all`. The tests in this contribution
are used unchanged for both versions.

Set the following paths before each compile. The test checkout can be shared
read-only. For the recorded locked packages, the explicit generation command is:

```sh
make IDMA_ROOT="$PWD" BENDER=true PYTHON=python3 \
  PEAKRDL='python3 -m peakrdl' idma_hw_all
IDMA_DIR=$PWD
CC_DIR=$(bender path common_cells)
AXI_DIR=$(bender path axi)
TEST_DIR=/absolute/path/to/this-contribution/test
```

Compile in a new empty build directory. Select tb_shared_axi for the frozen test
or tb_coupled_axi_order for the coupled-order test. Set the matching source name and
TOP. Set EXTRA only for coupled-order tests; set CANDIDATE only for the candidate's
coupled-order build. It enables passive internal checks in the TB, not DUT logic.

```sh
TOP=tb_coupled_axi_order
EXTRA='+define+TEST_NUM_AX=3 +define+TEST_BUFFER_DEPTH=8'
CANDIDATE=                         # author
# CANDIDATE=+define+CANDIDATE_PERMIT # candidate, coupled-order TB only
vcs -full64 -sverilog -timescale=1ns/1ps -assert svaext +lint=all \
  +incdir+"$CC_DIR/include" +incdir+"$AXI_DIR/include" \
  +incdir+"$IDMA_DIR/target/rtl/include" +incdir+"$IDMA_DIR/src/include" \
  +define+AUTHOR227 $EXTRA $CANDIDATE \
  "$CC_DIR/src/deprecated/delta_counter.sv" \
  "$CC_DIR/src/cc_pkg.sv" "$AXI_DIR/src/axi_pkg.sv" \
  $(find "$CC_DIR/src" -maxdepth 1 -name 'cc_*.sv' ! -name cc_pkg.sv | sort) \
  "$IDMA_DIR/src/idma_pkg.sv" "$IDMA_DIR/src/idma_float_pkg.sv" \
  "$IDMA_DIR"/src/backend/*.sv \
  "$IDMA_DIR/target/rtl/idma_legalizer_rw_axi.sv" \
  "$IDMA_DIR/target/rtl/idma_transport_layer_rw_axi.sv" \
  "$IDMA_DIR/target/rtl/idma_backend_rw_axi.sv" \
  "$TEST_DIR/$TOP.sv" -top "$TOP" -o simv > compile.log 2>&1
```

The frozen TB fixes NumAx=3 and BufferDepth=3. Compile it with no EXTRA or
CANDIDATE. Run its four combinations in separate output directories:

```sh
timeout 60 /absolute/build/simv +SHARED=0 +DECOUPLE_AW=0 > run.log 2>&1
# Repeat SHARED=0/1 and DECOUPLE_AW=0/1.
# A separate rejection control adds +CORRUPT_COPY to SHARED=0/AW=0.
```

For the coupled-order TB, compile NumAx=2 and 3 with BufferDepth=8. Each run gets a
new output directory. Run these cases on both author and candidate:

```sh
timeout 60 /absolute/build/simv +SCENARIO=1 +SHARED=0 +DEADLOCK_FREE=1 +BACKPRESSURE=1 +DECOUPLE_AW=1 > run.log 2>&1
# Repeat SCENARIO=2,3,4,5 with the same remaining arguments.
# SCENARIO=1: alternating RW coupling and both AW modes.
# SCENARIO=2: eligible short jobs, reaches the configured permit bound.
# SCENARIO=3: unaligned byte/beat boundary lengths.
# SCENARIO=4: RW-decoupled jobs; the new policy remains off.
# SCENARIO=5: queued deadlock-free and RW mode changes.
# Plain-mode control: SCENARIO=1, DEADLOCK_FREE=0, BACKPRESSURE=1.
# Same-edge policy control: SCENARIO=0, DEADLOCK_FREE=1, BACKPRESSURE=3.
```

Also compile NumAx=3/BufferDepth=3. Run SCENARIO=0 with DEADLOCK_FREE=0,
BACKPRESSURE=0 and all four SHARED/AW combinations. Repeat SHARED=1/AW=1 with
DEADLOCK_FREE=1. Compile NumAx=1/BufferDepth=3 for the expected parameter
rejection. The coupled-order one-byte rejection uses the candidate's NumAx=3,
BufferDepth=8, SCENARIO=1, SHARED=0, DEADLOCK_FREE=1, BACKPRESSURE=1 and
DECOUPLE_AW=1, with +CORRUPT_COPY.

A complete pass needs exactly one DONE, checks=4096, data/order/stability errors
all zero, exact job completion, known idle final state, and normal finish.
Require no deadline, fatal, unexpected assertion, or UNKNOWN_CHANNEL_CONTROL.
Read ORDER_TAGS in candidate queued tests. A rejection or wait-cycle run must
match its specific classification and counters; it is not a pass.

Scope: backend/fabric unit tests only. Compute, AXI error handling, multi-head
and mixed-protocol operation, arbitrary reset/abort, all parameter combinations,
and full SoC/LLC liveness are not established by these results.

Original authors, Git history, and SHL-0.51 licenses remain. The new tests use
SHL-0.51. AI assistance was used for code, tests, execution, and this text.
