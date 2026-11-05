`timescale 1ns/1ps
`include "gpu_config.vh"

module tb_gpu_triangle_engine;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg triangle_valid = 0;
    wire triangle_ready;
    reg [63:0] vertex0, vertex1, vertex2;
    wire [10:0] pixel_x;
    wire [9:0] pixel_y;
    wire [11:0] pixel_rgb;
    wire [15:0] pixel_depth;
    wire pixel_valid;
    reg pixel_ready = 0;
    wire busy, triangle_done, triangle_error;

    gpu_triangle_engine dut (
        .clk(clk), .reset_n(reset_n),
        .triangle_valid(triangle_valid), .triangle_ready(triangle_ready),
        .vertex0(vertex0), .vertex1(vertex1), .vertex2(vertex2),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_rgb(pixel_rgb),
        .pixel_depth(pixel_depth), .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .busy(busy), .triangle_done(triangle_done), .triangle_error(triangle_error)
    );

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

    reg seen [0:479999];
    integer count_pixels;
    integer cycle_count;
    integer i;
    integer first_count;
    reg stall_previous;
    reg [10:0] held_x;
    reg [9:0] held_y;
    reg [11:0] held_rgb;
    reg [15:0] held_depth;
    reg uniform_check_enable;

    always @(posedge clk) begin
        if (!reset_n) begin
            pixel_ready <= 1'b0;
        end else begin
            // Deliberate periodic backpressure.
            pixel_ready <= ((cycle_count % 5) != 1);
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            cycle_count <= 0;
            count_pixels <= 0;
            stall_previous <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (stall_previous) begin
                if (!pixel_valid || pixel_x !== held_x || pixel_y !== held_y ||
                    pixel_rgb !== held_rgb || pixel_depth !== held_depth) begin
                    $display("FAIL: pixel data changed while stalled");
                    $finish;
                end
            end
            stall_previous <= pixel_valid && !pixel_ready;
            if (pixel_valid && !pixel_ready) begin
                held_x <= pixel_x;
                held_y <= pixel_y;
                held_rgb <= pixel_rgb;
                held_depth <= pixel_depth;
            end
            if (pixel_valid && pixel_ready) begin
                if (uniform_check_enable &&
                    (pixel_rgb !== 12'h5A3 || pixel_depth !== 16'h8000)) begin
                    $display("FAIL: constant attributes were not preserved (rgb=%h depth=%h)",
                             pixel_rgb, pixel_depth);
                    $finish;
                end
                if (pixel_x >= 800 || pixel_y >= 600) begin
                    $display("FAIL: out-of-range pixel (%0d,%0d)", pixel_x, pixel_y);
                    $finish;
                end
                if (seen[pixel_y*800 + pixel_x]) begin
                    $display("FAIL: duplicate pixel (%0d,%0d)", pixel_x, pixel_y);
                    $finish;
                end
                seen[pixel_y*800 + pixel_x] <= 1'b1;
                count_pixels <= count_pixels + 1;
            end
            if (triangle_error) begin
                $display("FAIL: triangle engine asserted error");
                $finish;
            end
        end
    end

    task clear_seen;
        begin
            for (i = 0; i < 480000; i = i + 1)
                seen[i] = 1'b0;
            count_pixels = 0;
        end
    endtask

    task submit_triangle;
        input [63:0] a;
        input [63:0] b;
        input [63:0] c;
        integer timeout_count;
        begin
            @(negedge clk);
            vertex0 = a; vertex1 = b; vertex2 = c;
            triangle_valid = 1'b1;
            timeout_count = 0;
            while (triangle_ready !== 1'b1 && timeout_count < 20) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            if (triangle_ready !== 1'b1) begin
                $display("FAIL: triangle engine did not become ready");
                $finish;
            end
            @(posedge clk);
            #1 triangle_valid = 1'b0;
        end
    endtask

    task wait_triangle_done;
        integer timeout_count;
        begin
            timeout_count = 0;
            while (triangle_done !== 1'b1 && timeout_count < 650000) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end
            if (triangle_done !== 1'b1) begin
                $display("FAIL: triangle timeout");
                $finish;
            end
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        vertex0 = 0; vertex1 = 0; vertex2 = 0;
        uniform_check_enable = 1'b0;
        clear_seen();
        repeat (5) @(posedge clk);
        reset_n = 1'b1;

        // Constant color/depth must remain constant at every covered sample.
        uniform_check_enable = 1'b1;
        submit_triangle(
            make_vertex(16'hC000, 16'hC000, 16'h0000, 4'h5, 4'hA, 4'h3),
            make_vertex(16'h4000, 16'hC000, 16'h0000, 4'h5, 4'hA, 4'h3),
            make_vertex(16'h0000, 16'h4000, 16'h0000, 4'h5, 4'hA, 4'h3)
        );
        wait_triangle_done();
        uniform_check_enable = 1'b0;
        if (count_pixels < 1000) begin
            $display("FAIL: constant-attribute triangle generated too few pixels: %0d", count_pixels);
            $finish;
        end
        $display("PASS: constant RGB444 and depth interpolation");

        // A broad, non-degenerate triangle with all three color channels varying.
        clear_seen();
        submit_triangle(
            make_vertex(16'hC000, 16'hC000, 16'h0000, 4'hF, 4'h0, 4'h0),
            make_vertex(16'h4000, 16'hC000, 16'h4000, 4'h0, 4'hF, 4'h0),
            make_vertex(16'h0000, 16'h4000, 16'h7FFF, 4'h0, 4'h0, 4'hF)
        );
        wait_triangle_done();
        if (count_pixels < 1000) begin
            $display("FAIL: unexpectedly few pixels: %0d", count_pixels);
            $finish;
        end
        first_count = count_pixels;
        $display("PASS: first triangle generated %0d unique pixels", first_count);

        // Reverse winding while preserving each vertex's attributes.
        clear_seen();
        submit_triangle(
            make_vertex(16'hC000, 16'hC000, 16'h0000, 4'hF, 4'h0, 4'h0),
            make_vertex(16'h0000, 16'h4000, 16'h7FFF, 4'h0, 4'h0, 4'hF),
            make_vertex(16'h4000, 16'hC000, 16'h4000, 4'h0, 4'hF, 4'h0)
        );
        wait_triangle_done();
        if (count_pixels != first_count) begin
            $display("FAIL: winding changed coverage count (%0d vs %0d)", count_pixels, first_count);
            $finish;
        end
        $display("PASS: reversed winding generated identical coverage count");

        // Two triangles tile a rectangle. The shared diagonal must not create
        // duplicate pixels; the combined coverage must be exactly 400 x 300.
        clear_seen();
        submit_triangle(
            make_vertex(16'hC000, 16'h4000, 16'h0000, 4'hF, 4'h0, 4'h0),
            make_vertex(16'h4000, 16'h4000, 16'h0000, 4'h0, 4'hF, 4'h0),
            make_vertex(16'h4000, 16'hC000, 16'h0000, 4'h0, 4'h0, 4'hF)
        );
        wait_triangle_done();
        submit_triangle(
            make_vertex(16'hC000, 16'h4000, 16'h0000, 4'hF, 4'h0, 4'h0),
            make_vertex(16'h4000, 16'hC000, 16'h0000, 4'h0, 4'h0, 4'hF),
            make_vertex(16'hC000, 16'hC000, 16'h0000, 4'hF, 4'hF, 4'h0)
        );
        wait_triangle_done();
        if (count_pixels != 120000) begin
            $display("FAIL: shared-edge rectangle count %0d, expected 120000", count_pixels);
            $finish;
        end
        $display("PASS: adjacent triangles tile the rectangle without duplicate pixels");

        // Degenerate triangle must complete without generating fragments.
        clear_seen();
        submit_triangle(
            make_vertex(16'h0000, 16'h0000, 16'h0000, 4'hF, 4'h0, 4'h0),
            make_vertex(16'h0000, 16'h0000, 16'h0000, 4'h0, 4'hF, 4'h0),
            make_vertex(16'h0000, 16'h0000, 16'h0000, 4'h0, 4'h0, 4'hF)
        );
        wait_triangle_done();
        if (count_pixels != 0) begin
            $display("FAIL: degenerate triangle generated pixels");
            $finish;
        end
        $display("PASS: degenerate triangle rejected");

        // Screen-boundary triangle: Q1.15 endpoints map to 0/799 and 0/599.
        clear_seen();
        submit_triangle(
            make_vertex(16'h8000, 16'h8000, 16'h0000, 4'hF, 4'hF, 4'hF),
            make_vertex(16'h7FFF, 16'h8000, 16'h0000, 4'hF, 4'h0, 4'h0),
            make_vertex(16'h8000, 16'h7FFF, 16'h0000, 4'h0, 4'hF, 4'h0)
        );
        wait_triangle_done();
        if (count_pixels == 0) begin
            $display("FAIL: boundary triangle generated no pixels");
            $finish;
        end
        $display("PASS: boundary triangle generated %0d pixels", count_pixels);

        $display("ALL GPU TRIANGLE ENGINE TESTS PASSED");
        $finish;
    end
endmodule
