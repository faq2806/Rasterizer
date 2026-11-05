# Run from the Vivado Tcl console:
#   cd <path-to-gpu_rasterizer_project>
#   source create_vivado_project.tcl

set proj_name gpu_rasterizer_nexys4ddr
set proj_dir [file normalize ./vivado_project]
create_project $proj_name $proj_dir -part xc7a100tcsg324-1 -force

set rtl_dir [file normalize ./rtl]
set fpga_dir [file normalize ./fpga]
set tb_dir [file normalize ./tb]

read_verilog -include_dirs [list $rtl_dir] [list \
    $rtl_dir/gpu_viewport_transform.v \
    $rtl_dir/gpu_triangle_setup.v \
    $rtl_dir/signed_divider.v \
    $rtl_dir/gpu_interpolator.v \
    $rtl_dir/gpu_triangle_engine.v \
    $rtl_dir/gpu_triangle_pipeline.v \
    $rtl_dir/gpu_sync_fifo.v \
    $rtl_dir/gpu_geometry_fetch.v \
    $rtl_dir/gpu_geometry_read_mux.v \
    $rtl_dir/gpu_geometry_rasterizer_single_port_top.v \
    $rtl_dir/gpu_geometry_rasterizer_top.v \
    $rtl_dir/gpu_demo_roms.v \
    $fpga_dir/gpu_fpga_demo_top.v]

set_property top gpu_fpga_demo_top [current_fileset]
add_files -fileset constrs_1 $fpga_dir/nexys4_ddr_demo.xdc
update_compile_order -fileset sources_1

puts "Created $proj_name. Run Synthesis, Implementation, and Generate Bitstream."

add_files -fileset sim_1 [list \
    $tb_dir/tb_signed_divider.v \
    $tb_dir/tb_gpu_triangle_setup.v \
    $tb_dir/tb_gpu_triangle_engine.v \
    $tb_dir/tb_gpu_geometry_rasterizer_top.v]
set_property include_dirs [list $rtl_dir] [get_filesets sim_1]
set_property top tb_gpu_geometry_rasterizer_top [get_filesets sim_1]
update_compile_order -fileset sim_1
