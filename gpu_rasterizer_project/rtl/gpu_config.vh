`ifndef GPU_CONFIG_VH
`define GPU_CONFIG_VH

// -----------------------------------------------------------------------------
// Central geometry record format. Edit this file if the packed memory layout
// changes. All extraction logic references these definitions.
//
// Default vertex record (64 bits):
//   [63:48] X : signed Q1.15
//   [47:32] Y : signed Q1.15
//   [31:16] Z : signed Q1.15
//   [15:12] R : unsigned 4-bit
//   [11: 8] G : unsigned 4-bit
//   [ 7: 4] B : unsigned 4-bit
//   [ 3: 0] padding (LSBs)
//
// Default triangle record (64 bits):
//   [63:48] vertex index 0 (16-bit)
//   [47:32] vertex index 1 (16-bit)
//   [31:16] vertex index 2 (16-bit)
//   [15: 0] padding (LSBs)
//
// Positions are configurable independently. The field widths must continue
// to match GPU_COORD_WIDTH / GPU_COLOR_WIDTH / GPU_INDEX_WIDTH unless the
// corresponding datapath widths are changed as well.
// -----------------------------------------------------------------------------

`define GPU_SCREEN_WIDTH       800
`define GPU_SCREEN_HEIGHT      600
`define GPU_COORD_WIDTH        16
`define GPU_COORD_FRAC_BITS    15
`define GPU_COLOR_WIDTH        4
`define GPU_INDEX_WIDTH        16
`define GPU_VERTEX_WIDTH       64
`define GPU_TRIANGLE_WIDTH     64
`define GPU_PIXEL_X_WIDTH      11
`define GPU_PIXEL_Y_WIDTH      10
`define GPU_PIXEL_RGB_WIDTH    12
`define GPU_PIXEL_DEPTH_WIDTH  16

// Vertex fields. MSB/LSB pairs may be edited without changing RTL.
`define GPU_VTX_X_MSB 63
`define GPU_VTX_X_LSB 48
`define GPU_VTX_Y_MSB 47
`define GPU_VTX_Y_LSB 32
`define GPU_VTX_Z_MSB 31
`define GPU_VTX_Z_LSB 16
`define GPU_VTX_R_MSB 15
`define GPU_VTX_R_LSB 12
`define GPU_VTX_G_MSB 11
`define GPU_VTX_G_LSB 8
`define GPU_VTX_B_MSB 7
`define GPU_VTX_B_LSB 4

// Triangle index fields. LSB padding remains reserved by default.
`define GPU_TRI_I0_MSB 63
`define GPU_TRI_I0_LSB 48
`define GPU_TRI_I1_MSB 47
`define GPU_TRI_I1_LSB 32
`define GPU_TRI_I2_MSB 31
`define GPU_TRI_I2_LSB 16

// Pixel center convention: integer screen coordinates represent pixel
// corners; coverage and interpolation are evaluated at (x+0.5, y+0.5).
`define GPU_INTERP_FRAC_BITS 16

`endif
