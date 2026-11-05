// Per-attribute plane interpolator.
// Gradients are calculated once per triangle using two iterative divisions.
// Pixel samples are then advanced incrementally in lockstep with the rasterizer.
module gpu_interpolator #(
    parameter ATTR_WIDTH = 16,
    parameter SIGNED_ATTR = 0,
    parameter SUM_WIDTH = 48,
    parameter FRAC_BITS = 16
)(
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    input  wire [ATTR_WIDTH-1:0] attr0,
    input  wire [ATTR_WIDTH-1:0] attr1,
    input  wire [ATTR_WIDTH-1:0] attr2,
    input  wire signed [11:0] x0,
    input  wire signed [11:0] y0,
    input  wire signed [12:0] A0,
    input  wire signed [12:0] B0,
    input  wire signed [12:0] A1,
    input  wire signed [12:0] B1,
    input  wire signed [12:0] A2,
    input  wire signed [12:0] B2,
    input  wire signed [25:0] area,
    input  wire [10:0] pixel_x,
    input  wire [9:0] pixel_y,
    input  wire scan_valid,
    input  wire scan_row_end,
    input  wire scan_advance,
    output reg  [ATTR_WIDTH-1:0] attr_out,
    output wire attr_valid,
    output reg  busy,
    output reg  done,
    output reg  gradients_ready,
    output reg  sample_ready,
    output reg  divide_by_zero,
    output reg  overflow
);
    localparam [2:0] IDLE = 3'd0,
                     START_DX = 3'd1,
                     WAIT_DX = 3'd2,
                     START_DY = 3'd3,
                     WAIT_DY = 3'd4;

    reg [2:0] state;
    reg start_armed;
    reg [ATTR_WIDTH-1:0] attr0_latched;
    reg signed [11:0] x0_latched, y0_latched;
    reg signed [SUM_WIDTH-1:0] area_latched;
    reg signed [SUM_WIDTH-1:0] gx_numerator_scaled, gy_numerator_scaled;
    reg signed [SUM_WIDTH-1:0] gradient_x, gradient_y;
    reg signed [SUM_WIDTH-1:0] divider_dividend;
    reg divider_start;

    wire signed [SUM_WIDTH-1:0] divider_quotient;
    wire divider_busy, divider_done, divider_zero, divider_overflow;
    wire signed [SUM_WIDTH-1:0] divider_divisor;
    wire accept_start;

    reg signed [SUM_WIDTH-1:0] a0_ext, a1_ext, a2_ext;
    reg signed [SUM_WIDTH-1:0] A0_ext, A1_ext, A2_ext;
    reg signed [SUM_WIDTH-1:0] B0_ext, B1_ext, B2_ext;
    reg signed [SUM_WIDTH-1:0] gx_sum, gy_sum;
    reg signed [SUM_WIDTH-1:0] gx_scaled, gy_scaled;

    reg signed [15:0] px_ext, py_ext, vx_ext, vy_ext;
    reg signed [15:0] dx2, dy2;
    reg signed [63:0] dx2_ext, dy2_ext;
    reg signed [63:0] gx_ext64, gy_ext64;
    reg signed [63:0] term_x, term_y;
    reg signed [63:0] attr0_ext64, init_sample_q64;
    reg signed [63:0] sample_q64_reg, row_start_q64;
    reg signed [63:0] rounded64, half_lsb64;
    reg signed [63:0] signed_max64, signed_min64, unsigned_max64;

    assign divider_divisor = area_latched;
    assign accept_start = (state == IDLE) && start && start_armed;
    assign attr_valid = scan_valid && gradients_ready && sample_ready &&
                        !divide_by_zero && !overflow;

    signed_divider #(.WIDTH(SUM_WIDTH)) u_divider (
        .clk(clk), .reset_n(reset_n), .start(divider_start),
        .dividend(divider_dividend), .divisor(divider_divisor),
        .quotient(divider_quotient), .busy(divider_busy), .done(divider_done),
        .divide_by_zero(divider_zero), .overflow(divider_overflow)
    );

    // Plane derivatives: dA/dx = (a0*A1+a1*A2+a2*A0)/area;
    //                    dA/dy = (a0*B1+a1*B2+a2*B0)/area.
    // The edge weights are doubled in the rasterizer for pixel-center tests;
    // this derivative expression uses the undoubled edge coefficients.
    always @* begin
        if (SIGNED_ATTR != 0) begin
            a0_ext = {{(SUM_WIDTH-ATTR_WIDTH){attr0[ATTR_WIDTH-1]}}, attr0};
            a1_ext = {{(SUM_WIDTH-ATTR_WIDTH){attr1[ATTR_WIDTH-1]}}, attr1};
            a2_ext = {{(SUM_WIDTH-ATTR_WIDTH){attr2[ATTR_WIDTH-1]}}, attr2};
        end else begin
            a0_ext = {{(SUM_WIDTH-ATTR_WIDTH){1'b0}}, attr0};
            a1_ext = {{(SUM_WIDTH-ATTR_WIDTH){1'b0}}, attr1};
            a2_ext = {{(SUM_WIDTH-ATTR_WIDTH){1'b0}}, attr2};
        end
        A0_ext = {{(SUM_WIDTH-13){A0[12]}}, A0};
        A1_ext = {{(SUM_WIDTH-13){A1[12]}}, A1};
        A2_ext = {{(SUM_WIDTH-13){A2[12]}}, A2};
        B0_ext = {{(SUM_WIDTH-13){B0[12]}}, B0};
        B1_ext = {{(SUM_WIDTH-13){B1[12]}}, B1};
        B2_ext = {{(SUM_WIDTH-13){B2[12]}}, B2};

        gx_sum = (a0_ext * A1_ext) + (a1_ext * A2_ext) + (a2_ext * A0_ext);
        gy_sum = (a0_ext * B1_ext) + (a1_ext * B2_ext) + (a2_ext * B0_ext);
        gx_scaled = gx_sum <<< FRAC_BITS;
        gy_scaled = gy_sum <<< FRAC_BITS;
    end

    // Initial pixel-center sample relative to vertex 0.
    always @* begin
        px_ext = $signed({5'b00000, pixel_x});
        py_ext = $signed({6'b000000, pixel_y});
        vx_ext = {{4{x0_latched[11]}}, x0_latched};
        vy_ext = {{4{y0_latched[11]}}, y0_latched};
        dx2 = ((px_ext - vx_ext) <<< 1) + 16'sd1;
        dy2 = ((py_ext - vy_ext) <<< 1) + 16'sd1;
        dx2_ext = {{48{dx2[15]}}, dx2};
        dy2_ext = {{48{dy2[15]}}, dy2};
        gx_ext64 = {{(64-SUM_WIDTH){gradient_x[SUM_WIDTH-1]}}, gradient_x};
        gy_ext64 = {{(64-SUM_WIDTH){gradient_y[SUM_WIDTH-1]}}, gradient_y};
        term_x = gx_ext64 * dx2_ext;
        term_y = gy_ext64 * dy2_ext;

        if (SIGNED_ATTR != 0)
            attr0_ext64 = {{(64-ATTR_WIDTH){attr0_latched[ATTR_WIDTH-1]}}, attr0_latched};
        else
            attr0_ext64 = {{(64-ATTR_WIDTH){1'b0}}, attr0_latched};
        init_sample_q64 = (attr0_ext64 <<< FRAC_BITS) + ((term_x + term_y) >>> 1);

        half_lsb64 = (64'sd1 <<< (FRAC_BITS-1));
        if (sample_q64_reg >= 0)
            rounded64 = (sample_q64_reg + half_lsb64) >>> FRAC_BITS;
        else
            rounded64 = -(((-sample_q64_reg) + half_lsb64) >>> FRAC_BITS);

        signed_max64 = (64'sd1 <<< (ATTR_WIDTH-1)) - 1;
        signed_min64 = -(64'sd1 <<< (ATTR_WIDTH-1));
        unsigned_max64 = (64'sd1 <<< ATTR_WIDTH) - 1;
        if (SIGNED_ATTR != 0) begin
            if (rounded64 > signed_max64)
                attr_out = {1'b0, {(ATTR_WIDTH-1){1'b1}}};
            else if (rounded64 < signed_min64)
                attr_out = {1'b1, {(ATTR_WIDTH-1){1'b0}}};
            else
                attr_out = rounded64[ATTR_WIDTH-1:0];
        end else begin
            if (rounded64 < 0)
                attr_out = {ATTR_WIDTH{1'b0}};
            else if (rounded64 > unsigned_max64)
                attr_out = {ATTR_WIDTH{1'b1}};
            else
                attr_out = rounded64[ATTR_WIDTH-1:0];
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            start_armed <= 1'b1;
            attr0_latched <= {ATTR_WIDTH{1'b0}};
            x0_latched <= 0;
            y0_latched <= 0;
            area_latched <= 0;
            gx_numerator_scaled <= 0;
            gy_numerator_scaled <= 0;
            gradient_x <= 0;
            gradient_y <= 0;
            divider_dividend <= 0;
            divider_start <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            gradients_ready <= 1'b0;
            divide_by_zero <= 1'b0;
            overflow <= 1'b0;
        end else begin
            done <= 1'b0;
            divider_start <= 1'b0;
            if (!start)
                start_armed <= 1'b1;
            else if (state != IDLE)
                start_armed <= 1'b0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (accept_start) begin
                        start_armed <= 1'b0;
                        gradients_ready <= 1'b0;
                        divide_by_zero <= 1'b0;
                        overflow <= 1'b0;
                        attr0_latched <= attr0;
                        x0_latched <= x0;
                        y0_latched <= y0;
                        area_latched <= {{(SUM_WIDTH-26){area[25]}}, area};
                        gx_numerator_scaled <= gx_scaled;
                        gy_numerator_scaled <= gy_scaled;
                        divider_dividend <= gx_scaled;
                        if (area == 26'sd0) begin
                            gradient_x <= 0;
                            gradient_y <= 0;
                            divide_by_zero <= 1'b1;
                            gradients_ready <= 1'b1;
                            done <= 1'b1;
                        end else begin
                            busy <= 1'b1;
                            state <= START_DX;
                        end
                    end
                end
                START_DX: begin
                    divider_start <= 1'b1;
                    state <= WAIT_DX;
                end
                WAIT_DX: begin
                    if (divider_done) begin
                        gradient_x <= divider_quotient;
                        if (divider_overflow || divider_zero)
                            overflow <= 1'b1;
                        divider_dividend <= gy_numerator_scaled;
                        state <= START_DY;
                    end
                end
                START_DY: begin
                    divider_start <= 1'b1;
                    state <= WAIT_DY;
                end
                WAIT_DY: begin
                    if (divider_done) begin
                        gradient_y <= divider_quotient;
                        if (divider_overflow || divider_zero)
                            overflow <= 1'b1;
                        gradients_ready <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                default: begin
                    state <= IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end

    // Sample state advances only when the rasterizer accepts the candidate.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_q64_reg <= 0;
            row_start_q64 <= 0;
            sample_ready <= 1'b0;
        end else if (accept_start) begin
            sample_q64_reg <= 0;
            row_start_q64 <= 0;
            sample_ready <= 1'b0;
        end else if (scan_valid && gradients_ready && !sample_ready) begin
            sample_q64_reg <= init_sample_q64;
            row_start_q64 <= init_sample_q64;
            sample_ready <= 1'b1;
        end else if (scan_advance && sample_ready) begin
            if (scan_row_end) begin
                row_start_q64 <= row_start_q64 + gy_ext64;
                sample_q64_reg <= row_start_q64 + gy_ext64;
            end else begin
                sample_q64_reg <= sample_q64_reg + gx_ext64;
            end
        end
    end
endmodule
