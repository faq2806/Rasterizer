// Optional adapter for a single shared 64-bit read port.
// The geometry fetch FSM is sequential, so triangle and vertex requests never
// overlap. This mux routes the single outstanding response to its requester.
// The shared memory must return rsp_valid after the accepted request (not in
// the same cycle as req_valid && req_ready).
module gpu_geometry_read_mux #(
    parameter ADDR_WIDTH = 32
)(
    input  wire clk,
    input  wire reset_n,

    input  wire tri_req_valid,
    output wire tri_req_ready,
    input  wire [ADDR_WIDTH-1:0] tri_req_addr,
    output reg tri_rsp_valid,
    output reg [63:0] tri_rsp_data,

    input  wire vertex_req_valid,
    output wire vertex_req_ready,
    input  wire [ADDR_WIDTH-1:0] vertex_req_addr,
    output reg vertex_rsp_valid,
    output reg [63:0] vertex_rsp_data,

    output wire mem_req_valid,
    input  wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input  wire mem_rsp_valid,
    input  wire [63:0] mem_rsp_data
);
    reg outstanding;
    reg route_to_triangle;
    wire select_triangle = tri_req_valid;
    wire can_issue = !outstanding && mem_req_ready;

    assign mem_req_valid = !outstanding && (tri_req_valid || vertex_req_valid);
    assign mem_req_addr = select_triangle ? tri_req_addr : vertex_req_addr;
    assign tri_req_ready = can_issue && tri_req_valid;
    assign vertex_req_ready = can_issue && !tri_req_valid && vertex_req_valid;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            outstanding <= 1'b0;
            route_to_triangle <= 1'b0;
            tri_rsp_valid <= 1'b0;
            vertex_rsp_valid <= 1'b0;
            tri_rsp_data <= 0;
            vertex_rsp_data <= 0;
        end else begin
            tri_rsp_valid <= 1'b0;
            vertex_rsp_valid <= 1'b0;

            if (mem_req_valid && mem_req_ready) begin
                outstanding <= 1'b1;
                route_to_triangle <= select_triangle;
            end

            if (outstanding && mem_rsp_valid) begin
                if (route_to_triangle) begin
                    tri_rsp_valid <= 1'b1;
                    tri_rsp_data <= mem_rsp_data;
                end else begin
                    vertex_rsp_valid <= 1'b1;
                    vertex_rsp_data <= mem_rsp_data;
                end
                outstanding <= 1'b0;
            end
        end
    end
endmodule
