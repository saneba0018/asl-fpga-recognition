// memory_streamer - module TOP de l'accelerateur ASL (Cmod A7-35T)
//
// Seul top-level du projet : SPI (reset POR, SPI_Slave, spi_cmd_decoder) +
// FSM d'inference (conv1 -> pool1 -> conv2 -> pool2 -> dense1 -> dense2 sur
// un seul conv_engine + pool_engine, ping-pong ram_a/ram_b). Contraintes:
// cmod_a7_pmod_ja.xdc.
//
// Protocole: !busy charge l'image (784 octets XOR 0x80) dans ram_a via
// img_wr_* ; start pulse -> inference (~294k cycles, ~5,9 ms a 50 MHz) ;
// done pulse 1 cycle puis logits lisibles.
//
// mac_array traite jusqu'a LANES=32 termes/cycle pour conv2/dense1/dense2
// (C_IN multiple de 32) ; conv1 (C_IN=1) reste a 1 terme/cycle.
//
// Ping-pong: conv1 ram_a->ram_b, pool1 ram_b->ram_a, conv2 ram_a->ram_b,
// pool2 ram_b->ram_a, dense1 ram_a->ram_b, dense2 ram_b->ram_a(logits).
//
// Deux contraintes imposees par le decodeur: done doit rester une impulsion
// d'un cycle (pas un niveau, sinon le decodeur relatch juste apres l'avoir
// efface) ; result_rd_data doit etre lu de facon combinatoire (logit_buf),
// pas depuis une RAM synchrone qui decalerait tous les logits d'un rang.
//
// LED: rouge=busy, vert=heartbeat && o_ready, bleu=MMCM locked.

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

    // Largeur du datapath MAC (mac_array + act_ram_wide + param_rom_wide).
    localparam integer LANES = 32;

    // MMCM 12->50 MHz. Le rapport R = f_clk/f_spi doit rester >= 30 (marge
    // au-dessus du seuil R>=10 mesure en simulation) pour que le
    // prechargement MISO gagne sa course contre SPI_Slave et que les logits
    // restent alignes sur MISO_DATA_OFFSET=1 (cf. spi_comm.h). NO_MMCM
    // bypasse le MMCM pour simuler sous iverilog.
`ifdef NO_MMCM
    wire clk    = sysclk;
    wire locked = 1'b1;
`else
    wire clk;
    wire locked;

    clk_wiz_0 u_clk_wiz (
        .clk_out1(clk),
        .locked  (locked),
        .clk_in1 (sysclk)
    );
`endif

    // Reset POR: 256 cycles apres que le MMCM soit verrouille.
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

    // Moteur SPI (Nandland, licence MIT, avec les deux correctifs TX)
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


    // Buffer de logits : lecture combinatoire, rempli pendant dense2 (voir FSM)
    reg [7:0] logit_buf[0:23];

    always @(*) result_rd_data = logit_buf[result_rd_addr];

    // Etats de la FSM: S_IDLE (repos, image chargeable), S_RUN (un terme MAC
    // par cycle pour la couche courante), S_FLUSH (draine le pipeline avant
    // de passer a la couche suivante).
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_FLUSH = 2'd2;

    // Couches enchainees dans cet ordre par une seule paire d'engines
    localparam [2:0] L_CONV1 = 3'd0, L_POOL1 = 3'd1, L_CONV2 = 3'd2;
    localparam [2:0] L_POOL2 = 3'd3, L_DENSE1 = 3'd4, L_DENSE2 = 3'd5;

    // Point d'arret de l'inference, utile pour isoler une couche en debug.
    localparam [2:0] LAST_LAYER = L_DENSE2;

    reg [1:0] state;
    reg [2:0] layer;

    // Couche impaire : lit ram_b et ecrit ram_a ; paire : l'inverse.
    wire lay_src_b = layer[0];

    // Constantes de la couche courante (mux combinatoire sur layer).
    // Defauts = conv1, chaque couche surcharge ce qui lui est propre.
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

    // lay_wide: couche large (mac_array a LANES voies actives) ; lay_in_step:
    // increment de in_chan par cycle (LANES pour les couches larges, 1 sinon).
    reg               lay_wide;
    reg        [10:0] lay_in_step;

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
        lay_wide      = 1'b0;
        lay_in_step   = 11'd1;
        case (layer)
            // Pool : pas de poids ni de requant, canal itere par out_chan.
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
                lay_wide      = 1'b1;
                lay_in_step   = LANES;
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
            // Dense : traite comme une conv 1x1 sur un tensor 1x1.
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
                lay_wide      = 1'b1;
                lay_in_step   = LANES;
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
                lay_wide      = 1'b1;
                lay_in_step   = LANES;
            end
            default: ;  // L_CONV1 : defauts
        endcase
    end

    // Compteurs : element de sortie x terme de la somme. out_chan et in_chan
    // sont les boucles internes, ce qui rend l'adresse ROM purement
    // incrementale (layout TFLite [out_chan][k_row][k_col][in_chan]).
    reg [ 4:0] out_row, out_col;
    reg [ 6:0] out_chan;
    reg [ 1:0] k_row, k_col;
    reg [10:0] in_chan;

    // Derniere valeur de in_chan avant que la salve suivante deborde.
    wire [10:0] in_chan_last = in_chan_max - lay_in_step + 11'd1;

    wire term_first = (k_row == 2'd0) && (k_col == 2'd0) && (in_chan == 11'd0);
    wire term_last  = (k_row == k_max) && (k_col == k_max)
                      && (in_chan == in_chan_last);
    wire elem_last  = (out_row == lay_hout - 5'd1) && (out_col == lay_wout - 5'd1)
                      && (out_chan == lay_cout - 7'd1);

    // Adresse activation : (row*W_IN + col)*C_IN + chan. Pour conv1
    // (C_IN=1) ceci se reduit exactement a l'index d'ecriture SPI de l'image.
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

    // Adresse poids (dense : K=1): WOFF + ((out_chan*K+k_row)*K+k_col)*C_IN + in_chan
    wire [ 2:0] k_dim = k_max + 2'd1;
    wire [16:0] w_addr = lay_woff
                         + ((out_chan * k_dim + k_row) * k_dim + k_col) * lay_cin
                         + in_chan;

    // Adresse bias/mult/shift : index de canal global (0..151)
    wire [7:0] chan_addr = lay_ocbase + out_chan;

    // Drapeaux retardes d'un cycle : les lectures RAM/ROM sont synchrones.
    reg q_valid, q_first, q_last;

    always @(posedge clk or posedge rst) begin
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

    // Resultats -> RAM destination, ecrits en ordre HWC via un simple compteur.
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
    always @(posedge clk or posedge rst) begin
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

            // Capture des logits au vol pendant dense2 (evite de relire
            // ram_a, incompatible avec la lecture combinatoire du decodeur).
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

                // Une salve emise par cycle : in_chan, puis k_col, k_row,
                // puis l'element suivant (out_chan, out_col, out_row)
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
                    end else if (in_chan == in_chan_last) begin
                        in_chan <= 11'd0;
                        if (k_col == k_max) begin
                            k_col <= 2'd0;
                            k_row <= k_row + 2'd1;
                        end else begin
                            k_col <= k_col + 2'd1;
                        end
                    end else begin
                        in_chan <= in_chan + lay_in_step;
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

    // ram_a est partagee entre le chargement de l'image, la lecture des
    // activations et l'ecriture des couches impaires. L'image arrive deja
    // en int8 (XOR 0x80 fait par l'ESP32), aucune conversion ici.
    localparam integer RAMA_DEPTH = POOL1_H_OUT * POOL1_W_OUT * POOL1_C;  // 5408
    localparam integer RAMB_DEPTH = CONV1_H_OUT * CONV1_W_OUT * CONV1_C_OUT;  // 21632

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

    wire [LANES*8-1:0] a_rdata_wide, b_rdata_wide;
    wire [       7:0]  a_rdata_byte, b_rdata_byte;

    // Activation presentee a l'engine : rdata_wide (LANES octets, conv2/
    // dense1/dense2) ou rdata_byte (1 octet, conv1 + pool_engine).
    reg [LANES*8-1:0] act_rdata_wide;
    reg [       7:0]  act_rdata_byte;

    always @(*) begin
        if (lay_src_b) begin
            act_rdata_wide = b_rdata_wide;
            act_rdata_byte = b_rdata_byte;
        end else begin
            act_rdata_wide = a_rdata_wide;
            act_rdata_byte = a_rdata_byte;
        end
    end

    // Memoires
    act_ram_wide #(
        .DEPTH(RAMA_DEPTH),
        .LANES(LANES)
    ) u_ram_a (
        .clk       (clk),
        .we        (a_we),
        .waddr     (a_waddr),
        .wdata     (a_wdata),
        .raddr     (a_raddr),
        .rdata     (a_rdata_wide),
        .rdata_byte(a_rdata_byte)
    );

    act_ram_wide #(
        .DEPTH(RAMB_DEPTH),
        .LANES(LANES)
    ) u_ram_b (
        .clk       (clk),
        .we        (b_we),
        .waddr     (wr_index),
        .wdata     (wr_data),
        .raddr     (act_addr),
        .rdata     (b_rdata_wide),
        .rdata_byte(b_rdata_byte)
    );

    // Poids : ROM large (banquee sur LANES) pour conv2/dense1/dense2, plus
    // une petite ROM scalaire pour conv1 (WOFF=0..287, adresses non alignees
    // sur LANES). $readmemh remplit mem[0..287] depuis le debut de
    // weights.mem, qui est exactement la plage de conv1.
    wire [       7:0]  w_rdata_narrow;
    wire [LANES*8-1:0] w_rdata_wide;
    wire [31:0] bias_rdata;
    wire [31:0] mult_rdata;
    wire [ 5:0] shift_rdata;

    param_rom #(
        .WIDTH  (8),
        .DEPTH  (CONV2_WOFF),  // = 288 : WOFF(conv2), donc exactement la plage de conv1
        .MEMFILE("weights.mem")
    ) u_rom_w_conv1 (
        .clk  (clk),
        .raddr(w_addr[8:0]),
        .rdata(w_rdata_narrow)
    );

    param_rom_wide #(
        .WIDTH  (8),
        .DEPTH  (WEIGHT_NUM),
        .LANES  (LANES),
        .MEMFILE("weights.mem")
    ) u_rom_w_wide (
        .clk  (clk),
        .raddr(w_addr),
        .rdata(w_rdata_wide)
    );

    param_rom #(
        .WIDTH  (32),
        .DEPTH  (CHANNEL_NUM),
        .MEMFILE("bias.mem")
    ) u_rom_bias (
        .clk  (clk),
        .raddr(chan_addr),
        .rdata(bias_rdata)
    );

    param_rom #(
        .WIDTH  (32),
        .DEPTH  (CHANNEL_NUM),
        .MEMFILE("mult.mem")
    ) u_rom_mult (
        .clk  (clk),
        .raddr(chan_addr),
        .rdata(mult_rdata)
    );

    param_rom #(
        .WIDTH  (6),
        .DEPTH  (CHANNEL_NUM),
        .MEMFILE("shift.mem")
    ) u_rom_shift (
        .clk  (clk),
        .raddr(chan_addr),
        .rdata(shift_rdata)
    );

    // Vecteurs presentes a mac_array : lecture large (conv2/dense1/dense2)
    // ou 1 voie active + 31 masquees (conv1). C_IN de ces couches est
    // toujours multiple de LANES, donc jamais de masque partiel a calculer.
    wire [LANES*8-1:0] c_act_vec = lay_wide ? act_rdata_wide
                                             : {{(LANES - 1) * 8{1'b0}}, act_rdata_byte};
    wire [LANES*8-1:0] c_w_vec   = lay_wide ? w_rdata_wide
                                             : {{(LANES - 1) * 8{1'b0}}, w_rdata_narrow};
    wire [  LANES-1:0] c_lane_en = lay_wide ? {LANES{1'b1}}
                                             : {{(LANES - 1){1'b0}}, 1'b1};

    // Engines
    conv_engine #(
        .LANES(LANES)
    ) u_conv (
        .clk        (clk),
        .rst        (rst),
        .s_valid    (c_valid),
        .s_act_vec  (c_act_vec),
        .s_w_vec    (c_w_vec),
        .s_lane_en  (c_lane_en),
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

    // Le max-pooling ne requantifie pas et lit toujours en octets.
    pool_engine u_pool (
        .clk    (clk),
        .rst    (rst),
        .s_valid(p_valid),
        .s_act  (act_rdata_byte),
        .s_first(q_first),
        .s_last (q_last),
        .r_valid(p_rvalid),
        .r_data (p_rdata)
    );

    // Diagnostic visuel : le ET avec o_ready fait clignoter le vert
    // seulement si le decodeur est au repos (horloge + logique OK).
    reg [24:0] hb = 25'd0;

    always @(posedge clk) hb <= hb + 1'b1;

    assign led   = busy;
    assign led_g = hb[22] & o_ready;   // ~1,5 Hz a 12 MHz
    assign led_b = locked;            // MMCM verrouille

endmodule
