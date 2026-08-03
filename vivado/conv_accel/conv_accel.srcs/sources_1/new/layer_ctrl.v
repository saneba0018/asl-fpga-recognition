//-----------------------------------------------------------------------------
// layer_ctrl.v - orchestration des six couches du CNN
//
// Sequence les etages conv1 -> pool1 -> conv2 -> pool2 -> dense1 -> dense2
// et pilote leur execution sur les modules conv_engine et pool_engine.
//
// LAYOUT DES TENSEURS  (convention TFLite, canal en dernier)
//   activations : addr = (y * W + x) * C + c
//   poids conv  : addr = WOFF + ((oc * K + ky) * K + kx) * C_IN + ic
//   biais/mult/shift : addr = OCBASE + oc
//
// PING-PONG DES MEMOIRES
//   conv1  ram_a -> ram_b     784    -> 21632
//   pool1  ram_b -> ram_a     21632  -> 5408
//   conv2  ram_a -> ram_b     5408   -> 7744
//   pool2  ram_b -> ram_a     7744   -> 1600
//   dense1 ram_a -> ram_b     1600   -> 32
//   dense2 ram_b -> result_buf 32    -> 24
//
// COMPTEURS
// Un nid de six compteurs reutilise pour tous les etages :
//   oc, oy, ox, ic, ky, kx
// Pour dense (K=1) les compteurs ky, kx restent a 0.
// Pour pool (IS_POOL=1) ky, kx parcourent le bloc de pooling au lieu du noyau.
//
// LATENCE DES MEMOIRES
// act_ram et param_rom ont une lecture synchrone : la donnee arrive un cycle
// apres l'adresse. Les compteurs presentent donc les adresses en avance, et
// les drapeaux s_valid, s_first, s_last sont retardes d'un cycle pour arriver
// avec les donnees. C'est la source d'erreur la plus frequente.
//
// conv_engine emet r_valid deux cycles apres s_last :
//   cycle N   : dernier MAC de la fenetre
//   cycle N+1 : requantification
//   cycle N+2 : r_data valide, on ecrit dans la RAM destination
// L'adresse d'ecriture est capturee au cycle N puis retardee de deux cycles.
//
// pool_engine sort r_valid un cycle apres s_last.
//
// VALIDATION
// La sortie du controleur est comparee a un modele comportemental dans
// tb_layer_ctrl.v. Cette validation prouve le sequencement, pas le layout des
// tenseurs. La validation contre les .mem de reference produits par
// export_golden.py reste a faire.
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

module layer_ctrl (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,      // impulsion d'un cycle
    output reg         busy,
    output reg         done,       // IMPULSION d'un cycle, jamais un niveau

    // ram_a : lecture et ecriture
    output reg         a_we,
    output reg  [12:0] a_waddr,
    output reg  [ 7:0] a_wdata,
    output reg  [12:0] a_raddr,
    input  wire [ 7:0] a_rdata,

    // ram_b : lecture et ecriture
    output reg         b_we,
    output reg  [14:0] b_waddr,
    output reg  [ 7:0] b_wdata,
    output reg  [14:0] b_raddr,
    input  wire [ 7:0] b_rdata,

    // ROM des poids
    output reg  [16:0] w_addr,
    input  wire [ 7:0] w_data,

    // ROM des parametres par canal
    output reg  [ 7:0] param_addr,
    input  wire [31:0] bias_data,
    input  wire [31:0] mult_data,
    input  wire [ 5:0] shift_data,

    // result_buf : ecriture des logits par dense2
    output reg         res_we,
    output reg  [ 4:0] res_waddr,
    output reg  [ 7:0] res_wdata
);

    //-------------------------------------------------------------------------
    // Constantes CNN
    // A ALIGNER sur cnn_params.vh - voir le message qui accompagne ce fichier
    //-------------------------------------------------------------------------
    localparam integer CONV1_WOFF   = 0;
    localparam integer CONV2_WOFF   = 288;
    localparam integer DENSE1_WOFF  = 18720;
    localparam integer DENSE2_WOFF  = 69920;

    localparam integer CONV1_OCBASE  = 0;
    localparam integer CONV2_OCBASE  = 32;
    localparam integer DENSE1_OCBASE = 96;
    localparam integer DENSE2_OCBASE = 128;

    localparam signed [7:0] ZP_INPUT  = -8'sd128;
    localparam signed [7:0] ZP_CONV1  = -8'sd41;
    localparam signed [7:0] ZP_CONV2  = -8'sd81;
    localparam signed [7:0] ZP_DENSE1 = -8'sd114;
    localparam signed [7:0] ZP_DENSE2 =  8'sd62;

    //-------------------------------------------------------------------------
    // FSM au niveau des couches
    //-------------------------------------------------------------------------
    localparam [3:0]
        S_IDLE   = 4'd0,
        S_CONV1  = 4'd1,
        S_POOL1  = 4'd2,
        S_CONV2  = 4'd3,
        S_POOL2  = 4'd4,
        S_DENSE1 = 4'd5,
        S_DENSE2 = 4'd6,
        S_DRAIN  = 4'd7,   // vider le pipeline entre couches
        S_DONE   = 4'd8;

    reg [3:0] state;
    reg [3:0] next_state;   // couche a executer apres S_DRAIN

    //-------------------------------------------------------------------------
    // Parametres de la couche en cours, charges a l'entree de chaque etat
    //-------------------------------------------------------------------------
    reg [ 5:0] W_IN, H_IN, W_OUT, H_OUT;
    reg [10:0] C_IN;         // jusqu'a 1600 pour dense1
    reg [ 6:0] C_OUT;        // jusqu'a 64
    reg [ 1:0] K_M1;          // K - 1 : 2 pour conv, 1 pour pool, 0 pour dense
    reg [16:0] WOFF;
    reg [ 7:0] OCBASE;
    reg signed [7:0] ZP_IN_R;
    reg signed [7:0] ZP_OUT_R;
    reg signed [7:0] CLAMP_R;
    reg        SRC_B;         // 0 = ram_a source, 1 = ram_b source
    reg        DST_B;         // 0 = ram_a destination
    reg        DST_RES;       // 1 = destination = result_buf (dense2 seulement)
    reg        IS_POOL_R;
    reg        IS_DENSE_R;

    //-------------------------------------------------------------------------
    // Nid de six compteurs
    //-------------------------------------------------------------------------
    reg [ 6:0] oc;
    reg [ 5:0] oy;
    reg [ 5:0] ox;
    reg [10:0] ic;
    reg [ 1:0] ky;
    reg [ 1:0] kx;

    reg running;
    reg last_term;    // impulsion sur le dernier compteur

    // Fin de chaque compteur, decides selon le type de couche
    wire kx_end;
    wire ky_end;
    wire ic_end;
    wire ox_end;
    wire oy_end;
    wire oc_end;

    // pour dense, ky et kx restent a 0 : leur "fin" est atteinte immediatement
    assign kx_end = IS_DENSE_R ? 1'b1 : (kx == K_M1);
    assign ky_end = IS_DENSE_R ? 1'b1 : (ky == K_M1);

    // ic n'est pas parcouru pour pool (max sur un bloc, pas de C_IN)
    assign ic_end = IS_POOL_R ? 1'b1 : (ic == (C_IN - 1));

    assign ox_end = (ox == (W_OUT - 1));
    assign oy_end = (oy == (H_OUT - 1));
    assign oc_end = (oc == (C_OUT - 1));

    // Ordre du parcours :
    //   pour conv/dense : oc, oy, ox, ic, ky, kx (kx le plus interne)
    //   pour pool       : oc, oy, ox, ky, kx (ic figé a 0)
    wire inc_ky = kx_end;
    wire inc_ic = kx_end & ky_end;
    wire inc_ox = kx_end & ky_end & ic_end;
    wire inc_oy = kx_end & ky_end & ic_end & ox_end;
    wire inc_oc = kx_end & ky_end & ic_end & ox_end & oy_end;
    wire term   = kx_end & ky_end & ic_end & ox_end & oy_end & oc_end;

    //-------------------------------------------------------------------------
    // Chargement des parametres de couche et gestion de l'etat
    //-------------------------------------------------------------------------
    task load_conv1;
        begin
            W_IN <= 6'd28; H_IN <= 6'd28; C_IN <= 11'd1;
            W_OUT <= 6'd26; H_OUT <= 6'd26; C_OUT <= 7'd32;
            K_M1 <= 2'd2;
            WOFF <= CONV1_WOFF;  OCBASE <= CONV1_OCBASE;
            ZP_IN_R <= ZP_INPUT; ZP_OUT_R <= ZP_CONV1; CLAMP_R <= ZP_CONV1;
            SRC_B <= 1'b0; DST_B <= 1'b1; DST_RES <= 1'b0;
            IS_POOL_R <= 1'b0; IS_DENSE_R <= 1'b0;
        end
    endtask

    task load_pool1;
        begin
            W_IN <= 6'd26; H_IN <= 6'd26; C_IN <= 11'd32;
            W_OUT <= 6'd13; H_OUT <= 6'd13; C_OUT <= 7'd32;
            K_M1 <= 2'd1;    // bloc 2x2
            WOFF <= 17'd0; OCBASE <= 8'd0;
            SRC_B <= 1'b1; DST_B <= 1'b0; DST_RES <= 1'b0;
            IS_POOL_R <= 1'b1; IS_DENSE_R <= 1'b0;
        end
    endtask

    task load_conv2;
        begin
            W_IN <= 6'd13; H_IN <= 6'd13; C_IN <= 11'd32;
            W_OUT <= 6'd11; H_OUT <= 6'd11; C_OUT <= 7'd64;
            K_M1 <= 2'd2;
            WOFF <= CONV2_WOFF;  OCBASE <= CONV2_OCBASE;
            ZP_IN_R <= ZP_CONV1; ZP_OUT_R <= ZP_CONV2; CLAMP_R <= ZP_CONV2;
            SRC_B <= 1'b0; DST_B <= 1'b1; DST_RES <= 1'b0;
            IS_POOL_R <= 1'b0; IS_DENSE_R <= 1'b0;
        end
    endtask

    task load_pool2;
        begin
            W_IN <= 6'd11; H_IN <= 6'd11; C_IN <= 11'd64;
            W_OUT <= 6'd5;  H_OUT <= 6'd5;  C_OUT <= 7'd64;
            K_M1 <= 2'd1;
            WOFF <= 17'd0; OCBASE <= 8'd0;
            SRC_B <= 1'b1; DST_B <= 1'b0; DST_RES <= 1'b0;
            IS_POOL_R <= 1'b1; IS_DENSE_R <= 1'b0;
        end
    endtask

    task load_dense1;
        begin
            W_IN <= 6'd1;  H_IN <= 6'd1;  C_IN <= 11'd1600;
            W_OUT <= 6'd1; H_OUT <= 6'd1; C_OUT <= 7'd32;
            K_M1 <= 2'd0;
            WOFF <= DENSE1_WOFF; OCBASE <= DENSE1_OCBASE;
            ZP_IN_R <= ZP_CONV2; ZP_OUT_R <= ZP_DENSE1; CLAMP_R <= ZP_DENSE1;
            SRC_B <= 1'b0; DST_B <= 1'b1; DST_RES <= 1'b0;
            IS_POOL_R <= 1'b0; IS_DENSE_R <= 1'b1;
        end
    endtask

    task load_dense2;
        begin
            W_IN <= 6'd1;  H_IN <= 6'd1;  C_IN <= 11'd32;
            W_OUT <= 6'd1; H_OUT <= 6'd1; C_OUT <= 7'd24;
            K_M1 <= 2'd0;
            WOFF <= DENSE2_WOFF; OCBASE <= DENSE2_OCBASE;
            ZP_IN_R <= ZP_DENSE1; ZP_OUT_R <= ZP_DENSE2; CLAMP_R <= -8'sd128;
            SRC_B <= 1'b1; DST_B <= 1'b0; DST_RES <= 1'b1;   // vers result_buf
            IS_POOL_R <= 1'b0; IS_DENSE_R <= 1'b1;
        end
    endtask

    //-------------------------------------------------------------------------
    // FSM et compteurs
    //-------------------------------------------------------------------------
    reg [3:0] drain_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            next_state <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            running    <= 1'b0;
            last_term  <= 1'b0;
            drain_cnt  <= 4'd0;
            oc <= 0; oy <= 0; ox <= 0; ic <= 0; ky <= 0; kx <= 0;
        end else begin
            done      <= 1'b0;
            last_term <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state      <= S_CONV1;
                        next_state <= S_POOL1;
                        load_conv1();
                        oc <= 0; oy <= 0; ox <= 0; ic <= 0; ky <= 0; kx <= 0;
                        running <= 1'b1;
                        busy    <= 1'b1;
                    end
                end

                S_CONV1, S_POOL1, S_CONV2, S_POOL2, S_DENSE1, S_DENSE2: begin
                    if (running) begin
                        if (term) begin
                            running   <= 1'b0;
                            last_term <= 1'b1;
                        end

                        // incrementation en cascade
                        if (inc_oc) begin
                            oc <= oc + 1'b1;
                            oy <= 0; ox <= 0; ic <= 0; ky <= 0; kx <= 0;
                        end else if (inc_oy) begin
                            oy <= oy + 1'b1;
                            ox <= 0; ic <= 0; ky <= 0; kx <= 0;
                        end else if (inc_ox) begin
                            ox <= ox + 1'b1;
                            ic <= 0; ky <= 0; kx <= 0;
                        end else if (inc_ic) begin
                            ic <= ic + 1'b1;
                            ky <= 0; kx <= 0;
                        end else if (inc_ky) begin
                            ky <= ky + 1'b1;
                            kx <= 0;
                        end else if (!kx_end) begin
                            kx <= kx + 1'b1;
                        end
                    end else begin
                        // attend le vidage du pipeline
                        drain_cnt <= drain_cnt + 1'b1;
                        if (drain_cnt == 4'd8) begin
                            drain_cnt <= 0;
                            oc <= 0; oy <= 0; ox <= 0; ic <= 0; ky <= 0; kx <= 0;
                            case (state)
                                S_CONV1:  begin state <= S_POOL1;  load_pool1();  running <= 1'b1; end
                                S_POOL1:  begin state <= S_CONV2;  load_conv2();  running <= 1'b1; end
                                S_CONV2:  begin state <= S_POOL2;  load_pool2();  running <= 1'b1; end
                                S_POOL2:  begin state <= S_DENSE1; load_dense1(); running <= 1'b1; end
                                S_DENSE1: begin state <= S_DENSE2; load_dense2(); running <= 1'b1; end
                                S_DENSE2: begin state <= S_DONE; end
                            endcase
                        end
                    end
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;         // impulsion d'un cycle
                    state <= S_IDLE;
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Adresses de lecture, calculees a partir des compteurs de l'etage 0
    //-------------------------------------------------------------------------
    // conv/dense : (oy+ky)*W_IN + (ox+kx), puis * C_IN + ic
    // dense reutilise ky=kx=0, donc l'adresse est ic (linearisation flatten)
    // pool : (oy*2 + ky)*W_IN + (ox*2 + kx), puis * C_IN + oc
    wire [ 5:0] src_y = IS_POOL_R ? (oy[4:0] << 1) + ky : oy + ky;
    wire [ 5:0] src_x = IS_POOL_R ? (ox[4:0] << 1) + kx : ox + kx;

    wire [23:0] act_addr =
        IS_DENSE_R ? ic :
        IS_POOL_R  ? (src_y * W_IN + src_x) * C_IN + oc :
                     (src_y * W_IN + src_x) * C_IN + ic;

    wire [23:0] w_addr_calc =
        WOFF + ((oc * (K_M1 + 1) + ky) * (K_M1 + 1) + kx) * C_IN + ic;

    wire [23:0] out_addr_now =
        DST_RES  ? oc :
        IS_DENSE_R ? oc :
                   (oy * W_OUT + ox) * C_OUT + oc;

    always @(*) begin
        // par defaut, pas de lecture
        a_raddr = 13'd0;
        b_raddr = 15'd0;

        if (running) begin
            if (SRC_B) b_raddr = act_addr[14:0];
            else       a_raddr = act_addr[12:0];
        end
    end

    always @(*) begin
        w_addr     = IS_POOL_R ? 17'd0 : w_addr_calc[16:0];
        param_addr = OCBASE + oc;
    end

    //-------------------------------------------------------------------------
    // Drapeaux retardes d'un cycle, alignes avec les donnees
    //-------------------------------------------------------------------------
    reg        d_valid;
    reg        d_first;
    reg        d_last;
    reg [14:0] d_outaddr;

    // pour conv/dense : premier terme quand ic=0, ky=0, kx=0
    // pour pool      : premier terme quand ky=0, kx=0
    wire is_first_c =  (ic == 0) & (ky == 0) & (kx == 0);
    wire is_last_c  =  (ic == C_IN - 1) & (ky == K_M1) & (kx == K_M1);
    wire is_first_d =  (ic == 0);
    wire is_last_d  =  (ic == C_IN - 1);
    wire is_first_p =  (ky == 0) & (kx == 0);
    wire is_last_p  =  (ky == K_M1) & (kx == K_M1);

    wire is_first = IS_POOL_R  ? is_first_p :
                    IS_DENSE_R ? is_first_d : is_first_c;
    wire is_last  = IS_POOL_R  ? is_last_p  :
                    IS_DENSE_R ? is_last_d  : is_last_c;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            d_valid <= 1'b0; d_first <= 1'b0; d_last <= 1'b0;
            d_outaddr <= 0;
        end else begin
            d_valid <= running;
            d_first <= running & is_first;
            d_last  <= running & is_last;
            if (running & is_last) d_outaddr <= out_addr_now[14:0];
        end
    end

    //-------------------------------------------------------------------------
    // Donnee d'activation multiplexee selon la source
    //-------------------------------------------------------------------------
    wire [7:0] act_from_ram = SRC_B ? b_rdata : a_rdata;

    //-------------------------------------------------------------------------
    // conv_engine, actif quand !IS_POOL_R
    //-------------------------------------------------------------------------
    wire              conv_valid;
    wire signed [7:0] conv_data;

    conv_engine u_conv (
        .clk         (clk),
        .rst         (rst),
        .s_valid     (d_valid & ~IS_POOL_R),
        .s_act       (act_from_ram),
        .s_w         (w_data),
        .s_first     (d_first),
        .s_last      (d_last),
        .s_bias      (bias_data),
        .s_mult      (mult_data),
        .s_shift     (shift_data[4:0]),
        .s_zp_in     (ZP_IN_R),
        .s_zp_out    (ZP_OUT_R),
        .s_clamp_min (CLAMP_R),
        .r_valid     (conv_valid),
        .r_data      (conv_data)
    );

    //-------------------------------------------------------------------------
    // pool_engine, actif quand IS_POOL_R
    //-------------------------------------------------------------------------
    wire              pool_valid;
    wire signed [7:0] pool_data;

    pool_engine u_pool (
        .clk     (clk),
        .rst     (rst),
        .s_valid (d_valid & IS_POOL_R),
        .s_act   (act_from_ram),
        .s_first (d_first),
        .s_last  (d_last),
        .r_valid (pool_valid),
        .r_data  (pool_data)
    );

    //-------------------------------------------------------------------------
    // Selection de la sortie et alignement de l'adresse d'ecriture
    //
    // conv_engine emet r_valid deux cycles apres s_last ; pool_engine un
    // cycle apres. On retarde d_outaddr en consequence.
    //-------------------------------------------------------------------------
    reg [14:0] outaddr_p1, outaddr_p2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            outaddr_p1 <= 0;
            outaddr_p2 <= 0;
        end else begin
            outaddr_p1 <= d_outaddr;
            outaddr_p2 <= outaddr_p1;
        end
    end

    wire        r_valid_now = IS_POOL_R ? pool_valid : conv_valid;
    wire [ 7:0] r_data_now  = IS_POOL_R ? pool_data  : conv_data;
    wire [14:0] r_addr_now  = IS_POOL_R ? outaddr_p1 : outaddr_p2;

    //-------------------------------------------------------------------------
    // Routage de l'ecriture vers la RAM destination ou result_buf
    //-------------------------------------------------------------------------
    always @(*) begin
        a_we    = 1'b0; a_waddr = 13'd0; a_wdata = 8'd0;
        b_we    = 1'b0; b_waddr = 15'd0; b_wdata = 8'd0;
        res_we  = 1'b0; res_waddr = 5'd0; res_wdata = 8'd0;

        if (r_valid_now) begin
            if (DST_RES) begin
                res_we    = 1'b1;
                res_waddr = r_addr_now[4:0];
                res_wdata = r_data_now;
            end else if (DST_B) begin
                b_we    = 1'b1;
                b_waddr = r_addr_now;
                b_wdata = r_data_now;
            end else begin
                a_we    = 1'b1;
                a_waddr = r_addr_now[12:0];
                a_wdata = r_data_now;
            end
        end
    end

endmodule