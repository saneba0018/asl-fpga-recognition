// ROM de parametres Un module pour quatre instances:
//   weights: WIDTH=8, DEPTH=70688, weights.mem (int8, tous layers concatenes)
//   bias: WIDTH=32, DEPTH=152, bias.mem    (int32, channel global 0..151)
//   mult: WIDTH=32, DEPTH=152, mult.mem    (Q31 m[output channel])
//   shift: WIDTH=6, DEPTH=152, shift.mem   (right-shift, 7..12)
// Lecture synchrone 1 cycle comme act_ram.
//
// MEMFILE est un nom de fichier nu, sans repertoire : les .mem sont ajoutes
// au projet Vivado comme design sources, et $readmemh les resout alors par
// leur nom. Un prefixe "mem/" ferait echouer la synthese (CRITICAL WARNING
// Synth 8-4445) et les ROM seraient silencieusement optimisees a zero.
// En simulation en ligne de commande, lancer depuis le repertoire mem/.

module param_rom #(
    parameter WIDTH   = 8,
    parameter DEPTH   = 70688,
    parameter MEMFILE = "weights.mem",
    parameter AW      = $clog2(DEPTH)
) (
    input  wire             clk,
    input  wire [   AW-1:0] raddr,
    output reg  [WIDTH-1:0] rdata   // valide 1 cycle apres raddr
);

    reg [WIDTH-1:0] mem[0:DEPTH-1];

    initial $readmemh(MEMFILE, mem);

    always @(posedge clk) rdata <= mem[raddr];

endmodule
