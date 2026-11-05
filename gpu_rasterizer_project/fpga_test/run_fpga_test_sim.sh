#!/usr/bin/env bash
# Simulates the complete FPGA rasterizer test top with Icarus Verilog.
# Run from anywhere:  bash fpga_test/run_fpga_test_sim.sh
# Re-generate the test ROM first if you changed tests or the RTL arithmetic:
#   python tools/raster_golden.py gen
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL="$ROOT/rtl"
FT="$ROOT/fpga_test"
OUT="$ROOT/sim_build"
mkdir -p "$OUT"

iverilog -g2005 -Wall -Wno-timescale -I "$RTL" -s tb_raster_fpga_test -o "$OUT/tb_fpga_test.vvp" \
  "$RTL/gpu_viewport_transform.v" \
  "$RTL/gpu_triangle_setup.v" \
  "$RTL/signed_divider.v" \
  "$RTL/gpu_interpolator.v" \
  "$RTL/gpu_triangle_engine.v" \
  "$FT/raster_test_rom.v" \
  "$FT/rt_support.v" \
  "$FT/raster_test_harness.v" \
  "$FT/raster_fpga_test_top.v" \
  "$FT/tb_raster_fpga_test.v"

vvp "$OUT/tb_fpga_test.vvp" | tee "$OUT/tb_fpga_test.log"
grep -q "ALL FPGA HARNESS SIMULATION PHASES PASSED" "$OUT/tb_fpga_test.log"
