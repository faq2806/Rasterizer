`include "gpu_config.vh"

// Compatibility/ingress wrapper for a previous stage that already supplies
// one triangle's three NDC vertices directly. This bypasses geometry memory;
// the full indexed-memory path is gpu_geometry_rasterizer_top.
// The fragment interface matches the earlier gpu_triangle_pipeline ports.
module gpu_triangle_pipeline (
    input  wire clk,
    input  wire reset_n,
    input  wire start,

    input  wire signed [15:0] x0_ndc, y0_ndc, z0_ndc,
    input  wire signed [15:0] x1_ndc, y1_ndc, z1_ndc,
    input  wire signed [15:0] x2_ndc, y2_ndc, z2_ndc,
    input  wire [3:0] r0, g0, b0,
    input  wire [3:0] r1, g1, b1,
    input  wire [3:0] r2, g2, b2,

    output wire [10:0] fragment_x,
    output wire [9:0] fragment_y,
    output wire [11:0] fragment_rgb,
    output wire [15:0] fragment_depth,
    output wire fragment_valid,
    input  wire fragment_ready,

    output wire busy,
    output reg done,
    output reg error
);
    localparam [1:0] IDLE = 2'd0, SEND = 2'd1, WAIT_DONE = 2'd2;
    reg [1:0] state;
    reg start_armed;
    reg [63:0] v0_reg, v1_reg, v2_reg;

    reg [63:0] v0_pack, v1_pack, v2_pack;
    always @* begin
        v0_pack = 64'd0;
        v1_pack = 64'd0;
        v2_pack = 64'd0;
        v0_pack[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB] = x0_ndc;
        v0_pack[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB] = y0_ndc;
        v0_pack[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] = z0_ndc;
        v0_pack[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB] = r0;
        v0_pack[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB] = g0;
        v0_pack[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB] = b0;

        v1_pack[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB] = x1_ndc;
        v1_pack[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB] = y1_ndc;
        v1_pack[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] = z1_ndc;
        v1_pack[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB] = r1;
        v1_pack[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB] = g1;
        v1_pack[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB] = b1;

        v2_pack[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB] = x2_ndc;
        v2_pack[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB] = y2_ndc;
        v2_pack[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] = z2_ndc;
        v2_pack[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB] = r2;
        v2_pack[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB] = g2;
        v2_pack[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB] = b2;
    end

    wire engine_triangle_ready;
    wire engine_busy, engine_done, engine_error;
    wire [10:0] engine_x;
    wire [9:0] engine_y;
    wire [11:0] engine_rgb;
    wire [15:0] engine_depth;
    wire engine_pixel_valid;

    gpu_triangle_engine u_engine (
        .clk(clk), .reset_n(reset_n),
        .triangle_valid(state == SEND), .triangle_ready(engine_triangle_ready),
        .vertex0(v0_reg), .vertex1(v1_reg), .vertex2(v2_reg),
        .pixel_x(engine_x), .pixel_y(engine_y), .pixel_rgb(engine_rgb),
        .pixel_depth(engine_depth), .pixel_valid(engine_pixel_valid), .pixel_ready(fragment_ready),
        .busy(engine_busy), .triangle_done(engine_done), .triangle_error(engine_error)
    );

    assign fragment_x = engine_x;
    assign fragment_y = engine_y;
    assign fragment_rgb = engine_rgb;
    assign fragment_depth = engine_depth;
    assign fragment_valid = engine_pixel_valid;
    assign busy = (state != IDLE) || engine_busy;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            start_armed <= 1'b1;
            v0_reg <= 0; v1_reg <= 0; v2_reg <= 0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!start)
                start_armed <= 1'b1;
            case (state)
                IDLE: begin
                    if (start && start_armed) begin
                        start_armed <= 1'b0;
                        v0_reg <= v0_pack;
                        v1_reg <= v1_pack;
                        v2_reg <= v2_pack;
                        error <= 1'b0;
                        state <= SEND;
                    end
                end
                SEND: begin
                    if (engine_triangle_ready)
                        state <= WAIT_DONE;
                end
                WAIT_DONE: begin
                    if (engine_error)
                        error <= 1'b1;
                    if (engine_done) begin
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
