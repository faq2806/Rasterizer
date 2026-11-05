# Creates a Vivado project for the rasterization-stage FPGA test.
# From the Vivado Tcl console:
#   cd <path-to>/gpu_rasterizer_project
#   source fpga_test/create_raster_test_project.tcl
# Optional: build the bitstream in batch mode in one go:
#   vivado -mode batch -source fpga_test/create_raster_test_project.tcl -tclargs build
#
# Core clock: set MMCM_OUT_DIV below (1000 MHz / div). 40 = 25 MHz (default, safe),
# 20 = 50 MHz, 16 = 62.5 MHz, 12 = 83.3 MHz, 10 = 100 MHz.

set mmcm_out_div 40

set proj_name raster_fpga_test
set proj_dir  [file normalize ./vivado_raster_test]
create_project $proj_name $proj_dir -part xc7a100tcsg324-1 -force

set rtl_dir [file normalize ./rtl]
set ft_dir  [file normalize ./fpga_test]

add_files -norecurse [list \
    $rtl_dir/gpu_config.vh \
    $rtl_dir/gpu_viewport_transform.v \
    $rtl_dir/gpu_triangle_setup.v \
    $rtl_dir/signed_divider.v \
    $rtl_dir/gpu_interpolator.v \
    $rtl_dir/gpu_triangle_engine.v \
    $ft_dir/raster_test_rom.v \
    $ft_dir/rt_support.v \
    $ft_dir/raster_test_harness.v \
    $ft_dir/raster_fpga_test_top.v]
set_property file_type {Verilog Header} [get_files $rtl_dir/gpu_config.vh]
set_property include_dirs [list $rtl_dir] [current_fileset]
set_property top raster_fpga_test_top [current_fileset]
set_property generic "MMCM_OUT_DIV=$mmcm_out_div" [current_fileset]

add_files -fileset constrs_1 $ft_dir/raster_fpga_test.xdc

add_files -fileset sim_1 $ft_dir/tb_raster_fpga_test.v
set_property include_dirs [list $rtl_dir] [get_filesets sim_1]
set_property top tb_raster_fpga_test [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Created $proj_name (core clock = [expr {1000.0 / $mmcm_out_div}] MHz)."
puts "Run Synthesis -> Implementation -> Generate Bitstream, then CHECK the timing summary (WNS >= 0)."

if {[info exists argv] && [llength $argv] > 0 && [lindex $argv 0] eq "build"} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    open_run impl_1
    report_timing_summary -file $proj_dir/timing_summary.rpt
    report_utilization    -file $proj_dir/utilization.rpt
    puts "Bitstream: $proj_dir/$proj_name.runs/impl_1/raster_fpga_test_top.bit"
    puts "Timing:    $proj_dir/timing_summary.rpt"
}
