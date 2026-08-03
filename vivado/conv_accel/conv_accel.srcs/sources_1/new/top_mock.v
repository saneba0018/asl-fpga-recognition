//-----------------------------------------------------------------------------
// top_mock.v - bitstream de validation du lien SPI ESP32 <-> Cmod A7
//
// Contient la chaine SPI reelle (SPI_Slave + spi_cmd_decoder) et un
// accelerateur simule. Permet de developper et de valider tout le firmware
// maitre avant que le CNN n'existe.
//
// MOTIFS DE REPONSE
// Les trois premiers octets de l'image envoyee pilotent ce que le FPGA
// renvoie sur READ_RESULT :
//
//   image[0] = motif
//     0x00  echo des 24 premiers octets recus
//     0x01  rampe            logit[i] = i
//     0x02  signature        logit[i] = 0xA0 + i
//     0x03  damier           0x55 / 0xAA alternes
//     0x04  argmax force     tout a 0x00 sauf l'indice image[1] a 0x7F
//     0x05  compteur         logit[i] = nb_inferences + i
//     0x06  constante fixe   logit[i] = CONST_VAL, cablee dans le FPGA
//
//   image[1] = indice gagnant pour le motif 0x04 (0..23)
//   image[2] = 0 -> busy 208 ms ; non nul -> busy 20 ms (boucles rapides)
//
// Les motifs 0x01 a 0x06 sont generes par le FPGA seul : ils ne dependent
// d'aucune donnee envoyee par l'ESP32 et testent donc uniquement le chemin
// de reception cote maitre.
//
//   0x06 est le test le plus depouille : 24 octets identiques, aucune
//        dependance ni aux donnees envoyees ni a l'adresse de lecture.
//   0x02 est le plus informatif : la progression croissante revele
//        immediatement un decalage d'indice.
//   0x03 fait basculer tous les bits d'un octet au suivant, ce qui met en
//        evidence les erreurs de niveau bit qu'une rampe masquerait.
//
// DIAGNOSTIC VISUEL
//   led   (rouge) : allume pendant busy
//   led_g (vert)  : battement de coeur ~1,4 Hz, ET-e avec o_ready
//   led_b (bleu)  : inutilise
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

module top_mock (
    input  wire sysclk,     // L17, oscillateur integre 12 MHz

    // SPI vers ESP32-S3, connecteur Pmod JA
    input  wire spi_sck,    // JA1  G17
    input  wire spi_mosi,   // JA2  G19
    output wire spi_miso,   // JA3  N18
    input  wire spi_cs_n,   // JA4  L18

    // Ligne de statut dediee
    output wire o_ready,    // JA10 K18

    // LED RGB de diagnostic
    output wire led,        // C17 rouge
    output wire led_g,      // B16 vert
    output wire led_b       // B17 bleu
);

    // Valeur renvoyee par le motif 0x06. Cablee ici, jamais transmise par
    // l'ESP32 : le FPGA en est seul responsable.
    localparam [7:0] CONST_VAL = 8'h5A;

    //-------------------------------------------------------------------------
    // Reset a la mise sous tension : 256 cycles
    //-------------------------------------------------------------------------
    reg [7:0] por_cnt = 8'd0;
    reg       rst     = 1'b1;

    always @(posedge sysclk) begin
        if (por_cnt != 8'hFF) begin
            por_cnt <= por_cnt + 1'b1;
            rst     <= 1'b1;
        end else begin
            rst <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Moteur SPI (Nandland, licence MIT, avec les deux correctifs TX)
    //-------------------------------------------------------------------------
    wire       rx_dv;
    wire [7:0] rx_byte;
    wire       tx_dv;
    wire [7:0] tx_byte;
    wire       miso_int;

    // MISO en trois-etats hors transaction. Le PULLUP interne declare au XDC
    // tient la ligne au repos.
    reg spi_miso_mux;

    always @(*) begin
        if (spi_cs_n) spi_miso_mux = 1'bz;
        else spi_miso_mux = miso_int;
    end

    assign spi_miso = spi_miso_mux;

    SPI_Slave #(.SPI_MODE(0)) u_spi (
        .i_Rst_L    (~rst),
        .i_Clk      (sysclk),
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
    reg  [7:0] result_rd_data;

    reg        busy;
    reg        done;

    spi_cmd_decoder u_decoder (
        .clk            (sysclk),
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
    // Capture des octets de controle et des 24 premiers pixels
    //-------------------------------------------------------------------------
    reg [7:0] echo [0:23];
    reg [7:0] pattern;
    reg [7:0] arg_sel;
    reg [7:0] speed;
    reg [7:0] infer_cnt;

    always @(posedge sysclk or posedge rst) begin
        if (rst) begin
            pattern   <= 8'h00;
            arg_sel   <= 8'h00;
            speed     <= 8'h00;
            infer_cnt <= 8'h00;
        end else begin
            if (img_wr_en) begin
                if (img_wr_addr < 10'd24)
                    echo[img_wr_addr[4:0]] <= img_wr_data;
                if (img_wr_addr == 10'd0) pattern <= img_wr_data;
                if (img_wr_addr == 10'd1) arg_sel <= img_wr_data;
                if (img_wr_addr == 10'd2) speed   <= img_wr_data;
            end
            if (done) infer_cnt <= infer_cnt + 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // result_buf : lecture COMBINATOIRE
    //
    // Le decodeur presente result_rd_addr et attend result_rd_data au meme
    // cycle. Une lecture synchrone, comme celle de act_ram, decalerait tous
    // les logits d'un rang. C'est le piege principal de ce bloc.
    //-------------------------------------------------------------------------
    always @(*) begin
        case (pattern)
            8'h01: result_rd_data = {3'b000, result_rd_addr};
            8'h02: result_rd_data = 8'hA0 + {3'b000, result_rd_addr};

            8'h03: begin
                if (result_rd_addr[0]) result_rd_data = 8'hAA;
                else result_rd_data = 8'h55;
            end

            8'h04: begin
                if (result_rd_addr == arg_sel[4:0]) result_rd_data = 8'h7F;
                else result_rd_data = 8'h00;
            end

            8'h05:   result_rd_data = infer_cnt + {3'b000, result_rd_addr};
            8'h06:   result_rd_data = CONST_VAL;
            default: result_rd_data = echo[result_rd_addr];
        endcase
    end

    //-------------------------------------------------------------------------
    // Accelerateur simule
    //
    // done est une IMPULSION d'un cycle, jamais un niveau maintenu. Le
    // decodeur contient "if (done) done_latch <= 1;" avant sa machine a
    // etats : un niveau haut reecraserait le drapeau juste apres son
    // effacement par START_CONV ou READ_RESULT. Le futur layer_ctrl devra
    // respecter la meme convention.
    //-------------------------------------------------------------------------
    localparam [24:0] BUSY_SLOW = 25'd2_500_000;   // 208,3 ms a 12 MHz
    localparam [24:0] BUSY_FAST = 25'd240_000;     //  20,0 ms

    reg [24:0] busy_target;

    always @(*) begin
        if (speed != 8'h00) busy_target = BUSY_FAST;
        else busy_target = BUSY_SLOW;
    end

    reg [24:0] busy_cnt;

    always @(posedge sysclk or posedge rst) begin
        if (rst) begin
            busy     <= 1'b0;
            done     <= 1'b0;
            busy_cnt <= 25'd0;
        end else begin
            done <= 1'b0;                     // impulsion par defaut

            if (start && !busy) begin
                busy     <= 1'b1;
                busy_cnt <= busy_target;
            end else if (busy) begin
                if (busy_cnt == 25'd0) begin
                    busy <= 1'b0;
                    done <= 1'b1;             // impulsion de fin
                end else begin
                    busy_cnt <= busy_cnt - 1'b1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Diagnostic visuel
    //
    // Le ET avec o_ready fait que le vert ne clignote que si le decodeur est
    // au repos : preuve que l'horloge tourne ET que la logique est coherente,
    // pas seulement que l'oscillateur bat.
    //
    // Si le comportement observe est inverse, la LED RGB est active basse :
    // remplacer par ~(hb[22] & o_ready).
    //-------------------------------------------------------------------------
    reg [22:0] hb = 23'd0;

    always @(posedge sysclk) hb <= hb + 1'b1;

    assign led   = busy;
    assign led_g = hb[22] & o_ready;
    assign led_b = 1'b0;

endmodule