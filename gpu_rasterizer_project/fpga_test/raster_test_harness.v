`timescale 1ns/1ps
`include "gpu_config.vh"

// ============================================================================
// Self-checking test harness for gpu_triangle_engine (rasterization stage only).
//
// Replaces the missing upstream stage (vertex/triangle fetch) with a test ROM
// and the missing downstream stage (framebuffer / VGA) with on-chip checkers.
//
// For every test (one or more triangles) it checks, against the bit-exact
// golden model in tools/raster_golden.py:
//   * pixel count, bounding box, first/last pixel
//   * three CRC-32 signatures: coverage {x,y}, colour {rgb}, depth {z}
//   * per-pixel golden stream for small tests (first mismatch is captured)
//   * overlap (duplicate pixels between triangles) and unique-coverage count,
//     using an 800x600 1-bit bitmap in block RAM
// and independently of the model (protocol/property checks):
//   * x < 800, y < 600
//   * strictly increasing raster order inside each triangle
//   * valid/ready: data stable and valid held while stalled
//   * attributes inside the range of the triangle's vertex values
//   * exactly one triangle_done per triangle, no pixel_valid outside a triangle
//   * error flag, and a no-progress watchdog (DUT is reset on timeout)
//
// Fail-flag bits (16-bit word shown on 7-seg / UART):
//   0 COUNT   1 CRC_XY  2 CRC_RGB  3 CRC_Z   4 BBOX    5 RANGE  6 ORDER  7 STALL
//   8 DUP     9 UNION  10 TIMEOUT 11 ERROR  12 PROTO  13 ATTR  14 STREAM 15 FIRST/LAST
// ============================================================================
module raster_test_harness #(
    parameter CLKS_PER_BIT      = 217,
    parameter NO_PROGRESS_LIMIT = 2000000
)(
    input  wire        clk,
    input  wire        rst_n,

    // control (already synchronised/debounced)
    input  wire        start_req,
    input  wire        single_mode,
    input  wire        soak_mode,
    input  wire        dump_mode,
    input  wire        verbose,
    input  wire [1:0]  bp_mode,
    input  wire [5:0]  sel_test,

    // device under test
    output reg         dut_rst_req,
    output reg         tri_valid,
    input  wire        tri_ready,
    output reg  [63:0] tri_v0,
    output reg  [63:0] tri_v1,
    output reg  [63:0] tri_v2,
    input  wire [10:0] pix_x,
    input  wire [9:0]  pix_y,
    input  wire [11:0] pix_rgb,
    input  wire [15:0] pix_z,
    input  wire        pix_valid,
    output wire        pix_ready,
    input  wire        dut_busy,
    input  wire        dut_done,
    input  wire        dut_error,

    // run status
    output wire        running,
    output reg         run_complete,
    output reg         any_fail_sticky,
    output wire [6:0]  cur_test,
    output reg  [6:0]  pass_cnt,
    output reg  [6:0]  fail_cnt,
    output reg  [6:0]  first_fail,        // 7'h7F = none
    output reg  [15:0] flags_accum,
    output reg  [15:0] loop_cnt,
    output reg  [15:0] loop_fail_cnt,
    output wire [6:0]  num_tests,

    // results of the test selected by sel_test (for the 7-segment pages)
    output wire        sel_ran,
    output wire        sel_pass,
    output wire [15:0] sel_flags,
    output wire [19:0] sel_count,
    output wire [19:0] sel_exp_count,
    output wire [31:0] sel_crc_xy,
    output wire [31:0] sel_exp_crc_xy,
    output wire [31:0] sel_crc_rgb,
    output wire [31:0] sel_exp_crc_rgb,
    output wire [31:0] sel_crc_z,
    output wire [31:0] sel_exp_crc_z,
    output wire [31:0] sel_cycles,
    output wire [41:0] sel_bbox,
    output wire [41:0] sel_exp_bbox,
    output wire [48:0] sel_first,
    output wire [48:0] sel_exp_first,

    output wire        uart_tx,
    output wire        uart_active
);
    localparam F_COUNT = 0, F_XY = 1, F_RGB = 2, F_Z = 3, F_BBOX = 4, F_RANGE = 5,
               F_ORDER = 6, F_STALL = 7, F_DUP = 8, F_UNION = 9, F_TIMEOUT = 10,
               F_ERROR = 11, F_PROTO = 12, F_ATTR = 13, F_STREAM = 14, F_FIRSTLAST = 15;

    localparam [4:0] S_IDLE = 5'd0,  S_RUN_INIT = 5'd1, S_HEADER = 5'd2, S_TEST_INIT = 5'd3,
                     S_CLEAR = 5'd4, S_TRI_LOAD = 5'd5, S_TRI_LATCH = 5'd6, S_SUBMIT = 5'd7,
                     S_WAIT_DONE = 5'd8, S_DRAIN = 5'd9, S_EVAL = 5'd10, S_STORE = 5'd11,
                     S_REPORT = 5'd12, S_NEXT = 5'd13, S_SUMMARY = 5'd14;

    localparam [3:0] L_HDR = 4'd0, L_LEG = 4'd1, L_RES = 4'd2, L_CRC = 4'd3, L_BOX = 4'd4,
                     L_PIX = 4'd5, L_MM = 4'd6, L_SUM = 4'd7, L_DMP = 4'd8;

    localparam [18:0] BITMAP_LAST = 19'd479999;
    localparam [15:0] CRLF = 16'h0D0A;

    // ------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------
    reg [4:0]  state;
    reg [5:0]  test_idx;
    reg [7:0]  tri_i;
    reg [7:0]  tri_addr;
    reg [2:0]  step;
    reg [3:0]  drain_cnt;
    reg [3:0]  dut_rst_cnt;
    reg [18:0] clr_addr;
    reg        run_single, run_dump;
    reg [5:0]  run_sel;
    reg [15:0] cur_flags;
    reg        timeout_err;
    reg        cur_pass;

    assign running  = (state != S_IDLE);
    assign cur_test = {1'b0, test_idx};

    // ------------------------------------------------------------------------
    // ROMs
    // ------------------------------------------------------------------------
    wire [127:0] t_name;
    wire [7:0]   t_tri_start, t_tri_count;
    wire [3:0]   t_flags;
    wire [19:0]  t_exp_count, t_exp_union, t_exp_dup, t_exp_attr;
    wire [31:0]  t_exp_crc_xy, t_exp_crc_rgb, t_exp_crc_z;
    wire [41:0]  t_exp_bbox;
    wire [48:0]  t_exp_first, t_exp_last;
    wire [9:0]   t_stream_base;

    raster_test_rom u_rom (
        .test_idx(test_idx), .num_tests(num_tests), .name(t_name),
        .tri_start(t_tri_start), .tri_count(t_tri_count), .flags(t_flags),
        .exp_count(t_exp_count), .exp_union(t_exp_union), .exp_dup(t_exp_dup), .exp_attr(t_exp_attr),
        .exp_crc_xy(t_exp_crc_xy), .exp_crc_rgb(t_exp_crc_rgb), .exp_crc_z(t_exp_crc_z),
        .exp_bbox(t_exp_bbox), .exp_first(t_exp_first), .exp_last(t_exp_last),
        .stream_base(t_stream_base)
    );

    wire [6:0]   s_num_unused;
    wire [127:0] s_name_unused;
    wire [7:0]   s_ts_unused, s_tc_unused;
    wire [3:0]   s_fl_unused;
    wire [19:0]  s_u_unused, s_d_unused, s_a_unused;
    wire [48:0]  s_last_unused;
    wire [9:0]   s_sb_unused;
    raster_test_rom u_rom_sel (
        .test_idx(sel_test), .num_tests(s_num_unused), .name(s_name_unused),
        .tri_start(s_ts_unused), .tri_count(s_tc_unused), .flags(s_fl_unused),
        .exp_count(sel_exp_count), .exp_union(s_u_unused), .exp_dup(s_d_unused), .exp_attr(s_a_unused),
        .exp_crc_xy(sel_exp_crc_xy), .exp_crc_rgb(sel_exp_crc_rgb), .exp_crc_z(sel_exp_crc_z),
        .exp_bbox(sel_exp_bbox), .exp_first(sel_exp_first), .exp_last(s_last_unused),
        .stream_base(s_sb_unused)
    );

    wire [63:0] rom_v0, rom_v1, rom_v2;
    raster_tri_rom u_tri_rom (.tri_idx(tri_addr), .v0(rom_v0), .v1(rom_v1), .v2(rom_v2));

    reg  [9:0]  stream_addr;
    wire [48:0] stream_word;
    raster_stream_rom u_stream_rom (.addr(stream_addr), .word(stream_word));

    wire chk_dup    = t_flags[0];
    wire chk_stream = t_flags[1];
    wire exp_error  = t_flags[2];

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    function [31:0] crc32_32;
        input [31:0] crc;
        input [31:0] d;
        integer i;
        reg [31:0] c;
        begin
            c = crc;
            for (i = 31; i >= 0; i = i - 1)
                c = {c[30:0], 1'b0} ^ ((c[31] ^ d[i]) ? 32'h04C11DB7 : 32'h0);
            crc32_32 = c;
        end
    endfunction

    function [31:0] crc32_16;
        input [31:0] crc;
        input [15:0] d;
        integer i;
        reg [31:0] c;
        begin
            c = crc;
            for (i = 15; i >= 0; i = i - 1)
                c = {c[30:0], 1'b0} ^ ((c[31] ^ d[i]) ? 32'h04C11DB7 : 32'h0);
            crc32_16 = c;
        end
    endfunction

    function [15:0] min3;
        input [15:0] a, b, c;
        reg [15:0] m;
        begin
            m = (a < b) ? a : b;
            min3 = (m < c) ? m : c;
        end
    endfunction

    function [15:0] max3;
        input [15:0] a, b, c;
        reg [15:0] m;
        begin
            m = (a > b) ? a : b;
            max3 = (m > c) ? m : c;
        end
    endfunction

    // ------------------------------------------------------------------------
    // Backpressure generator for pixel_ready
    //   0: always ready   1: ready 2 of 3 cycles   2: random ~50%   3: random ~12.5%
    // ------------------------------------------------------------------------
    reg [15:0] lfsr;
    reg [1:0]  mod3;
    reg        bp_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 16'hACE1; mod3 <= 2'd0; bp_ready <= 1'b1;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            mod3 <= (mod3 == 2'd2) ? 2'd0 : mod3 + 2'd1;
            case (bp_mode)
                2'd0: bp_ready <= 1'b1;
                2'd1: bp_ready <= (mod3 != 2'd0);
                2'd2: bp_ready <= lfsr[0];
                default: bp_ready <= &lfsr[2:0];
            endcase
        end
    end

    reg pr_busy;
    // In dump mode each accepted pixel is printed before the next one is taken.
    assign pix_ready = bp_ready && !(run_dump && pr_busy);

    // ------------------------------------------------------------------------
    // Pixel checkers
    // ------------------------------------------------------------------------
    wire [48:0] pix_word = {pix_x, pix_y, pix_rgb, pix_z};
    wire        hs = pix_valid && pix_ready;
    wire        in_tri_window = (state == S_SUBMIT) || (state == S_WAIT_DONE);
    wire        test_phase = (state == S_CLEAR) || (state == S_TRI_LOAD) || (state == S_TRI_LATCH) ||
                             (state == S_SUBMIT) || (state == S_WAIT_DONE) || (state == S_DRAIN);
    wire        test_init  = (state == S_TEST_INIT);
    wire        tri_init   = (state == S_TRI_LATCH);

    reg [19:0] cnt, union_cnt, dup_cnt, attr_cnt;
    reg [31:0] crc_xy, crc_rgb, crc_z;
    reg [10:0] bb_xmin, bb_xmax;
    reg [9:0]  bb_ymin, bb_ymax;
    reg [48:0] first_word, last_word;
    reg        range_err, order_err, stall_err, proto_err, stream_err, error_seen;
    reg        mm_seen;
    reg [19:0] mm_idx;
    reg [48:0] mm_got, mm_exp;
    reg [31:0] cycles, stalls;
    reg [7:0]  done_cnt;
    reg [20:0] prev_key;
    reg        tri_first;
    reg        stall_prev;
    reg [48:0] stall_word;
    reg [23:0] noprog;
    reg [3:0]  rmin, rmax, gmin, gmax, bmin, bmax;
    reg [15:0] zmin, zmax;
    reg        hs_d;
    reg [48:0] word_d;

    wire [3:0] p_r = pix_rgb[11:8];
    wire [3:0] p_g = pix_rgb[7:4];
    wire [3:0] p_b = pix_rgb[3:0];
    wire attr_bad = (p_r < rmin) || (p_r > rmax) || (p_g < gmin) || (p_g > gmax) ||
                    (p_b < bmin) || (p_b > bmax) || (pix_z < zmin) || (pix_z > zmax);
    wire progress = hs || dut_done || (tri_valid && tri_ready) || (pix_valid && !pix_ready);
    wire timeout_hit = (noprog >= NO_PROGRESS_LIMIT);

    // vertex attribute ranges of the triangle being loaded
    wire [15:0] rv0z = rom_v0[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] ^ 16'h8000;
    wire [15:0] rv1z = rom_v1[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] ^ 16'h8000;
    wire [15:0] rv2z = rom_v2[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB] ^ 16'h8000;
    wire [15:0] rv0r = rom_v0[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB], rv1r = rom_v1[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB], rv2r = rom_v2[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB];
    wire [15:0] rv0g = rom_v0[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB], rv1g = rom_v1[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB], rv2g = rom_v2[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB];
    wire [15:0] rv0b = rom_v0[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB], rv1b = rom_v1[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB], rv2b = rom_v2[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB];
    wire [15:0] rmin_w = min3(rv0r, rv1r, rv2r), rmax_w = max3(rv0r, rv1r, rv2r);
    wire [15:0] gmin_w = min3(rv0g, rv1g, rv2g), gmax_w = max3(rv0g, rv1g, rv2g);
    wire [15:0] bmin_w = min3(rv0b, rv1b, rv2b), bmax_w = max3(rv0b, rv1b, rv2b);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0; attr_cnt <= 0;
            crc_xy <= 32'hFFFFFFFF; crc_rgb <= 32'hFFFFFFFF; crc_z <= 32'hFFFFFFFF;
            bb_xmin <= 11'h7FF; bb_xmax <= 0; bb_ymin <= 10'h3FF; bb_ymax <= 0;
            first_word <= 0; last_word <= 0;
            range_err <= 0; order_err <= 0; stall_err <= 0; proto_err <= 0;
            stream_err <= 0; error_seen <= 0;
            mm_seen <= 0; mm_idx <= 0; mm_got <= 0; mm_exp <= 0;
            cycles <= 0; stalls <= 0; done_cnt <= 0;
            prev_key <= 0; tri_first <= 1'b1;
            stall_prev <= 0; stall_word <= 0; noprog <= 0;
            rmin <= 0; rmax <= 0; gmin <= 0; gmax <= 0; bmin <= 0; bmax <= 0; zmin <= 0; zmax <= 0;
            stream_addr <= 0; hs_d <= 0; word_d <= 0;
        end else if (test_init) begin
            cnt <= 0; attr_cnt <= 0;
            crc_xy <= 32'hFFFFFFFF; crc_rgb <= 32'hFFFFFFFF; crc_z <= 32'hFFFFFFFF;
            bb_xmin <= 11'h7FF; bb_xmax <= 0; bb_ymin <= 10'h3FF; bb_ymax <= 0;
            first_word <= 0; last_word <= 0;
            range_err <= 0; order_err <= 0; stall_err <= 0; proto_err <= 0;
            stream_err <= 0; error_seen <= 0;
            mm_seen <= 0; mm_idx <= 0; mm_got <= 0; mm_exp <= 0;
            cycles <= 0; stalls <= 0; done_cnt <= 0;
            tri_first <= 1'b1; stall_prev <= 0; noprog <= 0;
            stream_addr <= t_stream_base; hs_d <= 0;
        end else begin
            // ---- CRC pipeline stage (one cycle behind the handshake) ----
            hs_d   <= hs && test_phase;
            word_d <= pix_word;
            if (hs_d) begin
                crc_xy  <= crc32_32(crc_xy, {5'd0, word_d[48:38], 6'd0, word_d[37:28]});
                crc_rgb <= crc32_16(crc_rgb, {4'd0, word_d[27:16]});
                crc_z   <= crc32_16(crc_z, word_d[15:0]);
            end

            if (tri_init) begin
                tri_first <= 1'b1;
                rmin <= rmin_w[3:0]; rmax <= rmax_w[3:0];
                gmin <= gmin_w[3:0]; gmax <= gmax_w[3:0];
                bmin <= bmin_w[3:0]; bmax <= bmax_w[3:0];
                zmin <= min3(rv0z, rv1z, rv2z); zmax <= max3(rv0z, rv1z, rv2z);
            end

            if (test_phase) begin
                // ---- per accepted pixel ----
                if (hs) begin
                    cnt <= cnt + 20'd1;
                    if (cnt == 20'd0) first_word <= pix_word;
                    last_word <= pix_word;
                    if (pix_x < bb_xmin) bb_xmin <= pix_x;
                    if (pix_x > bb_xmax) bb_xmax <= pix_x;
                    if (pix_y < bb_ymin) bb_ymin <= pix_y;
                    if (pix_y > bb_ymax) bb_ymax <= pix_y;
                    if (pix_x >= 11'd800 || pix_y >= 10'd600) range_err <= 1'b1;
                    if (!tri_first && ({pix_y, pix_x} <= prev_key)) order_err <= 1'b1;
                    prev_key  <= {pix_y, pix_x};
                    tri_first <= 1'b0;
                    if (attr_bad) attr_cnt <= attr_cnt + 20'd1;
                    if (chk_stream) begin
                        if ((cnt < t_exp_count) && (pix_word != stream_word)) begin
                            stream_err <= 1'b1;
                            if (!mm_seen) begin
                                mm_seen <= 1'b1; mm_idx <= cnt; mm_got <= pix_word; mm_exp <= stream_word;
                            end
                        end
                        stream_addr <= stream_addr + 10'd1;
                    end
                end
                // ---- handshake stability: once valid && !ready, the beat must stay ----
                if (stall_prev && (!pix_valid || (pix_word != stall_word))) stall_err <= 1'b1;
                stall_prev <= pix_valid && !pix_ready && !dut_rst_req;
                stall_word <= pix_word;
                if (pix_valid && !pix_ready) stalls <= stalls + 32'd1;
                // ---- protocol ----
                if (pix_valid && !timeout_err && (!in_tri_window || !dut_busy)) proto_err <= 1'b1;
                if (dut_done) begin
                    done_cnt <= done_cnt + 8'd1;
                    if (state != S_WAIT_DONE) proto_err <= 1'b1;
                end
                if (dut_error) error_seen <= 1'b1;
                // ---- performance + watchdog ----
                if (state != S_CLEAR && state != S_DRAIN) cycles <= cycles + 32'd1;
                if (in_tri_window) noprog <= progress ? 24'd0 : noprog + 24'd1;
                else               noprog <= 24'd0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Overlap bitmap: 800x600 x 1 bit in block RAM (read, then set, 2-stage)
    // ------------------------------------------------------------------------
    wire [19:0] pix_addr = {pix_y, 9'd0} + {1'b0, pix_y, 8'd0} + {4'd0, pix_y, 5'd0} + {9'd0, pix_x};
    reg         bm_hs_d, bm_hs_dd, bm_q;
    reg  [18:0] bm_addr_d, bm_addr_dd;
    (* ram_style = "block" *) reg bitmap [0:479999];
    wire        bm_clear = (state == S_CLEAR);
    wire        bm_we    = bm_clear || (bm_hs_dd && chk_dup);
    wire [18:0] bm_waddr = bm_clear ? clr_addr : bm_addr_dd;

`ifndef SYNTHESIS
    integer bk;
    initial for (bk = 0; bk < 480000; bk = bk + 1) bitmap[bk] = 1'b0;
`endif

    always @(posedge clk) begin
        if (bm_we) bitmap[bm_waddr] <= !bm_clear;
        bm_q <= bitmap[bm_addr_d];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bm_hs_d <= 0; bm_hs_dd <= 0; bm_addr_d <= 0; bm_addr_dd <= 0;
            union_cnt <= 0; dup_cnt <= 0;
        end else if (test_init) begin
            bm_hs_d <= 0; bm_hs_dd <= 0; union_cnt <= 0; dup_cnt <= 0;
        end else begin
            bm_hs_d    <= hs && test_phase && (pix_x < 11'd800) && (pix_y < 10'd600);
            bm_addr_d  <= pix_addr[18:0];
            bm_hs_dd   <= bm_hs_d;
            bm_addr_dd <= bm_addr_d;
            if (bm_hs_dd && chk_dup) begin
                if (bm_q) dup_cnt   <= dup_cnt + 20'd1;
                else      union_cnt <= union_cnt + 20'd1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Evaluation
    // ------------------------------------------------------------------------
    wire [41:0] act_bbox = {bb_xmin, bb_xmax, bb_ymin, bb_ymax};
    reg  [15:0] eval_flags;
    always @* begin
        eval_flags = 16'd0;
        eval_flags[F_COUNT]   = (cnt != t_exp_count);
        eval_flags[F_XY]      = (crc_xy != t_exp_crc_xy);
        eval_flags[F_RGB]     = (crc_rgb != t_exp_crc_rgb);
        eval_flags[F_Z]       = (crc_z != t_exp_crc_z);
        eval_flags[F_BBOX]    = (act_bbox != t_exp_bbox);
        eval_flags[F_RANGE]   = range_err;
        eval_flags[F_ORDER]   = order_err;
        eval_flags[F_STALL]   = stall_err;
        eval_flags[F_DUP]     = chk_dup && (dup_cnt != t_exp_dup);
        eval_flags[F_UNION]   = chk_dup && (union_cnt != t_exp_union);
        eval_flags[F_TIMEOUT] = timeout_err;
        eval_flags[F_ERROR]   = (error_seen != exp_error);
        eval_flags[F_PROTO]   = proto_err || (!timeout_err && (done_cnt != t_tri_count));
        eval_flags[F_ATTR]    = (attr_cnt != t_exp_attr);
        eval_flags[F_STREAM]  = chk_stream && stream_err;
        eval_flags[F_FIRSTLAST] = (cnt != 20'd0) && (t_exp_count != 20'd0) &&
                                  ((first_word != t_exp_first) || (last_word != t_exp_last));
    end

    // ------------------------------------------------------------------------
    // Per-test result storage (distributed RAM) for the display pages
    // ------------------------------------------------------------------------
    reg [15:0] r_flags  [0:63];
    reg [19:0] r_count  [0:63];
    reg [31:0] r_crcxy  [0:63];
    reg [31:0] r_crcrgb [0:63];
    reg [31:0] r_crcz   [0:63];
    reg [31:0] r_cycles [0:63];
    reg [41:0] r_bbox   [0:63];
    reg [48:0] r_first  [0:63];
    reg [63:0] ran_mask, pass_mask;

    always @(posedge clk) begin
        if (state == S_STORE) begin
            r_flags[test_idx]  <= cur_flags;
            r_count[test_idx]  <= cnt;
            r_crcxy[test_idx]  <= crc_xy;
            r_crcrgb[test_idx] <= crc_rgb;
            r_crcz[test_idx]   <= crc_z;
            r_cycles[test_idx] <= cycles;
            r_bbox[test_idx]   <= act_bbox;
            r_first[test_idx]  <= first_word;
        end
    end

    assign sel_ran     = ran_mask[sel_test];
    assign sel_pass    = pass_mask[sel_test];
    assign sel_flags   = r_flags[sel_test];
    assign sel_count   = r_count[sel_test];
    assign sel_crc_xy  = r_crcxy[sel_test];
    assign sel_crc_rgb = r_crcrgb[sel_test];
    assign sel_crc_z   = r_crcz[sel_test];
    assign sel_cycles  = r_cycles[sel_test];
    assign sel_bbox    = r_bbox[sel_test];
    assign sel_first   = r_first[sel_test];

    // ------------------------------------------------------------------------
    // UART report lines (fixed 128-byte frames; leading NUL bytes are skipped)
    // ------------------------------------------------------------------------
    function [7:0] hx;
        input [3:0] n;
        hx = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
    endfunction
    function [15:0] h2; input [7:0] v;  h2 = {hx(v[7:4]), hx(v[3:0])}; endfunction
    function [23:0] h3; input [11:0] v; h3 = {hx(v[11:8]), hx(v[7:4]), hx(v[3:0])}; endfunction
    function [31:0] h4; input [15:0] v; h4 = {hx(v[15:12]), hx(v[11:8]), hx(v[7:4]), hx(v[3:0])}; endfunction
    function [39:0] h5; input [19:0] v; h5 = {hx(v[19:16]), h4(v[15:0])}; endfunction
    function [63:0] h8; input [31:0] v; h8 = {h4(v[31:16]), h4(v[15:0])}; endfunction
    function [127:0] hpix;   // "xxx,yyy,rgb,zzzz"
        input [48:0] w;
        hpix = {h3({1'b0, w[48:38]}), ",", h3({2'b0, w[37:28]}), ",", h3(w[27:16]), ",", h4(w[15:0])};
    endfunction
    function [119:0] hbox;   // "xxx,xxx,yyy,yyy"
        input [41:0] b;
        hbox = {h3({1'b0, b[41:31]}), ",", h3({1'b0, b[30:20]}), ",", h3({2'b0, b[19:10]}), ",", h3({2'b0, b[9:0]})};
    endfunction

    reg [48:0] dmp_word;
    reg [6:0]  run_fail_cnt;

    reg  [3:0]    pr_type;
    reg  [6:0]    pr_idx;
    reg  [1023:0] pr_line;
    // Only the line being printed is built (also keeps simulation fast).
    always @* begin
        pr_line = 1024'd0;
        if (pr_busy) begin
            case (pr_type)
                L_HDR:    pr_line = {CRLF, "=== RASTER ENGINE FPGA TEST  TESTS=", h2({1'b0, num_tests}),
                         " RUN=", (run_single ? "ONE" : "ALL"), " BP=", hx({2'b0, bp_mode}),
                         " DUMP=", hx({3'b0, run_dump}), " LOOP=", h4(loop_cnt), " ===", CRLF};
                L_LEG:    pr_line = {"FLAGS: 0=CNT 1=XY 2=RGB 3=Z 4=BBOX 5=RANGE 6=ORDER 7=STALL 8=DUP 9=UNION",
                         " A=TMO B=ERR C=PROTO D=ATTR E=STRM F=1ST/LAST", CRLF};
                L_RES:    pr_line = {"T", h2({2'b0, test_idx}), " ", (cur_pass ? "PASS" : "FAIL"), " ", t_name,
                         " F=", h4(cur_flags), " N=", h5(cnt), "/", h5(t_exp_count),
                         " CYC=", h8(cycles), " STALL=", h8(stalls), CRLF};
                L_CRC:    pr_line = {"    XY=", h8(crc_xy), "/", h8(t_exp_crc_xy), " RGB=", h8(crc_rgb), "/",
                         h8(t_exp_crc_rgb), " Z=", h8(crc_z), "/", h8(t_exp_crc_z), CRLF};
                L_BOX:    pr_line = {"    BBOX=", hbox(act_bbox), " EXP=", hbox(t_exp_bbox),
                         " TRI=", h2(done_cnt), "/", h2(t_tri_count),
                         " DUP=", h5(dup_cnt), "/", h5(t_exp_dup), " UNION=", h5(union_cnt), "/",
                         h5(t_exp_union), " AV=", h5(attr_cnt), "/", h5(t_exp_attr), CRLF};
                L_PIX:    pr_line = {"    FIRST=", hpix(first_word), " EXP=", hpix(t_exp_first),
                         " LAST=", hpix(last_word), " EXP=", hpix(t_exp_last), CRLF};
                L_MM:     pr_line = {"    STREAM MISMATCH AT PIXEL #", h5(mm_idx), " GOT=", hpix(mm_got),
                         " EXP=", hpix(mm_exp), CRLF};
                L_SUM:    pr_line = {"=== RESULT ", (any_fail_sticky ? "FAIL" : "PASS"), " PASSED=", h2({1'b0, pass_cnt}),
                         " FAILED=", h2({1'b0, fail_cnt}), " FIRSTFAIL=", h2({1'b0, first_fail}),
                         " FLAGS=", h4(flags_accum), " LOOPS=", h4(loop_cnt),
                         " LOOPFAILS=", h4(loop_fail_cnt), " ===", CRLF};
                default:  pr_line = {"P ", hpix(dmp_word), CRLF};
            endcase
        end
    end
    wire [7:0] pr_char = pr_line[8*(7'd127 - pr_idx) +: 8];

    reg       tx_start;
    reg [7:0] tx_data;
    wire      tx_busy;
    rt_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data), .tx(uart_tx), .busy(tx_busy)
    );
    assign uart_active = pr_busy || tx_busy;

    // ------------------------------------------------------------------------
    // Main sequencer (+ printer control)
    // ------------------------------------------------------------------------
    wire failing = (eval_flags != 16'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; test_idx <= 0; tri_i <= 0; tri_addr <= 0; step <= 0;
            drain_cnt <= 0; dut_rst_cnt <= 0; dut_rst_req <= 0; clr_addr <= 0;
            run_single <= 0; run_dump <= 0; run_sel <= 0;
            cur_flags <= 0; cur_pass <= 0; timeout_err <= 0;
            tri_valid <= 0; tri_v0 <= 0; tri_v1 <= 0; tri_v2 <= 0;
            run_complete <= 0; any_fail_sticky <= 0;
            pass_cnt <= 0; fail_cnt <= 0; run_fail_cnt <= 0; first_fail <= 7'h7F; flags_accum <= 0;
            loop_cnt <= 0; loop_fail_cnt <= 0; ran_mask <= 0; pass_mask <= 0;
            pr_busy <= 0; pr_type <= 0; pr_idx <= 0; tx_start <= 0; tx_data <= 0; dmp_word <= 0;
        end else begin
            tx_start <= 1'b0;

            // ---- character printer ----
            if (pr_busy) begin
                if (pr_char == 8'h00) begin
                    if (pr_idx == 7'd127) pr_busy <= 1'b0;
                    pr_idx <= pr_idx + 7'd1;
                end else if (!tx_busy && !tx_start) begin
                    tx_start <= 1'b1;
                    tx_data  <= pr_char;
                    if (pr_idx == 7'd127) pr_busy <= 1'b0;
                    pr_idx <= pr_idx + 7'd1;
                end
            end

            // ---- DUT soft reset after a timeout ----
            if (dut_rst_cnt != 0) begin
                dut_rst_cnt <= dut_rst_cnt - 4'd1;
                dut_rst_req <= 1'b1;
            end else begin
                dut_rst_req <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    if (start_req && (!single_mode || ({1'b0, sel_test} < num_tests))) begin
                        run_single <= single_mode;
                        run_dump   <= dump_mode;
                        run_sel    <= sel_test;
                        run_complete <= 1'b0;
                        any_fail_sticky <= 1'b0;
                        first_fail <= 7'h7F;
                        flags_accum <= 16'd0;
                        loop_cnt <= 16'd0;
                        loop_fail_cnt <= 16'd0;
                        state <= S_RUN_INIT;
                    end
                end

                S_RUN_INIT: begin
                    pass_cnt <= 0; fail_cnt <= 0; run_fail_cnt <= 0;
                    ran_mask <= 64'd0; pass_mask <= 64'd0;
                    test_idx <= run_single ? run_sel : 6'd0;
                    step <= 0;
                    state <= S_HEADER;
                end

                S_HEADER: begin
                    if (!pr_busy) begin
                        if (step == 3'd0) begin
                            pr_type <= L_HDR; pr_idx <= 0; pr_busy <= 1'b1; step <= 3'd1;
                        end else if (step == 3'd1) begin
                            pr_type <= L_LEG; pr_idx <= 0; pr_busy <= 1'b1; step <= 3'd2;
                        end else begin
                            state <= S_TEST_INIT;
                        end
                    end
                end

                S_TEST_INIT: begin
                    // checker accumulators clear in this state (see checker block)
                    tri_i <= 0;
                    timeout_err <= 1'b0;
                    clr_addr <= 0;
                    state <= chk_dup ? S_CLEAR : S_TRI_LOAD;
                end

                S_CLEAR: begin
                    if (clr_addr == BITMAP_LAST) state <= S_TRI_LOAD;
                    clr_addr <= clr_addr + 19'd1;
                end

                S_TRI_LOAD: begin
                    tri_addr <= t_tri_start + tri_i;
                    state <= S_TRI_LATCH;
                end

                S_TRI_LATCH: begin
                    tri_v0 <= rom_v0; tri_v1 <= rom_v1; tri_v2 <= rom_v2;
                    tri_valid <= 1'b1;
                    state <= S_SUBMIT;
                end

                S_SUBMIT: begin
                    if (tri_ready) begin
                        tri_valid <= 1'b0;
                        state <= S_WAIT_DONE;
                    end else if (timeout_hit) begin
                        tri_valid <= 1'b0;
                        timeout_err <= 1'b1;
                        dut_rst_cnt <= 4'd8;
                        drain_cnt <= 0;
                        state <= S_DRAIN;
                    end
                end

                S_WAIT_DONE: begin
                    if (run_dump && hs) begin
                        dmp_word <= pix_word;
                        pr_type <= L_DMP; pr_idx <= 0; pr_busy <= 1'b1;
                    end
                    if (dut_done) begin
                        if (tri_i + 8'd1 < t_tri_count) begin
                            tri_i <= tri_i + 8'd1;
                            state <= S_TRI_LOAD;
                        end else begin
                            drain_cnt <= 0;
                            state <= S_DRAIN;
                        end
                    end else if (timeout_hit) begin
                        timeout_err <= 1'b1;
                        dut_rst_cnt <= 4'd8;
                        drain_cnt <= 0;
                        state <= S_DRAIN;
                    end
                end

                S_DRAIN: begin
                    if (drain_cnt == 4'd6 && dut_rst_cnt == 0 && !dut_rst_req && !pr_busy)
                        state <= S_EVAL;
                    else if (drain_cnt != 4'd6)
                        drain_cnt <= drain_cnt + 4'd1;
                end

                S_EVAL: begin
                    cur_flags <= eval_flags;
                    cur_pass  <= !failing;
                    state <= S_STORE;
                end

                S_STORE: begin
                    ran_mask[test_idx] <= 1'b1;
                    if (cur_flags == 16'd0) begin
                        pass_mask[test_idx] <= 1'b1;
                        pass_cnt <= pass_cnt + 7'd1;
                    end else begin
                        fail_cnt <= fail_cnt + 7'd1;
                        run_fail_cnt <= run_fail_cnt + 7'd1;
                        any_fail_sticky <= 1'b1;
                        if (first_fail == 7'h7F) first_fail <= {1'b0, test_idx};
                    end
                    flags_accum <= flags_accum | cur_flags;
                    step <= 0;
                    state <= S_REPORT;
                end

                S_REPORT: begin
                    if (!pr_busy) begin
                        step <= step + 3'd1;
                        case (step)
                            3'd0: begin pr_type <= L_RES; pr_idx <= 0; pr_busy <= 1'b1; end
                            3'd1: if (verbose || !cur_pass) begin pr_type <= L_CRC; pr_idx <= 0; pr_busy <= 1'b1; end
                            3'd2: if (verbose || !cur_pass) begin pr_type <= L_BOX; pr_idx <= 0; pr_busy <= 1'b1; end
                            3'd3: if (verbose || !cur_pass) begin pr_type <= L_PIX; pr_idx <= 0; pr_busy <= 1'b1; end
                            3'd4: if (mm_seen) begin pr_type <= L_MM; pr_idx <= 0; pr_busy <= 1'b1; end
                            default: state <= S_NEXT;
                        endcase
                    end
                end

                S_NEXT: begin
                    if (run_single || ({1'b0, test_idx} == num_tests - 7'd1)) begin
                        step <= 0;
                        state <= S_SUMMARY;
                    end else begin
                        test_idx <= test_idx + 6'd1;
                        state <= S_TEST_INIT;
                    end
                end

                S_SUMMARY: begin
                    if (!pr_busy) begin
                        if (step == 3'd0) begin
                            pr_type <= L_SUM; pr_idx <= 0; pr_busy <= 1'b1; step <= 3'd1;
                        end else begin
                            loop_cnt <= loop_cnt + 16'd1;
                            if (run_fail_cnt != 0) loop_fail_cnt <= loop_fail_cnt + 16'd1;
                            if (soak_mode) begin
                                state <= S_RUN_INIT;
                            end else begin
                                run_complete <= 1'b1;
                                state <= S_IDLE;
                            end
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
