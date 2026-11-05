// Small synchronous first-word-fall-through FIFO with ready/valid interface.
// DEPTH need not be a power of two.
module gpu_sync_fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 16
)(
    input  wire clk,
    input  wire reset_n,
    input  wire in_valid,
    output wire in_ready,
    input  wire [WIDTH-1:0] in_data,
    output wire out_valid,
    input  wire out_ready,
    output wire [WIDTH-1:0] out_data,
    output wire [31:0] count
);
    function integer clog2;
        input integer value;
        integer i;
        integer v;
        begin
            v = value - 1;
            for (i = 0; v > 0; i = i + 1)
                v = v >> 1;
            clog2 = (i < 1) ? 1 : i;
        end
    endfunction

    localparam PTR_WIDTH = (DEPTH <= 2) ? 1 : clog2(DEPTH);
    localparam COUNT_WIDTH = clog2(DEPTH+1);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] write_ptr;
    reg [PTR_WIDTH-1:0] read_ptr;
    reg [COUNT_WIDTH-1:0] count_reg;
    wire push;
    wire pop;

    assign out_valid = (count_reg != 0);
    assign out_data = mem[read_ptr];
    assign count = count_reg;
    assign in_ready = (count_reg < DEPTH) || (out_valid && out_ready);
    assign push = in_valid && in_ready;
    assign pop = out_valid && out_ready;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_ptr <= 0;
            read_ptr <= 0;
            count_reg <= 0;
        end else begin
            if (push) begin
                mem[write_ptr] <= in_data;
                if (write_ptr == DEPTH-1)
                    write_ptr <= 0;
                else
                    write_ptr <= write_ptr + 1'b1;
            end
            if (pop) begin
                if (read_ptr == DEPTH-1)
                    read_ptr <= 0;
                else
                    read_ptr <= read_ptr + 1'b1;
            end
            case ({push, pop})
                2'b10: count_reg <= count_reg + 1'b1;
                2'b01: count_reg <= count_reg - 1'b1;
                default: count_reg <= count_reg;
            endcase
        end
    end
endmodule
