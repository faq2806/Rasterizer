`include "gpu_config.vh"

// Indexed geometry fetch controller.
// Each memory channel permits one outstanding read. A request is held until
// req_ready; the FSM then waits for rsp_valid before capturing rsp_data.
// Address convention is configurable: VERTEX_ADDR_SHIFT=0 for 64-bit-word
// addressing, or 3 for byte addressing (8-byte vertex records).
module gpu_geometry_fetch #(
    parameter ADDR_WIDTH = 32,
    parameter VERTEX_ADDR_SHIFT = 0,
    parameter TRIANGLE_ADDR_STRIDE = 1
)(
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    input  wire [31:0] triangle_count,
    input  wire [ADDR_WIDTH-1:0] triangle_base_addr,
    input  wire [ADDR_WIDTH-1:0] vertex_base_addr,

    output wire tri_mem_req_valid,
    input  wire tri_mem_req_ready,
    output wire [ADDR_WIDTH-1:0] tri_mem_req_addr,
    input  wire tri_mem_rsp_valid,
    input  wire [63:0] tri_mem_rsp_data,

    output wire vertex_mem_req_valid,
    input  wire vertex_mem_req_ready,
    output wire [ADDR_WIDTH-1:0] vertex_mem_req_addr,
    input  wire vertex_mem_rsp_valid,
    input  wire [63:0] vertex_mem_rsp_data,

    output wire triangle_valid,
    input  wire triangle_ready,
    output wire [63:0] vertex0,
    output wire [63:0] vertex1,
    output wire [63:0] vertex2,

    output wire busy,
    output reg done
);
    localparam [3:0] IDLE = 4'd0,
                     TRI_REQ = 4'd1,
                     TRI_WAIT = 4'd2,
                     VTX_REQ = 4'd3,
                     VTX_WAIT = 4'd4,
                     OUTPUT_TRI = 4'd5,
                     FINISH = 4'd6;

    reg [3:0] state;
    reg start_armed;
    reg [31:0] remaining;
    reg [31:0] triangle_number;
    reg [ADDR_WIDTH-1:0] tri_addr_reg;
    reg [ADDR_WIDTH-1:0] vertex_base_reg;
    reg [`GPU_INDEX_WIDTH-1:0] index0_reg, index1_reg, index2_reg;
    reg [1:0] vertex_select;
    reg [63:0] vertex0_reg, vertex1_reg, vertex2_reg;

    wire [`GPU_INDEX_WIDTH-1:0] index_selected;
    wire [ADDR_WIDTH-1:0] index_offset;

    assign index_selected = (vertex_select == 0) ? index0_reg :
                            (vertex_select == 1) ? index1_reg : index2_reg;
    assign index_offset = ({{(ADDR_WIDTH-`GPU_INDEX_WIDTH){1'b0}}, index_selected}) << VERTEX_ADDR_SHIFT;

    assign tri_mem_req_valid = (state == TRI_REQ);
    assign tri_mem_req_addr = tri_addr_reg;
    assign vertex_mem_req_valid = (state == VTX_REQ);
    assign vertex_mem_req_addr = vertex_base_reg + index_offset;

    assign triangle_valid = (state == OUTPUT_TRI);
    assign vertex0 = vertex0_reg;
    assign vertex1 = vertex1_reg;
    assign vertex2 = vertex2_reg;
    assign busy = (state != IDLE);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            start_armed <= 1'b1;
            remaining <= 0;
            triangle_number <= 0;
            tri_addr_reg <= 0;
            vertex_base_reg <= 0;
            index0_reg <= 0;
            index1_reg <= 0;
            index2_reg <= 0;
            vertex_select <= 0;
            vertex0_reg <= 0;
            vertex1_reg <= 0;
            vertex2_reg <= 0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!start)
                start_armed <= 1'b1;

            case (state)
                IDLE: begin
                    if (start && start_armed) begin
                        start_armed <= 1'b0;
                        remaining <= triangle_count;
                        triangle_number <= 0;
                        tri_addr_reg <= triangle_base_addr;
                        vertex_base_reg <= vertex_base_addr;
                        if (triangle_count == 0)
                            state <= FINISH;
                        else
                            state <= TRI_REQ;
                    end
                end
                TRI_REQ: begin
                    if (tri_mem_req_valid && tri_mem_req_ready)
                        state <= TRI_WAIT;
                end
                TRI_WAIT: begin
                    if (tri_mem_rsp_valid) begin
                        index0_reg <= tri_mem_rsp_data[`GPU_TRI_I0_MSB:`GPU_TRI_I0_LSB];
                        index1_reg <= tri_mem_rsp_data[`GPU_TRI_I1_MSB:`GPU_TRI_I1_LSB];
                        index2_reg <= tri_mem_rsp_data[`GPU_TRI_I2_MSB:`GPU_TRI_I2_LSB];
                        vertex_select <= 0;
                        state <= VTX_REQ;
                    end
                end
                VTX_REQ: begin
                    if (vertex_mem_req_valid && vertex_mem_req_ready)
                        state <= VTX_WAIT;
                end
                VTX_WAIT: begin
                    if (vertex_mem_rsp_valid) begin
                        case (vertex_select)
                            0: vertex0_reg <= vertex_mem_rsp_data;
                            1: vertex1_reg <= vertex_mem_rsp_data;
                            default: vertex2_reg <= vertex_mem_rsp_data;
                        endcase
                        if (vertex_select == 2)
                            state <= OUTPUT_TRI;
                        else begin
                            vertex_select <= vertex_select + 1'b1;
                            state <= VTX_REQ;
                        end
                    end
                end
                OUTPUT_TRI: begin
                    if (triangle_valid && triangle_ready) begin
                        if (remaining == 1) begin
                            remaining <= 0;
                            state <= FINISH;
                        end else begin
                            remaining <= remaining - 1'b1;
                            triangle_number <= triangle_number + 1'b1;
                            tri_addr_reg <= tri_addr_reg + TRIANGLE_ADDR_STRIDE;
                            state <= TRI_REQ;
                        end
                    end
                end
                FINISH: begin
                    done <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
