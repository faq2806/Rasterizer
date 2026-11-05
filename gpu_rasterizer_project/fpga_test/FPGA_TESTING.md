# FPGA test of the rasterization stage (Nexys 4 DDR)

This test drives **only `gpu_triangle_engine`**: viewport transform, triangle
setup, edge-function scan with top-left rule, and R/G/B/Z interpolation. The
missing stages are replaced:

| Real pipeline              | In this test                                     |
|----------------------------|--------------------------------------------------|
| geometry fetch (DDR2)      | `raster_tri_rom`: 79 triangles in 44 tests       |
| framebuffer write + VGA    | on-chip checkers, overlap bitmap, UART pixel dump |

All expected values come from a **bit-exact Python model** of the RTL
(`tools/raster_golden.py`). A failure on the board means the hardware does not
match what the RTL simulates: a synthesis or timing problem, a reset or CDC
issue, or an RTL construct that synthesizes differently from how it simulates.
The generator also reports *algorithm* problems in the RTL itself. It compares
against ideal floating-point barycentric interpolation and checks shared edges
for double-drawn pixels.

```
 test ROM ──► sequencer ──► gpu_triangle_engine ──► pixel stream ──► checkers ──► LEDs / 7-seg / UART
 (79 tris)    (valid/ready)   (DUT, own reset)        (backpressure)   (16 checks)
```

## 1. Files

| File | Purpose |
|---|---|
| `fpga_test/raster_fpga_test_top.v` | Board top: MMCM clock, resets, buttons/switches, DUT, 7-seg pages, LEDs |
| `fpga_test/raster_test_harness.v` | Sequencer, all checkers, 800×600 overlap bitmap, result RAM, UART report |
| `fpga_test/rt_support.v` | UART TX, debouncer, LED pulse stretcher, 7-segment driver |
| `fpga_test/raster_test_rom.v` | **Generated**: test table, triangle ROM, per-pixel golden stream |
| `fpga_test/test_vectors_report.txt` | **Generated**: every expected value in readable form |
| `fpga_test/raster_fpga_test.xdc` | Nexys 4 DDR pins (switches, buttons, 16 LEDs, RGB LEDs, 7-seg, UART) |
| `fpga_test/create_raster_test_project.tcl` | Creates the Vivado project (optionally builds the bitstream) |
| `fpga_test/tb_raster_fpga_test.v` + `run_fpga_test_sim.sh` | Full simulation of the board top, including fault injection |
| `tools/raster_golden.py` | Golden model, generator, UART capture/compare, PNG rendering, flag decoder |

## 2. Workflow

```bash
# 1. (only if tests or RTL arithmetic changed) regenerate ROM + expected table
python tools/raster_golden.py gen            # add --render renders  for expected PNGs
# 2. simulate the whole board top (must end with ALL ... PASSED)
bash fpga_test/run_fpga_test_sim.sh
```

Then in Vivado: `cd` to `gpu_rasterizer_project`, `source fpga_test/create_raster_test_project.tcl`,
run Generate Bitstream, **open the timing summary and confirm WNS ≥ 0**, and program the board.

To capture the report on the PC, open a terminal on the board's USB-UART COM
port at 115200 8N1 (PuTTY or Tera Term), or run:

```bash
pip install pyserial
python tools/raster_golden.py capture COM5 uart_log.txt
```

## 3. Controls

| Control | Function |
|---|---|
| **BTNC** | Start a run |
| **BTND** | Abort: soft reset of harness and DUT (hold briefly) |
| **BTNR** | Toggle 7-seg pages 11–14 between **A**ctual and **E**xpected (LED7 / right DP lit = expected) |
| CPU_RESET | Full reset |
| SW[5:0] | Test index (for single-test mode and for the result pages) |
| SW[7:6] | Backpressure on `pixel_ready`: 0 = none, 1 = ready 2 of 3 cycles, 2 = random 50 %, 3 = random 12.5 % |
| SW[8] | 0 = run all tests, 1 = run only test SW[5:0] |
| SW[9] | Soak: repeat forever (with SW[7:6]=2/3 the random pattern differs every loop) |
| SW[10] | UART pixel dump: every accepted pixel is printed (use with SW[8]=1) |
| SW[11] | Verbose UART: CRC/BBOX/pixel lines also for passing tests |
| SW[15:12] | 7-segment page |

## 4. LEDs

| LED | Meaning |
|---|---|
| LD0 | Run finished and **all** tests passed |
| LD1 | At least one test failed (sticky until next start) |
| LD2 | Run in progress |
| LD3 / LD4 | Engine busy / pixels being accepted (stretched so they are visible) |
| LD5 | MMCM locked (if off, nothing else is valid) |
| LD6 | UART transmitting |
| LD7 | Alt view (expected values on pages 11–14) |
| LD8 | Count failure (COUNT or UNION) |
| LD9 | **Coverage** failure: CRC_XY, BBOX, RANGE, ORDER or DUP |
| LD10 | **Colour interpolation** failure (CRC_RGB) |
| LD11 | **Depth interpolation** failure (CRC_Z) |
| LD12 | Attribute outside vertex range (ATTR) |
| LD13 | Handshake / protocol failure (STALL, PROTO) |
| LD14 | TIMEOUT or ERROR flag |
| LD15 | Per-pixel stream or first/last-pixel mismatch |
| LD16 RGB | green = PASS, red = FAIL, blue = running |
| LD17 RGB | blue heartbeat: core clock is running |

LD8–LD15 are ORed over all tests in the run; the per-test detail is on the 7-seg and the UART.

## 5. Seven-segment pages (SW[15:12])

Pages 1–14 refer to the test selected by SW[5:0]. `--------` = that test has not run yet.

| Page | Shows | Example |
|---|---|---|
| 0 | Status: `IdLE  nn` (nn = number of tests), `run tt ff` (current test, fails so far; F after run = a failure happened), `PASS  nn` (passed count), `FAIL ff cc` (**first failing test**, fail count) | `PASS  2C` |
| 1 | `t ss P/F flags`: test index, verdict (`-` not run), 16-bit fail flags | `t1CF2006` |
| 2 / 3 | Pixel count actual (`nA`) / expected (`nE`) | `nA 0EA60` |
| 4 / 5 | CRC_XY (coverage) actual / expected | |
| 6 / 7 | CRC_RGB (colour) actual / expected | |
| 8 / 9 | CRC_Z (depth) actual / expected | |
| 10 | Cycles taken by the test (performance) | |
| 11 | Bounding box X: `xmin A/E xmax` | `0C8A 258` |
| 12 | Bounding box Y: `ymin A/E ymax` | |
| 13 | First pixel: `x A/E y` | |
| 14 | First pixel: `rgb A/E depth` | |
| 15 | Soak: loop count (left 4) and loops with a failure (right 4) | |

BTNR switches pages 11–14 to expected values (marker `E` instead of `A`).
Expected counts and CRCs are always shown on the odd pages, and every expected
value is listed in `test_vectors_report.txt`.

## 6. Fail flags

| Bit | Name | Meaning | Typical cause |
|---|---|---|---|
| 0 | COUNT | pixel count ≠ model | coverage/edge logic, lost or extra handshakes |
| 1 | CRC_XY | sequence of (x,y) ≠ model | edge functions, bbox, top-left rule, scan stepping |
| 2 | CRC_RGB | colour stream ≠ model | interpolator gradient/divider, rounding, R/G/B wiring |
| 3 | CRC_Z | depth stream ≠ model | Z interpolator, 16-bit path, sign-flip of Z |
| 4 | BBOX | min/max of emitted x,y ≠ model | bbox clipping, viewport transform |
| 5 | RANGE | x ≥ 800 or y ≥ 600 emitted | clipping broken |
| 6 | ORDER | raster order not strictly increasing inside a triangle (also catches duplicates) | scan FSM, `scan_advance` glitch |
| 7 | STALL | `pixel_valid` dropped or data changed while `pixel_ready=0` | valid/ready violation (only visible with SW[7:6]≠0) |
| 8 | DUP | pixels drawn twice by different triangles ≠ model (0) | top-left ownership on shared edges |
| 9 | UNION | unique covered pixels ≠ model | holes or overlaps in meshes |
| 10 | TIMEOUT | no progress for 2 M cycles; the DUT was reset | FSM hang, divider never done, `triangle_ready` stuck |
| 11 | ERROR | `triangle_error` ≠ expected (0) | divider overflow / divide-by-zero path |
| 12 | PROTO | `triangle_done` count ≠ triangles, valid while not busy, done at wrong time | engine control FSM |
| 13 | ATTR | pixels whose attribute is outside the triangle's vertex range | interpolation overshoot / wrong plane |
| 14 | STREAM | per-pixel compare against golden stream (tests ≤ 64 px) | exact first bad pixel is printed on UART |
| 15 | FIRST/LAST | first or last pixel ≠ model | start/end of scan, initial sample value |

Decode any flag word: `python tools/raster_golden.py decode 2006`.

**How to read a failure.** If only CRC_RGB and/or CRC_Z fail, coverage is correct
and the fault is in the interpolators. If CRC_XY, COUNT or BBOX fail, the fault
is in the viewport, setup or edge scan. If a test fails only with SW[7:6] ≠ 0,
the fault is in backpressure/handshake handling. If failures appear at a higher
core clock but disappear at 25 MHz, it is timing. Check WNS and the critical
path in the timing report.

## 7. UART report (115200 8N1)

```
=== RASTER ENGINE FPGA TEST  TESTS=2C RUN=ALL BP=0 DUMP=0 LOOP=0000 ===
FLAGS: 0=CNT 1=XY 2=RGB 3=Z 4=BBOX ...
T00 PASS const_ccw        F=0000 N=0EA60/0EA60 CYC=00026A41 STALL=00000000
...
T1C FAIL tiny_pair_shared F=4006 N=00024/00024 CYC=... STALL=...
    XY=........ /........  RGB=..../....  Z=..../....          (actual / expected)
    BBOX=xmin,xmax,ymin,ymax EXP=... TRI=02/02 DUP=../.. UNION=../.. AV=../..
    FIRST=x,y,rgb,depth EXP=...  LAST=... EXP=...
    STREAM MISMATCH AT PIXEL #00007 GOT=... EXP=...
=== RESULT FAIL PASSED=2B FAILED=01 FIRSTFAIL=1C FLAGS=4006 LOOPS=0001 LOOPFAILS=0001 ===
```

The detail lines are printed for failing tests, and for every test with SW[11]=1.
All numbers are hex.

**Pixel dump + image comparison.** Set SW[8]=1, choose the test with SW[5:0],
set SW[10]=1, then capture and compare:

```bash
python tools/raster_golden.py capture COM5 dump.txt
python tools/raster_golden.py compare dump.txt --out cmp
```

`compare` lists the first differing pixels and writes three PNGs to `cmp/`:
actual, expected, and a diff (green = identical, yellow = attribute differs,
red = missing on hardware, blue = extra on hardware). This is how you see what
the board rasterized without a framebuffer or VGA. At 115200 baud the dump
prints about 570 pixels/s, so use small tests (16–1F hex, the tiny and sliver
tests) or raise `UART_BAUD` (921600 works with the on-board FTDI bridge).

## 8. Test list

Run `python tools/raster_golden.py list` for every expected value.

| # (hex) | Tests | What they exercise |
|---|---|---|
| 00–05 | const_ccw/cw, rgb_grad, _cw, _rot1, _rot2 | constant attributes, both windings, all three vertex rotations |
| 06–08 | red/green/blue_ramp | each colour interpolator in isolation (others constant) |
| 09–0B | depth_ramp, depth_min/max_const | full Z range, Z sign-flip, extremes 0x0000/0xFFFF |
| 0C–0D | screen_half_bnd, full_screen_quad | Q1.15 endpoints → 0/799/599, 478 601-pixel union |
| 0E–12 | rect_tile ×2, fan4, mesh_4x3 (24 tris), strip (mixed winding) | shared-edge ownership, no holes or overlaps (bitmap) |
| 13–15 | degen point/collinear/horizontal | zero-area rejection, done without pixels |
| 16–1C | tiny_* | flat top/bottom, vertical edges, 0- and 1-pixel triangles, per-pixel golden stream |
| 1D–1F | slivers (diagonal, vertical, horizontal) | long empty scans, thin coverage, edge precision |
| 20–22 | corners, colour clamp | x=799 special case, screen corners, clamp to 0/15 |
| 23–2B | random_0..7, random_big | seeded random geometry and attributes |

## 9. Suggested test procedure

1. **Bring-up**: SW all 0, press BTNC. LD5 and the LD17 heartbeat are on, page 0 shows `run`, then `PASS  2C`.
2. **Backpressure**: repeat with SW[7:6] = 1, 2, 3. Results must be identical. Only STALL counts change.
3. **Soak**: SW[9]=1, SW[7:6]=2, leave it for minutes. Page 15 counts loops and failed loops (must stay 0).
4. **Timing margin**: rebuild with `mmcm_out_div` 20 (50 MHz), 16, 12, 10 in the Tcl script. The first speed that fails shows the real limit; compare it with Vivado's WNS.
5. **Debug a failure**: SW[15:12]=0 shows the first failing test. Set SW[5:0] to it and read page 1 (flags) and pages 2–14. Then run it alone with SW[8]=1, SW[11]=1, and SW[10]=1 to dump and compare images on the PC.

## 10. Resource and timing notes

- The overlap bitmap uses 480 000 bits of block RAM (about 15 RAMB36). The four interpolators use most of the DSPs.
- The default core clock is **25 MHz** (`MMCM_OUT_DIV=40`). The engine has long single-cycle paths: SETUP computes viewport → edge setup → 32-bit multiplies in one cycle, and the interpolator does a 48×16 multiply for the initial sample. 100 MHz is unlikely to close timing without pipelining the RTL.
- Changing `MMCM_OUT_DIV` automatically rescales the UART baud divisor and the debounce time. The watchdog is in cycles (`NO_PROGRESS_LIMIT`, 2 M), so it does not depend on the clock speed.
- The bitstream does not depend on DDR2 or VGA. Only the engine RTL files from `rtl/` are used.
