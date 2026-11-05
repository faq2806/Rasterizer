# Verilog hardware triangle rasterizer

Target board: **Digilent Nexys 4 DDR, Artix-7 XC7A100T**. RTL is plain Verilog (no SystemVerilog constructs are intentionally required).

This source package implements the current geometry-to-pixel phase:

```text
triangle read port ─┐
                    v
              geometry fetch <── vertex read port
                    |
                    v
              triangle FIFO
                    |
                    v
        triangle setup + viewport transform
                    |
                    v
       edge-function rasterization + interpolation
                    |
                    v
                pixel FIFO
                    |
                    v
       RGB444 / X / Y / depth valid-ready stream
```

There is deliberately **no framebuffer, Z-buffer, depth test, display controller, or frame swapping**.

## 1. Important design boundary

The external DDR2/MIG protocol and bank mapping have not been specified. The RTL therefore does not invent a controller or assign data types to banks. `gpu_geometry_fetch` exposes two abstract 64-bit read channels. Each channel uses:

- `*_req_valid`: request is being presented and remains asserted until accepted.
- `*_req_ready`: request acceptance.
- `*_req_addr`: address of one 64-bit record.
- `*_rsp_valid`: response data is valid.
- `*_rsp_data`: returned 64-bit record.

There is at most one outstanding read, and a response must arrive after its request handshake (not in the same cycle). The fetch FSM waits indefinitely for a response; add timeout/error handling in the eventual memory adapter if the controller requires it.

Use `gpu_triangle_pipeline` when a previous stage already supplies the three NDC vertices directly and you want the earlier `fragment_*` interface. Use `gpu_geometry_rasterizer_top` when the eventual controller can expose separate triangle and vertex read channels. Use `gpu_geometry_rasterizer_single_port_top` when there is one shared read port; that wrapper includes `gpu_geometry_read_mux`. Since geometry fetch is sequential, the mux never needs to arbitrate simultaneous triangle and vertex reads.

Address units are parameterized:

- `VERTEX_ADDR_SHIFT=0`: addresses count 64-bit words.
- `VERTEX_ADDR_SHIFT=3`: addresses count bytes, so the vertex index is multiplied by eight.
- `TRIANGLE_ADDR_STRIDE=1`: consecutive triangle records are one 64-bit word apart when word-addressed; set it to `8` when byte-addressed.

The memory adapter must still map these logical addresses to the actual MIG address fields. Four banks do not imply four independent simultaneous ports; no bank mapping is hardcoded here.

## 2. Centralized record layout

Edit **`rtl/gpu_config.vh`** to change field positions. The default format is:

### Vertex record: 64 bits

| Bits | Field | Format |
|---|---|---|
| `[63:48]` | X | signed Q1.15 |
| `[47:32]` | Y | signed Q1.15 |
| `[31:16]` | Z | signed Q1.15 |
| `[15:12]` | R | unsigned 4-bit |
| `[11:8]` | G | unsigned 4-bit |
| `[7:4]` | B | unsigned 4-bit |
| `[3:0]` | padding | ignored |

### Triangle record: 64 bits

| Bits | Field |
|---|---|
| `[63:48]` | vertex index 0 |
| `[47:32]` | vertex index 1 |
| `[31:16]` | vertex index 2 |
| `[15:0]` | padding (LSBs) |

The RTL extracts all six vertex fields and all three triangle indices through the macros in `gpu_config.vh`. Moving a field of the same width therefore requires editing only its MSB/LSB definitions. The default datapath widths are 16-bit coordinates, 4-bit channels, and 16-bit indices; changing a field's *width* also requires changing the matching width macro and datapath declarations, not just its bit positions.

## 3. Coordinate and rasterization conventions

- Input X/Y/Z are signed Q1.15 values.
- Viewport mapping is X: `[-1,+1)` to `[0,799]`, and Y: `[-1,+1)` to `[599,0]` (Y inverted for screen coordinates).
- The positive X endpoint code `16'h7fff` is explicitly mapped to column 799. The positive Y endpoint code maps to row 0.
- The rasterizer clips the **bounding box**, never individual vertices.
- Coverage is evaluated at pixel centers `(x+0.5, y+0.5)`.
- A top-left ownership test is used so a shared edge is assigned consistently to one triangle.
- The scan is incremental: each X step adds `2*A` to each doubled edge function; each row step adds `2*B`.
- Color and depth planes are calculated once per triangle. Four interpolators run in parallel (R/G/B/Z), each using the iterative signed divider for X and Y gradients. Once setup is complete, candidate samples advance in lockstep with the rasterizer.
- Color interpolation is affine in screen space. The vertex format does not contain clip-space W, so perspective-correct varying interpolation is not attempted.
- Z is converted from signed Q1.15 to unsigned 16-bit normalized depth by flipping its sign bit, then interpolated. There is no Z comparison or memory access.

**NDC clipping is not implemented.** This is consistent with the current scope. The configured Q1.15 input domain maps to the viewport; a later upstream clipper is required if the geometry source uses homogeneous clip coordinates or needs clipping against a 3D view volume before perspective division.

## 4. Module list

| File | Purpose |
|---|---|
| `gpu_config.vh` | Record fields, dimensions, numeric conventions |
| `gpu_viewport_transform.v` | Q1.15 NDC to integer screen coordinates |
| `gpu_triangle_setup.v` | Bounds, screen clipping, edge coefficients, signed area |
| `signed_divider.v` | Iterative signed restoring divider |
| `gpu_interpolator.v` | Per-attribute gradient setup and incremental sample interpolation |
| `gpu_triangle_engine.v` | Integrated triangle setup, raster scan, edge coverage, RGB/depth generation |
| `gpu_triangle_pipeline.v` | Compatibility wrapper for direct NDC triangle inputs and the earlier fragment interface |
| `gpu_sync_fifo.v` | Synchronous ready/valid FIFO |
| `gpu_geometry_fetch.v` | Triangle record read, index decode, sequential vertex reads |
| `gpu_geometry_read_mux.v` | Optional single-read-port request/response mux |
| `gpu_geometry_rasterizer_top.v` | Fetch + triangle FIFO + engine + pixel FIFO |
| `gpu_geometry_rasterizer_single_port_top.v` | Convenience top for one shared memory read interface |
| `gpu_demo_roms.v` | Small fixed geometry ROMs for FPGA smoke testing |
| `fpga/gpu_fpga_demo_top.v` | Nexys 4 DDR button/LED/seven-segment demonstration |

## 5. Valid/ready behavior

A transfer occurs only on a rising clock edge where `valid && ready` are both high.

- Triangle fetch holds the three vertex records stable while `triangle_valid` is high and `triangle_ready` is low.
- The triangle FIFO decouples fetch from triangle processing.
- The rasterizer holds the candidate pixel and all interpolated attributes while `pixel_valid` is high and `pixel_ready` is low.
- The pixel FIFO decouples the rasterizer from its eventual framebuffer writer.
- Top-level `done` is asserted only after all requested triangles have been processed **and the pixel FIFO has drained**. A consumer that holds `pixel_ready=0` will intentionally prevent completion.
- Top-level `error` is sticky until the next accepted start. Current errors indicate interpolation divide/overflow failure; a degenerate or invisible triangle is skipped without raising an error.

## 6. Simulation

Testbenches:

- `tb/tb_signed_divider.v`: positive/negative division, divide-by-zero, signed overflow.
- `tb/tb_gpu_triangle_engine.v`: constant RGB/depth preservation, coverage, reversed winding, backpressure stability, degenerate triangle, viewport boundary triangle, shared-edge rectangle tiling, duplicate-pixel check.
- `tb/tb_gpu_geometry_rasterizer_top.v`: end-to-end two-triangle indexed fetch with variable request acceptance/response delays, both FIFOs, output backpressure, duplicate-pixel check.

With Icarus Verilog installed, run:

```bash
./run_iverilog.sh
```

The testbenches use a 10 ns clock for simulation; this is not a requirement on the hardware clock. The package was assembled without an installed Icarus Verilog or Vivado executable in the authoring environment, so the simulations and synthesis have **not** been executed here. Run the script locally and resolve any tool-version-specific diagnostics before treating the RTL as verified.

## 7. Vivado / Nexys 4 DDR demonstration

Open Vivado Tcl Console in this directory and run:

```tcl
source create_vivado_project.tcl
```

The script creates a project for `xc7a100tcsg324-1`, selects `gpu_fpga_demo_top`, and adds `fpga/nexys4_ddr_demo.xdc`. The pin assignments are based on Digilent’s official Nexys 4 DDR master XDC.

The demo uses a small internal triangle ROM and three-vertex ROM. Press the center button (BTNC) to run the complete geometry-fetch-to-pixel path. The eight-digit display shows the number of pixels emitted; LEDs show error, done, busy, and low pixel-count bits. Pixel output is consumed continuously in this demonstration.

The top-level `clk` is an input. `start` is accepted as a one-shot request and must return low before another run can be launched. No clock wizard or clock-generation module is included. The supplied XDC constrains the onboard 100 MHz oscillator on E3. If the project supplies a different clock (for example, a 40 MHz generated clock), connect that clock to `clk` and replace the clock constraint with the actual period. The default debounce count is 400,000 cycles (4 ms at 100 MHz or 10 ms at 40 MHz); override `DEBOUNCE_CYCLES` if required.

The FPGA ROM demonstration verifies the RTL pipeline and handshake structure, **not DDR2/MIG operation**. The actual memory controller must be connected through the abstract read interface after its address units, request acceptance, response latency, and bank mapping are established.

## 8. Timing and resource note

The four interpolators each perform two iterative 48-bit divisions during triangle setup. That keeps the per-pixel path incremental rather than dividing every pixel, but it consumes divider and multiplier resources. The initial implementation prioritizes correctness and a transparent FSM over area optimization. Run Vivado synthesis and timing analysis at the actual clock target; do not assume timing closure merely because the design is RTL-synthesizable. If timing or DSP/LUT use is too high, the next optimization should be sharing the gradient divider or using narrower intermediate datapaths after range analysis.

## 9. Known integration items for the later memory phase

Only the following wrapper-level items should be needed when the memory system is ready:

1. Adapt the actual MIG/DDR2 read command/response signals to the ready/valid interface (or use the single-port top and adapt one read channel).
2. Set `VERTEX_ADDR_SHIFT`, `TRIANGLE_ADDR_STRIDE`, and base addresses to the real address-unit convention.
3. Update `gpu_config.vh` field positions to match the actual packed files.

No framebuffer, depth-test memory, or display logic is included in this package.
