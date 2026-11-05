// Iterative signed restoring divider (one quotient bit per clock).
// start is accepted once per low-to-high request; done is a one-cycle pulse.
module signed_divider #(
    parameter WIDTH = 48
)(
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    input  wire signed [WIDTH-1:0] dividend,
    input  wire signed [WIDTH-1:0] divisor,
    output reg  signed [WIDTH-1:0] quotient,
    output reg  busy,
    output reg  done,
    output reg  divide_by_zero,
    output reg  overflow
);
    localparam [1:0] IDLE = 2'd0, CALC = 2'd1, FINISH = 2'd2;
    localparam [WIDTH-1:0] MIN_SIGNED = {1'b1, {(WIDTH-1){1'b0}}};
    localparam [WIDTH-1:0] MAX_SIGNED = {1'b0, {(WIDTH-1){1'b1}}};
    localparam [WIDTH-1:0] NEG_ONE = {WIDTH{1'b1}};

    reg [1:0] state;
    reg start_armed;
    reg [WIDTH-1:0] dividend_shift;
    reg [WIDTH-1:0] quotient_work;
    reg [WIDTH:0] remainder_work;
    reg [WIDTH:0] divisor_ext;
    reg [WIDTH:0] remainder_trial;
    reg [WIDTH:0] remainder_next;
    reg [WIDTH-1:0] quotient_next;
    reg quotient_negative;
    reg [31:0] count;
    reg [WIDTH-1:0] dividend_magnitude;
    reg [WIDTH-1:0] divisor_magnitude;

    always @* begin
        dividend_magnitude = dividend[WIDTH-1] ? ((~dividend) + {{(WIDTH-1){1'b0}},1'b1}) : dividend;
        divisor_magnitude  = divisor[WIDTH-1]  ? ((~divisor)  + {{(WIDTH-1){1'b0}},1'b1}) : divisor;

        remainder_trial = {remainder_work[WIDTH-1:0], dividend_shift[WIDTH-1]};
        remainder_next = remainder_trial;
        quotient_next = quotient_work << 1;
        if (remainder_trial >= divisor_ext) begin
            remainder_next = remainder_trial - divisor_ext;
            quotient_next[0] = 1'b1;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            start_armed <= 1'b1;
            quotient <= {WIDTH{1'b0}};
            busy <= 1'b0;
            done <= 1'b0;
            divide_by_zero <= 1'b0;
            overflow <= 1'b0;
            dividend_shift <= {WIDTH{1'b0}};
            divisor_ext <= {(WIDTH+1){1'b0}};
            quotient_work <= {WIDTH{1'b0}};
            remainder_work <= {(WIDTH+1){1'b0}};
            quotient_negative <= 1'b0;
            count <= 0;
        end else begin
            done <= 1'b0;
            if (!start)
                start_armed <= 1'b1;
            else if (state != IDLE)
                start_armed <= 1'b0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start && start_armed) begin
                        start_armed <= 1'b0;
                        busy <= 1'b1;
                        divide_by_zero <= 1'b0;
                        overflow <= 1'b0;
                        if (divisor == {WIDTH{1'b0}}) begin
                            quotient <= {WIDTH{1'b0}};
                            divide_by_zero <= 1'b1;
                            state <= FINISH;
                        end else if ((dividend == MIN_SIGNED) && (divisor == NEG_ONE)) begin
                            quotient <= MAX_SIGNED;
                            overflow <= 1'b1;
                            state <= FINISH;
                        end else begin
                            dividend_shift <= dividend_magnitude;
                            divisor_ext <= {1'b0, divisor_magnitude};
                            quotient_work <= {WIDTH{1'b0}};
                            remainder_work <= {(WIDTH+1){1'b0}};
                            quotient_negative <= dividend[WIDTH-1] ^ divisor[WIDTH-1];
                            count <= WIDTH;
                            state <= CALC;
                        end
                    end
                end
                CALC: begin
                    dividend_shift <= dividend_shift << 1;
                    quotient_work <= quotient_next;
                    remainder_work <= remainder_next;
                    count <= count - 1'b1;
                    if (count == 1) begin
                        if (quotient_negative)
                            quotient <= (~quotient_next) + {{(WIDTH-1){1'b0}},1'b1};
                        else
                            quotient <= quotient_next;
                        state <= FINISH;
                    end
                end
                FINISH: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
                default: begin
                    state <= IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule
