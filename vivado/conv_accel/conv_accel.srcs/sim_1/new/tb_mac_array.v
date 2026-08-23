`timescale 1ns / 1ps
// tb_mac_array - envoie le meme flot de termes a mac_unit (1 terme/cycle) et
// mac_array (LANES/cycle) et verifie que les deux accumulateurs finissent
// identiques, sur C_IN = 1/32/1600 (conv1/conv2/dense) et des longueurs non
// multiples de LANES (masque lane_en).
module tb_mac_array;

    localparam LANES = 32;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;

    // --- implementation de reference : mac_unit, 1 terme/cycle ---
    reg               s_en, s_first;
    reg signed [ 7:0] s_act, s_w;
    reg signed [ 7:0] zp;
    reg signed [31:0] bias;
    wire signed [31:0] s_acc;

    mac_unit u_ser (
        .clk(clk), .rst(rst), .en(s_en), .first_term(s_first),
        .act(s_act), .weight(s_w), .zero_point(zp), .bias(bias), .acc(s_acc));

    // --- implementation parallele ---
    reg                    p_en, p_first;
    reg [LANES*8-1:0]      p_act, p_w;
    reg [LANES-1:0]        p_lane;
    wire signed [31:0]     p_acc;

    mac_array #(.LANES(LANES)) u_par (
        .clk(clk), .rst(rst), .en(p_en), .first_term(p_first),
        .act_vec(p_act), .w_vec(p_w), .lane_en(p_lane),
        .zero_point(zp), .bias(bias), .acc(p_acc));

    // stimuli
    reg signed [7:0] act_q [0:2047];
    reg signed [7:0] w_q   [0:2047];

    integer trial, k, c, nchunk, errors, n;
    reg signed [31:0] ser_res, par_res;

    task reset_both;
        begin
            s_en = 0; s_first = 0; p_en = 0; p_first = 0; p_lane = 0;
            rst = 1'b1; @(posedge clk); #1; rst = 1'b0; @(posedge clk); #1;
        end
    endtask

    // Joue N termes en serie sur mac_unit
    task run_serial(input integer n_terms);
        begin
            for (k = 0; k < n_terms; k = k + 1) begin
                s_act   = act_q[k];
                s_w     = w_q[k];
                s_first = (k == 0);
                s_en    = 1'b1;
                @(posedge clk); #1;
            end
            s_en = 1'b0;
        end
    endtask

    // Joue les memes N termes par salves de LANES sur mac_array
    task run_parallel(input integer n_terms);
        integer ch, lane, idx;
        begin
            nchunk = (n_terms + LANES - 1) / LANES;
            for (ch = 0; ch < nchunk; ch = ch + 1) begin
                p_act  = 0; p_w = 0; p_lane = 0;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    idx = ch * LANES + lane;
                    if (idx < n_terms) begin
                        p_act[lane*8+:8] = act_q[idx];
                        p_w  [lane*8+:8] = w_q  [idx];
                        p_lane[lane]     = 1'b1;
                    end
                end
                p_first = (ch == 0);
                p_en    = 1'b1;
                @(posedge clk); #1;
            end
            p_en = 1'b0;
        end
    endtask

    task check(input integer n_terms, input [8*24:1] label);
        begin
            for (k = 0; k < n_terms; k = k + 1) begin
                act_q[k] = $random;
                w_q[k]   = $random;
            end
            zp   = $random;
            bias = $random;

            // Les deux DUT partagent rst : il faut capturer le resultat
            // serie AVANT de reinitialiser pour la passe parallele.
            reset_both();  run_serial(n_terms);    ser_res = s_acc;
            reset_both();  run_parallel(n_terms);  par_res = p_acc;

            if (ser_res !== par_res) begin
                errors = errors + 1;
                $display("  %-22s N=%4d  serie=%0d  parallele=%0d   DIVERGENT",
                         label, n_terms, ser_res, par_res);
            end else begin
                $display("  %-22s N=%4d  acc=%0d   OK", label, n_terms, ser_res);
            end
        end
    endtask

    initial begin
        errors = 0;
        $display("\n=== tb_mac_array : %0d voies vs mac_unit serie ===", LANES);

        check(   1, "conv1  (C_IN=1)");
        check(  32, "conv2  (C_IN=32)");
        check(1600, "dense1 (C_IN=1600)");
        check(  32, "dense2 (C_IN=32)");
        check( 288, "conv2 3x3x32 complet");

        // longueurs non alignees : validation du masque lane_en
        check(   7, "partiel  N=7");
        check(  33, "partiel  N=33");
        check(  63, "partiel  N=63");

        // rafale aleatoire
        for (trial = 0; trial < 12; trial = trial + 1) begin
            n = (($random % 500) + 500) % 500 + 1;
            check(n, "aleatoire");
        end

        $display("\n==========================================");
        if (errors == 0)
            $display("  RESULTAT : mac_array bit a bit identique a mac_unit");
        else
            $display("  RESULTAT : %0d configuration(s) DIVERGENTE(S)", errors);
        $display("==========================================\n");
        $finish;
    end
endmodule
