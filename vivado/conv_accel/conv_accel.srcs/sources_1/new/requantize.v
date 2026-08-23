// Sources:
// "A Methodology and Open-Source Tools to Implement CNNs Quantized with TensorFlow Lite on FPGAs"
//     Appendix A: https://doi.org/10.3390/electronics12204367
// gemmlowp fixedpoint, RoundingDivideByPOT (reference impl):
//     https://github.com/google/gemmlowp/blob/master/fixedpoint/fixedpoint.h
// LiteRT Specs https://developers.google.com/edge/litert/conversion/tensorflow/quantization/quantization_spec

// module srdhm base sur Parra, D.; Escobar Sanabria,D.; Camargo, C. Appendix A1 et gemmlowp
// SaturatingRoundingDoublingHighMul
// q = round(acc * m / 2^31) avec m = Q31, acc = int32, q = int32
// (acc * m) est calculé en 64 bits, puis arrondi et trunc vers zéro pour obtenir le résultat final en 32 bits.
// La saturation du cas a == b == INT32_MIN (Appendix A1 ligne 2) est omise :
// m est toujours positif (2^30 <= m < 2^31, assert dans export_params.py), le cas est inatteignable.
//
// PIPELINE (2 etages) : la multiplication 32x32->64 combinatoire etait le
// chemin critique du design a 50 MHz (cf. mem_streamer.v). acc/m n'ont pas
// besoin de rester stables plus d'un cycle : conv_engine.v les tient
// (acc via mac_unit, m via mult_r) exactement le temps que prend cet etage 1
// pour les capturer, puis suit la latence via un registre a decalage sur
// req_pending. Marge confortable meme pour la couche la plus serree
// (conv1 : 9 cycles entre deux elements, latence totale 4 cycles).
//
//   etage 1 : prod_r <= acc * m           (registre en sortie du multiplieur)
//   etage 2 : q      <= round(prod_r / 2^31)   (nudge + shift, registres)

module srdhm (
    input  wire                clk,
    input  wire signed [31:0]  acc,  // int32 accumulator
    input  wire signed [31:0]  m,    // int32 Q31 multiplier
    output reg  signed [31:0]  q     // round(acc * m / 2^31), 2 cycles de latence
);

    // etage 1 : produit exact, registre en sortie du multiplieur
    reg signed [63:0] prod_r;
    always @(posedge clk) prod_r <= acc * m;

    // biais: +2^30 si >=0 ; (1 - 2^30) si <0.
    wire signed [63:0] nudge = prod_r[63] ? -64'sd1073741823 : 64'sd1073741824;
    wire signed [63:0] s = prod_r + nudge;

    // divise par 2^31:
    //   s >= 0 : shift == floor == trunc
    //   s <  0 : trunc = -((-s) >> 31)
    wire signed [63:0] q_ext = s[63] ? -((-s) >>> 31) : (s >>> 31);

    // etage 2 : resultat final, registre
    always @(posedge clk) q <= q_ext[31:0];

endmodule

// base sur papier appendix A2 et gemmlowp (implementation fidele, ligne a ligne)
// full combinational logic
// RoundingDivideByPOT : r = round(q / 2^shift)
//
// convention de tie : les .5 exacts arrondissent en s'eloignant de zero
// (threshold = mask>>1 + (q<0 ? 1 : 0), comme gemmlowp/Appendix 2).
// NB: le double arrondi srdhm+round_shift suit le chemin historique gemmlowp de
// TFLite; les builds recents de LiteRT utilisent le single rounding (ruy,
// TFLITE_SINGLE_ROUNDING) -> ecarts de +-1 possibles sur de rares valeurs.

module round_shift (
    input  signed     [31:0] q,      // sortie du srdhm (resultat etape A)
    input             [ 4:0] shift,  // decalage a droite, >= 0 (0 = passthrough)
    output reg signed [31:0] r       // round(q / 2^shift)
);

    // A2: mask = 2^shift - 1; remainder = q & mask
    wire signed [31:0] mask = (32'sd1 <<< shift) - 32'sd1;  // shift==0 -> mask=0 (passthrough)
    wire signed [31:0] remainder = q & mask;

    // A2: threshold = (mask >> 1) + (q < 0 ? 1 : 0)
    reg signed [31:0] threshold;
    always @* begin
        if (q[31]) begin
            threshold = (mask >>> 1) + 32'sd1;
        end else begin
            threshold = mask >>> 1;
        end
    end

    // A2: r = (q >> shift) + (remainder > threshold ? 1 : 0)
    always @* begin
        if (remainder > threshold) begin
            r = (q >>> shift) + 32'sd1;
        end else begin
            r = q >>> shift;
        end
    end

endmodule

// zero-point add + clamp
// full combinational logic
//   0 correspond au zp_out
//   couche ReLU (conv1, conv2, dense1) -> clamp_min = zp_out
//   pas d'activation (dense2, logits)  -> clamp_min = -128
//   clamp_max = 127 toujours.
//   y_q = clamp(q + zp_out, clamp_min, 127)

module relu_clamp (
    input  wire signed [31:0] q,          // de round_shift output
    input  wire signed [31:0] clamp_min,  // int32 minimum clamp value
    input  wire signed [31:0] zp_out,
    output reg signed  [31:0] y_q         // int32 output
);

    // move onto this tensor's zero-point
    wire signed [31:0] t = q + zp_out;

    // comparaisons
    always @* begin
        if (t < clamp_min)  //min clamp (zp_out ou -128)
            y_q = clamp_min;
        else if (t > 32'sd127)  //int32 max clamp (tjrs 127)
            y_q = 32'sd127;
        else y_q = t;
    end

endmodule

//requantize
//
// shift/zp_out/clamp_min sont combinatoires en aval de srdhm (q sort 2
// cycles apres acc/m) : le contrat avec l'appelant est donc que shift/zp_out/
// clamp_min restent stables au moins aussi longtemps que acc/m, cf.
// conv_engine.v ou mult_r/shift_r/zp_out_r/clamp_min_r sont latches et tenus
// jusqu'au prochain element (largement plus long que 2 cycles).

module requantize (
    input  wire                clk,
    input  wire signed [31:0] acc,
    input  wire signed [31:0] m,
    input  wire        [ 4:0] shift,
    input  wire signed [31:0] zp_out,
    input  wire signed [31:0] clamp_min,
    output wire signed [31:0] y_q
);
    wire signed [31:0] q, r;
    srdhm u_srdhm (
        .clk(clk),
        .acc(acc),
        .m  (m),
        .q  (q)
    );
    round_shift u_shift (
        .q(q),
        .shift(shift),
        .r(r)
    );
    relu_clamp u_clamp (
        .q(r),
        .zp_out(zp_out),
        .clamp_min(clamp_min),
        .y_q(y_q)
    );
endmodule
