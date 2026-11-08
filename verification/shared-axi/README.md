# Shared single-port AXI check for iDMA PR 227

This test instantiates the real generated `idma_backend_rw_axi`. It uses an
independent AXI memory fabric with either separate read/write ports or one
shared port. The shared port registers its AW-priority grant while idle and retains an accepted
burst until its data finishes. No READY output depends combinationally on any AXI request input. It does not model or replace the DMA.

Official base: `a6b1d6657c03998b6df0baf905d7babd006ba614`.
PR 227 author head: `ac6a0d088904264fa5be17bd6d774e9c935d1d68`
([Georg Rutishauser's proposal](https://github.com/pulp-platform/iDMA/pull/227)).
The original and author versions use their identical Bender.lock dependencies.
The author version sets `beo.deadlock_free=1`. Both set `beo.decouple_rw=0`.
No production RTL changes are included in this test contribution.

## Results

VCS W-2024.09-SP1, 64-bit AXI data, 32-bit address, BufferDepth=3,
NumAxInFlight=3, HardwareLegalizer=1, RAWCouplingAvail=1, CombinedShifter=0,
MemSysDepth=0, compute disabled, NO_ERROR_HANDLING.
Each run has a 100 us HDL deadline and 60 s wall limit.

| Version | Shared port | decouple_aw | Actual outcome |
| --- | --- | --- | --- |
| Original | 0 | 0 or 1 | PASS, 1 AR/AW pair, 8 R/W beats |
| Original | 1 | 0 or 1 | Buffer fills after 3 R beats; 0 W, no completion |
| PR 227 | 0 | 0 or 1 | PASS, 4 AR/AW pairs, 8 R/W beats |
| PR 227 | 1 | 0 | PASS, 4 AR/AW pairs, 8 R/W beats |
| PR 227 | 1 | 1 | Second AW owns port before second AR; no completion |

All five successful runs copy the same 64 bytes from 0x100 to 0x200 and compare
all 4096 memory bytes against independent gold, including all guards. The byte
pattern mixes high address bits so original source and destination differ.
The two deliberate `+CORRUPT_COPY` controls flip one checked destination byte
only after DMA completion. Each produces exactly one data mismatch and
`DATA_FAILURE`. VCS returned zero even for these fatal controls. Return code
alone therefore does not establish success.

For the PR 227 shared-port/decouple_aw=1 case, the actual state at 90 and 100 us
is unchanged: AR=1, AW=2, R=2, W=2, B=1, completion=0. The first copy segment
finished. The second AW then acquired the shared port. Its W data needs the
second read, but the port cannot accept that AR while waiting for W.
At the deadline: writing=1, reading=0, ARVALID=1/ARREADY=0, WVALID=0.
This identifies a wait cycle, rather than classifying a growing clock as progress.
The original capacity deadlock instead remains at AR=1/AW=0/R=3/W=0/B=0.

The capacity proposal fixes this shared-port input when AW remains coupled.
The AW-decoupled combination still needs an explicit supported-configuration
restriction or additional address-order control. These tests do not establish
which API contract the maintainer intends. An accepted-read permit for each
coupled AW is one possible extension; it must carry mode metadata with the
corresponding queued address. No unvalidated current-version RTL extension is
presented as a completed fix here.

## Reproduction

Use two independent checkouts and build directories. In each checkout, use the
stated Git revision and resolve its fixed Bender.lock dependencies. Use the
project's uv.lock environment for its official generation commands:

```bash
make target/rtl/idma_backend_rw_axi.sv target/rtl/include/idma/compute.svh
CC_DIR=$(bender path common_cells)
AXI_DIR=$(bender path axi)
IDMA_DIR=$PWD
TB=/absolute/path/to/tb_shared_axi.sv
mkdir build-shared-port
cd build-shared-port
```

Compile the real modules (set AUTHOR only for PR 227):

```bash
AUTHOR=                         # original
# AUTHOR=+define+AUTHOR227       # author head, in its separate build directory
vcs -full64 -sverilog -timescale=1ns/1ps -assert svaext \
  +incdir+"$CC_DIR/include" +incdir+"$AXI_DIR/include" \
  +incdir+"$IDMA_DIR/src/include" +incdir+"$IDMA_DIR/target/rtl/include" \
  $AUTHOR "$CC_DIR/src/cc_pkg.sv" "$AXI_DIR/src/axi_pkg.sv" \
  $(find "$CC_DIR/src" -maxdepth 1 -name 'cc_*.sv' ! -name cc_pkg.sv | sort) \
  "$CC_DIR/src/deprecated/delta_counter.sv" \
  "$IDMA_DIR/src/idma_pkg.sv" "$IDMA_DIR/src/idma_float_pkg.sv" \
  "$IDMA_DIR"/src/backend/*.sv \
  "$IDMA_DIR/target/rtl/idma_legalizer_rw_axi.sv" \
  "$IDMA_DIR/target/rtl/idma_transport_layer_rw_axi.sv" \
  "$IDMA_DIR/target/rtl/idma_backend_rw_axi.sv" \
  "$TB" -top tb_shared_axi -o simv
```

The locked common_cells contains the author's legacy `delta_counter` module in
`src/deprecated/`; it must be included. No dependency or RTL rename is needed.
Run each command in a separate output directory, with the absolute simv path:

```bash
timeout 60 /absolute/build/simv +SHARED=0 +DECOUPLE_AW=0 > run.log 2>&1
# Repeat for (SHARED,DECOUPLE_AW)=(0,1),(1,0),(1,1).
# Separate data-check rejection control:
timeout 60 /absolute/build/simv +SHARED=0 +DECOUPLE_AW=0 +CORRUPT_COPY > bad-data.log 2>&1
```

A PASS requires one `SHARED_AXI_DONE` with checks=4096/errors=0/complete=1, the expected
transaction counts, normal finish, and no deadline, assertion, error or fatal.
A deadline is not PASS. Confirm the stated wait state and stable 90/100 us
transaction counts for each deadlock diagnosis. The intentional data control
requires errors=1, the exact 0x200 mismatch, and DATA_FAILURE; it is never PASS.

Generation used Python 3.13.5 with uv.lock-matching Mako 1.3.12, MarkupSafe 3.0.3,
PyYAML 6.0.3, PeakRDL CLI 1.5.0 and raw-header 0.2.8. Immutable Bender.lock
hardware commits and the public TB SHA are in results.json. Local generation
used these exact packages in a task-local PYTHONPATH, not a dependency upgrade.
The final test uses the registered AW-priority arbiter and a byte pattern that
mixes high address bits. All eight comparison runs and both data-check rejection
controls use exact unique-completion checking and reject unknown final
queue/busy state. Earlier preparation failures and superseded runs are excluded
from the published results.

This is a backend/fabric unit result, not an LLC, SoC, all-protocol, all-width,
error-path, compute-mode or physical implementation claim. No synthesis claim
is made because this contribution changes only the test and documentation.

AI assistance: OpenAI Codex assisted the test, execution, checking and writing.
An independent AI reviewed the actual source and results. No human review is claimed.
