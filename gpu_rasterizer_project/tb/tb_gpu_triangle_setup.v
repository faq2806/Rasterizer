`timescale 1ns/1ps
module tb_gpu_triangle_setup;
    reg signed [11:0] x0, y0, x1, y1, x2, y2;
    wire signed [11:0] x_min, x_max, y_min, y_max;
    wire signed [25:0] area;
    wire signed [12:0] A0, B0, A1, B1, A2, B2;
    wire signed [24:0] C0, C1, C2;
    wire degenerate, bbox_empty;

    gpu_triangle_setup dut (
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .x_min(x_min), .x_max(x_max), .y_min(y_min), .y_max(y_max),
        .area(area), .A0(A0), .B0(B0), .C0(C0), .A1(A1), .B1(B1), .C1(C1),
        .A2(A2), .B2(B2), .C2(C2), .degenerate(degenerate), .bbox_empty(bbox_empty)
    );

    initial begin
        // Partially off the left edge: only the scan bounds are clipped.
        x0=-12'sd10; y0=12'sd100;
        x1= 12'sd10; y1=12'sd100;
        x2= 12'sd0;  y2=12'sd120;
        #1;
        if (bbox_empty || x_min != 0 || x_max != 10 || y_min != 100 || y_max != 120 || degenerate) begin
            $display("FAIL: partially off-screen bounding-box clipping");
            $finish;
        end

        // Completely outside the left edge: clipped interval is empty.
        x0=-12'sd30; y0=12'sd0;
        x1=-12'sd10; y1=12'sd20;
        x2=-12'sd20; y2=12'sd30;
        #1;
        if (!bbox_empty) begin
            $display("FAIL: fully off-screen triangle was not rejected");
            $finish;
        end

        // Partially beyond the right and bottom limits.
        x0=12'sd790; y0=12'sd590;
        x1=12'sd810; y1=12'sd590;
        x2=12'sd800; y2=12'sd610;
        #1;
        if (bbox_empty || x_min != 790 || x_max != 799 || y_min != 590 || y_max != 599) begin
            $display("FAIL: right/bottom bounding-box clipping");
            $finish;
        end

        $display("ALL TRIANGLE SETUP CLIPPING TESTS PASSED");
        $finish;
    end
endmodule
