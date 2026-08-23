// conv_engine: wrapper autour de mac_array + requantize, utilise par
// conv1/conv2/dense1/dense2. Un "terme" est une salve de jusqu'a LANES
// produits sommes en un cycle (conv1: 1 seule voie active, C_IN=1).
//
//   s_valid & s_first : acc <- s_bias + somme(salve)
//   s_valid           : acc <- acc    + somme(salve)
//   s_valid & s_last  : latch (m, shift, zp_out, clamp_min), r_valid pulse
//                       4 cycles plus tard (pipeline srdhm 2 etages)

module conv_engine #(
    parameter LANES = 32
) (
    // timing
    input wire clk,
    input wire rst,

    // data stream IN
    input wire                s_valid,     // salve valide ce cycle
    input wire [LANES*8-1:0]  s_act_vec,   // LANES activations int8 (x_q)
    input wire [LANES*8-1:0]  s_w_vec,     // LANES poids int8 (w_q)
    input wire [  LANES-1:0]  s_lane_en,   // voies actives cette salve
    input wire                s_first,     // 1ere salve -> acc = s_bias + somme
    input wire                s_last,      // derniere salve -> requant + emit
    input wire signed [31:0]  s_bias,      // int32 bias      (echantillonne @ s_first)
    input wire signed [31:0]  s_mult,      // Q31 multiplier  (echantillonne @ s_last)
    input wire        [ 4:0]  s_shift,     // right shift     (echantillonne @ s_last)
    input wire signed [ 7:0]  s_zp_in,     // input zero-point (chaque salve)
    input wire signed [ 7:0]  s_zp_out,    // output zero-point (echantillonne @ s_last)
    input wire signed [ 7:0]  s_clamp_min, // = zp_out couches ReLU, -128 dense2


    //result stream OUT
    output reg              r_valid,  // un pulse par element qui est termine
    output reg signed [7:0] r_data    // int8 y_q
);

    // MAC
    wire signed [31:0] acc;

    mac_array #(.LANES(LANES)) u_mac (
        .clk       (clk),
        .rst       (rst),
        .en        (s_valid),
        .first_term(s_first),
        .act_vec   (s_act_vec),
        .w_vec     (s_w_vec),
        .lane_en   (s_lane_en),
        .zero_point(s_zp_in),
        .bias      (s_bias),
        .acc       (acc)
    );

    //constantes de requant latched sur le dernier terme
    reg signed [31:0] mult_r;
    reg        [ 4:0] shift_r;
    reg signed [31:0] zp_out_r;  // sign-extend int8 -> int32
    reg signed [31:0] clamp_min_r;
    reg               req_pending;  // acc final present ce cycle, capture par u_req

    // req_pending suit la latence de requantize (2 cycles) jusqu'a l'emission.
    reg req_pending_d1, req_pending_d2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            req_pending    <= 1'b0;
            req_pending_d1 <= 1'b0;
            req_pending_d2 <= 1'b0;
        end else begin
            req_pending    <= s_valid & s_last;
            req_pending_d1 <= req_pending;
            req_pending_d2 <= req_pending_d1;
            if (s_valid & s_last) begin
                mult_r      <= s_mult;
                shift_r     <= s_shift;
                zp_out_r    <= s_zp_out;
                clamp_min_r <= s_clamp_min;
            end
        end
    end

    // requantize: srdhm (2 cycles) -> round_shift -> relu_clamp. y_q valide
    // au cycle req_pending_d2.
    wire signed [31:0] y_q;

    requantize u_req (
        .clk      (clk),
        .acc      (acc),
        .m        (mult_r),
        .shift    (shift_r),
        .zp_out   (zp_out_r),
        .clamp_min(clamp_min_r),
        .y_q      (y_q)
    );

    //emission: un pulse r_valid par element, dans l'ordre
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            r_valid <= 1'b0;
            r_data  <= 8'sd0;
        end else begin
            r_valid <= req_pending_d2;
            if (req_pending_d2) r_data <= y_q[7:0];
        end
    end

endmodule
