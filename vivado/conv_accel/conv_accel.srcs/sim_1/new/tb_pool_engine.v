`timescale 1ns / 1ps

module tb_pool_engine;

    reg clk = 0, rst = 1;
    reg s_valid = 0, s_first = 0, s_last = 0;
    reg signed [7:0] s_act = 0;
    wire r_valid;
    wire signed [7:0] r_data;

    pool_engine dut (
        .clk(clk),
        .rst(rst),
        .s_valid(s_valid),
        .s_act(s_act),
        .s_first(s_first),
        .s_last(s_last),
        .r_valid(r_valid),
        .r_data(r_data)
    );

    always #5 clk = ~clk;

    always @(posedge clk) if (r_valid) $display("pool out = %0d", r_data);

    initial begin
        @(negedge clk) rst = 0;

        @(negedge clk) s_valid = 1;
        s_first = 1;
        s_act   = -8'sd5;
        @(negedge clk) s_first = 0;
        s_act = 8'sd7;
        @(negedge clk) s_act = 8'sd3;
        @(negedge clk) s_last = 1;
        s_act = -8'sd1;

        @(negedge clk) s_last = 0;
        s_first = 1;
        s_act   = -8'sd20;
        @(negedge clk) s_first = 0;
        s_act = -8'sd30;
        @(negedge clk) s_act = -8'sd128;
        @(negedge clk) s_last = 1;
        s_act = -8'sd60;

        @(negedge clk) s_valid = 0;
        s_last = 0;

        repeat (4) @(negedge clk);
        $display("expected: 7 then -20");
        $finish;
    end

endmodule
