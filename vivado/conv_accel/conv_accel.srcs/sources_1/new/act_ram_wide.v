// act_ram_wide - RAM d'activations a lecture large, construite en LANES bancs.
// mac_array veut LANES octets/cycle mais les engines n'en ecrivent qu'un a la
// fois. Le layout canal-en-dernier place les C canaux d'un pixel a des
// adresses consecutives, donc repartir les octets sur LANES bancs par
// addr[4:0] (banc = addr[4:0], index = addr>>5) met les LANES canaux d'un
// pixel dans LANES bancs differents au meme index -- une lecture large
// recupere tout en un cycle, une ecriture n'active qu'un banc. rdata_byte
// reutilise la meme lecture (mux par raddr[4:0]) pour conv1 (C_IN=1). Les
// lectures larges exigent raddr aligne sur LANES et DEPTH multiple de LANES
// (5408=169*32, 21632=676*32) -- vrai pour toutes les couches larges du
// reseau (C_IN = 32/1600/32).

`timescale 1ns / 1ps

module act_ram_wide #(
    parameter DEPTH = 21632,             // profondeur en OCTETS
    parameter LANES = 32,
    parameter AW    = $clog2(DEPTH)
) (
    input  wire                clk,

    // ecriture : un octet par cycle (sortie des engines / chargement SPI)
    input  wire                we,
    input  wire [AW-1:0]       waddr,
    input  wire [7:0]          wdata,

    // lecture : LANES octets contigus a partir de raddr (aligne sur LANES)
    input  wire [AW-1:0]       raddr,
    output wire [LANES*8-1:0]  rdata,

    // meme lecture, vue comme un seul octet a raddr (conv1)
    output wire [7:0]          rdata_byte
);

    localparam integer BANK_AW = $clog2(LANES);          // 5 pour 32 bancs
    localparam integer BANK_DEPTH = DEPTH / LANES;

    wire [BANK_AW-1:0] w_bank = waddr[BANK_AW-1:0];
    wire [AW-1:0]      w_word = waddr >> BANK_AW;
    wire [AW-1:0]      r_word = raddr >> BANK_AW;

    genvar b;
    generate
        for (b = 0; b < LANES; b = b + 1) begin : g_bank
            act_ram #(.DEPTH(BANK_DEPTH)) u_bank (
                .clk  (clk),
                .we   (we && (w_bank == b[BANK_AW-1:0])),
                .waddr(w_word[$clog2(BANK_DEPTH)-1:0]),
                .wdata(wdata),
                .raddr(r_word[$clog2(BANK_DEPTH)-1:0]),
                .rdata(rdata[b*8 +: 8])
            );
        end
    endgenerate

    // Selection de banc pour la lecture octet. raddr est retarde d'un cycle
    // pour accompagner la donnee (lecture synchrone, comme act_ram).
    reg [BANK_AW-1:0] r_bank_q;
    always @(posedge clk) r_bank_q <= raddr[BANK_AW-1:0];

    assign rdata_byte = rdata[r_bank_q*8 +: 8];

endmodule
