//-----------------------------------------------------------------------------
// top.v - top-level de l'accelerateur ASL sur Cmod A7-35T
//
// Remplace top_mock.v une fois layer_ctrl.v disponible. Le lien SPI est
// identique, donc le firmware ESP32 fonctionne sans modification.
//
// CE QUI CHANGE PAR RAPPORT AU MOCK
//   - horloge systeme portee a 100 MHz par un MMCM (Clocking Wizard)
//   - act_ram en ping-pong reelle, arbitree entre le SPI et layer_ctrl
//   - quatre param_rom initialisees par $readmemh
//   - result_buf ecrit par layer_ctrl au lieu d'un motif de test
//   - le cycle busy provient de l'inference reelle
//
// PREREQUIS
//   1. Generer le MMCM : IP Catalog -> Clocking Wizard -> clk_wiz_0
//      entree 12 MHz sur sysclk, sortie 100 MHz sur clk_out1, locked actif.
//   2. Ajouter les quatre fichiers .mem au projet en tant que sources.
//   3. Fournir layer_ctrl.v (deja au depot).
//
// Pour synthetiser sans MMCM, definir NO_MMCM dans les options Verilog :
// Settings -> Synthesis -> Verilog options -> Defines -> NO_MMCM
// L'horloge systeme reste a 12 MHz et l'inference dure ~206 ms.
//
// LEDs
//   led   (rouge) : allume pendant busy
//   led_g (vert)  : battement de coeur
//   led_b (bleu)  : allume quand l'horloge est verrouillee
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

module top (
    input  wire sysclk,     // L17, oscillateur integre 12 MHz

    // SPI vers ESP32-S3, connecteur Pmod JA
    input  wire spi_sck,    // JA1  G17
    input  wire spi_mosi,   // JA2  G19
    output wire spi_miso,   // JA3  N18
    input  wire spi_cs_n,   // JA4  L18

    // Ligne de statut dediee
    output wire o_ready,    // JA10 K18

    // LED RGB
    output wire led,        // C17 rouge
    output wire led_g,      // B16 vert
    output wire led_b       // B17 bleu
);

    // cnn_params.vh declare ses localparam a portee de fichier : l'include
    // doit donc etre place a l'interieur du module.
    `include "cnn_params.vh"

    // Largeurs d'adresse deduites des profondeurs
    localparam integer RAM_A_DEPTH = 5408;
    localparam integer RAM_B_DEPTH = 21632;
    localparam integer AW_A        = 13;      // $clog2(5408)
    localparam integer AW_B        = 15;      // $clog2(21632)
    localparam integer AW_W        = 17;      // $clog2(70688)
    localparam integer AW_C        = 8;       // $clog2(152)

    //-------------------------------------------------------------------------
    // Horloge systeme
    //-------------------------------------------------------------------------
    wire clk;
    wire locked;

`ifdef NO_MMCM
    assign clk    = sysclk;
    assign locked = 1'b1;
`else
    clk_wiz_0 u_clk (
        .clk_in1  (sysclk),
        .clk_out1 (clk),
        .locked   (locked)
    );
`endif

    //-------------------------------------------------------------------------
    // Reset synchrone
    //-------------------------------------------------------------------------
    reg [7:0] por_cnt = 8'd0;
    reg       rst     = 1'b1;

    always @(posedge clk) begin
        if (!locked) begin
            por_cnt <= 8'd0;
            rst     <= 1'b1;
        end else if (por_cnt != 8'hFF) begin
            por_cnt <= por_cnt + 1'b1;
            rst     <= 1'b1;
        end else begin
            rst <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Moteur SPI
    //-------------------------------------------------------------------------
    wire       rx_dv;
    wire [7:0] rx_byte;
    wire       tx_dv;
    wire [7:0] tx_byte;
    wire       miso_int;

    assign spi_miso = spi_cs_n ? 1'bz : miso_int;

    SPI_Slave #(.SPI_MODE(0)) u_spi (
        .i_Rst_L    (~rst),
        .i_Clk      (clk),
        .o_RX_DV    (rx_dv),
        .o_RX_Byte  (rx_byte),
        .i_TX_DV    (tx_dv),
        .i_TX_Byte  (tx_byte),
        .i_SPI_Clk  (spi_sck),
        .o_SPI_MISO (miso_int),
        .i_SPI_MOSI (spi_mosi),
        .i_SPI_CS_n (spi_cs_n)
    );

    //-------------------------------------------------------------------------
    // Decodeur de commandes
    //-------------------------------------------------------------------------
    wire       img_wr_en;
    wire [9:0] img_wr_addr;
    wire [7:0] img_wr_data;
    wire       start;
    wire [4:0] result_rd_addr;
    wire [7:0] result_rd_data;

    wire       busy;
    wire       done;

    spi_cmd_decoder u_decoder (
        .clk            (clk),
        .rst            (rst),
        .rx_dv          (rx_dv),
        .rx_byte        (rx_byte),
        .cs_n           (spi_cs_n),
        .tx_dv          (tx_dv),
        .tx_byte        (tx_byte),
        .img_wr_en      (img_wr_en),
        .img_wr_addr    (img_wr_addr),
        .img_wr_data    (img_wr_data),
        .start          (start),
        .busy           (busy),
        .done           (done),
        .result_rd_addr (result_rd_addr),
        .result_rd_data (result_rd_data),
        .o_ready        (o_ready)
    );

    //-------------------------------------------------------------------------
    // Arbitrage de ram_a : SPI si repos, layer_ctrl si busy
    //-------------------------------------------------------------------------
    wire            lc_a_we;
    wire [AW_A-1:0] lc_a_waddr;
    wire [7:0]      lc_a_wdata;
    wire [AW_A-1:0] lc_a_raddr;
    wire [7:0]      a_rdata;

    wire            a_we    = busy ? lc_a_we    : img_wr_en;
    wire [AW_A-1:0] a_waddr = busy ? lc_a_waddr : {{(AW_A-10){1'b0}}, img_wr_addr};
    wire [7:0]      a_wdata = busy ? lc_a_wdata : img_wr_data;
    wire [AW_A-1:0] a_raddr = lc_a_raddr;

    act_ram #(.DEPTH(RAM_A_DEPTH)) u_ram_a (
        .clk   (clk),
        .we    (a_we),
        .waddr (a_waddr),
        .wdata (a_wdata),
        .raddr (a_raddr),
        .rdata (a_rdata)
    );

    //-------------------------------------------------------------------------
    // ram_b : accedee uniquement par layer_ctrl
    //-------------------------------------------------------------------------
    wire            b_we;
    wire [AW_B-1:0] b_waddr;
    wire [7:0]      b_wdata;
    wire [AW_B-1:0] b_raddr;
    wire [7:0]      b_rdata;

    act_ram #(.DEPTH(RAM_B_DEPTH)) u_ram_b (
        .clk   (clk),
        .we    (b_we),
        .waddr (b_waddr),
        .wdata (b_wdata),
        .raddr (b_raddr),
        .rdata (b_rdata)
    );

    //-------------------------------------------------------------------------
    // Memoires de parametres, initialisees par $readmemh
    //-------------------------------------------------------------------------
    wire [AW_W-1:0] w_addr;
    wire [7:0]      w_data;
    wire [AW_C-1:0] param_addr;
    wire [31:0]     bias_data;
    wire [31:0]     mult_data;
    wire [5:0]      shift_data;

    param_rom #(
        .WIDTH   (8),
        .DEPTH   (WEIGHT_NUM),
        .MEMFILE ("C:/FPGA/asl-felix/vivado/conv_accel/mem/weights.mem")
    ) u_rom_w (
        .clk   (clk),
        .raddr (w_addr),
        .rdata (w_data)
    );

    param_rom #(
        .WIDTH   (32),
        .DEPTH   (CHANNEL_NUM),
        .MEMFILE ("C:/FPGA/asl-felix/vivado/conv_accel/mem/bias.mem")
    ) u_rom_bias (
        .clk   (clk),
        .raddr (param_addr),
        .rdata (bias_data)
    );

    param_rom #(
        .WIDTH   (32),
        .DEPTH   (CHANNEL_NUM),
        .MEMFILE ("C:/FPGA/asl-felix/vivado/conv_accel/mem/mult.mem")
    ) u_rom_mult (
        .clk   (clk),
        .raddr (param_addr),
        .rdata (mult_data)
    );

    param_rom #(
        .WIDTH   (6),
        .DEPTH   (CHANNEL_NUM),
        .MEMFILE ("C:/FPGA/asl-felix/vivado/conv_accel/mem/shift.mem")
    ) u_rom_shift (
        .clk   (clk),
        .raddr (param_addr),
        .rdata (shift_data)
    );

    //-------------------------------------------------------------------------
    // result_buf : 24 logits, lecture COMBINATOIRE obligatoire
    //-------------------------------------------------------------------------
    wire       res_we;
    wire [4:0] res_waddr;
    wire [7:0] res_wdata;

    reg [7:0] result_buf [0:23];

    always @(posedge clk) begin
        if (res_we) result_buf[res_waddr] <= res_wdata;
    end

    assign result_rd_data = result_buf[result_rd_addr];

    //-------------------------------------------------------------------------
    // Orchestration
    //-------------------------------------------------------------------------
    layer_ctrl u_layer_ctrl (
        .clk        (clk),
        .rst        (rst),

        .start      (start),
        .busy       (busy),
        .done       (done),

        .a_we       (lc_a_we),
        .a_waddr    (lc_a_waddr),
        .a_wdata    (lc_a_wdata),
        .a_raddr    (lc_a_raddr),
        .a_rdata    (a_rdata),

        .b_we       (b_we),
        .b_waddr    (b_waddr),
        .b_wdata    (b_wdata),
        .b_raddr    (b_raddr),
        .b_rdata    (b_rdata),

        .w_addr     (w_addr),
        .w_data     (w_data),
        .param_addr (param_addr),
        .bias_data  (bias_data),
        .mult_data  (mult_data),
        .shift_data (shift_data),

        .res_we     (res_we),
        .res_waddr  (res_waddr),
        .res_wdata  (res_wdata)
    );

    //-------------------------------------------------------------------------
    // Diagnostic visuel
    //-------------------------------------------------------------------------
    reg [25:0] hb = 26'd0;
    always @(posedge clk) hb <= hb + 1'b1;

`ifdef NO_MMCM
    assign led_g = hb[22] & o_ready;
`else
    assign led_g = hb[25] & o_ready;
`endif

    assign led   = busy;
    assign led_b = locked;

endmodule