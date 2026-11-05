// Small support blocks for the rasterizer FPGA test harness:
//   rt_uart_tx      8N1 UART transmitter
//   rt_debounce     synchronizer + debouncer with rising-edge pulse
//   rt_stretch      pulse stretcher so short events are visible on an LED
//   rt_seven_seg    8-digit multiplexed seven-segment driver with letter glyphs
`timescale 1ns/1ps

module rt_uart_tx #(
    parameter CLKS_PER_BIT = 217
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy
);
    reg [9:0]  shreg;
    reg [3:0]  bitn;
    reg [15:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1; busy <= 1'b0; shreg <= 10'h3FF; bitn <= 4'd0; cnt <= 16'd0;
        end else if (!busy) begin
            if (start) begin
                shreg <= {1'b1, data, 1'b0};   // stop, data (LSB first), start
                busy  <= 1'b1;
                bitn  <= 4'd0;
                cnt   <= 16'd0;
                tx    <= 1'b0;                 // start bit
            end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt <= 16'd0;
            if (bitn == 4'd9) begin
                busy <= 1'b0;
                tx   <= 1'b1;
            end else begin
                bitn <= bitn + 4'd1;
                tx   <= shreg[bitn + 4'd1];
            end
        end else begin
            cnt <= cnt + 16'd1;
        end
    end
endmodule

module rt_debounce #(
    parameter CYCLES = 250000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire din,
    output reg  level,
    output wire rise
);
    reg s1, s2, level_d;
    reg [31:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 1'b0; s2 <= 1'b0; level <= 1'b0; level_d <= 1'b0; cnt <= 32'd0;
        end else begin
            s1 <= din;
            s2 <= s1;
            level_d <= level;
            if (s2 == level)
                cnt <= 32'd0;
            else if (cnt >= CYCLES - 1) begin
                level <= s2;
                cnt <= 32'd0;
            end else
                cnt <= cnt + 32'd1;
        end
    end
    assign rise = level && !level_d;
endmodule

module rt_stretch #(
    parameter BITS = 20
)(
    input  wire clk,
    input  wire rst_n,
    input  wire event_in,
    output wire out
);
    reg [BITS-1:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            cnt <= {BITS{1'b0}};
        else if (event_in)     cnt <= {BITS{1'b1}};
        else if (cnt != 0)     cnt <= cnt - 1'b1;
    end
    assign out = (cnt != 0);
endmodule

// Glyph codes (5 bits per digit). 0-15 = hex digit.
//   16 blank, 17 P, 18 r, 19 u, 20 n, 21 L, 22 I, 23 t, 24 -, 25 H, 26 o
// glyphs[39:35] is the LEFTMOST digit (AN7), glyphs[4:0] the rightmost (AN0).
module rt_seven_seg #(
    parameter REFRESH_BITS = 16      // each digit is lit for 2^(REFRESH_BITS-3) cycles
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [39:0] glyphs,
    input  wire [7:0]  dps,          // decimal points, bit 0 = rightmost
    output wire [6:0]  seg,          // active low, seg[6]=CA ... seg[0]=CG
    output wire        dp,           // active low
    output wire [7:0]  an            // active low
);
    reg [REFRESH_BITS-1:0] refresh;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) refresh <= {REFRESH_BITS{1'b0}};
        else        refresh <= refresh + 1'b1;
    end
    wire [2:0] digit = refresh[REFRESH_BITS-1 -: 3];
    wire [4:0] g = glyphs[digit*5 +: 5];
    reg  [6:0] on;     // {a,b,c,d,e,f,g}
    always @* begin
        case (g)
            5'd0:  on = 7'b1111110;
            5'd1:  on = 7'b0110000;
            5'd2:  on = 7'b1101101;
            5'd3:  on = 7'b1111001;
            5'd4:  on = 7'b0110011;
            5'd5:  on = 7'b1011011;
            5'd6:  on = 7'b1011111;
            5'd7:  on = 7'b1110000;
            5'd8:  on = 7'b1111111;
            5'd9:  on = 7'b1111011;
            5'd10: on = 7'b1110111;   // A
            5'd11: on = 7'b0011111;   // b
            5'd12: on = 7'b1001110;   // C
            5'd13: on = 7'b0111101;   // d
            5'd14: on = 7'b1001111;   // E
            5'd15: on = 7'b1000111;   // F
            5'd17: on = 7'b1100111;   // P
            5'd18: on = 7'b0000101;   // r
            5'd19: on = 7'b0011100;   // u
            5'd20: on = 7'b0010101;   // n
            5'd21: on = 7'b0001110;   // L
            5'd22: on = 7'b0000110;   // I
            5'd23: on = 7'b0001111;   // t
            5'd24: on = 7'b0000001;   // -
            5'd25: on = 7'b0110111;   // H
            5'd26: on = 7'b0011101;   // o
            default: on = 7'b0000000; // blank
        endcase
    end
    assign seg = ~on;
    assign dp  = ~dps[digit];
    assign an  = ~(8'b00000001 << digit);
endmodule
