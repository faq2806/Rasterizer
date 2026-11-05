`include "gpu_config.vh"

// Tiny synthesizable geometry ROMs used only by gpu_fpga_demo_top.
// They exercise triangle fetch, three sequential vertex reads, setup,
// rasterization, interpolation, and the output FIFO without a DDR2/MIG design.
module gpu_demo_triangle_rom (
    input  wire clk,
    input  wire reset_n,
    input  wire req_valid,
    output wire req_ready,
    input  wire [31:0] req_addr,
    output reg rsp_valid,
    output reg [63:0] rsp_data
);
    function [63:0] pack_demo_triangle;
        reg [63:0] t;
        begin
            t = 64'd0;
            t[`GPU_TRI_I0_MSB:`GPU_TRI_I0_LSB] = 16'd0;
            t[`GPU_TRI_I1_MSB:`GPU_TRI_I1_LSB] = 16'd1;
            t[`GPU_TRI_I2_MSB:`GPU_TRI_I2_LSB] = 16'd2;
            pack_demo_triangle = t;
        end
    endfunction
    localparam [63:0] DEMO_TRIANGLE = pack_demo_triangle();
    assign req_ready = 1'b1;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rsp_valid <= 1'b0;
            rsp_data <= 64'd0;
        end else begin
            rsp_valid <= req_valid && req_ready;
            if (req_valid && req_ready) begin
                if (req_addr == 0)
                    rsp_data <= DEMO_TRIANGLE;
                else
                    rsp_data <= 64'd0;
            end
        end
    end
endmodule

module gpu_demo_vertex_rom #(parameter ADDR_SHIFT = 0) (
    input  wire clk,
    input  wire reset_n,
    input  wire req_valid,
    output wire req_ready,
    input  wire [31:0] req_addr,
    output reg rsp_valid,
    output reg [63:0] rsp_data
);
    function [63:0] pack_demo_vertex;
        input [15:0] x;
        input [15:0] y;
        input [15:0] z;
        input [3:0] r;
        input [3:0] g;
        input [3:0] b;
        reg [63:0] t;
        begin
            t = 64'd0;
            t[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB] = x;
            t[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB] = y;
            t[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] = z;
            t[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB] = r;
            t[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB] = g;
            t[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB] = b;
            pack_demo_vertex = t;
        end
    endfunction
    localparam [63:0] VERTEX_0 = pack_demo_vertex(16'hC000,16'hC000,16'h0000,4'hF,4'h0,4'h0);
    localparam [63:0] VERTEX_1 = pack_demo_vertex(16'h4000,16'hC000,16'h0000,4'h0,4'hF,4'h0);
    localparam [63:0] VERTEX_2 = pack_demo_vertex(16'h0000,16'h4000,16'h0000,4'h0,4'h0,4'hF);
    assign req_ready = 1'b1;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rsp_valid <= 1'b0;
            rsp_data <= 64'd0;
        end else begin
            rsp_valid <= req_valid && req_ready;
            if (req_valid && req_ready) begin
                case (req_addr >> ADDR_SHIFT)
                    0: rsp_data <= VERTEX_0;
                    1: rsp_data <= VERTEX_1;
                    2: rsp_data <= VERTEX_2;
                    default: rsp_data <= 64'd0;
                endcase
            end
        end
    end
endmodule
