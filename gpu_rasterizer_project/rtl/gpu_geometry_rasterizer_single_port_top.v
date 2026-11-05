// Convenience wrapper for a single shared memory read port.
// Use this when the future DDR2/MIG adapter exposes only one read channel.
// The geometry-fetch controller is sequential; the mux routes all triangle
// and vertex read requests and returns each response to the right FSM input.
module gpu_geometry_rasterizer_single_port_top #(
    parameter ADDR_WIDTH = 32,
    parameter VERTEX_ADDR_SHIFT = 0,
    parameter TRIANGLE_ADDR_STRIDE = 1,
    parameter TRIANGLE_FIFO_DEPTH = 4,
    parameter PIXEL_FIFO_DEPTH = 64
)(
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    input  wire [31:0] triangle_count,
    input  wire [ADDR_WIDTH-1:0] triangle_base_addr,
    input  wire [ADDR_WIDTH-1:0] vertex_base_addr,

    output wire mem_req_valid,
    input  wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input  wire mem_rsp_valid,
    input  wire [63:0] mem_rsp_data,

    output wire [10:0] pixel_x,
    output wire [9:0] pixel_y,
    output wire [11:0] pixel_rgb,
    output wire [15:0] pixel_depth,
    output wire pixel_valid,
    input  wire pixel_ready,
    output wire busy,
    output wire done,
    output wire error
);
    wire tri_req_valid, tri_req_ready, tri_rsp_valid;
    wire [ADDR_WIDTH-1:0] tri_req_addr;
    wire [63:0] tri_rsp_data;
    wire vtx_req_valid, vtx_req_ready, vtx_rsp_valid;
    wire [ADDR_WIDTH-1:0] vtx_req_addr;
    wire [63:0] vtx_rsp_data;

    gpu_geometry_read_mux #(.ADDR_WIDTH(ADDR_WIDTH)) u_read_mux (
        .clk(clk), .reset_n(reset_n),
        .tri_req_valid(tri_req_valid), .tri_req_ready(tri_req_ready), .tri_req_addr(tri_req_addr),
        .tri_rsp_valid(tri_rsp_valid), .tri_rsp_data(tri_rsp_data),
        .vertex_req_valid(vtx_req_valid), .vertex_req_ready(vtx_req_ready), .vertex_req_addr(vtx_req_addr),
        .vertex_rsp_valid(vtx_rsp_valid), .vertex_rsp_data(vtx_rsp_data),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_data(mem_rsp_data)
    );

    gpu_geometry_rasterizer_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .VERTEX_ADDR_SHIFT(VERTEX_ADDR_SHIFT),
        .TRIANGLE_ADDR_STRIDE(TRIANGLE_ADDR_STRIDE),
        .TRIANGLE_FIFO_DEPTH(TRIANGLE_FIFO_DEPTH),
        .PIXEL_FIFO_DEPTH(PIXEL_FIFO_DEPTH)
    ) u_pipeline (
        .clk(clk), .reset_n(reset_n), .start(start),
        .triangle_count(triangle_count),
        .triangle_base_addr(triangle_base_addr), .vertex_base_addr(vertex_base_addr),
        .tri_mem_req_valid(tri_req_valid), .tri_mem_req_ready(tri_req_ready),
        .tri_mem_req_addr(tri_req_addr), .tri_mem_rsp_valid(tri_rsp_valid), .tri_mem_rsp_data(tri_rsp_data),
        .vertex_mem_req_valid(vtx_req_valid), .vertex_mem_req_ready(vtx_req_ready),
        .vertex_mem_req_addr(vtx_req_addr), .vertex_mem_rsp_valid(vtx_rsp_valid), .vertex_mem_rsp_data(vtx_rsp_data),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_rgb(pixel_rgb), .pixel_depth(pixel_depth),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .busy(busy), .done(done), .error(error)
    );
endmodule
