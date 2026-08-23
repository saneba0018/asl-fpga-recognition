`timescale 1ns / 1ps

module tb_conv_engine;

    localparam LANES = 32;

    reg clk = 0, rst = 1;
    reg s_valid = 0, s_first = 0, s_last = 0;
    reg signed [7:0] s_act = 0, s_w = 0;
    reg signed [31:0] s_bias = 0, s_mult = 0;
    reg [4:0] s_shift = 0;
    reg signed [7:0] s_zp_in = 0, s_zp_out = 0, s_clamp_min = 0;
    wire r_valid;
    wire signed [7:0] r_data;

    // conv1-style : une seule voie active par salve (lane 0), le reste
    // masque par s_lane_en -- meme comportement qu'un mac_unit serie.
    wire [LANES*8-1:0] s_act_vec = {{(LANES-1){8'd0}}, s_act};
    wire [LANES*8-1:0] s_w_vec   = {{(LANES-1){8'd0}}, s_w};
    wire [LANES-1:0]   s_lane_en = {{(LANES-1){1'b0}}, 1'b1};

    conv_engine #(.LANES(LANES)) dut (
        .clk(clk),
        .rst(rst),
        .s_valid(s_valid),
        .s_act_vec(s_act_vec),
        .s_w_vec(s_w_vec),
        .s_lane_en(s_lane_en),
        .s_first(s_first),
        .s_last(s_last),
        .s_bias(s_bias),
        .s_mult(s_mult),
        .s_shift(s_shift),
        .s_zp_in(s_zp_in),
        .s_zp_out(s_zp_out),
        .s_clamp_min(s_clamp_min),
        .r_valid(r_valid),
        .r_data(r_data)
    );

    always #5 clk = ~clk;

    always @(posedge clk) if (r_valid) $display("conv out = %0d", r_data);

    initial begin
        s_zp_in     = -8'sd128;
        s_mult      = 32'sd1073741824;
        s_shift     = 5'd4;
        s_zp_out    = -8'sd41;
        s_clamp_min = -8'sd41;
        @(negedge clk) rst = 0;

        @(negedge clk) s_valid = 1;
        s_first = 1;
        s_bias = 32'sd100;
        s_act = -8'sd118;
        s_w = 8'sd3;
        @(negedge clk) s_first = 0;
        s_act = -8'sd98;
        s_w   = -8'sd2;
        @(negedge clk) s_last = 1;
        s_act = -8'sd28;
        s_w   = 8'sd5;

        @(negedge clk) s_last = 0;
        s_first = 1;
        s_bias = -32'sd400;
        s_act = -8'sd128;
        s_w = 8'sd7;
        @(negedge clk) s_first = 0;
        s_act = -8'sd58;
        s_w   = -8'sd4;
        @(negedge clk) s_last = 1;
        s_act = 8'sd126;
        s_w   = 8'sd1;

        @(negedge clk) s_valid = 0;
        s_last = 0;

        // requantize (srdhm pipeline 2 etages) porte r_valid a 4 cycles
        // apres s_last ; marge large pour laisser sortir le 2e resultat.
        repeat (10) @(negedge clk);
        $display("expected: -23 then -41");
        $finish;
    end

endmodule
