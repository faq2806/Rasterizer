// Combinational setup for integer screen-space vertices.
// Bounds are clipped here; vertices themselves are never individually clamped.
module gpu_triangle_setup (
    input  wire signed [11:0] x0, y0,
    input  wire signed [11:0] x1, y1,
    input  wire signed [11:0] x2, y2,
    output reg  signed [11:0] x_min,
    output reg  signed [11:0] x_max,
    output reg  signed [11:0] y_min,
    output reg  signed [11:0] y_max,
    output reg  signed [25:0] area,
    output reg  signed [12:0] A0, B0,
    output reg  signed [24:0] C0,
    output reg  signed [12:0] A1, B1,
    output reg  signed [24:0] C1,
    output reg  signed [12:0] A2, B2,
    output reg  signed [24:0] C2,
    output reg  degenerate,
    output reg  bbox_empty
);
    reg signed [12:0] dx01, dy01, dx12, dy12, dx20, dy20;
    reg signed [12:0] dx02, dy02;
    reg signed [23:0] x0_ext24, y0_ext24, x1_ext24, y1_ext24, x2_ext24, y2_ext24;
    reg signed [23:0] p_x0y1, p_y0x1;
    reg signed [23:0] p_x1y2, p_y1x2;
    reg signed [23:0] p_x2y0, p_y2x0;
    reg signed [24:0] c0_wide, c1_wide, c2_wide;
    reg signed [25:0] dx01_ext26, dy02_ext26, dy01_ext26, dx02_ext26;
    reg signed [25:0] area_p0, area_p1;
    reg signed [26:0] area_wide;

    always @* begin
        // Raw min/max.
        x_min = (x0 < x1) ? ((x0 < x2) ? x0 : x2) : ((x1 < x2) ? x1 : x2);
        x_max = (x0 > x1) ? ((x0 > x2) ? x0 : x2) : ((x1 > x2) ? x1 : x2);
        y_min = (y0 < y1) ? ((y0 < y2) ? y0 : y2) : ((y1 < y2) ? y1 : y2);
        y_max = (y0 > y1) ? ((y0 > y2) ? y0 : y2) : ((y1 > y2) ? y1 : y2);

        // Clip the candidate region, not the original vertices.
        if (x_min < 12'sd0)   x_min = 12'sd0;
        if (x_max > 12'sd799) x_max = 12'sd799;
        if (y_min < 12'sd0)   y_min = 12'sd0;
        if (y_max > 12'sd599) y_max = 12'sd599;
        bbox_empty = (x_min > x_max) || (y_min > y_max);

        dx01 = x1 - x0; dy01 = y1 - y0;
        dx12 = x2 - x1; dy12 = y2 - y1;
        dx20 = x0 - x2; dy20 = y0 - y2;
        dx02 = x2 - x0; dy02 = y2 - y0;

        // E(P) = A*x + B*y + C for each directed edge.
        A0 = -dy01; B0 = dx01;
        A1 = -dy12; B1 = dx12;
        A2 = -dy20; B2 = dx20;

        x0_ext24 = {{12{x0[11]}}, x0}; y0_ext24 = {{12{y0[11]}}, y0};
        x1_ext24 = {{12{x1[11]}}, x1}; y1_ext24 = {{12{y1[11]}}, y1};
        x2_ext24 = {{12{x2[11]}}, x2}; y2_ext24 = {{12{y2[11]}}, y2};
        p_x0y1 = x0_ext24 * y1_ext24; p_y0x1 = y0_ext24 * x1_ext24;
        p_x1y2 = x1_ext24 * y2_ext24; p_y1x2 = y1_ext24 * x2_ext24;
        p_x2y0 = x2_ext24 * y0_ext24; p_y2x0 = y2_ext24 * x0_ext24;
        c0_wide = {p_x0y1[23], p_x0y1} - {p_y0x1[23], p_y0x1};
        c1_wide = {p_x1y2[23], p_x1y2} - {p_y1x2[23], p_y1x2};
        c2_wide = {p_x2y0[23], p_x2y0} - {p_y2x0[23], p_y2x0};
        C0 = c0_wide;
        C1 = c1_wide;
        C2 = c2_wide;

        dx01_ext26 = {{13{dx01[12]}}, dx01};
        dy02_ext26 = {{13{dy02[12]}}, dy02};
        dy01_ext26 = {{13{dy01[12]}}, dy01};
        dx02_ext26 = {{13{dx02[12]}}, dx02};
        area_p0 = dx01_ext26 * dy02_ext26;
        area_p1 = dy01_ext26 * dx02_ext26;
        area_wide = {area_p0[25], area_p0} - {area_p1[25], area_p1};
        area = area_wide[25:0];
        degenerate = (area == 26'sd0);
    end
endmodule
