`include "gpu_config.vh"

// NDC Q1.15 to integer screen coordinates. Y is inverted for screen space.
// +1.0 is not representable in signed Q1.15; 16'h7fff is treated as the
// positive endpoint so it maps to the final screen column.
module gpu_viewport_transform (
    input  wire signed [15:0] x_ndc,
    input  wire signed [15:0] y_ndc,
    output reg  signed [11:0] x_screen,
    output reg  signed [11:0] y_screen
);
    reg signed [17:0] x_shifted;
    reg signed [17:0] y_shifted;
    reg        [31:0] x_product;
    reg        [31:0] y_product;

    always @* begin
        x_shifted = $signed({{2{x_ndc[15]}}, x_ndc}) + 18'sd32768;
        y_shifted = 18'sd32768 - $signed({{2{y_ndc[15]}}, y_ndc});

        // Both shifted values are non-negative in the Q1.15 input domain.
        x_product = {{14{1'b0}}, x_shifted[17:0]} * 32'd799;
        y_product = {{14{1'b0}}, y_shifted[17:0]} * 32'd599;

        x_screen = $signed(x_product[27:16]);
        y_screen = $signed(y_product[27:16]);
        if (x_ndc == 16'sh7fff)
            x_screen = 12'sd799;
    end
endmodule
