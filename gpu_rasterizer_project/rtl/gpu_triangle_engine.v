`include "gpu_config.vh"

// Complete single-triangle setup/rasterization engine.
// Input is three packed 64-bit vertices; output is a backpressure-safe stream
// of {x,y,RGB444,depth16}. Depth is interpolated only; no Z test or Z memory.
module gpu_triangle_engine (
    input  wire clk,
    input  wire reset_n,

    input  wire triangle_valid,
    output wire triangle_ready,
    input  wire [63:0] vertex0,
    input  wire [63:0] vertex1,
    input  wire [63:0] vertex2,

    output wire [10:0] pixel_x,
    output wire [9:0] pixel_y,
    output wire [11:0] pixel_rgb,
    output wire [15:0] pixel_depth,
    output wire pixel_valid,
    input  wire pixel_ready,

    output wire busy,
    output reg triangle_done,
    output reg triangle_error
);
    localparam [2:0] IDLE = 3'd0,
                     SETUP = 3'd1,
                     GRAD_START = 3'd2,
                     WAIT_GRAD = 3'd3,
                     SCAN = 3'd4,
                     FINISH = 3'd5;

    reg [2:0] state;
    reg [63:0] v0_reg, v1_reg, v2_reg;

    wire signed [15:0] ndc_x0 = $signed(v0_reg[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB]);
    wire signed [15:0] ndc_y0 = $signed(v0_reg[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB]);
    wire signed [15:0] ndc_z0 = $signed(v0_reg[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB]);
    wire signed [15:0] ndc_x1 = $signed(v1_reg[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB]);
    wire signed [15:0] ndc_y1 = $signed(v1_reg[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB]);
    wire signed [15:0] ndc_z1 = $signed(v1_reg[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB]);
    wire signed [15:0] ndc_x2 = $signed(v2_reg[`GPU_VTX_X_MSB:`GPU_VTX_X_LSB]);
    wire signed [15:0] ndc_y2 = $signed(v2_reg[`GPU_VTX_Y_MSB:`GPU_VTX_Y_LSB]);
    wire signed [15:0] ndc_z2 = $signed(v2_reg[`GPU_VTX_Z_MSB:`GPU_VTX_Z_LSB]);

    wire [3:0] v0_r = v0_reg[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB];
    wire [3:0] v0_g = v0_reg[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB];
    wire [3:0] v0_b = v0_reg[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB];
    wire [3:0] v1_r = v1_reg[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB];
    wire [3:0] v1_g = v1_reg[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB];
    wire [3:0] v1_b = v1_reg[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB];
    wire [3:0] v2_r = v2_reg[`GPU_VTX_R_MSB:`GPU_VTX_R_LSB];
    wire [3:0] v2_g = v2_reg[`GPU_VTX_G_MSB:`GPU_VTX_G_LSB];
    wire [3:0] v2_b = v2_reg[`GPU_VTX_B_MSB:`GPU_VTX_B_LSB];

    wire signed [11:0] sx0, sy0, sx1, sy1, sx2, sy2;
    gpu_viewport_transform vp0(.x_ndc(ndc_x0), .y_ndc(ndc_y0), .x_screen(sx0), .y_screen(sy0));
    gpu_viewport_transform vp1(.x_ndc(ndc_x1), .y_ndc(ndc_y1), .x_screen(sx1), .y_screen(sy1));
    gpu_viewport_transform vp2(.x_ndc(ndc_x2), .y_ndc(ndc_y2), .x_screen(sx2), .y_screen(sy2));

    wire signed [11:0] ts_xmin, ts_xmax, ts_ymin, ts_ymax;
    wire signed [25:0] ts_area;
    wire signed [12:0] ts_A0, ts_B0, ts_A1, ts_B1, ts_A2, ts_B2;
    wire signed [24:0] ts_C0, ts_C1, ts_C2;
    wire ts_degenerate, ts_bbox_empty;

    gpu_triangle_setup u_setup (
        .x0(sx0), .y0(sy0), .x1(sx1), .y1(sy1), .x2(sx2), .y2(sy2),
        .x_min(ts_xmin), .x_max(ts_xmax), .y_min(ts_ymin), .y_max(ts_ymax),
        .area(ts_area), .A0(ts_A0), .B0(ts_B0), .C0(ts_C0),
        .A1(ts_A1), .B1(ts_B1), .C1(ts_C1),
        .A2(ts_A2), .B2(ts_B2), .C2(ts_C2),
        .degenerate(ts_degenerate), .bbox_empty(ts_bbox_empty)
    );

    reg signed [11:0] x0_reg, y0_reg, x1_reg, y1_reg, x2_reg, y2_reg;
    reg [15:0] z0_reg, z1_reg, z2_reg;
    reg [3:0] r0_reg, g0_reg, b0_reg, r1_reg, g1_reg, b1_reg, r2_reg, g2_reg, b2_reg;
    reg signed [11:0] xmin_reg, xmax_reg, ymin_reg, ymax_reg;
    reg signed [25:0] area_reg;
    reg signed [12:0] A0_reg, B0_reg, A1_reg, B1_reg, A2_reg, B2_reg;
    reg signed [24:0] C0_reg, C1_reg, C2_reg;

    // Extend edge coefficients for the doubled pixel-center edge functions.
    wire signed [31:0] A0_ext32 = {{19{A0_reg[12]}}, A0_reg};
    wire signed [31:0] B0_ext32 = {{19{B0_reg[12]}}, B0_reg};
    wire signed [31:0] C0_ext32 = {{7{C0_reg[24]}}, C0_reg};
    wire signed [31:0] A1_ext32 = {{19{A1_reg[12]}}, A1_reg};
    wire signed [31:0] B1_ext32 = {{19{B1_reg[12]}}, B1_reg};
    wire signed [31:0] C1_ext32 = {{7{C1_reg[24]}}, C1_reg};
    wire signed [31:0] A2_ext32 = {{19{A2_reg[12]}}, A2_reg};
    wire signed [31:0] B2_ext32 = {{19{B2_reg[12]}}, B2_reg};
    wire signed [31:0] C2_ext32 = {{7{C2_reg[24]}}, C2_reg};

    wire signed [31:0] ts_A0_ext32 = {{19{ts_A0[12]}}, ts_A0};
    wire signed [31:0] ts_B0_ext32 = {{19{ts_B0[12]}}, ts_B0};
    wire signed [31:0] ts_C0_ext32 = {{7{ts_C0[24]}}, ts_C0};
    wire signed [31:0] ts_A1_ext32 = {{19{ts_A1[12]}}, ts_A1};
    wire signed [31:0] ts_B1_ext32 = {{19{ts_B1[12]}}, ts_B1};
    wire signed [31:0] ts_C1_ext32 = {{7{ts_C1[24]}}, ts_C1};
    wire signed [31:0] ts_A2_ext32 = {{19{ts_A2[12]}}, ts_A2};
    wire signed [31:0] ts_B2_ext32 = {{19{ts_B2[12]}}, ts_B2};
    wire signed [31:0] ts_C2_ext32 = {{7{ts_C2[24]}}, ts_C2};
    wire signed [31:0] ts_xmin_ext32 = {{20{ts_xmin[11]}}, ts_xmin};
    wire signed [31:0] ts_ymin_ext32 = {{20{ts_ymin[11]}}, ts_ymin};
    wire signed [31:0] setup_init_e0 = (((ts_A0_ext32 * ts_xmin_ext32) + (ts_B0_ext32 * ts_ymin_ext32) + ts_C0_ext32) <<< 1) + ts_A0_ext32 + ts_B0_ext32;
    wire signed [31:0] setup_init_e1 = (((ts_A1_ext32 * ts_xmin_ext32) + (ts_B1_ext32 * ts_ymin_ext32) + ts_C1_ext32) <<< 1) + ts_A1_ext32 + ts_B1_ext32;
    wire signed [31:0] setup_init_e2 = (((ts_A2_ext32 * ts_xmin_ext32) + (ts_B2_ext32 * ts_ymin_ext32) + ts_C2_ext32) <<< 1) + ts_A2_ext32 + ts_B2_ext32;

    reg signed [11:0] scan_x, scan_y;
    reg signed [31:0] e0, e1, e2;
    reg signed [31:0] row_e0, row_e1, row_e2;
    reg inside_triangle;
    reg edge0_inclusive, edge1_inclusive, edge2_inclusive;

    wire grad_start = (state == GRAD_START);
    wire all_gradients_ready;
    wire all_samples_ready;
    wire interp_error;
    wire scan_row_end = (state == SCAN) && (scan_x == xmax_reg);
    wire scan_advance;
    wire inside_candidate;

    wire [3:0] interp_r, interp_g, interp_b;
    wire [15:0] interp_z;
    wire valid_r, valid_g, valid_b, valid_z;
    wire busy_r, busy_g, busy_b, busy_z;
    wire done_r, done_g, done_b, done_z;
    wire ready_r, ready_g, ready_b, ready_z;
    wire sample_r, sample_g, sample_b, sample_z;
    wire zero_r, zero_g, zero_b, zero_z;
    wire ovf_r, ovf_g, ovf_b, ovf_z;

    assign all_gradients_ready = ready_r && ready_g && ready_b && ready_z;
    assign all_samples_ready = sample_r && sample_g && sample_b && sample_z;
    assign interp_error = ovf_r || ovf_g || ovf_b || ovf_z ||
                          ((area_reg != 0) && (zero_r || zero_g || zero_b || zero_z));
    assign inside_candidate = inside_triangle;
    assign scan_advance = (state == SCAN) && all_gradients_ready && all_samples_ready &&
                          (!inside_candidate || pixel_ready);

    gpu_interpolator #(.ATTR_WIDTH(4), .SIGNED_ATTR(0), .SUM_WIDTH(48), .FRAC_BITS(16)) u_interp_r (
        .clk(clk), .reset_n(reset_n), .start(grad_start),
        .attr0(r0_reg), .attr1(r1_reg), .attr2(r2_reg),
        .x0(x0_reg), .y0(y0_reg),
        .A0(A0_reg), .B0(B0_reg), .A1(A1_reg), .B1(B1_reg), .A2(A2_reg), .B2(B2_reg), .area(area_reg),
        .pixel_x(scan_x[10:0]), .pixel_y(scan_y[9:0]),
        .scan_valid(state == SCAN), .scan_row_end(scan_row_end), .scan_advance(scan_advance),
        .attr_out(interp_r), .attr_valid(valid_r), .busy(busy_r), .done(done_r),
        .gradients_ready(ready_r), .sample_ready(sample_r), .divide_by_zero(zero_r), .overflow(ovf_r)
    );
    gpu_interpolator #(.ATTR_WIDTH(4), .SIGNED_ATTR(0), .SUM_WIDTH(48), .FRAC_BITS(16)) u_interp_g (
        .clk(clk), .reset_n(reset_n), .start(grad_start),
        .attr0(g0_reg), .attr1(g1_reg), .attr2(g2_reg),
        .x0(x0_reg), .y0(y0_reg),
        .A0(A0_reg), .B0(B0_reg), .A1(A1_reg), .B1(B1_reg), .A2(A2_reg), .B2(B2_reg), .area(area_reg),
        .pixel_x(scan_x[10:0]), .pixel_y(scan_y[9:0]),
        .scan_valid(state == SCAN), .scan_row_end(scan_row_end), .scan_advance(scan_advance),
        .attr_out(interp_g), .attr_valid(valid_g), .busy(busy_g), .done(done_g),
        .gradients_ready(ready_g), .sample_ready(sample_g), .divide_by_zero(zero_g), .overflow(ovf_g)
    );
    gpu_interpolator #(.ATTR_WIDTH(4), .SIGNED_ATTR(0), .SUM_WIDTH(48), .FRAC_BITS(16)) u_interp_b (
        .clk(clk), .reset_n(reset_n), .start(grad_start),
        .attr0(b0_reg), .attr1(b1_reg), .attr2(b2_reg),
        .x0(x0_reg), .y0(y0_reg),
        .A0(A0_reg), .B0(B0_reg), .A1(A1_reg), .B1(B1_reg), .A2(A2_reg), .B2(B2_reg), .area(area_reg),
        .pixel_x(scan_x[10:0]), .pixel_y(scan_y[9:0]),
        .scan_valid(state == SCAN), .scan_row_end(scan_row_end), .scan_advance(scan_advance),
        .attr_out(interp_b), .attr_valid(valid_b), .busy(busy_b), .done(done_b),
        .gradients_ready(ready_b), .sample_ready(sample_b), .divide_by_zero(zero_b), .overflow(ovf_b)
    );
    gpu_interpolator #(.ATTR_WIDTH(16), .SIGNED_ATTR(0), .SUM_WIDTH(48), .FRAC_BITS(16)) u_interp_z (
        .clk(clk), .reset_n(reset_n), .start(grad_start),
        .attr0(z0_reg), .attr1(z1_reg), .attr2(z2_reg),
        .x0(x0_reg), .y0(y0_reg),
        .A0(A0_reg), .B0(B0_reg), .A1(A1_reg), .B1(B1_reg), .A2(A2_reg), .B2(B2_reg), .area(area_reg),
        .pixel_x(scan_x[10:0]), .pixel_y(scan_y[9:0]),
        .scan_valid(state == SCAN), .scan_row_end(scan_row_end), .scan_advance(scan_advance),
        .attr_out(interp_z), .attr_valid(valid_z), .busy(busy_z), .done(done_z),
        .gradients_ready(ready_z), .sample_ready(sample_z), .divide_by_zero(zero_z), .overflow(ovf_z)
    );

    assign triangle_ready = (state == IDLE);
    assign busy = (state != IDLE);
    assign pixel_x = scan_x[10:0];
    assign pixel_y = scan_y[9:0];
    assign pixel_rgb = {interp_r, interp_g, interp_b};
    assign pixel_depth = interp_z;
    assign pixel_valid = (state == SCAN) && inside_candidate && all_gradients_ready &&
                         all_samples_ready && valid_r && valid_g && valid_b && valid_z && !interp_error;

    // Top-left edge ownership. Coefficients correspond to the directed edges
    // V0->V1, V1->V2, and V2->V0. Sign flips for the opposite winding.
    always @* begin
        if (area_reg > 0) begin
            edge0_inclusive = (A0_reg > 0) || ((A0_reg == 0) && (B0_reg > 0));
            edge1_inclusive = (A1_reg > 0) || ((A1_reg == 0) && (B1_reg > 0));
            edge2_inclusive = (A2_reg > 0) || ((A2_reg == 0) && (B2_reg > 0));
            inside_triangle = ((e0 > 0) || ((e0 == 0) && edge0_inclusive)) &&
                              ((e1 > 0) || ((e1 == 0) && edge1_inclusive)) &&
                              ((e2 > 0) || ((e2 == 0) && edge2_inclusive));
        end else begin
            edge0_inclusive = (A0_reg < 0) || ((A0_reg == 0) && (B0_reg < 0));
            edge1_inclusive = (A1_reg < 0) || ((A1_reg == 0) && (B1_reg < 0));
            edge2_inclusive = (A2_reg < 0) || ((A2_reg == 0) && (B2_reg < 0));
            inside_triangle = ((e0 < 0) || ((e0 == 0) && edge0_inclusive)) &&
                              ((e1 < 0) || ((e1 == 0) && edge1_inclusive)) &&
                              ((e2 < 0) || ((e2 == 0) && edge2_inclusive));
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            v0_reg <= 0; v1_reg <= 0; v2_reg <= 0;
            x0_reg <= 0; y0_reg <= 0; x1_reg <= 0; y1_reg <= 0; x2_reg <= 0; y2_reg <= 0;
            z0_reg <= 0; z1_reg <= 0; z2_reg <= 0;
            r0_reg <= 0; g0_reg <= 0; b0_reg <= 0;
            r1_reg <= 0; g1_reg <= 0; b1_reg <= 0;
            r2_reg <= 0; g2_reg <= 0; b2_reg <= 0;
            xmin_reg <= 0; xmax_reg <= 0; ymin_reg <= 0; ymax_reg <= 0;
            area_reg <= 0;
            A0_reg <= 0; B0_reg <= 0; C0_reg <= 0;
            A1_reg <= 0; B1_reg <= 0; C1_reg <= 0;
            A2_reg <= 0; B2_reg <= 0; C2_reg <= 0;
            scan_x <= 0; scan_y <= 0;
            e0 <= 0; e1 <= 0; e2 <= 0;
            row_e0 <= 0; row_e1 <= 0; row_e2 <= 0;
            triangle_done <= 1'b0;
            triangle_error <= 1'b0;
        end else begin
            triangle_done <= 1'b0;
            triangle_error <= 1'b0;
            case (state)
                IDLE: begin
                    if (triangle_valid && triangle_ready) begin
                        v0_reg <= vertex0;
                        v1_reg <= vertex1;
                        v2_reg <= vertex2;
                        state <= SETUP;
                    end
                end
                SETUP: begin
                    x0_reg <= sx0; y0_reg <= sy0;
                    x1_reg <= sx1; y1_reg <= sy1;
                    x2_reg <= sx2; y2_reg <= sy2;
                    z0_reg <= ndc_z0 ^ 16'h8000;
                    z1_reg <= ndc_z1 ^ 16'h8000;
                    z2_reg <= ndc_z2 ^ 16'h8000;
                    r0_reg <= v0_r; g0_reg <= v0_g; b0_reg <= v0_b;
                    r1_reg <= v1_r; g1_reg <= v1_g; b1_reg <= v1_b;
                    r2_reg <= v2_r; g2_reg <= v2_g; b2_reg <= v2_b;

                    xmin_reg <= ts_xmin; xmax_reg <= ts_xmax;
                    ymin_reg <= ts_ymin; ymax_reg <= ts_ymax;
                    area_reg <= ts_area;
                    A0_reg <= ts_A0; B0_reg <= ts_B0; C0_reg <= ts_C0;
                    A1_reg <= ts_A1; B1_reg <= ts_B1; C1_reg <= ts_C1;
                    A2_reg <= ts_A2; B2_reg <= ts_B2; C2_reg <= ts_C2;

                    if (ts_degenerate || ts_bbox_empty) begin
                        state <= FINISH;
                    end else begin
                        scan_x <= ts_xmin;
                        scan_y <= ts_ymin;
                        // Initial values at the center of the first candidate.
                        e0 <= setup_init_e0;
                        e1 <= setup_init_e1;
                        e2 <= setup_init_e2;
                        row_e0 <= setup_init_e0;
                        row_e1 <= setup_init_e1;
                        row_e2 <= setup_init_e2;
                        state <= GRAD_START;
                    end
                end
                GRAD_START: state <= WAIT_GRAD;
                WAIT_GRAD: begin
                    if (all_gradients_ready) begin
                        if (interp_error) begin
                            triangle_error <= 1'b1;
                            state <= FINISH;
                        end else begin
                            state <= SCAN;
                        end
                    end
                end
                SCAN: begin
                    if (scan_advance) begin
                        if (scan_x < xmax_reg) begin
                            scan_x <= scan_x + 1'b1;
                            e0 <= e0 + (A0_ext32 <<< 1);
                            e1 <= e1 + (A1_ext32 <<< 1);
                            e2 <= e2 + (A2_ext32 <<< 1);
                        end else if (scan_y < ymax_reg) begin
                            scan_x <= xmin_reg;
                            scan_y <= scan_y + 1'b1;
                            row_e0 <= row_e0 + (B0_ext32 <<< 1);
                            row_e1 <= row_e1 + (B1_ext32 <<< 1);
                            row_e2 <= row_e2 + (B2_ext32 <<< 1);
                            e0 <= row_e0 + (B0_ext32 <<< 1);
                            e1 <= row_e1 + (B1_ext32 <<< 1);
                            e2 <= row_e2 + (B2_ext32 <<< 1);
                        end else begin
                            state <= FINISH;
                        end
                    end
                end
                FINISH: begin
                    triangle_done <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
