// ROM de parametres, un module pour weights/bias/mult/shift (voir mem_streamer
// pour les DEPTH/MEMFILE de chaque instance). Lecture synchrone 1 cycle.
// MEMFILE doit rester un nom nu (sans "mem/") : Vivado resout les .mem par
// nom comme design sources, un prefixe ferait echouer $readmemh en silence.

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

    // bornes explicites : evite l'avertissement quand MEMFILE > DEPTH (voulu
    // pour la petite ROM conv1, qui ne lit que le debut de weights.mem).
    initial $readmemh(MEMFILE, mem, 0, DEPTH - 1);

    always @(posedge clk) rdata <= mem[raddr];

endmodule
