// pool_engine — max 2x2 stride 2
//
// streame les <=4 pixels de la fenetre avec s_first/s_last;
// l'engine emet le max signe. Pas de requant
//
// Comportement:
//   s_valid & s_first  : maxv <- s_act
//   s_valid & ~s_first : maxv <- max signe(maxv, s_act)
//   s_valid & s_last   : apres le max ci-dessus, emettre r_data = maxv,
//                        r_valid pulse 1 cycle

module pool_engine (
    input wire clk,
    input wire rst,

    // operand stream IN
    input wire              s_valid,  // pixel valide ce cycle
    input wire signed [7:0] s_act,    // int8 pixel de la fenetre
    input wire              s_first,  // 1er pixel -> maxv = s_act
    input wire              s_last,   // dernier pixel -> emit

    // result stream OUT
    output reg              r_valid,  // un pulse par fenetre terminee
    output reg signed [7:0] r_data    // int8 max signe de la fenetre
);

    reg signed [7:0] max;  // max courant
    reg pending;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending <= 1'b0;
            r_valid <= 1'b0;
            r_data  <= 8'sd0;
            max     <= 8'sd0;
        end else begin
            // max courant
            if (s_valid) begin
                if (s_first) max <= s_act;  // premier act = max
                else if (max < s_act) max <= s_act;
            end

            // output decale d'un cycle: au cycle pending, max est complet
            pending <= s_valid & s_last;
            r_valid <= pending;  // pulse 1 cycle, auto-clear
            if (pending) r_data <= max;
        end
    end

endmodule
