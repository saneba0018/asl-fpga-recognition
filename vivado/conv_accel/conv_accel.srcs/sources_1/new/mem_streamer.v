//-----------------------------------------------------------------------------
// memory_streamer - module TOP de l'accelerateur ASL (Cmod A7-35T)
//
// Reprend la chaine SPI validee par top_mock.v (reset POR, SPI_Slave,
// spi_cmd_decoder, LED de diagnostic) et remplace l'accelerateur simule par
// le sequenceur d'inference reel : FSM + generation d'adresses enchainant
// conv1 -> pool1 -> conv2 -> pool2 -> dense1 -> dense2 sur un seul
// conv_engine + pool_engine (ping-pong ram_a / ram_b).
//
// Les broches sont identiques a celles de top_mock : top_mock.xdc s'applique
// sans modification. Un seul des deux modules peut etre top a la fois dans le
// projet Vivado (Set as Top).
//
// PROTOCOLE
//   !busy : le SPI charge l'image (784 octets, camera XOR 0x80) dans
//           ram_a[0..783] via img_wr_* ; le decodeur bloque deja SEND_IMAGE
//           pendant busy
//   start : pulse -> inference (~2,5M cycles, soit ~209 ms a 12 MHz)
//   done  : IMPULSION d'un cycle ; les logits int8 sont lisibles ensuite
//
// 1 terme MAC par cycle. Les lectures RAM/ROM sont synchrones (1 cycle),
// d'ou les drapeaux retardes q_* qui s'alignent sur les donnees.
//
// PING-PONG : la couche paire lit ram_a et ecrit ram_b, l'impaire l'inverse.
//   conv1  ram_a(image 784) -> ram_b(21632)
//   pool1  ram_b            -> ram_a(5408)
//   conv2  ram_a            -> ram_b(7744)
//   pool2  ram_b            -> ram_a(1600)
//   dense1 ram_a            -> ram_b(32)
//   dense2 ram_b            -> ram_a(24 logits)
//
// DEUX CONVENTIONS IMPOSEES PAR LE DECODEUR
//
//   1. done. Le decodeur fait "if (done) done_latch <= 1;" en dehors de sa
//      machine a etats. Un niveau maintenu, comme celui de la version de
//      reference (git/), reecraserait le drapeau juste apres son effacement
//      par START_CONV ou READ_RESULT, et GET_STATUS renverrait done=1 en
//      permanence. done doit rester une impulsion d'un seul cycle.
//
//   2. result_rd_data. Le decodeur presente result_rd_addr et attend la
//      donnee au MEME cycle (lecture combinatoire, cf. preload_res). La
//      version de reference sort les logits directement de act_ram, dont la
//      lecture est SYNCHRONE : tous les logits seraient decales d'un rang.
//      D'ou le buffer combinatoire logit_buf, recopie en fin d'inference.
//
// DIAGNOSTIC VISUEL
//   led   (rouge) : allume pendant busy
//   led_g (vert)  : battement de coeur ~1,4 Hz, ET-e avec o_ready
//   led_b (bleu)  : inutilise
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

module memory_streamer (
    input  wire sysclk,    // L17, oscillateur integre 12 MHz

    // SPI vers ESP32-S3, connecteur Pmod JA
    input  wire spi_sck,   // JA1  G17
    input  wire spi_mosi,  // JA2  G19
    output wire spi_miso,  // JA3  N18
    input  wire spi_cs_n,  // JA4  L18

    // Ligne de statut dediee
    output wire o_ready,   // JA10 K18

    // LED RGB de diagnostic
    output wire led,       // C17 rouge
    output wire led_g,     // B16 vert
    output wire led_b      // B17 bleu
);

    `include "cnn_params.vh"

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

    // Decodeur de commandes
    wire       img_wr_en;
    wire [9:0] img_wr_addr;  // 0..783
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


    // Buffer de logits : lecture combinatoire 
    // Rempli pendant dense2, voir la FSM
    reg [7:0] logit_buf[0:23];

    always @(*) result_rd_data = logit_buf[result_rd_addr];

    // Etats de la FSM globale
    //
    //   S_IDLE  : au repos, l'image peut etre chargee par le SPI (!busy)
    //   S_RUN   : un terme MAC emis par cycle pour la couche courante
    //   S_FLUSH : draine le pipeline avant de passer a la couche suivante
    //             (evite les hazards lecture-apres-ecriture entre couches)

    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_FLUSH = 2'd2;

    // Couches enchainees dans cet ordre par une seule paire d'engines
    localparam [2:0] L_CONV1 = 3'd0, L_POOL1 = 3'd1, L_CONV2 = 3'd2;
    localparam [2:0] L_POOL2 = 3'd3, L_DENSE1 = 3'd4, L_DENSE2 = 3'd5;

    // Point d'arret de l'inference. Le baisser (p.ex. a L_CONV1) permet
    // d'isoler une couche pendant le debug : busy retombe des qu'elle est
    // terminee et son resultat reste dans sa RAM destination.
    localparam [2:0] LAST_LAYER = L_DENSE2;

    reg [1:0] state;
    reg [2:0] layer;

    // Couche impaire : lit ram_b et ecrit ram_a ; paire : l'inverse.
    // conv1 (couche 0) lit donc ram_a (l'image) et ecrit ram_b.
    wire lay_src_b = layer[0];

    //-------------------------------------------------------------------------
    // Constantes de la couche courante (mux combinatoire sur layer)
    //
    // Les defauts sont ceux de conv1 ; chaque couche suivante surchargera
    // dans le case ce qui lui est propre.
    //-------------------------------------------------------------------------
    reg               lay_is_pool;
    reg        [ 4:0] lay_hout;  // H_OUT
    reg        [ 4:0] lay_wout;  // W_OUT
    reg        [ 6:0] lay_cout;  // C_OUT (pool: C)
    reg        [ 4:0] lay_win;  // W_IN
    reg        [10:0] lay_cin;  // C_IN  (pool: C; dense: longueur aplatie)
    reg        [ 1:0] k_max;  // K-1 (conv 3x3: 2, pool 2x2: 1, dense: 0)
    reg        [10:0] in_chan_max;  // C_IN-1 (pool: 0, le canal est itere par out_chan)
    reg        [16:0] lay_woff;  // offset ROM poids
    reg        [ 7:0] lay_ocbase;  // offset ROMs bias/mult/shift
    reg signed [ 7:0] lay_zp_in;
    reg signed [ 7:0] lay_zp_out;
    reg signed [ 7:0] lay_clamp_min;
    reg        [14:0] lay_nelems;  // nb d'elements de sortie de la couche

    always @(*) begin
        // defauts = conv1
        lay_is_pool   = 1'b0;
        lay_hout      = CONV1_H_OUT;
        lay_wout      = CONV1_W_OUT;
        lay_cout      = CONV1_C_OUT;
        lay_win       = CONV1_W_IN;
        lay_cin       = CONV1_C_IN;
        k_max         = CONV1_K - 1;
        in_chan_max   = CONV1_C_IN - 1;
        lay_woff      = CONV1_WOFF;
        lay_ocbase    = CONV1_OC_BASE;
        lay_zp_in     = CONV1_ZP_IN;
        lay_zp_out    = CONV1_ZP_OUT;
        lay_clamp_min = CONV1_CLAMP_MIN;
        lay_nelems    = CONV1_H_OUT * CONV1_W_OUT * CONV1_C_OUT;
        case (layer)
            // Pool : pas de poids ni de requant, le canal est itere par
            // out_chan (in_chan_max = 0) et la fenetre fait 2x2 (k_max = 1).
            // Les champs woff / ocbase / zp / clamp ne sont pas lus.
            L_POOL1: begin
                lay_is_pool = 1'b1;
                lay_hout    = POOL1_H_OUT;
                lay_wout    = POOL1_W_OUT;
                lay_cout    = POOL1_C;
                lay_win     = POOL1_W_IN;
                lay_cin     = POOL1_C;
                k_max       = 2'd1;
                in_chan_max = 11'd0;
                lay_nelems  = POOL1_H_OUT * POOL1_W_OUT * POOL1_C;
            end
            L_CONV2: begin
                lay_hout      = CONV2_H_OUT;
                lay_wout      = CONV2_W_OUT;
                lay_cout      = CONV2_C_OUT;
                lay_win       = CONV2_W_IN;
                lay_cin       = CONV2_C_IN;
                k_max         = CONV2_K - 1;
                in_chan_max   = CONV2_C_IN - 1;
                lay_woff      = CONV2_WOFF;
                lay_ocbase    = CONV2_OC_BASE;
                lay_zp_in     = CONV2_ZP_IN;
                lay_zp_out    = CONV2_ZP_OUT;
                lay_clamp_min = CONV2_CLAMP_MIN;
                lay_nelems    = CONV2_H_OUT * CONV2_W_OUT * CONV2_C_OUT;
            end
            L_POOL2: begin
                lay_is_pool = 1'b1;
                lay_hout    = POOL2_H_OUT;
                lay_wout    = POOL2_W_OUT;
                lay_cout    = POOL2_C;
                lay_win     = POOL2_W_IN;
                lay_cin     = POOL2_C;
                k_max       = 2'd1;
                in_chan_max = 11'd0;
                lay_nelems  = POOL2_H_OUT * POOL2_W_OUT * POOL2_C;
            end
            // Dense : traite comme une conv 1x1 sur un tensor 1x1. C_IN est
            // la longueur aplatie, donc act_addr se reduit a in_chan et
            // parcourt lineairement la sortie de la couche precedente.
            L_DENSE1: begin
                lay_hout      = 5'd1;
                lay_wout      = 5'd1;
                lay_cout      = DENSE1_C_OUT;
                lay_win       = 5'd1;
                lay_cin       = DENSE1_C_IN;
                k_max         = 2'd0;
                in_chan_max   = DENSE1_C_IN - 1;
                lay_woff      = DENSE1_WOFF;
                lay_ocbase    = DENSE1_OC_BASE;
                lay_zp_in     = DENSE1_ZP_IN;
                lay_zp_out    = DENSE1_ZP_OUT;
                lay_clamp_min = DENSE1_CLAMP_MIN;
                lay_nelems    = DENSE1_C_OUT;
            end
            L_DENSE2: begin
                lay_hout      = 5'd1;
                lay_wout      = 5'd1;
                lay_cout      = DENSE2_C_OUT;
                lay_win       = 5'd1;
                lay_cin       = DENSE2_C_IN;
                k_max         = 2'd0;
                in_chan_max   = DENSE2_C_IN - 1;
                lay_woff      = DENSE2_WOFF;
                lay_ocbase    = DENSE2_OC_BASE;
                lay_zp_in     = DENSE2_ZP_IN;
                lay_zp_out    = DENSE2_ZP_OUT;
                lay_clamp_min = DENSE2_CLAMP_MIN;  // -128 : logits bruts, pas de ReLU
                lay_nelems    = DENSE2_C_OUT;
            end
            default: ;  // L_CONV1 : defauts
        endcase
    end

    //-------------------------------------------------------------------------
    // Compteurs : element de sortie x terme de la somme
    //
    //   out_row, out_col  position dans le tensor de sortie
    //   out_chan          canal de sortie (filtre courant)
    //   k_row, k_col      position dans le noyau
    //   in_chan           canal d'entree
    //
    // out_chan et in_chan sont les boucles internes : les ecritures sortent
    // en HWC sequentiel et les termes dans l'ordre du layout des poids TFLite
    // [out_chan][k_row][k_col][in_chan], ce qui rend l'adresse ROM purement
    // incrementale.
    //-------------------------------------------------------------------------
    reg [ 4:0] out_row, out_col;
    reg [ 6:0] out_chan;
    reg [ 1:0] k_row, k_col;
    reg [10:0] in_chan;

    wire term_first = (k_row == 2'd0) && (k_col == 2'd0) && (in_chan == 11'd0);
    wire term_last  = (k_row == k_max) && (k_col == k_max)
                      && (in_chan == in_chan_max);
    wire elem_last  = (out_row == lay_hout - 5'd1) && (out_col == lay_wout - 5'd1)
                      && (out_chan == lay_cout - 7'd1);

    //-------------------------------------------------------------------------
    // Adresse activation : (row*W_IN + col)*C_IN + chan
    //   conv/dense : row = out_row+k_row,   col = out_col+k_col,   chan = in_chan
    //   pool       : row = 2*out_row+k_row, col = 2*out_col+k_col, chan = out_chan
    //
    // Pour conv1 : C_IN = 1 et W_IN = 28, donc
    //   act_addr = (out_row+k_row)*28 + out_col+k_col
    // soit exactement l'index d'ecriture SPI de l'image.
    //-------------------------------------------------------------------------
    reg [ 4:0] act_row, act_col;
    reg [10:0] act_chan;

    always @(*) begin
        if (lay_is_pool) begin
            act_row  = (out_row << 1) + k_row;
            act_col  = (out_col << 1) + k_col;
            act_chan = out_chan;
        end else begin
            act_row  = out_row + k_row;
            act_col  = out_col + k_col;
            act_chan = in_chan;
        end
    end

    wire [14:0] act_pix = act_row * lay_win + act_col;
    wire [14:0] act_addr = act_pix * lay_cin + act_chan;

    // Adresse poids (dense : K = 1) :
    //   WOFF + ((out_chan*K + k_row)*K + k_col)*C_IN + in_chan
    wire [ 2:0] k_dim = k_max + 2'd1;
    wire [16:0] w_addr = lay_woff
                         + ((out_chan * k_dim + k_row) * k_dim + k_col) * lay_cin
                         + in_chan;

    // Adresse bias/mult/shift : index de canal global (0..151)
    wire [7:0] chan_addr = lay_ocbase + out_chan;

    //-------------------------------------------------------------------------
    // Drapeaux retardes d'un cycle : les lectures RAM/ROM etant synchrones,
    // la donnee arrive un cycle apres l'adresse qui l'a demandee.
    //-------------------------------------------------------------------------
    reg q_valid, q_first, q_last;

    always @(posedge sysclk or posedge rst) begin
        if (rst) begin
            q_valid <= 1'b0;
            q_first <= 1'b0;
            q_last  <= 1'b0;
        end else begin
            q_valid <= (state == S_RUN);
            q_first <= term_first;
            q_last  <= term_last;
        end
    end

    // Routage du stream vers l'engine de la couche : un seul des deux voit
    // les termes a la fois
    wire c_valid = q_valid && !lay_is_pool;
    wire p_valid = q_valid && lay_is_pool;

    //-------------------------------------------------------------------------
    // Resultats -> RAM destination. L'engine emet dans l'ordre HWC, l'adresse
    // d'ecriture est donc un simple compteur.
    //-------------------------------------------------------------------------
    wire              c_rvalid;
    wire signed [7:0] c_rdata;
    wire              p_rvalid;
    wire signed [7:0] p_rdata;

    reg       wr_we;
    reg [7:0] wr_data;

    always @(*) begin
        if (lay_is_pool) begin
            wr_we   = p_rvalid;
            wr_data = p_rdata;
        end else begin
            wr_we   = c_rvalid;
            wr_data = c_rdata;
        end
    end

    reg [14:0] wr_index;

    // FSM top + avance des compteurs
    always @(posedge sysclk or posedge rst) begin
        if (rst) begin
            state    <= S_IDLE;
            layer    <= L_CONV1;
            busy     <= 1'b0;
            done     <= 1'b0;
            out_row  <= 5'd0;
            out_col  <= 5'd0;
            out_chan <= 7'd0;
            k_row    <= 2'd0;
            k_col    <= 2'd0;
            in_chan  <= 11'd0;
            wr_index <= 15'd0;
        end else begin
            done <= 1'b0;  // impulsion par defaut

            if (wr_we) wr_index <= wr_index + 15'd1;

            // Capture des logits au vol. dense2 emet ses 24 sorties dans
            // l'ordre, wr_index en est donc l'index. Les prendre ici evite de
            // relire ram_a, dont la lecture synchrone est incompatible avec
            // le decodeur (cf. en-tete).
            if (busy && wr_we && (layer == L_DENSE2) && (wr_index < 15'd24))
                logit_buf[wr_index[4:0]] <= wr_data;

            case (state)

                // Attente de start ; l'image se charge dans ram_a pendant ce
                // temps via img_wr_* (le decodeur bloque SEND_IMAGE si busy)
                S_IDLE: begin
                    if (start) begin
                        busy     <= 1'b1;
                        layer    <= L_CONV1;
                        out_row  <= 5'd0;
                        out_col  <= 5'd0;
                        out_chan <= 7'd0;
                        k_row    <= 2'd0;
                        k_col    <= 2'd0;
                        in_chan  <= 11'd0;
                        wr_index <= 15'd0;
                        state    <= S_RUN;
                    end
                end

                // Un terme emis par cycle : in_chan, puis k_col, k_row, puis l'element
                // suivant (out_chan, out_col, out_row)
                S_RUN: begin
                    if (term_last) begin
                        k_row <= 2'd0;
                        k_col <= 2'd0;
                        in_chan <= 11'd0;
                        if (elem_last) begin
                            state <= S_FLUSH;
                        end else if (out_chan == lay_cout - 7'd1) begin
                            out_chan <= 7'd0;
                            if (out_col == lay_wout - 5'd1) begin
                                out_col <= 5'd0;
                                out_row <= out_row + 5'd1;
                            end else begin
                                out_col <= out_col + 5'd1;
                            end
                        end else begin
                            out_chan <= out_chan + 7'd1;
                        end
                    end else if (in_chan == in_chan_max) begin
                        in_chan <= 11'd0;
                        if (k_col == k_max) begin
                            k_col <= 2'd0;
                            k_row <= k_row + 2'd1;
                        end else begin
                            k_col <= k_col + 2'd1;
                        end
                    end else begin
                        in_chan <= in_chan + 11'd1;
                    end
                end

                // Attente de l'ecriture du dernier resultat de la couche
                S_FLUSH: begin
                    if (wr_index == lay_nelems) begin
                        if (layer == LAST_LAYER) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;  // impulsion d'un cycle, cf. en-tete
                            state <= S_IDLE;
                        end else begin
                            layer  <= layer + 3'd1;
                            out_row     <= 5'd0;
                            out_col     <= 5'd0;
                            out_chan     <= 7'd0;
                            k_row     <= 2'd0;
                            k_col     <= 2'd0;
                            in_chan     <= 11'd0;
                            wr_index <= 15'd0;
                            state  <= S_RUN;
                        end
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Ports de ram_a : partagee entre le chargement de l'image (hors
    // inference), la lecture des activations et l'ecriture des resultats des
    // couches impaires.
    //
    // L'image arrive deja en int8 : l'ESP32 applique le XOR 0x80 sur l'octet
    // camera avant l'envoi, rien a convertir ici. L'ordre d'ecriture SPI
    // (0..783) coincide avec le layout HWC de conv1, aucune translation
    // d'adresse n'est necessaire.
    //-------------------------------------------------------------------------
    localparam integer RAMA_DEPTH = POOL1_H_OUT * POOL1_W_OUT * POOL1_C;  // 5408
    localparam integer RAMB_DEPTH = CONV1_H_OUT * CONV1_W_OUT * CONV1_C_OUT;  // 21632

    wire [7:0] a_rdata, b_rdata;

    reg        a_we;
    reg [12:0] a_waddr;
    reg [ 7:0] a_wdata;
    reg [12:0] a_raddr;

    always @(*) begin
        if (busy) begin
            a_we    = wr_we && lay_src_b;  // source = b -> destination = a
            a_waddr = wr_index[12:0];
            a_wdata = wr_data;
        end else begin
            a_we    = img_wr_en;
            a_waddr = {3'd0, img_wr_addr};
            a_wdata = img_wr_data;
        end
    end

    // Hors inference ram_a n'est pas lue : les logits sont captures au vol
    // dans logit_buf, pas relus ici.
    always @(*) begin
        if (busy) a_raddr = act_addr[12:0];
        else a_raddr = 13'd0;
    end

    wire b_we = busy && wr_we && !lay_src_b;

    // Activation presentee a l'engine, un cycle apres act_addr
    reg [7:0] act_rdata;

    always @(*) begin
        if (lay_src_b) act_rdata = b_rdata;
        else act_rdata = a_rdata;
    end

    //-------------------------------------------------------------------------
    // Memoires
    //-------------------------------------------------------------------------
    act_ram #(
        .DEPTH(RAMA_DEPTH)
    ) u_ram_a (
        .clk  (sysclk),
        .we   (a_we),
        .waddr(a_waddr),
        .wdata(a_wdata),
        .raddr(a_raddr),
        .rdata(a_rdata)
    );

    act_ram #(
        .DEPTH(RAMB_DEPTH)
    ) u_ram_b (
        .clk  (sysclk),
        .we   (b_we),
        .waddr(wr_index),
        .wdata(wr_data),
        .raddr(act_addr),
        .rdata(b_rdata)
    );

    wire [ 7:0] w_rdata;
    wire [31:0] bias_rdata;
    wire [31:0] mult_rdata;
    wire [ 5:0] shift_rdata;

    param_rom #(
        .WIDTH  (8),
        .DEPTH  (WEIGHT_NUM),
        .MEMFILE("weights.mem")
    ) u_rom_w (
        .clk  (sysclk),
        .raddr(w_addr),
        .rdata(w_rdata)
    );

    param_rom #(
        .WIDTH  (32),
        .DEPTH  (CHANNEL_NUM),
        .MEMFILE("bias.mem")
    ) u_rom_bias (
        .clk  (sysclk),
        .raddr(chan_addr),
        .rdata(bias_rdata)
    );

    param_rom #(
        .WIDTH  (32),
        .DEPTH  (CHANNEL_NUM),
        .MEMFILE("mult.mem")
    ) u_rom_mult (
        .clk  (sysclk),
        .raddr(chan_addr),
        .rdata(mult_rdata)
    );

    param_rom #(
        .WIDTH  (6),
        .DEPTH  (CHANNEL_NUM),
        .MEMFILE("shift.mem")
    ) u_rom_shift (
        .clk  (sysclk),
        .raddr(chan_addr),
        .rdata(shift_rdata)
    );

    //-------------------------------------------------------------------------
    // Engines
    //-------------------------------------------------------------------------
    conv_engine u_conv (
        .clk        (sysclk),
        .rst        (rst),
        .s_valid    (c_valid),
        .s_act      (act_rdata),
        .s_w        (w_rdata),
        .s_first    (q_first),
        .s_last     (q_last),
        .s_bias     (bias_rdata),
        .s_mult     (mult_rdata),
        .s_shift    (shift_rdata[4:0]),
        .s_zp_in    (lay_zp_in),
        .s_zp_out   (lay_zp_out),
        .s_clamp_min(lay_clamp_min),
        .r_valid    (c_rvalid),
        .r_data     (c_rdata)
    );

    // Le max-pooling ne requantifie pas : ni bias, ni mult/shift, ni
    // zero-point. Il ne voit que le stream d'activations et ses bornes de
    // fenetre.
    pool_engine u_pool (
        .clk    (sysclk),
        .rst    (rst),
        .s_valid(p_valid),
        .s_act  (act_rdata),
        .s_first(q_first),
        .s_last (q_last),
        .r_valid(p_rvalid),
        .r_data (p_rdata)
    );

    //-------------------------------------------------------------------------
    // Diagnostic visuel
    //
    // Le ET avec o_ready fait que le vert ne clignote que si le decodeur est
    // au repos : preuve que l'horloge tourne ET que la logique est coherente.
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
