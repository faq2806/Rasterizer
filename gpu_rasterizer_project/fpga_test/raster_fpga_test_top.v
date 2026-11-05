`timescale 1ns/1ps
// ============================================================================
// Nexys 4 DDR (XC7A100T) board top for testing ONLY the rasterization stage
// (gpu_triangle_engine: viewport + setup + edge scan + RGB/Z interpolation).
//
// Upstream (geometry fetch) is replaced by a test ROM, downstream (framebuffer,
// VGA) by on-chip checkers. See FPGA_TESTING.md for the full operating guide.
//
// Switches
//   SW[5:0]   test index (single-test mode, and test shown on the 7-seg pages)
//   SW[7:6]   pixel_ready backpressure: 0 none, 1 2-of-3, 2 random 50%, 3 random 12%
//   SW[8]     0 = run all tests, 1 = run only test SW[5:0]
//   SW[9]     soak: repeat the run forever (re-read at the end of every loop)
//   SW[10]    UART pixel dump (every pixel is printed; use with SW[8]=1)
//   SW[11]    verbose UART report (CRC/BBOX/pixel lines also for passing tests)
//   SW[15:12] 7-segment page (0-15)
// Buttons
//   BTNC start   BTND abort (soft reset of harness + DUT)   BTNR toggle actual/expected
//   CPU_RESETN full reset
// ============================================================================
module raster_fpga_test_top #(
    parameter MMCM_OUT_DIV      = 40,           // core clock = 1000 MHz / MMCM_OUT_DIV (40 -> 25 MHz)
    parameter SIM_CLK_HZ        = 100000000,    // simulation only: MMCM bypassed, core clock = clk100
    parameter UART_BAUD         = 115200,
    parameter DEBOUNCE_MS       = 10,
    parameter REFRESH_BITS      = 16,
    parameter NO_PROGRESS_LIMIT = 2000000
)(
    input  wire        clk100,
    input  wire        cpu_resetn,
    input  wire        btnc,
    input  wire        btnd,
    input  wire        btnr,
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire        led16_r, led16_g, led16_b,
    output wire        led17_r, led17_g, led17_b,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [7:0]  an,
    output wire        uart_tx
);
    // ------------------------------------------------------------------------
    // Clock: MMCM 100 MHz -> VCO 1000 MHz -> core clock (bypassed in simulation)
    // ------------------------------------------------------------------------
    wire clk;
    wire locked;
`ifdef SYNTHESIS
    localparam integer CORE_HZ = 1000000000 / MMCM_OUT_DIV;
    wire clkfb, clk_mmcm;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(10.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(10.0),
        .CLKOUT0_DIVIDE_F(10.0),
        .CLKOUT1_DIVIDE(MMCM_OUT_DIV)
    ) u_mmcm (
        .CLKIN1(clk100), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT1(clk_mmcm), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
        .CLKOUT0(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB()
    );
    BUFG u_bufg (.I(clk_mmcm), .O(clk));
`else
    localparam integer CORE_HZ = SIM_CLK_HZ;
    assign clk = clk100;
    assign locked = 1'b1;
`endif
    localparam integer DEB_RAW = (CORE_HZ / 1000) * DEBOUNCE_MS;
    localparam integer DEB_CYC = (DEB_RAW < 2) ? 2 : DEB_RAW;
    localparam integer CLKS_PER_BIT = CORE_HZ / UART_BAUD;

    // ------------------------------------------------------------------------
    // Resets
    // ------------------------------------------------------------------------
    wire pre_rst_n = cpu_resetn & locked;
    reg [3:0] rst_pipe;
    always @(posedge clk or negedge pre_rst_n) begin
        if (!pre_rst_n) rst_pipe <= 4'd0;
        else            rst_pipe <= {rst_pipe[2:0], 1'b1};
    end
    wire base_rst_n = rst_pipe[3];

    wire btnc_lvl, btnc_rise, btnd_lvl, btnd_rise, btnr_lvl, btnr_rise;
    rt_debounce #(.CYCLES(DEB_CYC)) u_db_c (.clk(clk), .rst_n(base_rst_n), .din(btnc), .level(btnc_lvl), .rise(btnc_rise));
    rt_debounce #(.CYCLES(DEB_CYC)) u_db_d (.clk(clk), .rst_n(base_rst_n), .din(btnd), .level(btnd_lvl), .rise(btnd_rise));
    rt_debounce #(.CYCLES(DEB_CYC)) u_db_r (.clk(clk), .rst_n(base_rst_n), .din(btnr), .level(btnr_lvl), .rise(btnr_rise));

    reg soft_rst_n;
    always @(posedge clk or negedge base_rst_n) begin
        if (!base_rst_n) soft_rst_n <= 1'b0;
        else             soft_rst_n <= ~btnd_lvl;
    end

    wire dut_rst_req;
    reg  dut_rst_n;
    always @(posedge clk or negedge soft_rst_n) begin
        if (!soft_rst_n) dut_rst_n <= 1'b0;
        else             dut_rst_n <= ~dut_rst_req;
    end

    // ------------------------------------------------------------------------
    // Switch synchroniser
    // ------------------------------------------------------------------------
    reg [15:0] sw_m, sw_s;
    always @(posedge clk) begin
        sw_m <= sw;
        sw_s <= sw_m;
    end
    wire [5:0] sel_test = sw_s[5:0];
    wire [3:0] page     = sw_s[15:12];

    reg alt_view;
    always @(posedge clk or negedge base_rst_n) begin
        if (!base_rst_n)    alt_view <= 1'b0;
        else if (btnr_rise) alt_view <= ~alt_view;
    end

    // ------------------------------------------------------------------------
    // Device under test: the rasterization stage
    // ------------------------------------------------------------------------
    wire        tri_valid, tri_ready;
    wire [63:0] tri_v0, tri_v1, tri_v2;
    wire [10:0] eng_x;
    wire [9:0]  eng_y;
    wire [11:0] eng_rgb;
    wire [15:0] eng_z;
    wire        eng_valid, eng_ready;
    wire        eng_busy, eng_done, eng_error;

    gpu_triangle_engine u_engine (
        .clk(clk), .reset_n(dut_rst_n),
        .triangle_valid(tri_valid), .triangle_ready(tri_ready),
        .vertex0(tri_v0), .vertex1(tri_v1), .vertex2(tri_v2),
        .pixel_x(eng_x), .pixel_y(eng_y), .pixel_rgb(eng_rgb), .pixel_depth(eng_z),
        .pixel_valid(eng_valid), .pixel_ready(eng_ready),
        .busy(eng_busy), .triangle_done(eng_done), .triangle_error(eng_error)
    );

    // ------------------------------------------------------------------------
    // Harness
    // ------------------------------------------------------------------------
    wire        running, run_complete, any_fail;
    wire [6:0]  cur_test, pass_cnt, fail_cnt, first_fail, num_tests;
    wire [15:0] flags_accum, loop_cnt, loop_fail_cnt;
    wire        sel_ran, sel_pass;
    wire [15:0] sel_flags;
    wire [19:0] sel_count, sel_exp_count;
    wire [31:0] sel_crc_xy, sel_exp_crc_xy, sel_crc_rgb, sel_exp_crc_rgb, sel_crc_z, sel_exp_crc_z;
    wire [31:0] sel_cycles;
    wire [41:0] sel_bbox, sel_exp_bbox;
    wire [48:0] sel_first, sel_exp_first;
    wire        uart_active;

    raster_test_harness #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .NO_PROGRESS_LIMIT(NO_PROGRESS_LIMIT)
    ) u_harness (
        .clk(clk), .rst_n(soft_rst_n),
        .start_req(btnc_rise), .single_mode(sw_s[8]), .soak_mode(sw_s[9]),
        .dump_mode(sw_s[10]), .verbose(sw_s[11]), .bp_mode(sw_s[7:6]), .sel_test(sel_test),
        .dut_rst_req(dut_rst_req),
        .tri_valid(tri_valid), .tri_ready(tri_ready),
        .tri_v0(tri_v0), .tri_v1(tri_v1), .tri_v2(tri_v2),
        .pix_x(eng_x), .pix_y(eng_y), .pix_rgb(eng_rgb), .pix_z(eng_z),
        .pix_valid(eng_valid), .pix_ready(eng_ready),
        .dut_busy(eng_busy), .dut_done(eng_done), .dut_error(eng_error),
        .running(running), .run_complete(run_complete), .any_fail_sticky(any_fail),
        .cur_test(cur_test), .pass_cnt(pass_cnt), .fail_cnt(fail_cnt), .first_fail(first_fail),
        .flags_accum(flags_accum), .loop_cnt(loop_cnt), .loop_fail_cnt(loop_fail_cnt),
        .num_tests(num_tests),
        .sel_ran(sel_ran), .sel_pass(sel_pass), .sel_flags(sel_flags),
        .sel_count(sel_count), .sel_exp_count(sel_exp_count),
        .sel_crc_xy(sel_crc_xy), .sel_exp_crc_xy(sel_exp_crc_xy),
        .sel_crc_rgb(sel_crc_rgb), .sel_exp_crc_rgb(sel_exp_crc_rgb),
        .sel_crc_z(sel_crc_z), .sel_exp_crc_z(sel_exp_crc_z),
        .sel_cycles(sel_cycles), .sel_bbox(sel_bbox), .sel_exp_bbox(sel_exp_bbox),
        .sel_first(sel_first), .sel_exp_first(sel_exp_first),
        .uart_tx(uart_tx), .uart_active(uart_active)
    );

    // ------------------------------------------------------------------------
    // Seven-segment pages
    // ------------------------------------------------------------------------
    localparam [4:0] G_BL = 5'd16, G_P = 5'd17, G_R = 5'd18, G_U = 5'd19, G_N = 5'd20,
                     G_L = 5'd21, G_I = 5'd22, G_T = 5'd23, G_DASH = 5'd24, G_H = 5'd25,
                     G_O = 5'd26, G_A = 5'd10, G_D = 5'd13, G_E = 5'd14, G_F = 5'd15, G_S = 5'd5;

    function [4:0] hg; input [3:0] n; hg = {1'b0, n}; endfunction
    function [39:0] hex8; input [31:0] v;
        hex8 = {hg(v[31:28]), hg(v[27:24]), hg(v[23:20]), hg(v[19:16]),
                hg(v[15:12]), hg(v[11:8]), hg(v[7:4]), hg(v[3:0])};
    endfunction
    function [14:0] hex3; input [11:0] v; hex3 = {hg(v[11:8]), hg(v[7:4]), hg(v[3:0])}; endfunction

    wire [41:0] bbox_show  = alt_view ? sel_exp_bbox  : sel_bbox;
    wire [48:0] first_show = alt_view ? sel_exp_first : sel_first;
    wire [4:0]  ae_mark    = alt_view ? G_E : G_A;            // A = actual, E = expected
    wire        act_ok     = sel_ran || alt_view;
    wire [4:0]  sel_state  = !sel_ran ? G_DASH : (sel_pass ? G_P : G_F);
    localparam [39:0] DASHES = {8{5'd24}};

    reg [39:0] glyphs;
    always @* begin
        case (page)
            4'd0: begin
                if (running)
                    glyphs = {G_R, G_U, G_N, (any_fail ? G_F : G_BL),
                              hg({1'b0, cur_test[6:4]}), hg(cur_test[3:0]),
                              hg({1'b0, fail_cnt[6:4]}), hg(fail_cnt[3:0])};
                else if (!run_complete)
                    glyphs = {G_I, G_D, G_L, G_E, G_BL, G_BL, hg({1'b0, num_tests[6:4]}), hg(num_tests[3:0])};
                else if (any_fail)
                    glyphs = {G_F, G_A, G_I, G_L, hg({1'b0, first_fail[6:4]}), hg(first_fail[3:0]),
                              hg({1'b0, fail_cnt[6:4]}), hg(fail_cnt[3:0])};
                else
                    glyphs = {G_P, G_A, G_S, G_S, G_BL, G_BL, hg({1'b0, pass_cnt[6:4]}), hg(pass_cnt[3:0])};
            end
            4'd1:  glyphs = {G_T, hg({2'b0, sel_test[5:4]}), hg(sel_test[3:0]), sel_state,
                             (sel_ran ? {hg(sel_flags[15:12]), hg(sel_flags[11:8]), hg(sel_flags[7:4]), hg(sel_flags[3:0])}
                                      : {G_DASH, G_DASH, G_DASH, G_DASH})};
            4'd2:  glyphs = sel_ran ? {G_N, G_A, G_BL, hg(sel_count[19:16]), hg(sel_count[15:12]),
                                       hg(sel_count[11:8]), hg(sel_count[7:4]), hg(sel_count[3:0])} : DASHES;
            4'd3:  glyphs = {G_N, G_E, G_BL, hg(sel_exp_count[19:16]), hg(sel_exp_count[15:12]),
                             hg(sel_exp_count[11:8]), hg(sel_exp_count[7:4]), hg(sel_exp_count[3:0])};
            4'd4:  glyphs = sel_ran ? hex8(sel_crc_xy) : DASHES;
            4'd5:  glyphs = hex8(sel_exp_crc_xy);
            4'd6:  glyphs = sel_ran ? hex8(sel_crc_rgb) : DASHES;
            4'd7:  glyphs = hex8(sel_exp_crc_rgb);
            4'd8:  glyphs = sel_ran ? hex8(sel_crc_z) : DASHES;
            4'd9:  glyphs = hex8(sel_exp_crc_z);
            4'd10: glyphs = sel_ran ? hex8(sel_cycles) : DASHES;
            4'd11: glyphs = act_ok ? {hex3({1'b0, bbox_show[41:31]}), ae_mark, G_BL, hex3({1'b0, bbox_show[30:20]})} : DASHES;
            4'd12: glyphs = act_ok ? {hex3({2'b0, bbox_show[19:10]}), ae_mark, G_BL, hex3({2'b0, bbox_show[9:0]})} : DASHES;
            4'd13: glyphs = act_ok ? {hex3({1'b0, first_show[48:38]}), ae_mark, G_BL, hex3({2'b0, first_show[37:28]})} : DASHES;
            4'd14: glyphs = act_ok ? {hex3(first_show[27:16]), ae_mark,
                                      hg(first_show[15:12]), hg(first_show[11:8]), hg(first_show[7:4]), hg(first_show[3:0])} : DASHES;
            default: glyphs = {hg(loop_cnt[15:12]), hg(loop_cnt[11:8]), hg(loop_cnt[7:4]), hg(loop_cnt[3:0]),
                               hg(loop_fail_cnt[15:12]), hg(loop_fail_cnt[11:8]), hg(loop_fail_cnt[7:4]), hg(loop_fail_cnt[3:0])};
        endcase
    end

    reg [25:0] hb;
    always @(posedge clk or negedge base_rst_n) begin
        if (!base_rst_n) hb <= 26'd0;
        else             hb <= hb + 26'd1;
    end

    rt_seven_seg #(.REFRESH_BITS(REFRESH_BITS)) u_seg (
        .clk(clk), .rst_n(base_rst_n), .glyphs(glyphs),
        .dps({running & hb[22], 6'd0, alt_view}), .seg(seg), .dp(dp), .an(an)
    );

    // ------------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------------
    wire busy_vis, pix_vis, uart_vis;
    rt_stretch #(.BITS(20)) u_st0 (.clk(clk), .rst_n(base_rst_n), .event_in(eng_busy), .out(busy_vis));
    rt_stretch #(.BITS(20)) u_st1 (.clk(clk), .rst_n(base_rst_n), .event_in(eng_valid & eng_ready), .out(pix_vis));
    rt_stretch #(.BITS(20)) u_st2 (.clk(clk), .rst_n(base_rst_n), .event_in(uart_active), .out(uart_vis));

    assign led[0]  = run_complete & ~any_fail;                 // all tests passed
    assign led[1]  = any_fail;                                 // at least one failure (sticky)
    assign led[2]  = running;
    assign led[3]  = busy_vis;                                 // engine busy
    assign led[4]  = pix_vis;                                  // pixels being accepted
    assign led[5]  = locked;
    assign led[6]  = uart_vis;
    assign led[7]  = alt_view;
    assign led[8]  = flags_accum[0]  | flags_accum[9];         // pixel / unique count
    assign led[9]  = flags_accum[1]  | flags_accum[4] | flags_accum[5] | flags_accum[6] | flags_accum[8]; // coverage
    assign led[10] = flags_accum[2];                           // colour interpolation
    assign led[11] = flags_accum[3];                           // depth interpolation
    assign led[12] = flags_accum[13];                          // attribute range
    assign led[13] = flags_accum[7]  | flags_accum[12];        // handshake / protocol
    assign led[14] = flags_accum[10] | flags_accum[11];        // timeout / error
    assign led[15] = flags_accum[14] | flags_accum[15];        // stream / first-last

    wire pwm = (hb[2:0] == 3'd0);                              // RGB LEDs at 1/8 brightness
    assign led16_r = pwm & any_fail;
    assign led16_g = pwm & run_complete & ~any_fail;
    assign led16_b = pwm & running & ~any_fail;
    assign led17_r = 1'b0;
    assign led17_g = 1'b0;
    assign led17_b = pwm & hb[24];                             // heartbeat: core clock alive
endmodule
