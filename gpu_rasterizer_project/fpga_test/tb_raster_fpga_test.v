`timescale 1ns/1ps
// Simulation of the complete FPGA test top (MMCM bypassed, fast UART).
//   Phase 1: run ALL tests, no backpressure                 -> must PASS
//   Phase 2: single test, random 50% backpressure, mesh     -> must PASS
//   Phase 3: single tiny test, heavy backpressure + dump     -> must PASS, dump count checked
//   Phase 4: fault injection (stuck colour bit)              -> must FAIL with RGB/ATTR only
//   Phase 5: fault injection (coverage: x LSB stuck at 0)    -> must FAIL with coverage flags
// The UART text the board would print is decoded and echoed to the console.
module tb_raster_fpga_test;
    localparam CPB = 8;                       // 100 MHz / 12.5 Mbaud
    localparam T_MESH = 17, T_TINY_PAIR = 28, T_CONST = 0;

    reg clk = 0;
    always #5 clk = ~clk;

    reg        cpu_resetn = 0;
    reg        btnc = 0, btnd = 0, btnr = 0;
    reg [15:0] sw = 16'd0;
    wire [15:0] led;
    wire led16_r, led16_g, led16_b, led17_r, led17_g, led17_b;
    wire [6:0] seg;
    wire dp;
    wire [7:0] an;
    wire uart_tx;

    raster_fpga_test_top #(
        .SIM_CLK_HZ(100000000), .UART_BAUD(12500000), .DEBOUNCE_MS(0), .REFRESH_BITS(8)
    ) uut (
        .clk100(clk), .cpu_resetn(cpu_resetn), .btnc(btnc), .btnd(btnd), .btnr(btnr), .sw(sw),
        .led(led), .led16_r(led16_r), .led16_g(led16_g), .led16_b(led16_b),
        .led17_r(led17_r), .led17_g(led17_g), .led17_b(led17_b),
        .seg(seg), .dp(dp), .an(an), .uart_tx(uart_tx)
    );

    // ---------------- UART receiver / console echo ----------------
    integer dump_lines = 0;
    reg [7:0] rx;
    reg [7:0] prev_rx = 8'h0A;
    integer bi;
    initial begin
        forever begin
            @(negedge uart_tx);
            repeat (CPB / 2) @(posedge clk);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                repeat (CPB) @(posedge clk);
                rx[bi] = uart_tx;
            end
            repeat (CPB) @(posedge clk);
            if (rx == 8'h50 && prev_rx == 8'h0A) dump_lines = dump_lines + 1;   // "P" at line start
            // echo everything except per-pixel dump lines (counted only)
            if (rx != 8'h0D) $write("%c", rx);
            if (rx == 8'h0A) $fflush;
            prev_rx = rx;
        end
    end

    integer errors = 0;
    integer guard;

    task press_start;
        begin
            @(posedge clk); btnc = 1'b1;
            repeat (20) @(posedge clk); btnc = 1'b0;
        end
    endtask

    task wait_complete;
        input integer max_cycles;
        begin
            guard = 0;
            while (uut.u_harness.running !== 1'b1 && guard < 1000) begin @(posedge clk); guard = guard + 1; end
            guard = 0;
            while (uut.u_harness.run_complete !== 1'b1 && guard < max_cycles) begin
                @(posedge clk); guard = guard + 1;
            end
            if (uut.u_harness.run_complete !== 1'b1) begin
                $display("\nTB FAIL: run did not complete within %0d cycles", max_cycles);
                $finish;
            end
            // let the last UART characters drain
            repeat (2000) @(posedge clk);
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        cpu_resetn = 1'b1;
        repeat (50) @(posedge clk);

        // ---------------- Phase 1: all tests, no backpressure ----------------
        sw = 16'h0000;
        press_start();
        wait_complete(40000000);
        if (uut.u_harness.fail_cnt != 0 || uut.u_harness.pass_cnt != uut.u_harness.num_tests || led[0] !== 1'b1) begin
            $display("\nTB FAIL: phase 1 pass=%0d fail=%0d", uut.u_harness.pass_cnt, uut.u_harness.fail_cnt);
            errors = errors + 1;
        end else
            $display("\nTB PHASE 1 OK: all %0d tests passed", uut.u_harness.pass_cnt);

        // ---------------- Phase 2: mesh test with random backpressure ----------------
        sw = 16'h0000 | (1 << 8) | (2'd2 << 6) | T_MESH;
        repeat (10) @(posedge clk);
        press_start();
        wait_complete(10000000);
        if (uut.u_harness.fail_cnt != 0 || uut.u_harness.pass_cnt != 1 || uut.u_harness.stalls == 0) begin
            $display("\nTB FAIL: phase 2");
            errors = errors + 1;
        end else
            $display("\nTB PHASE 2 OK: mesh passed under random backpressure (%0d stall cycles)",
                     uut.u_harness.stalls);

        // ---------------- Phase 3: tiny pair, heavy backpressure, UART dump, verbose ----------------
        dump_lines = 0;
        sw = (1 << 11) | (1 << 10) | (1 << 8) | (2'd3 << 6) | T_TINY_PAIR;
        repeat (10) @(posedge clk);
        press_start();
        wait_complete(10000000);
        if (uut.u_harness.fail_cnt != 0 || dump_lines != uut.u_harness.t_exp_count) begin
            $display("\nTB FAIL: phase 3 fail=%0d dump_lines=%0d expected=%0d", uut.u_harness.fail_cnt,
                     dump_lines, uut.u_harness.t_exp_count);
            errors = errors + 1;
        end else
            $display("\nTB PHASE 3 OK: %0d pixels dumped over UART", dump_lines);

        // ---------------- Phase 4: inject a stuck colour bit (blue bit 2 = 1) ----------------
        sw = (1 << 8) | T_CONST;
        force uut.eng_rgb[2] = 1'b1;
        repeat (10) @(posedge clk);
        press_start();
        wait_complete(10000000);
        release uut.eng_rgb[2];
        // expected: CRC_RGB(2), ATTR(13), FIRST/LAST(15); coverage and depth untouched
        if (uut.u_harness.cur_flags !== 16'hA004) begin
            $display("\nTB FAIL: phase 4 flags=%h expected A004", uut.u_harness.cur_flags);
            errors = errors + 1;
        end else
            $display("\nTB PHASE 4 OK: injected colour fault detected, flags=%h", uut.u_harness.cur_flags);

        // ---------------- Phase 5: inject a coverage fault (pixel_x LSB stuck at 0) ----------------
        sw = (1 << 8) | T_CONST;
        force uut.eng_x[0] = 1'b0;
        repeat (10) @(posedge clk);
        press_start();
        wait_complete(10000000);
        release uut.eng_x[0];
        // expected at least CRC_XY, ORDER; colour/depth CRCs untouched
        if (!uut.u_harness.cur_flags[1] || !uut.u_harness.cur_flags[6] ||
            uut.u_harness.cur_flags[2] || uut.u_harness.cur_flags[3]) begin
            $display("\nTB FAIL: phase 5 flags=%h", uut.u_harness.cur_flags);
            errors = errors + 1;
        end else
            $display("\nTB PHASE 5 OK: injected coverage fault detected, flags=%h", uut.u_harness.cur_flags);

        if (errors == 0) $display("\nALL FPGA HARNESS SIMULATION PHASES PASSED");
        else             $display("\nFPGA HARNESS SIMULATION FAILED (%0d phase errors)", errors);
        $finish;
    end
endmodule
