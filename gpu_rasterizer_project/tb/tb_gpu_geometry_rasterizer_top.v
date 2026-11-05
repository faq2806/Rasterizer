`timescale 1ns/1ps
`include "gpu_config.vh"

// End-to-end test: delayed memory responses -> indexed fetch -> triangle FIFO
// -> setup/interpolation/rasterization -> pixel FIFO -> ready/valid consumer.
module tb_gpu_geometry_rasterizer_top;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg start = 0;
    reg [31:0] cycle_count = 0;

    wire tri_req_valid, tri_req_ready;
    wire [31:0] tri_req_addr;
    reg tri_rsp_valid = 0;
    reg [63:0] tri_rsp_data = 0;
    reg tri_pending = 0;
    reg [2:0] tri_delay = 0;
    reg [31:0] tri_addr_saved = 0;

    wire vtx_req_valid, vtx_req_ready;
    wire [31:0] vtx_req_addr;
    reg vtx_rsp_valid = 0;
    reg [63:0] vtx_rsp_data = 0;
    reg vtx_pending = 0;
    reg [2:0] vtx_delay = 0;
    reg [31:0] vtx_addr_saved = 0;

    wire [10:0] pixel_x;
    wire [9:0] pixel_y;
    wire [11:0] pixel_rgb;
    wire [15:0] pixel_depth;
    wire pixel_valid;
    reg pixel_ready = 0;
    wire busy, done, error;

    assign tri_req_ready = !tri_pending && ((cycle_count % 3) != 0);
    assign vtx_req_ready = !vtx_pending && ((cycle_count % 4) != 0);

    function [63:0] make_vertex;
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
            make_vertex = t;
        end
    endfunction
    function [63:0] triangle_rom;
        input [31:0] addr;
        reg [63:0] t;
        begin
            t = 64'd0;
            if (addr == 0) begin
                t[`GPU_TRI_I0_MSB:`GPU_TRI_I0_LSB] = 16'd0;
                t[`GPU_TRI_I1_MSB:`GPU_TRI_I1_LSB] = 16'd1;
                t[`GPU_TRI_I2_MSB:`GPU_TRI_I2_LSB] = 16'd2;
            end else begin
                t[`GPU_TRI_I0_MSB:`GPU_TRI_I0_LSB] = 16'd3;
                t[`GPU_TRI_I1_MSB:`GPU_TRI_I1_LSB] = 16'd4;
                t[`GPU_TRI_I2_MSB:`GPU_TRI_I2_LSB] = 16'd5;
            end
            triangle_rom = t;
        end
    endfunction
    function [63:0] vertex_rom;
        input [31:0] addr;
        begin
            case (addr)
                0: vertex_rom = make_vertex(16'hC000,16'hC000,16'h0000,4'hF,4'h0,4'h0);
                1: vertex_rom = make_vertex(16'h4000,16'hC000,16'h0000,4'h0,4'hF,4'h0);
                2: vertex_rom = make_vertex(16'h0000,16'h4000,16'h0000,4'h0,4'h0,4'hF);
                3: vertex_rom = make_vertex(16'h4000,16'h4000,16'h0000,4'hF,4'hF,4'h0);
                4: vertex_rom = make_vertex(16'h7FFF,16'h4000,16'h0000,4'h0,4'hF,4'hF);
                5: vertex_rom = make_vertex(16'h7FFF,16'h7FFF,16'h0000,4'hF,4'h0,4'hF);
                default: vertex_rom = 64'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cycle_count <= 0;
            tri_rsp_valid <= 0; tri_rsp_data <= 0;
            tri_pending <= 0; tri_delay <= 0; tri_addr_saved <= 0;
            vtx_rsp_valid <= 0; vtx_rsp_data <= 0;
            vtx_pending <= 0; vtx_delay <= 0; vtx_addr_saved <= 0;
            pixel_ready <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            pixel_ready <= ((cycle_count % 7) == 0);

            tri_rsp_valid <= 1'b0;
            if (!tri_pending && tri_req_valid && tri_req_ready) begin
                tri_pending <= 1'b1;
                tri_delay <= 3'd2;
                tri_addr_saved <= tri_req_addr;
            end else if (tri_pending) begin
                if (tri_delay == 0) begin
                    tri_rsp_valid <= 1'b1;
                    tri_rsp_data <= triangle_rom(tri_addr_saved);
                    tri_pending <= 1'b0;
                end else begin
                    tri_delay <= tri_delay - 1'b1;
                end
            end

            vtx_rsp_valid <= 1'b0;
            if (!vtx_pending && vtx_req_valid && vtx_req_ready) begin
                vtx_pending <= 1'b1;
                vtx_delay <= vtx_req_addr[1:0] + 1'b1;
                vtx_addr_saved <= vtx_req_addr;
            end else if (vtx_pending) begin
                if (vtx_delay == 0) begin
                    vtx_rsp_valid <= 1'b1;
                    vtx_rsp_data <= vertex_rom(vtx_addr_saved);
                    vtx_pending <= 1'b0;
                end else begin
                    vtx_delay <= vtx_delay - 1'b1;
                end
            end
        end
    end

    gpu_geometry_rasterizer_top #(
        .ADDR_WIDTH(32), .VERTEX_ADDR_SHIFT(0), .TRIANGLE_ADDR_STRIDE(1),
        .TRIANGLE_FIFO_DEPTH(4), .PIXEL_FIFO_DEPTH(8)
    ) dut (
        .clk(clk), .reset_n(reset_n), .start(start),
        .triangle_count(32'd2), .triangle_base_addr(32'd0), .vertex_base_addr(32'd0),
        .tri_mem_req_valid(tri_req_valid), .tri_mem_req_ready(tri_req_ready),
        .tri_mem_req_addr(tri_req_addr), .tri_mem_rsp_valid(tri_rsp_valid),
        .tri_mem_rsp_data(tri_rsp_data),
        .vertex_mem_req_valid(vtx_req_valid), .vertex_mem_req_ready(vtx_req_ready),
        .vertex_mem_req_addr(vtx_req_addr), .vertex_mem_rsp_valid(vtx_rsp_valid),
        .vertex_mem_rsp_data(vtx_rsp_data),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_rgb(pixel_rgb),
        .pixel_depth(pixel_depth), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .busy(busy), .done(done), .error(error)
    );

    reg seen [0:479999];
    integer pixel_count;
    integer i;
    reg stalled_last_cycle;
    reg [48:0] stalled_pixel;

    always @(posedge clk) begin
        if (!reset_n) begin
            pixel_count <= 0;
            stalled_last_cycle <= 0;
        end else begin
            if (stalled_last_cycle) begin
                if (!pixel_valid || {pixel_depth,pixel_y,pixel_x,pixel_rgb} !== stalled_pixel) begin
                    $display("FAIL: pixel FIFO output changed during backpressure");
                    $finish;
                end
            end
            stalled_last_cycle <= pixel_valid && !pixel_ready;
            if (pixel_valid && !pixel_ready)
                stalled_pixel <= {pixel_depth,pixel_y,pixel_x,pixel_rgb};
            if (pixel_valid && pixel_ready) begin
                if (pixel_x >= 800 || pixel_y >= 600) begin
                    $display("FAIL: out-of-range output pixel");
                    $finish;
                end
                if (seen[pixel_y*800 + pixel_x]) begin
                    $display("FAIL: duplicate pixel from full pipeline");
                    $finish;
                end
                seen[pixel_y*800 + pixel_x] <= 1'b1;
                pixel_count <= pixel_count + 1;
            end
            if (error) begin
                $display("FAIL: pipeline error asserted");
                $finish;
            end
        end
    end

    initial begin
        for (i = 0; i < 480000; i = i + 1)
            seen[i] = 1'b0;
        repeat (5) @(posedge clk);
        reset_n = 1;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;

        begin : WAIT_DONE
            integer timeout_count;
            timeout_count = 0;
            while (done !== 1'b1 && timeout_count < 1500000) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end
            if (done !== 1'b1) begin
                $display("FAIL: end-to-end pipeline timeout");
                $finish;
            end
        end
        if (pixel_count < 1000) begin
            $display("FAIL: end-to-end path generated too few pixels: %0d", pixel_count);
            $finish;
        end
        $display("PASS: two indexed triangles traversed the complete memory-to-pixel path (%0d pixels)", pixel_count);
        $finish;
    end
endmodule
