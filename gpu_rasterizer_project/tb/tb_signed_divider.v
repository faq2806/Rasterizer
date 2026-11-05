`timescale 1ns/1ps
module tb_signed_divider;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg start = 0;
    reg signed [15:0] dividend = 0;
    reg signed [15:0] divisor = 1;
    wire signed [15:0] quotient;
    wire busy, done, divide_by_zero, overflow;

    signed_divider #(.WIDTH(16)) dut (
        .clk(clk), .reset_n(reset_n), .start(start),
        .dividend(dividend), .divisor(divisor), .quotient(quotient),
        .busy(busy), .done(done), .divide_by_zero(divide_by_zero), .overflow(overflow)
    );

    task run_case;
        input signed [15:0] a;
        input signed [15:0] b;
        input signed [15:0] expected;
        input expected_zero;
        input expected_overflow;
        integer timeout_count;
        begin
            @(negedge clk);
            dividend = a;
            divisor = b;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout_count = 0;
            while (done !== 1'b1 && timeout_count < 100) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end
            if (done !== 1'b1) begin
                $display("FAIL: divider timeout");
                $finish;
            end
            if (quotient !== expected || divide_by_zero !== expected_zero || overflow !== expected_overflow) begin
                $display("FAIL: %0d / %0d => %0d (zero=%b ovf=%b), expected %0d (zero=%b ovf=%b)",
                         a, b, quotient, divide_by_zero, overflow,
                         expected, expected_zero, expected_overflow);
                $finish;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        run_case(16'sd12345, 16'sd123, 16'sd100, 1'b0, 1'b0);
        run_case(-16'sd12345, 16'sd123, -16'sd100, 1'b0, 1'b0);
        run_case(16'sd12345, -16'sd123, -16'sd100, 1'b0, 1'b0);
        run_case(-16'sd12345, -16'sd123, 16'sd100, 1'b0, 1'b0);
        run_case(16'sd123, 16'sd0, 16'sd0, 1'b1, 1'b0);
        run_case(-16'sh8000, -16'sd1, 16'sh7fff, 1'b0, 1'b1);
        $display("ALL SIGNED DIVIDER TESTS PASSED");
        $finish;
    end
endmodule
