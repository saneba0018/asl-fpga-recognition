`timescale 1ns / 1ps

module tb_mac_unit;

    reg clk = 0, rst = 1;
    reg en = 0, first_term = 0;
    reg signed [7:0] act = 0, weight = 0, zero_point = 0;
    reg signed  [31:0] bias = 0;
    wire signed [31:0] acc;

    mac_unit dut (
        .clk(clk),
        .rst(rst),
        .en(en),
        .first_term(first_term),
        .act(act),
        .weight(weight),
        .zero_point(zero_point),
        .bias(bias),
        .acc(acc)
    );

    always #5 clk = ~clk;

    initial begin
        zero_point = -8'sd128;
        bias       = 32'sd100;
        @(negedge clk) rst = 0;

        @(negedge clk) en = 1;
        first_term = 1;
        act = -8'sd118;
        weight = 8'sd3;
        @(negedge clk) first_term = 0;
        act = -8'sd98;
        weight = -8'sd2;
        @(negedge clk) act = -8'sd28;
        weight = 8'sd5;
        @(negedge clk) en = 0;

        $display("acc = %0d (expect 570)", acc);
        if (acc !== 32'sd570) $display("FAIL");
        else $display("PASS");
        $finish;
    end

endmodule
