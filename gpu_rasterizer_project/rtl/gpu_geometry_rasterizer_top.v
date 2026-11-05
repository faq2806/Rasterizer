// Full geometry-memory-to-pixel-stream integration.
// This module deliberately does not implement the MIG/DDR2 controller. Connect
// its two read channels to a memory adapter matching the req/response contract.
module gpu_geometry_rasterizer_top #(
    parameter ADDR_WIDTH = 32,
    parameter VERTEX_ADDR_SHIFT = 0,  // 0: 64-bit word addresses; 3: byte addresses
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

    output wire tri_mem_req_valid,
    input  wire tri_mem_req_ready,
    output wire [ADDR_WIDTH-1:0] tri_mem_req_addr,
    input  wire tri_mem_rsp_valid,
    input  wire [63:0] tri_mem_rsp_data,

    output wire vertex_mem_req_valid,
    input  wire vertex_mem_req_ready,
    output wire [ADDR_WIDTH-1:0] vertex_mem_req_addr,
    input  wire vertex_mem_rsp_valid,
    input  wire [63:0] vertex_mem_rsp_data,

    output wire [10:0] pixel_x,
    output wire [9:0] pixel_y,
    output wire [11:0] pixel_rgb,
    output wire [15:0] pixel_depth,
    output wire pixel_valid,
    input  wire pixel_ready,

    output wire busy,
    output reg done,
    output reg error
);

    reg active_reg;
    reg fetch_finished;
    reg start_armed;
    wire fetch_start;
    assign fetch_start = start && !active_reg && start_armed;
    assign busy = active_reg;

    wire fetch_triangle_valid;
    wire fetch_triangle_ready;
    wire [63:0] fetch_v0, fetch_v1, fetch_v2;
    wire fetch_busy, fetch_done;

    gpu_geometry_fetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .VERTEX_ADDR_SHIFT(VERTEX_ADDR_SHIFT),
        .TRIANGLE_ADDR_STRIDE(TRIANGLE_ADDR_STRIDE)
    ) u_fetch (
        .clk(clk), .reset_n(reset_n), .start(fetch_start),
        .triangle_count(triangle_count),
        .triangle_base_addr(triangle_base_addr), .vertex_base_addr(vertex_base_addr),
        .tri_mem_req_valid(tri_mem_req_valid), .tri_mem_req_ready(tri_mem_req_ready),
        .tri_mem_req_addr(tri_mem_req_addr), .tri_mem_rsp_valid(tri_mem_rsp_valid),
        .tri_mem_rsp_data(tri_mem_rsp_data),
        .vertex_mem_req_valid(vertex_mem_req_valid), .vertex_mem_req_ready(vertex_mem_req_ready),
        .vertex_mem_req_addr(vertex_mem_req_addr), .vertex_mem_rsp_valid(vertex_mem_rsp_valid),
        .vertex_mem_rsp_data(vertex_mem_rsp_data),
        .triangle_valid(fetch_triangle_valid), .triangle_ready(fetch_triangle_ready),
        .vertex0(fetch_v0), .vertex1(fetch_v1), .vertex2(fetch_v2),
        .busy(fetch_busy), .done(fetch_done)
    );

    wire tri_fifo_in_ready, tri_fifo_out_valid, tri_fifo_out_ready;
    wire [191:0] tri_fifo_out_data;
    wire [191:0] tri_fifo_in_data = {fetch_v0, fetch_v1, fetch_v2};

    gpu_sync_fifo #(.WIDTH(192), .DEPTH(TRIANGLE_FIFO_DEPTH)) u_triangle_fifo (
        .clk(clk), .reset_n(reset_n),
        .in_valid(fetch_triangle_valid), .in_ready(tri_fifo_in_ready), .in_data(tri_fifo_in_data),
        .out_valid(tri_fifo_out_valid), .out_ready(tri_fifo_out_ready), .out_data(tri_fifo_out_data),
        .count()
    );
    assign fetch_triangle_ready = tri_fifo_in_ready;

    wire engine_triangle_ready;
    wire engine_pixel_valid;
    wire engine_pixel_ready;
    wire [10:0] engine_pixel_x;
    wire [9:0] engine_pixel_y;
    wire [11:0] engine_pixel_rgb;
    wire [15:0] engine_pixel_depth;
    wire engine_busy;
    wire engine_triangle_done;
    wire engine_triangle_error;

    gpu_triangle_engine u_engine (
        .clk(clk), .reset_n(reset_n),
        .triangle_valid(tri_fifo_out_valid), .triangle_ready(engine_triangle_ready),
        .vertex0(tri_fifo_out_data[191:128]),
        .vertex1(tri_fifo_out_data[127:64]),
        .vertex2(tri_fifo_out_data[63:0]),
        .pixel_x(engine_pixel_x), .pixel_y(engine_pixel_y),
        .pixel_rgb(engine_pixel_rgb), .pixel_depth(engine_pixel_depth),
        .pixel_valid(engine_pixel_valid), .pixel_ready(engine_pixel_ready),
        .busy(engine_busy), .triangle_done(engine_triangle_done),
        .triangle_error(engine_triangle_error)
    );
    assign tri_fifo_out_ready = engine_triangle_ready;

    wire pixel_fifo_in_ready, pixel_fifo_out_valid;
    wire [48:0] pixel_fifo_out_data;
    wire [48:0] pixel_fifo_in_data = {engine_pixel_depth, engine_pixel_rgb, engine_pixel_y, engine_pixel_x};
    assign engine_pixel_ready = pixel_fifo_in_ready;

    gpu_sync_fifo #(.WIDTH(49), .DEPTH(PIXEL_FIFO_DEPTH)) u_pixel_fifo (
        .clk(clk), .reset_n(reset_n),
        .in_valid(engine_pixel_valid), .in_ready(pixel_fifo_in_ready), .in_data(pixel_fifo_in_data),
        .out_valid(pixel_fifo_out_valid), .out_ready(pixel_ready), .out_data(pixel_fifo_out_data),
        .count()
    );

    assign pixel_valid = pixel_fifo_out_valid;
    assign pixel_x = pixel_fifo_out_data[10:0];
    assign pixel_y = pixel_fifo_out_data[20:11];
    assign pixel_rgb = pixel_fifo_out_data[32:21];
    assign pixel_depth = pixel_fifo_out_data[48:33];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_reg <= 1'b0;
            fetch_finished <= 1'b0;
            start_armed <= 1'b1;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!start)
                start_armed <= 1'b1;
            if (fetch_start) begin
                start_armed <= 1'b0;
                active_reg <= 1'b1;
                fetch_finished <= 1'b0;
                error <= 1'b0;
            end
            if (fetch_done)
                fetch_finished <= 1'b1;
            if (engine_triangle_error)
                error <= 1'b1;

            // Completion includes draining the output FIFO. The upstream
            // geometry path may be idle while accepted pixels remain queued.
            if (active_reg && fetch_finished && !fetch_busy &&
                !tri_fifo_out_valid && !engine_busy && !engine_pixel_valid &&
                !pixel_fifo_out_valid) begin
                active_reg <= 1'b0;
                fetch_finished <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule
