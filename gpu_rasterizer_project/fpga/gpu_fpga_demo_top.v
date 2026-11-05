// Nexys 4 DDR (XC7A100T) demonstration top.
// Clock generation is external: connect clk to the board clock or project clock
// manager output. reset_n is active-low. BTNC is used as the start button.
module gpu_fpga_demo_top #(
    parameter DEBOUNCE_CYCLES = 400000,
    parameter VERTEX_ADDR_SHIFT = 0
)(
    input  wire clk,
    input  wire reset_n,
    input  wire start_button,
    output wire [7:0] led,
    output wire [6:0] seg,
    output wire [7:0] an,
    output wire dp
);
    reg reset_sync1, reset_sync2;
    wire internal_reset_n = reset_sync2;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reset_sync1 <= 1'b0;
            reset_sync2 <= 1'b0;
        end else begin
            reset_sync1 <= 1'b1;
            reset_sync2 <= reset_sync1;
        end
    end

    reg button_meta, button_sync;
    reg button_stable;
    reg button_stable_d;
    reg [31:0] debounce_count;
    wire start_pulse;

    always @(posedge clk or negedge internal_reset_n) begin
        if (!internal_reset_n) begin
            button_meta <= 1'b0;
            button_sync <= 1'b0;
            button_stable <= 1'b0;
            button_stable_d <= 1'b0;
            debounce_count <= 0;
        end else begin
            button_meta <= start_button;
            button_sync <= button_meta;
            button_stable_d <= button_stable;
            if (button_sync == button_stable) begin
                debounce_count <= 0;
            end else if (debounce_count >= DEBOUNCE_CYCLES-1) begin
                button_stable <= button_sync;
                debounce_count <= 0;
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end
    assign start_pulse = button_stable && !button_stable_d;

    wire tri_req_valid, tri_req_ready, tri_rsp_valid;
    wire [31:0] tri_req_addr;
    wire [63:0] tri_rsp_data;
    wire vtx_req_valid, vtx_req_ready, vtx_rsp_valid;
    wire [31:0] vtx_req_addr;
    wire [63:0] vtx_rsp_data;

    gpu_demo_triangle_rom u_triangle_rom (
        .clk(clk), .reset_n(internal_reset_n), .req_valid(tri_req_valid),
        .req_ready(tri_req_ready), .req_addr(tri_req_addr),
        .rsp_valid(tri_rsp_valid), .rsp_data(tri_rsp_data)
    );
    gpu_demo_vertex_rom #(.ADDR_SHIFT(VERTEX_ADDR_SHIFT)) u_vertex_rom (
        .clk(clk), .reset_n(internal_reset_n), .req_valid(vtx_req_valid),
        .req_ready(vtx_req_ready), .req_addr(vtx_req_addr),
        .rsp_valid(vtx_rsp_valid), .rsp_data(vtx_rsp_data)
    );

    wire [10:0] pixel_x;
    wire [9:0] pixel_y;
    wire [11:0] pixel_rgb;
    wire [15:0] pixel_depth;
    wire pixel_valid;
    wire busy, done, error;
    reg [31:0] pixel_count;
    reg done_latched, error_latched;

    gpu_geometry_rasterizer_top #(
        .ADDR_WIDTH(32),
        .VERTEX_ADDR_SHIFT(VERTEX_ADDR_SHIFT),
        .TRIANGLE_ADDR_STRIDE(1),
        .TRIANGLE_FIFO_DEPTH(4),
        .PIXEL_FIFO_DEPTH(64)
    ) u_gpu (
        .clk(clk), .reset_n(internal_reset_n), .start(start_pulse),
        .triangle_count(32'd1), .triangle_base_addr(32'd0), .vertex_base_addr(32'd0),
        .tri_mem_req_valid(tri_req_valid), .tri_mem_req_ready(tri_req_ready),
        .tri_mem_req_addr(tri_req_addr), .tri_mem_rsp_valid(tri_rsp_valid),
        .tri_mem_rsp_data(tri_rsp_data),
        .vertex_mem_req_valid(vtx_req_valid), .vertex_mem_req_ready(vtx_req_ready),
        .vertex_mem_req_addr(vtx_req_addr), .vertex_mem_rsp_valid(vtx_rsp_valid),
        .vertex_mem_rsp_data(vtx_rsp_data),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_rgb(pixel_rgb),
        .pixel_depth(pixel_depth), .pixel_valid(pixel_valid), .pixel_ready(1'b1),
        .busy(busy), .done(done), .error(error)
    );

    always @(posedge clk or negedge internal_reset_n) begin
        if (!internal_reset_n) begin
            pixel_count <= 0;
            done_latched <= 1'b0;
            error_latched <= 1'b0;
        end else begin
            if (start_pulse) begin
                pixel_count <= 0;
                done_latched <= 1'b0;
                error_latched <= 1'b0;
            end else begin
                if (pixel_valid)
                    pixel_count <= pixel_count + 1'b1;
                if (done)
                    done_latched <= 1'b1;
                if (error)
                    error_latched <= 1'b1;
            end
        end
    end

    assign led = {error_latched, done_latched, busy, pixel_count[4:0]};
    assign dp = 1'b1;

    reg [19:0] refresh_counter;
    reg [3:0] hex_digit;
    reg [6:0] seg_on;
    wire [2:0] digit_select = refresh_counter[17:15];

    always @(posedge clk or negedge internal_reset_n) begin
        if (!internal_reset_n)
            refresh_counter <= 0;
        else
            refresh_counter <= refresh_counter + 1'b1;
    end

    always @* begin
        case (digit_select)
            3'd0: hex_digit = pixel_count[3:0];
            3'd1: hex_digit = pixel_count[7:4];
            3'd2: hex_digit = pixel_count[11:8];
            3'd3: hex_digit = pixel_count[15:12];
            3'd4: hex_digit = pixel_count[19:16];
            3'd5: hex_digit = pixel_count[23:20];
            3'd6: hex_digit = pixel_count[27:24];
            default: hex_digit = pixel_count[31:28];
        endcase
        case (hex_digit)
            4'h0: seg_on = 7'b1111110;
            4'h1: seg_on = 7'b0110000;
            4'h2: seg_on = 7'b1101101;
            4'h3: seg_on = 7'b1111001;
            4'h4: seg_on = 7'b0110011;
            4'h5: seg_on = 7'b1011011;
            4'h6: seg_on = 7'b1011111;
            4'h7: seg_on = 7'b1110000;
            4'h8: seg_on = 7'b1111111;
            4'h9: seg_on = 7'b1111011;
            4'hA: seg_on = 7'b1110111;
            4'hB: seg_on = 7'b0011111;
            4'hC: seg_on = 7'b1001110;
            4'hD: seg_on = 7'b0111101;
            4'hE: seg_on = 7'b1001111;
            default: seg_on = 7'b1000111;
        endcase
    end
    assign seg = ~seg_on;
    assign an = ~(8'b00000001 << digit_select);
endmodule
