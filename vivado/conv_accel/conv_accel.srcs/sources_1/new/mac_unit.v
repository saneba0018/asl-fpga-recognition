module mac_unit (
    input  wire               clk,
    rst,
    input  wire               en,
    input  wire               first_term,  // flag
    input  wire signed [ 7:0] act,         // int8 activation input
    input  wire signed [ 7:0] weight,      // int8 weight input
    input  wire signed [ 7:0] zero_point,  // int8 zero point input
    input  wire signed [31:0] bias,        // int32 bias input
    output reg signed  [31:0] acc          // int32 accumulator output
);

    // zero_point soustrait de act
    wire signed [31:0] product = (act - zero_point) * weight;

    // multiply and accumulate
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc <= 32'sd0;
        end else if (en) begin
            if (first_term) begin
                acc <= bias + product;
            end else begin
                acc <= acc + product;
            end
        end
    end

endmodule
