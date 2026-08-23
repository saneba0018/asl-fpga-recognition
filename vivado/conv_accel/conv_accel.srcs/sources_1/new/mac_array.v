// mac_array - accumulateur MAC a LANES voies paralleles (remplace mac_unit,
// 1 terme/cycle, par LANES termes/cycle). LANES=32 car conv2/dense1/dense2
// ont C_IN multiple de 32 (layout canal-en-dernier -> une voie par canal
// d'entree, aucun realignement). lane_en masque les voies inactives (conv1,
// C_IN=1, n'active que la voie 0). Accumulation int32 non saturee: sommer en
// arbre plutot qu'en serie donne le meme resultat que mac_unit (verifie par
// tb_mac_array).

`timescale 1ns / 1ps

module mac_array #(
    parameter LANES = 32
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     en,
    input  wire                     first_term,
    input  wire [       LANES*8-1:0] act_vec,     // LANES activations int8
    input  wire [       LANES*8-1:0] w_vec,       // LANES poids int8
    input  wire [         LANES-1:0] lane_en,     // voies contribuant ce cycle
    input  wire signed [        7:0] zero_point,
    input  wire signed [       31:0] bias,
    output reg  signed [       31:0] acc
);

    // Somme combinatoire des LANES produits.
    // Calcul en 32 bits signes par voie : identique a mac_unit, ou le contexte
    // d'affectation 32 bits etend les operandes avant la soustraction.
    reg signed [31:0] sum;

    integer i;
    reg signed [31:0] a_ext, w_ext;

    always @(*) begin
        sum = 32'sd0;
        for (i = 0; i < LANES; i = i + 1) begin
            a_ext = $signed(act_vec[i*8+:8]);
            w_ext = $signed(w_vec[i*8+:8]);
            if (lane_en[i]) sum = sum + (a_ext - $signed(zero_point)) * w_ext;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc <= 32'sd0;
        end else if (en) begin
            if (first_term) acc <= bias + sum;
            else            acc <= acc + sum;
        end
    end

endmodule
