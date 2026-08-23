// param_rom_wide - ROM de poids a lecture large, en LANES bancs (meme
// principe que act_ram_wide, applique a weights.mem : le layout TFLite
// addr = WOFF + ((oc*K+ky)*K+kx)*C_IN+ic rend les C_IN poids d'un tap
// contigus). $readmemh ne peut pas remplir LANES bancs directement, donc le
// fichier est lu en entier dans un tableau temporaire a l'elaboration puis
// redistribue (initialisation pure, synthetisable). Tous les WOFF du reseau
// sont multiples de 32.

`timescale 1ns / 1ps

module param_rom_wide #(
    parameter WIDTH   = 8,
    parameter DEPTH   = 70688,
    parameter LANES   = 32,
    parameter MEMFILE = "weights.mem",
    parameter AW      = $clog2(DEPTH)
) (
    input  wire                  clk,
    input  wire [AW-1:0]         raddr,        // aligne sur LANES
    output reg  [LANES*WIDTH-1:0] rdata        // valide 1 cycle apres raddr
);

    localparam integer BANK_AW    = $clog2(LANES);
    localparam integer BANK_DEPTH = (DEPTH + LANES - 1) / LANES;

    reg [WIDTH-1:0] bank [0:LANES-1][0:BANK_DEPTH-1];

    // Lecture du fichier puis redistribution sur les bancs
    reg [WIDTH-1:0] flat [0:DEPTH-1];
    integer i;
    initial begin
        $readmemh(MEMFILE, flat);
        for (i = 0; i < DEPTH; i = i + 1)
            bank[i % LANES][i / LANES] = flat[i];
    end

    wire [AW-1:0] r_word = raddr >> BANK_AW;

    integer b;
    always @(posedge clk)
        for (b = 0; b < LANES; b = b + 1)
            rdata[b*WIDTH +: WIDTH] <= bank[b][r_word[$clog2(BANK_DEPTH)-1:0]];

endmodule
