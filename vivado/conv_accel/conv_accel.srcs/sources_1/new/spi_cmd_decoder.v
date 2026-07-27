// spi_cmd_decoder : decodeur de trame SPI pour l'accelerateur ASL
//
// CORRECTIF 2026-07-27 - prechargement de tx_byte
// -----------------------------------------------------------------------
// L'ancienne version chargeait tx_byte sur le rx_dv de l'octet de
// turnaround. Trop tard : rx_dv traverse trois etages de synchronisation
// dans SPI_Slave, puis le decodeur reagit, puis SPI_Slave enregistre
// r_TX_Byte. Environ 5 cycles a 12 MHz.
//
// Or SPI_Slave verrouille le bit de poids fort de l'octet suivant sur le
// DERNIER front SCK de l'octet courant (r_SPI_MISO_Bit <= r_TX_Byte[7]
// quand le compteur reboucle). Le nouveau tx_byte arrivait donc apres.
// Chaque octet emis portait le bit 7 du precedent.
//
// Correctif : armer tx_byte des le decodage de la commande, un octet plus
// tot, via le drapeau r_preload. Le turnaround sert alors reellement a ce
// pour quoi il existe.
// -----------------------------------------------------------------------
//
// Protocole : [CMD(1)][DATA(N)], N implicite dans CMD
//   0x02 SEND_IMAGE   : 784 octets vers act_ram
//   0x03 START_CONV   : pulse start vers layer_ctrl
//   0x04 READ_RESULT  : 1 dummy + 24 octets depuis result_buf
//   0x05 GET_STATUS   : 1 dummy + 1 octet {busy, done, 6'b0}
//   0x01 LOAD_WEIGHTS : reservee
//
// Pendant busy=1, SEND_IMAGE, START_CONV et READ_RESULT sont ignores.
// GET_STATUS reste toujours accepte.

`timescale 1ns/1ps

module spi_cmd_decoder (
    input  wire        clk,
    input  wire        rst,

    // depuis spi_slave (Nandland)
    input  wire        rx_dv,
    input  wire [7:0]  rx_byte,
    input  wire        cs_n,

    // vers spi_slave (Nandland)
    output reg         tx_dv,
    output reg  [7:0]  tx_byte,

    // vers act_ram (ecriture image)
    output reg         img_wr_en,
    output reg  [9:0]  img_wr_addr,
    output reg  [7:0]  img_wr_data,

    // vers/depuis layer_ctrl
    output reg         start,
    input  wire        busy,
    input  wire        done,

    // depuis result_buf (lecture COMBINATOIRE obligatoire)
    output reg  [4:0]  result_rd_addr,
    input  wire [7:0]  result_rd_data,

    // GPIO
    output wire        o_ready
);

    localparam IMG_SIZE = 784;
    localparam RES_SIZE = 24;

    localparam IDLE        = 3'd0;
    localparam S_RX_IMG    = 3'd1;
    localparam S_TX_RESULT = 3'd2;
    localparam S_TX_STATUS = 3'd3;
    localparam S_IGNORE    = 3'd4;

    localparam CMD_SEND_IMG = 8'h02;
    localparam CMD_START    = 8'h03;
    localparam CMD_READ_RES = 8'h04;
    localparam CMD_GET_STAT = 8'h05;

    reg [2:0] state;
    reg [9:0] byte_cnt;
    reg       done_latch;

    // Drapeaux de prechargement : armes au decodage de la commande,
    // consommes au cycle d'horloge suivant.
    reg       preload_res;
    reg       preload_stat;

    assign o_ready = ~busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= IDLE;
            byte_cnt       <= 0;
            img_wr_en      <= 0;
            img_wr_addr    <= 0;
            img_wr_data    <= 0;
            start          <= 0;
            tx_dv          <= 0;
            tx_byte        <= 0;
            result_rd_addr <= 0;
            done_latch     <= 0;
            preload_res    <= 0;
            preload_stat   <= 0;
        end else begin
            // impulsions par defaut a 0
            img_wr_en <= 0;
            start     <= 0;
            tx_dv     <= 0;

            // done latche jusqu'a lecture
            if (done) done_latch <= 1;

            //-----------------------------------------------------------------
            // Prechargement : un cycle apres le decodage de la commande.
            // result_rd_addr a ete positionne au cycle precedent, donc
            // result_rd_data est valide ici (lecture combinatoire).
            //-----------------------------------------------------------------
            if (preload_res) begin
                tx_byte        <= result_rd_data;   // result[0]
                tx_dv          <= 1;
                result_rd_addr <= 5'd1;             // prepare le suivant
                byte_cnt       <= 10'd1;
                preload_res    <= 0;
            end

            if (preload_stat) begin
                tx_byte      <= {busy, done_latch, 6'b0};
                tx_dv        <= 1;
                preload_stat <= 0;
            end

            // CS_n haut = fin de trame
            if (cs_n) begin
                state        <= IDLE;
                byte_cnt     <= 0;
                preload_res  <= 0;
                preload_stat <= 0;
            end
            else case (state)

                IDLE: if (rx_dv) begin
                    case (rx_byte)
                        CMD_SEND_IMG: if (!busy) begin
                            state    <= S_RX_IMG;
                            byte_cnt <= 0;
                        end else state <= S_IGNORE;

                        CMD_START: begin
                            if (!busy) begin
                                start      <= 1;
                                done_latch <= 0;
                            end
                            state <= S_IGNORE;
                        end

                        CMD_READ_RES: if (!busy) begin
                            state          <= S_TX_RESULT;
                            byte_cnt       <= 0;
                            result_rd_addr <= 5'd0;
                            preload_res    <= 1;     // arme des maintenant
                        end else state <= S_IGNORE;

                        CMD_GET_STAT: begin
                            state        <= S_TX_STATUS;
                            preload_stat <= 1;       // arme des maintenant
                        end

                        default: state <= S_IGNORE;
                    endcase
                end

                S_RX_IMG: if (rx_dv) begin
                    img_wr_en   <= 1;
                    img_wr_addr <= byte_cnt;
                    img_wr_data <= rx_byte;
                    byte_cnt    <= byte_cnt + 1;
                    if (byte_cnt == IMG_SIZE - 1)
                        state <= S_IGNORE;
                end

                //-------------------------------------------------------------
                // Chaque rx_dv arme l'octet SUIVANT. result[0] a deja ete
                // arme par preload_res, donc on demarre a byte_cnt = 1.
                //
                // Trame : [CMD][turnaround][24 octets]
                //   MISO octet 0 : indefini
                //   MISO octet 1 : indefini (turnaround)
                //   MISO octets 2..25 : result[0..23]
                //-------------------------------------------------------------
                S_TX_RESULT: if (rx_dv) begin
                    if (byte_cnt < RES_SIZE) begin
                        tx_byte        <= result_rd_data;
                        tx_dv          <= 1;
                        result_rd_addr <= byte_cnt[4:0] + 5'd1;
                        byte_cnt       <= byte_cnt + 1;
                    end else begin
                        state      <= S_IGNORE;
                        done_latch <= 0;
                    end
                end

                // Le status a ete arme par preload_stat. Il ne reste qu'a
                // attendre la fin de la trame.
                S_TX_STATUS: if (rx_dv) begin
                    state <= S_IGNORE;
                end

                S_IGNORE: ; // attendre CS_n haut

            endcase
        end
    end

endmodule