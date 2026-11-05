#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL="$ROOT/rtl"
TB="$ROOT/tb"
FPGA="$ROOT/fpga"
OUT="$ROOT/sim_build"
mkdir -p "$OUT"

run_sim() {
  local image="$1"
  local log="$2"
  vvp "$image" | tee "$log"
  if grep -q "FAIL:" "$log"; then
    echo "Simulation failed: $log" >&2
    exit 1
  fi
}

iverilog -g2005 -I "$RTL" -s tb_gpu_triangle_setup -o "$OUT/tb_setup.vvp" \
  "$RTL/gpu_triangle_setup.v" \
  "$TB/tb_gpu_triangle_setup.v"
run_sim "$OUT/tb_setup.vvp" "$OUT/tb_setup.log"

iverilog -g2005 -I "$RTL" -s tb_signed_divider -o "$OUT/tb_divider.vvp" \
  "$RTL/signed_divider.v" \
  "$TB/tb_signed_divider.v"
run_sim "$OUT/tb_divider.vvp" "$OUT/tb_divider.log"

iverilog -g2005 -I "$RTL" -s tb_gpu_triangle_engine -o "$OUT/tb_engine.vvp" \
  "$RTL/gpu_viewport_transform.v" \
  "$RTL/gpu_triangle_setup.v" \
  "$RTL/signed_divider.v" \
  "$RTL/gpu_interpolator.v" \
  "$RTL/gpu_triangle_engine.v" \
  "$RTL/gpu_triangle_pipeline.v" \
  "$TB/tb_gpu_triangle_engine.v"
run_sim "$OUT/tb_engine.vvp" "$OUT/tb_engine.log"

iverilog -g2005 -I "$RTL" -s tb_gpu_geometry_rasterizer_top -o "$OUT/tb_top.vvp" \
  "$RTL/gpu_viewport_transform.v" \
  "$RTL/gpu_triangle_setup.v" \
  "$RTL/signed_divider.v" \
  "$RTL/gpu_interpolator.v" \
  "$RTL/gpu_triangle_engine.v" \
  "$RTL/gpu_sync_fifo.v" \
  "$RTL/gpu_geometry_fetch.v" \
  "$RTL/gpu_geometry_read_mux.v" \
  "$RTL/gpu_geometry_rasterizer_top.v" \
  "$RTL/gpu_geometry_rasterizer_single_port_top.v" \
  "$RTL/gpu_triangle_pipeline.v" \
  "$TB/tb_gpu_geometry_rasterizer_top.v"
run_sim "$OUT/tb_top.vvp" "$OUT/tb_top.log"

# Parse/synthesis-front-end check for the board top and all FPGA-only sources.
iverilog -g2005 -I "$RTL" -s gpu_fpga_demo_top -tnull \
  "$RTL/gpu_viewport_transform.v" \
  "$RTL/gpu_triangle_setup.v" \
  "$RTL/signed_divider.v" \
  "$RTL/gpu_interpolator.v" \
  "$RTL/gpu_triangle_engine.v" \
  "$RTL/gpu_sync_fifo.v" \
  "$RTL/gpu_geometry_fetch.v" \
  "$RTL/gpu_geometry_read_mux.v" \
  "$RTL/gpu_geometry_rasterizer_top.v" \
  "$RTL/gpu_demo_roms.v" \
  "$FPGA/gpu_fpga_demo_top.v"
