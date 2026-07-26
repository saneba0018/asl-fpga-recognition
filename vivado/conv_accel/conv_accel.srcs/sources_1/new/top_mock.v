//-----------------------------------------------------------------------------
// top_mock.v - bitstream factice pour le developpement du firmware ESP32
//
// Contient la chaine SPI reelle (SPI_Slave + spi_cmd_decoder + act_ram) et un
// faux accelerateur. Permet de valider tout le firmware maitre avant que le
// CNN n'existe.
//
// Comportement du faux accelerateur :
//   - START_CONV declenche un busy de ~208 ms (meme ordre de grandeur que le
//     vrai calcul a 12 MHz), puis un pulse done.
//   - READ_RESULT renvoie :
//       * avant toute image   : 0xA0, 0xA1, ... 0xB7  (constantes connues,
//                               identiques a tb_spi_cmd_decoder)
//       * apres un SEND_IMAGE : les 24 premiers pixels de la derniere image
//                               recue -> valide le transfert de bout en bout
//
// Diagnostic visuel (LED RGB) :
//   VERT clignotant ~1,4 Hz  -> oscillateur actif, POR termine, FPGA pret
//   VERT eteint en continu   -> le design ne tourne pas, ou o_ready est bas
//   ROUGE bref (~0,2 s)      -> un START_CONV a ete decode
//
// Brochage : voir top_mock.xdc
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

module top_mock (
    input  wire sysclk,    // 12 MHz, oscillateur de la Cmod A7
    input  wire spi_sck,
    input  wire spi_mosi,
    output wire spi_miso,
    input  wire spi_cs_n,
    output wire o_ready,   // GPIO vers l'ESP32, actif haut
    output wire led,       // rouge - allume pendant busy
    output wire led_g,     // vert  - battement de coeur
    output wire led_b      // bleu  - inutilise
);

    //-------------------------------------------------------------------------
    // Reset a la mise sous tension (pas de bouton necessaire)
    // Les registres FPGA s'initialisent a la configuration, donc por demarre
    // a 0 et rst reste haut pendant 255 cycles.
    //-------------------------------------------------------------------------
    reg [7:0] por = 8'h00;
    reg       rst = 1'b1;

    always @(posedge sysclk) begin
        if (por != 8'hFF) begin
            por <= por + 1'b1;
            rst <= 1'b1;
        end else begin
            rst <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Esclave SPI (coeur Nandland, licence MIT)
    //-------------------------------------------------------------------------
    wire       rx_dv;
    wire [7:0] rx_byte;
    wire       tx_dv;
    wire [7:0] tx_byte;

    SPI_Slave #(
        .SPI_MODE(0)
    ) u_spi (
        .i_Rst_L    (~rst),        // actif bas cote Nandland
        .i_Clk      (sysclk),
        .o_RX_DV    (rx_dv),
        .o_RX_Byte  (rx_byte),
        .i_TX_DV    (tx_dv),
        .i_TX_Byte  (tx_byte),
        .i_SPI_Clk  (spi_sck),
        .o_SPI_MISO (spi_miso),
        .i_SPI_MOSI (spi_mosi),
        .i_SPI_CS_n (spi_cs_n)
    );

    //-------------------------------------------------------------------------
    // Decodeur de commandes (le vrai, celui du projet)
    //-------------------------------------------------------------------------
    wire       img_wr_en;
    wire [9:0] img_wr_addr;
    wire [7:0] img_wr_data;
    wire       start;
    wire [4:0] result_rd_addr;

    reg  [7:0] result_rd_data;
    reg        busy;
    reg        done;

    spi_cmd_decoder u_dec (
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
    // Memoire d'activation : l'image atterrit vraiment quelque part
    // DEPTH = 1024 pour que AW = 10 corresponde a img_wr_addr[9:0]
    //-------------------------------------------------------------------------
    wire [7:0] act_rdata_unused;

    act_ram #(
        .DEPTH(1024)
    ) u_act (
        .clk   (sysclk),
        .we    (img_wr_en),
        .waddr (img_wr_addr),
        .wdata (img_wr_data),
        .raddr (10'd0),
        .rdata (act_rdata_unused)
    );

    //-------------------------------------------------------------------------
    // Echo des 24 premiers pixels
    // Permet de verifier que SEND_IMAGE a reellement transfere les bons
    // octets, en les relisant via READ_RESULT.
    //-------------------------------------------------------------------------
    reg [7:0] echo [0:23];
    reg       echo_valid;

    always @(posedge sysclk or posedge rst) begin
        if (rst) begin
            echo_valid <= 1'b0;
        end else begin
            if (img_wr_en && img_wr_addr < 10'd24)
                echo[img_wr_addr[4:0]] <= img_wr_data;

            if (img_wr_en && img_wr_addr == 10'd783)
                echo_valid <= 1'b1;   // image complete recue
        end
    end

    //-------------------------------------------------------------------------
    // Faux buffer de resultat, combinatoire (comme le vrai result_buf le sera)
    //-------------------------------------------------------------------------
    always @(*) begin
        if (echo_valid) result_rd_data = echo[result_rd_addr];
        else            result_rd_data = 8'hA0 + result_rd_addr;
    end

    //-------------------------------------------------------------------------
    // Faux accelerateur : busy pendant ~208 ms, puis pulse done
    // 2 500 000 cycles a 12 MHz = 208 ms, l'ordre de grandeur du vrai calcul
    // (2 476 928 MAC a 1 MAC/cycle).
    //-------------------------------------------------------------------------
    localparam integer BUSY_CYCLES = 2_500_000;

    reg [21:0] cnt;

    always @(posedge sysclk or posedge rst) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            cnt  <= 22'd0;
        end else begin
            done <= 1'b0;                        // pulse d'un cycle par defaut

            if (start) begin
                busy <= 1'b1;
                cnt  <= 22'd0;
            end else if (busy) begin
                if (cnt == BUSY_CYCLES - 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Diagnostic visuel
    //
    // hb[22] bascule toutes les 4 194 304 / 12e6 = 0,35 s
    // -> periode complete 0,70 s, soit un clignotement a ~1,4 Hz.
    //
    // Le ET avec o_ready fait que le vert ne clignote QUE si le decodeur est
    // au repos : c'est une preuve que l'horloge tourne ET que la logique est
    // dans un etat coherent, pas seulement que l'oscillateur bat.
    //
    // NB : la LED RGB de la Cmod A7 est supposee active haute. Si le
    // comportement observe est inverse (vert allume en continu avec de brefs
    // eteints), remplacer par : assign led_g = ~(hb[22] & o_ready);
    //-------------------------------------------------------------------------
    reg [22:0] hb = 23'd0;

    always @(posedge sysclk) hb <= hb + 1'b1;

    assign led   = busy;                // rouge : inference en cours
    assign led_g = hb[22] & o_ready;    // vert  : battement de coeur
    assign led_b = 1'b0;                // bleu  : inutilise

endmodule