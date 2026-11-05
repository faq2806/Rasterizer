#!/usr/bin/env python3
"""
Bit-exact golden model of gpu_triangle_engine + FPGA test-vector generator.

The model mirrors the RTL arithmetic exactly (viewport transform, triangle
setup, top-left edge rule, incremental scan, iterative-divider gradients,
rounding/clamping of the interpolators). Everything the FPGA harness checks
is derived from it.

Sub-commands
  gen      Generate fpga_test/raster_test_rom.v and fpga_test/test_vectors_report.txt
           (optionally PNG images of every expected test with --render DIR)
  list     Print the test list with expected values
  compare  Compare a UART log captured from the board (pixel dump and/or
           result lines) against the model; renders actual/expected/diff PNGs
  decode   Decode a 16-bit fail-flag word into check names
  capture  Read the board UART (needs pyserial) into a log file

Usage examples (run from gpu_rasterizer_project/):
  python tools/raster_golden.py gen
  python tools/raster_golden.py gen --render renders
  python tools/raster_golden.py decode 0x2006
  python tools/raster_golden.py capture COM5 uart_log.txt
  python tools/raster_golden.py compare uart_log.txt --out compare_out
"""
import argparse
import os
import random
import re
import struct
import sys
import zlib

W, H = 800, 600
MAX_TESTS = 64
STREAM_MAX_PIXELS = 64      # tests with <= this many pixels get a per-pixel golden stream
STREAM_BUDGET = 1024        # total golden-stream ROM entries

FLAG_NAMES = [
    "COUNT", "CRC_XY(coverage)", "CRC_RGB(color)", "CRC_Z(depth)", "BBOX",
    "RANGE(x/y off-screen)", "ORDER(raster order/dup in tri)", "STALL(handshake)",
    "DUP(overlap between tris)", "UNION(unique coverage)", "TIMEOUT", "ERROR(flag)",
    "PROTO(done/valid protocol)", "ATTR(attr outside vertex range)",
    "STREAM(per-pixel golden)", "FIRST/LAST pixel",
]


# ----------------------------------------------------------------------------
# Fixed-width integer helpers
# ----------------------------------------------------------------------------
def sx(v, bits):
    """Wrap v to a signed integer of `bits` bits (two's complement)."""
    m = (1 << bits) - 1
    v &= m
    return v - (1 << bits) if v >> (bits - 1) else v


def tdiv(n, d):
    """Signed division truncating toward zero (matches signed_divider.v)."""
    q = abs(n) // abs(d)
    return -q if (n < 0) != (d < 0) else q


# ----------------------------------------------------------------------------
# RTL-equivalent pieces
# ----------------------------------------------------------------------------
def viewport(xn, yn):
    """gpu_viewport_transform.v"""
    xs = xn + 32768                      # 0..65535
    ys = 32768 - yn                      # 1..65536
    x = sx(((xs * 799) & 0xFFFFFFFF) >> 16, 12)
    y = sx(((ys * 599) & 0xFFFFFFFF) >> 16, 12)
    if xn == 0x7FFF:
        x = 799
    return x, y


def round_clamp(v, width):
    """gpu_interpolator.v rounding (+0.5, symmetric) and unsigned clamp."""
    half = 1 << 15
    r = (v + half) >> 16 if v >= 0 else -(((-v) + half) >> 16)
    return 0 if r < 0 else min(r, (1 << width) - 1)


class Vtx:
    __slots__ = ("x", "y", "z", "r", "g", "b")

    def __init__(self, x, y, z, r, g, b):
        assert -32768 <= x <= 32767 and -32768 <= y <= 32767 and -32768 <= z <= 32767
        assert 0 <= r <= 15 and 0 <= g <= 15 and 0 <= b <= 15
        self.x, self.y, self.z, self.r, self.g, self.b = x, y, z, r, g, b

    def pack(self):
        return (((self.x & 0xFFFF) << 48) | ((self.y & 0xFFFF) << 32) |
                ((self.z & 0xFFFF) << 16) | (self.r << 12) | (self.g << 8) | (self.b << 4))


def rasterize(v0, v1, v2, audit=None):
    """Returns the pixel stream [(x, y, rgb12, depth16), ...] in emission order."""
    (x0, y0), (x1, y1), (x2, y2) = viewport(v0.x, v0.y), viewport(v1.x, v1.y), viewport(v2.x, v2.y)
    xmin = max(min(x0, x1, x2), 0)
    xmax = min(max(x0, x1, x2), 799)
    ymin = max(min(y0, y1, y2), 0)
    ymax = min(max(y0, y1, y2), 599)
    A = [sx(-(y1 - y0), 13), sx(-(y2 - y1), 13), sx(-(y0 - y2), 13)]
    B = [sx(x1 - x0, 13), sx(x2 - x1, 13), sx(x0 - x2, 13)]
    C = [sx(x0 * y1 - y0 * x1, 25), sx(x1 * y2 - y1 * x2, 25), sx(x2 * y0 - y2 * x0, 25)]
    area = sx((x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0), 26)
    if area == 0 or xmin > xmax or ymin > ymax:
        return []

    if area > 0:
        incl = [(A[k] > 0) or (A[k] == 0 and B[k] > 0) for k in range(3)]
    else:
        incl = [(A[k] < 0) or (A[k] == 0 and B[k] < 0) for k in range(3)]
    e_init = [sx(((A[k] * xmin + B[k] * ymin + C[k]) << 1) + A[k] + B[k], 32) for k in range(3)]

    attrs = [  # (a0, a1, a2, width)
        (v0.r, v1.r, v2.r, 4), (v0.g, v1.g, v2.g, 4), (v0.b, v1.b, v2.b, 4),
        ((v0.z & 0xFFFF) ^ 0x8000, (v1.z & 0xFFFF) ^ 0x8000, (v2.z & 0xFFFF) ^ 0x8000, 16),
    ]
    planes = []
    dx2 = sx(((xmin - x0) << 1) + 1, 16)
    dy2 = sx(((ymin - y0) << 1) + 1, 16)
    for a0, a1, a2, wdt in attrs:
        gxs = sx(sx(a0 * A[1] + a1 * A[2] + a2 * A[0], 48) << 16, 48)
        gys = sx(sx(a0 * B[1] + a1 * B[2] + a2 * B[0], 48) << 16, 48)
        gx = sx(tdiv(gxs, area), 48)
        gy = sx(tdiv(gys, area), 48)
        init = sx((a0 << 16) + (sx(gx * dx2 + gy * dy2, 64) >> 1), 64)
        planes.append((init, gx, gy, wdt))

    out = []
    pos = area > 0
    for y in range(ymin, ymax + 1):
        dy = y - ymin
        r0 = e_init[0] + 2 * B[0] * dy
        r1 = e_init[1] + 2 * B[1] * dy
        r2 = e_init[2] + 2 * B[2] * dy
        for x in range(xmin, xmax + 1):
            dx = x - xmin
            e0 = sx(r0 + 2 * A[0] * dx, 32)
            e1 = sx(r1 + 2 * A[1] * dx, 32)
            e2 = sx(r2 + 2 * A[2] * dx, 32)
            if pos:
                inside = ((e0 > 0 or (e0 == 0 and incl[0])) and (e1 > 0 or (e1 == 0 and incl[1]))
                          and (e2 > 0 or (e2 == 0 and incl[2])))
            else:
                inside = ((e0 < 0 or (e0 == 0 and incl[0])) and (e1 < 0 or (e1 == 0 and incl[1]))
                          and (e2 < 0 or (e2 == 0 and incl[2])))
            if not inside:
                continue
            vals = [round_clamp(sx(init + dy * gy + dx * gx, 64), wdt) for init, gx, gy, wdt in planes]
            out.append((x, y, (vals[0] << 8) | (vals[1] << 4) | vals[2], vals[3]))
            if audit is not None:
                # Ideal barycentric value at the pixel centre (float). E1 weights v0,
                # E2 weights v1, E0 weights v2; doubled edge values / (2*area).
                w0, w1, w2 = e1 / (2.0 * area), e2 / (2.0 * area), e0 / (2.0 * area)
                for k, (a0, a1, a2, wdt) in enumerate(attrs):
                    ideal = a0 * w0 + a1 * w1 + a2 * w2
                    ideal = min(max(ideal, 0.0), (1 << wdt) - 1)
                    err = abs(vals[k] - ideal)
                    if err > audit["max_err"][k]:
                        audit["max_err"][k] = err
                    if err > 0.5 + 1e-9:
                        audit["bad_round"][k] += 1
    return out


# ----------------------------------------------------------------------------
# Signatures (must match raster_test_harness.v)
# ----------------------------------------------------------------------------
def crc_step(crc, data, nbits):
    for i in range(nbits - 1, -1, -1):
        fb = ((crc >> 31) & 1) ^ ((data >> i) & 1)
        crc = (crc << 1) & 0xFFFFFFFF
        if fb:
            crc ^= 0x04C11DB7
    return crc


def pix_word(p):
    x, y, rgb, z = p
    return (x << 38) | (y << 28) | (rgb << 16) | z


def evaluate_test(tris, audit=None):
    """Simulate a whole test (sequence of triangles) the way the harness sees it."""
    pixels, seen = [], set()
    dup = attr_viol = 0
    for v0, v1, v2 in tris:
        rmin, rmax = min(v0.r, v1.r, v2.r), max(v0.r, v1.r, v2.r)
        gmin, gmax = min(v0.g, v1.g, v2.g), max(v0.g, v1.g, v2.g)
        bmin, bmax = min(v0.b, v1.b, v2.b), max(v0.b, v1.b, v2.b)
        zs = [(v.z & 0xFFFF) ^ 0x8000 for v in (v0, v1, v2)]
        zmin, zmax = min(zs), max(zs)
        for p in rasterize(v0, v1, v2, audit):
            x, y, rgb, z = p
            r, g, b = rgb >> 8, (rgb >> 4) & 15, rgb & 15
            if not (rmin <= r <= rmax and gmin <= g <= gmax and bmin <= b <= bmax and zmin <= z <= zmax):
                attr_viol += 1
            if (x, y) in seen:
                dup += 1
            seen.add((x, y))
            pixels.append(p)
    crc_xy = crc_rgb = crc_z = 0xFFFFFFFF
    for x, y, rgb, z in pixels:
        crc_xy = crc_step(crc_xy, (x << 16) | y, 32)
        crc_rgb = crc_step(crc_rgb, rgb, 16)
        crc_z = crc_step(crc_z, z, 16)
    if pixels:
        bbox = (min(p[0] for p in pixels), max(p[0] for p in pixels),
                min(p[1] for p in pixels), max(p[1] for p in pixels))
    else:
        bbox = (0x7FF, 0, 0x3FF, 0)   # harness reset values when no pixel arrives
    return dict(pixels=pixels, count=len(pixels), union=len(seen), dup_cnt=dup, attr=attr_viol,
                crc_xy=crc_xy, crc_rgb=crc_rgb, crc_z=crc_z, bbox=bbox,
                first=pix_word(pixels[0]) if pixels else 0,
                last=pix_word(pixels[-1]) if pixels else 0)


# ----------------------------------------------------------------------------
# Test definitions
# ----------------------------------------------------------------------------
def ndc_x_for(X):
    """Smallest Q1.15 x whose viewport column is exactly X."""
    if X == 799:
        return 0x7FFF
    xs = -(-X * 65536 // 799)
    for c in range(xs - 2, xs + 3):
        xn = c - 32768
        if -32768 <= xn <= 32767 and viewport(xn, 0)[0] == X:
            return xn
    raise ValueError(X)


def ndc_y_for(Y):
    """Q1.15 y whose viewport row is exactly Y."""
    ys = max(1, -(-Y * 65536 // 599))
    for c in range(ys - 2, ys + 3):
        yn = 32768 - c
        if -32768 <= yn <= 32767 and viewport(0, yn)[1] == Y:
            return yn
    raise ValueError(Y)


def S(X, Y, r=8, g=8, b=8, z=0):
    """Vertex given in integer screen pixels (maps back exactly through the viewport)."""
    return Vtx(ndc_x_for(X), ndc_y_for(Y), z, r, g, b)


def N(x, y, z=0, r=8, g=8, b=8):
    """Vertex given as raw Q1.15 integers."""
    return Vtx(x, y, z, r, g, b)


def build_tests():
    T = []

    def add(name, tris, dup=None):
        assert len(name) <= 16, name
        T.append(dict(name=name, tris=tris, dup=(len(tris) > 1) if dup is None else dup))

    # 0-5: the reference triangles from tb_gpu_triangle_engine plus winding/rotation variants
    c0 = N(-0x4000, -0x4000, 0, 5, 10, 3)
    c1 = N(0x4000, -0x4000, 0, 5, 10, 3)
    c2 = N(0, 0x4000, 0, 5, 10, 3)
    add("const_ccw", [(c0, c1, c2)])
    add("const_cw", [(c0, c2, c1)])
    g0 = N(-0x4000, -0x4000, 0x0000, 15, 0, 0)
    g1 = N(0x4000, -0x4000, 0x4000, 0, 15, 0)
    g2 = N(0x0000, 0x4000, 0x7FFF, 0, 0, 15)
    add("rgb_grad", [(g0, g1, g2)])
    add("rgb_grad_cw", [(g0, g2, g1)])
    add("rgb_grad_rot1", [(g1, g2, g0)])
    add("rgb_grad_rot2", [(g2, g0, g1)])

    # 6-11: isolate each interpolator channel
    add("red_ramp", [(S(100, 100, 0, 3, 3), S(700, 120, 15, 3, 3), S(300, 500, 7, 3, 3))])
    add("green_ramp", [(S(100, 100, 3, 0, 3), S(700, 120, 3, 15, 3), S(300, 500, 3, 7, 3))])
    add("blue_ramp", [(S(100, 100, 3, 3, 0), S(700, 120, 3, 3, 15), S(300, 500, 3, 3, 7))])
    add("depth_ramp", [(S(100, 100, 9, 9, 9, -32768), S(700, 120, 9, 9, 9, 32767),
                        S(300, 500, 9, 9, 9, 0))])
    add("depth_min_const", [(S(150, 80, 1, 2, 3, -32768), S(650, 200, 1, 2, 3, -32768),
                             S(200, 450, 1, 2, 3, -32768))])
    add("depth_max_const", [(S(150, 80, 4, 5, 6, 32767), S(650, 200, 4, 5, 6, 32767),
                             S(200, 450, 4, 5, 6, 32767))])

    # 12-18: large coverage, shared edges (dup/union checks) and meshes
    add("screen_half_bnd", [(N(-32768, -32768, 0, 15, 15, 15), N(32767, -32768, 0, 15, 0, 0),
                             N(-32768, 32767, 0, 0, 15, 0))])
    bl, br = N(-32768, -32768, -32768, 15, 0, 0), N(32767, -32768, 0, 0, 15, 0)
    tr, tl = N(32767, 32767, 32767, 0, 0, 15), N(-32768, 32767, 0, 15, 15, 0)
    add("full_screen_quad", [(bl, br, tr), (bl, tr, tl)])
    add("rect_tile_diag1", [(N(-0x4000, 0x4000, 0, 15, 0, 0), N(0x4000, 0x4000, 0, 0, 15, 0),
                             N(0x4000, -0x4000, 0, 0, 0, 15)),
                            (N(-0x4000, 0x4000, 0, 15, 0, 0), N(0x4000, -0x4000, 0, 0, 0, 15),
                             N(-0x4000, -0x4000, 0, 15, 15, 0))])
    p00, p10 = S(200, 150, 15, 0, 0, -20000), S(600, 150, 0, 15, 0, 0)
    p11, p01 = S(600, 450, 0, 0, 15, 20000), S(200, 450, 15, 15, 15, 5000)
    add("rect_tile_diag2", [(p00, p10, p01), (p10, p11, p01)])
    ctr = S(400, 300, 15, 15, 15, 0)
    q = [S(200, 100, 15, 0, 0, -10000), S(600, 100, 0, 15, 0, 10000),
         S(600, 500, 0, 0, 15, -10000), S(200, 500, 15, 15, 0, 10000)]
    add("fan4_square", [(ctr, q[i], q[(i + 1) % 4]) for i in range(4)])
    gx_, gy_ = [80, 240, 400, 560, 720], [60, 220, 380, 540]
    gv = [[S(gx_[i], gy_[j], (i * 4 + j) % 16, (i * 3 + j * 5) % 16, (15 - i * 2 - j) % 16,
             (i * 7000 - j * 6000)) for i in range(5)] for j in range(4)]
    mesh = []
    for j in range(3):
        for i in range(4):
            a, b, c, d = gv[j][i], gv[j][i + 1], gv[j + 1][i + 1], gv[j + 1][i]
            if (i + j) % 2 == 0:
                mesh += [(a, b, c), (a, c, d)]
            else:
                mesh += [(a, b, d), (b, c, d)]
    add("mesh_4x3", mesh)
    sp = [S(50 + 120 * (k // 2), 200 if k % 2 == 0 else 400, (k * 2) % 16, (k * 5) % 16,
            (15 - k) % 16, k * 4000 - 16000) for k in range(8)]
    add("strip_mixed_wind", [(sp[k], sp[k + 1], sp[k + 2]) for k in range(6)])

    # 19-21: degenerate triangles (must finish with zero pixels)
    pt = S(400, 300, 15, 15, 15)
    add("degen_point", [(pt, pt, pt)])
    add("degen_collinear", [(S(100, 100), S(200, 200), S(300, 300))])
    add("degen_horizontal", [(S(100, 300), S(400, 300), S(700, 300))])

    # 22-28: tiny triangles (per-pixel golden stream) and edge-ownership cases
    add("tiny_1px", [(S(10, 10, 15, 0, 0), S(12, 10, 0, 15, 0), S(10, 12, 0, 0, 15))])
    add("tiny_thin", [(S(60, 60, 15, 15, 0), S(63, 61, 0, 15, 15), S(62, 61, 15, 0, 15))])
    add("tiny_flat_top", [(S(20, 20, 15, 0, 0, -32768), S(28, 20, 0, 15, 0, 0),
                           S(24, 26, 0, 0, 15, 32767))])
    add("tiny_flat_bottom", [(S(20, 40, 15, 0, 0), S(24, 34, 0, 15, 0), S(28, 40, 0, 0, 15))])
    add("tiny_vert_left", [(S(40, 20, 15, 8, 0), S(40, 28, 0, 8, 15), S(46, 24, 8, 15, 8))])
    add("tiny_vert_right", [(S(60, 24, 2, 4, 6), S(66, 20, 12, 10, 8), S(66, 28, 1, 15, 3))])
    sa, sb, sc, sd = S(80, 80, 15, 0, 0), S(86, 80, 0, 15, 0), S(86, 86, 0, 0, 15), S(80, 86, 9, 9, 9)
    add("tiny_pair_shared", [(sa, sb, sc), (sa, sc, sd)])

    # 29-34: slivers, screen corners, colour clamping
    add("sliver_diag_long", [(S(5, 5, 15, 0, 0), S(795, 590, 0, 15, 0), S(790, 595, 0, 0, 15))])
    add("sliver_vertical", [(S(400, 2, 15, 15, 0), S(403, 597, 0, 15, 15), S(401, 597, 15, 0, 15))])
    add("sliver_horiz", [(S(2, 300, 3, 9, 15), S(797, 301, 15, 9, 3), S(797, 303, 9, 3, 15))])
    add("corner_top_right", [(S(799, 0, 15, 15, 15, 32767), S(700, 0, 15, 0, 0, 0),
                              S(799, 100, 0, 0, 15, -32768))])
    add("corner_bot_left", [(S(0, 599, 15, 15, 15), S(0, 500, 0, 15, 0), S(100, 599, 15, 0, 15))])
    add("color_clamp_ext", [(N(-32768, 32767, -32768, 0, 15, 0), N(32767, 0, 32767, 15, 0, 15),
                             N(-20000, -32768, 0, 15, 15, 0))])

    # 35-43: seeded random triangles
    rnd = random.Random(20261105)
    for k in range(8):
        vs = [N(rnd.randint(-30000, 30000), rnd.randint(-30000, 30000), rnd.randint(-32768, 32767),
                rnd.randint(0, 15), rnd.randint(0, 15), rnd.randint(0, 15)) for _ in range(3)]
        add("random_%d" % k, [tuple(vs)])
    vs = [N(rnd.randint(-32768, -20000), rnd.randint(-32768, -20000), rnd.randint(-32768, 32767), 0, 15, 7),
          N(rnd.randint(20000, 32767), rnd.randint(-32768, 0), rnd.randint(-32768, 32767), 15, 0, 7),
          N(rnd.randint(-5000, 5000), rnd.randint(20000, 32767), rnd.randint(-32768, 32767), 7, 7, 15)]
    add("random_big", [tuple(vs)])
    assert len(T) <= MAX_TESTS
    return T


def compute_all(verbose=True):
    tests = build_tests()
    stream_used = 0
    for i, t in enumerate(tests):
        audit = dict(max_err=[0.0] * 4, bad_round=[0] * 4)
        r = evaluate_test(t["tris"], audit)
        t.update(r)
        t["audit"] = audit
        t["stream"] = (0 < r["count"] <= STREAM_MAX_PIXELS) and stream_used + r["count"] <= STREAM_BUDGET
        t["stream_base"] = stream_used if t["stream"] else 0
        if t["stream"]:
            stream_used += r["count"]
        if verbose:
            print("  T%02d %-16s tris=%2d pixels=%6d" % (i, t["name"], len(t["tris"]), r["count"]),
                  file=sys.stderr)
    return tests, stream_used


# ----------------------------------------------------------------------------
# Output generation
# ----------------------------------------------------------------------------
def verilog_rom(tests, stream_used):
    tri_list = []
    L = []
    w = L.append
    w("// ============================================================================")
    w("// AUTO-GENERATED by tools/raster_golden.py -- DO NOT EDIT BY HAND.")
    w("// Re-generate with:  python tools/raster_golden.py gen")
    w("// Test table, triangle ROM and per-pixel golden-stream ROM for the FPGA")
    w("// rasterizer test harness. Expected values come from the bit-exact model.")
    w("// ============================================================================")
    w("")
    w("// Test flags: bit0 CHECK_DUP (bitmap overlap/union), bit1 CHECK_STREAM,")
    w("//             bit2 EXPECT_ERROR")
    w("module raster_test_rom (")
    w("    input  wire [5:0]   test_idx,")
    w("    output wire [6:0]   num_tests,")
    w("    output reg  [127:0] name,")
    w("    output reg  [7:0]   tri_start,")
    w("    output reg  [7:0]   tri_count,")
    w("    output reg  [3:0]   flags,")
    w("    output reg  [19:0]  exp_count,")
    w("    output reg  [19:0]  exp_union,")
    w("    output reg  [19:0]  exp_dup,")
    w("    output reg  [19:0]  exp_attr,")
    w("    output reg  [31:0]  exp_crc_xy,")
    w("    output reg  [31:0]  exp_crc_rgb,")
    w("    output reg  [31:0]  exp_crc_z,")
    w("    output reg  [41:0]  exp_bbox,      // {xmin[10:0], xmax[10:0], ymin[9:0], ymax[9:0]}")
    w("    output reg  [48:0]  exp_first,     // {x[10:0], y[9:0], rgb[11:0], depth[15:0]}")
    w("    output reg  [48:0]  exp_last,")
    w("    output reg  [9:0]   stream_base")
    w(");")
    w("    assign num_tests = 7'd%d;" % len(tests))
    w("    always @* begin")
    w("        name = {16{8'h20}}; tri_start = 8'd0; tri_count = 8'd0; flags = 4'd0;")
    w("        exp_count = 20'd0; exp_union = 20'd0; exp_dup = 20'd0; exp_attr = 20'd0;")
    w("        exp_crc_xy = 32'hFFFFFFFF; exp_crc_rgb = 32'hFFFFFFFF; exp_crc_z = 32'hFFFFFFFF;")
    w("        exp_bbox = {11'h7FF, 11'h000, 10'h3FF, 10'h000}; exp_first = 49'd0; exp_last = 49'd0;")
    w("        stream_base = 10'd0;")
    w("        case (test_idx)")
    for i, t in enumerate(tests):
        start = len(tri_list)
        tri_list += t["tris"]
        flags = (1 if t["dup"] else 0) | (2 if t["stream"] else 0)
        bx0, bx1, by0, by1 = t["bbox"]
        w("        6'd%d: begin // %s" % (i, t["name"]))
        w('            name = "%-16s";' % t["name"])
        w("            tri_start = 8'd%d; tri_count = 8'd%d; flags = 4'd%d;" % (start, len(t["tris"]), flags))
        w("            exp_count = 20'd%d; exp_union = 20'd%d; exp_dup = 20'd%d; exp_attr = 20'd%d;"
          % (t["count"], t["union"] if t["dup"] else 0, t["dup_cnt"] if t["dup"] else 0, t["attr"]))
        w("            exp_crc_xy = 32'h%08X; exp_crc_rgb = 32'h%08X; exp_crc_z = 32'h%08X;"
          % (t["crc_xy"], t["crc_rgb"], t["crc_z"]))
        w("            exp_bbox = {11'd%d, 11'd%d, 10'd%d, 10'd%d};" % (bx0, bx1, by0, by1))
        w("            exp_first = 49'h%013X; exp_last = 49'h%013X; stream_base = 10'd%d;"
          % (t["first"], t["last"], t["stream_base"]))
        w("        end")
    w("        default: ;")
    w("        endcase")
    w("    end")
    w("endmodule")
    w("")
    assert len(tri_list) <= 256, "triangle ROM exceeds 8-bit index"
    w("// Triangle ROM: three packed 64-bit vertices (layout from rtl/gpu_config.vh).")
    w("module raster_tri_rom (")
    w("    input  wire [7:0]  tri_idx,")
    w("    output reg  [63:0] v0,")
    w("    output reg  [63:0] v1,")
    w("    output reg  [63:0] v2")
    w(");")
    w("    always @* begin")
    w("        v0 = 64'd0; v1 = 64'd0; v2 = 64'd0;")
    w("        case (tri_idx)")
    for k, (a, b, c) in enumerate(tri_list):
        w("        8'd%d: begin v0 = 64'h%016X; v1 = 64'h%016X; v2 = 64'h%016X; end"
          % (k, a.pack(), b.pack(), c.pack()))
    w("        default: ;")
    w("        endcase")
    w("    end")
    w("endmodule")
    w("")
    w("// Golden per-pixel stream for small tests: {x[10:0], y[9:0], rgb[11:0], depth[15:0]}")
    w("module raster_stream_rom (")
    w("    input  wire [9:0]  addr,")
    w("    output reg  [48:0] word")
    w(");")
    w("    always @* begin")
    w("        case (addr)")
    a = 0
    for t in tests:
        if t["stream"]:
            for p in t["pixels"]:
                w("        10'd%d: word = 49'h%013X;" % (a, pix_word(p)))
                a += 1
    assert a == stream_used
    w("        default: word = 49'd0;")
    w("        endcase")
    w("    end")
    w("endmodule")
    return "\n".join(L) + "\n"


def report_text(tests):
    L = []
    L.append("Expected results for the FPGA rasterizer test (generated by tools/raster_golden.py)")
    L.append("All values hex unless noted. BBOX = xmin,xmax,ymin,ymax. FIRST/LAST = x,y,rgb,depth.")
    L.append("Flags: D = dup/union bitmap check, S = per-pixel golden stream check.")
    L.append("")
    L.append("%-3s %-16s %4s %-2s %6s %8s %8s %8s %-15s %-16s %-16s" %
             ("#", "name", "tris", "ck", "count", "CRC_XY", "CRC_RGB", "CRC_Z", "BBOX", "FIRST", "LAST"))
    for i, t in enumerate(tests):
        ck = ("D" if t["dup"] else "-") + ("S" if t["stream"] else "-")

        def pw(v):
            return "%03X,%03X,%03X,%04X" % (v >> 38, (v >> 28) & 0x3FF, (v >> 16) & 0xFFF, v & 0xFFFF)
        L.append("%02X  %-16s %4d %-2s %06X %08X %08X %08X %03X,%03X,%03X,%03X %s %s" %
                 (i, t["name"], len(t["tris"]), ck, t["count"], t["crc_xy"], t["crc_rgb"], t["crc_z"],
                  t["bbox"][0], t["bbox"][1], t["bbox"][2], t["bbox"][3], pw(t["first"]), pw(t["last"])))
    L.append("")
    L.append("Union/dup/attr expectations (dup tests only for union/dup):")
    for i, t in enumerate(tests):
        if t["dup"] or t["attr"]:
            L.append("  %02X %-16s union=%05X dup=%05X attr_viol=%05X" %
                     (i, t["name"], t["union"], t["dup_cnt"], t["attr"]))
    L.append("")
    L.append("Interpolation audit vs. ideal floating-point barycentric (max |error| in LSB, "
             "pixels whose rounding differs from ideal):")
    for i, t in enumerate(tests):
        a = t["audit"]
        L.append("  %02X %-16s R %.3f/%d  G %.3f/%d  B %.3f/%d  Z %.3f/%d" %
                 (i, t["name"], a["max_err"][0], a["bad_round"][0], a["max_err"][1], a["bad_round"][1],
                  a["max_err"][2], a["bad_round"][2], a["max_err"][3], a["bad_round"][3]))
    return "\n".join(L) + "\n"


def algorithm_warnings(tests):
    warns = []
    for i, t in enumerate(tests):
        if t["dup_cnt"]:
            warns.append("T%02d %s: %d pixels are drawn by more than one triangle (top-left rule "
                         "violation in the RTL algorithm itself)" % (i, t["name"], t["dup_cnt"]))
        if t["attr"]:
            warns.append("T%02d %s: %d pixels have an attribute outside the vertex range "
                         "(interpolator overshoot in the RTL algorithm)" % (i, t["name"], t["attr"]))
        a = t["audit"]
        for k, ch in enumerate("RGBZ"):
            if a["max_err"][k] > 1.0 + 1e-9:
                warns.append("T%02d %s: %s interpolation error up to %.3f LSB vs. ideal"
                             % (i, t["name"], ch, a["max_err"][k]))
    return warns


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def render(pixels, path, mode="rgb"):
    img = bytearray([24, 24, 24] * (W * H))
    for x, y, rgb, z in pixels:
        if 0 <= x < W and 0 <= y < H:
            o = (y * W + x) * 3
            if mode == "rgb":
                img[o:o + 3] = bytes([(rgb >> 8) * 17, ((rgb >> 4) & 15) * 17, (rgb & 15) * 17])
            else:
                img[o:o + 3] = bytes([z >> 8] * 3)
    write_png(path, W, H, img)


def cmd_gen(args):
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.normpath(os.path.join(here, "..", "fpga_test"))
    print("Running bit-exact model for all tests ...", file=sys.stderr)
    tests, used = compute_all()
    with open(os.path.join(out_dir, "raster_test_rom.v"), "w", newline="\n") as f:
        f.write(verilog_rom(tests, used))
    with open(os.path.join(out_dir, "test_vectors_report.txt"), "w", newline="\n") as f:
        f.write(report_text(tests))
    print("Wrote %d tests, %d triangles, %d golden-stream pixels to %s" %
          (len(tests), sum(len(t["tris"]) for t in tests), used, out_dir), file=sys.stderr)
    for wmsg in algorithm_warnings(tests):
        print("ALGORITHM NOTE: " + wmsg, file=sys.stderr)
    if args.render:
        os.makedirs(args.render, exist_ok=True)
        for i, t in enumerate(tests):
            render(t["pixels"], os.path.join(args.render, "T%02d_%s_rgb.png" % (i, t["name"])))
            render(t["pixels"], os.path.join(args.render, "T%02d_%s_depth.png" % (i, t["name"])), "z")
        print("Rendered expected images to %s" % args.render, file=sys.stderr)


def decode_flags(v):
    return [FLAG_NAMES[b] for b in range(16) if (v >> b) & 1]


def cmd_decode(args):
    v = int(args.flags, 16)
    names = decode_flags(v)
    print("0x%04X -> %s" % (v, ", ".join(names) if names else "no failures"))


def cmd_list(args):
    tests, _ = compute_all(verbose=False)
    print(report_text(tests))


RES_RE = re.compile(r"^T([0-9A-F]{2}) (PASS|FAIL) (.{16}) F=([0-9A-F]{4})")
PIX_RE = re.compile(r"^P ([0-9A-F]{3}),([0-9A-F]{3}),([0-9A-F]{3}),([0-9A-F]{4})")


def cmd_compare(args):
    tests = build_tests()      # pixels are evaluated lazily, only for dumped tests
    os.makedirs(args.out, exist_ok=True)
    pending = []
    n_fail = 0
    with open(args.log, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = PIX_RE.match(line)
            if m:
                pending.append(tuple(int(g, 16) for g in m.groups()))
                continue
            m = RES_RE.match(line)
            if not m:
                continue
            idx, verdict, flags = int(m.group(1), 16), m.group(2), int(m.group(4), 16)
            if verdict == "FAIL":
                n_fail += 1
                print("T%02X %s FAIL: %s" % (idx, m.group(3).strip(), ", ".join(decode_flags(flags))))
            if pending and idx < len(tests):
                if "pixels" not in tests[idx]:
                    tests[idx].update(evaluate_test(tests[idx]["tris"]))
                exp = tests[idx]["pixels"]
                act = pending
                print("T%02X %s: dumped %d pixels, model %d" % (idx, tests[idx]["name"], len(act), len(exp)))
                shown = 0
                for k in range(max(len(act), len(exp))):
                    a = act[k] if k < len(act) else None
                    e = exp[k] if k < len(exp) else None
                    if a != e:
                        if shown < args.max_diff:
                            print("   pixel #%d  got=%s  exp=%s" % (k, a, e))
                        shown += 1
                print("   %d differing stream positions" % shown)
                ea = {(p[0], p[1]): p for p in exp}
                aa = {(p[0], p[1]): p for p in act}
                img = bytearray([24, 24, 24] * (W * H))
                for key in set(ea) | set(aa):
                    x, y = key
                    if not (0 <= x < W and 0 <= y < H):
                        continue
                    o = (y * W + x) * 3
                    if key in ea and key in aa:
                        col = (0, 160, 0) if ea[key] == aa[key] else (255, 255, 0)
                    elif key in ea:
                        col = (255, 0, 0)       # missing on hardware
                    else:
                        col = (0, 128, 255)     # extra on hardware
                    img[o:o + 3] = bytes(col)
                base = os.path.join(args.out, "T%02X_%s" % (idx, tests[idx]["name"]))
                write_png(base + "_diff.png", W, H, img)
                render(act, base + "_actual.png")
                render(exp, base + "_expected.png")
                print("   images: %s_{actual,expected,diff}.png (diff: green ok, yellow attr "
                      "differs, red missing, blue extra)" % base)
            pending = []
    print("%d failing result line(s) in log" % n_fail)


def cmd_capture(args):
    try:
        import serial
    except ImportError:
        sys.exit("pyserial not installed: pip install pyserial  (or log the terminal with PuTTY/TeraTerm)")
    with serial.Serial(args.port, args.baud, timeout=1) as s, open(args.out, "w", newline="\n") as f:
        print("Capturing %s @ %d -> %s  (press BTNC on the board; Ctrl+C to stop)" % (args.port, args.baud, args.out))
        buf = b""
        try:
            while True:
                buf += s.read(4096)
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("ascii", "replace").rstrip("\r")
                    f.write(text + "\n")
                    if not text.startswith("P "):
                        print(text)
                    if text.startswith("=== RESULT") and not args.keep_going:
                        return
        except KeyboardInterrupt:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--render", metavar="DIR", help="also write expected PNG images")
    g.set_defaults(fn=cmd_gen)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    d = sub.add_parser("decode")
    d.add_argument("flags", help="16-bit hex flag word, e.g. 2006")
    d.set_defaults(fn=cmd_decode)
    c = sub.add_parser("compare")
    c.add_argument("log")
    c.add_argument("--out", default="compare_out")
    c.add_argument("--max-diff", type=int, default=20)
    c.set_defaults(fn=cmd_compare)
    p = sub.add_parser("capture")
    p.add_argument("port")
    p.add_argument("out")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--keep-going", action="store_true", help="do not stop at the RESULT line (soak mode)")
    p.set_defaults(fn=cmd_capture)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
