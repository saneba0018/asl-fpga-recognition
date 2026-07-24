// spi_cmd_decoder : décodeur de trame SPI pour l'accélérateur ASL
// Écoute o_RX_DV / o_RX_Byte du spi_slave (Nandland) et pilote act_ram,
// layer_ctrl et result_buf selon la commande reçue.
//
// Protocole : [CMD(1)][DATA(N)], N implicite dans CMD
//   0x02 SEND_IMAGE   : 784 octets vers act_ram
//   0x03 START_CONV   : pulse start vers layer_ctrl
//   0x04 READ_RESULT  : 1 dummy + 24 octets depuis result_buf
//   0x05 GET_STATUS   : 1 dummy + 1 octet {busy, done, 6'b0}
//   0x01 LOAD_WEIGHTS : réservée
//
// Pendant busy=1, SEND_IMAGE, START_CONV et READ_RESULT sont ignorés.
// GET_STATUS reste toujours accepté.
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

    // vers act_ram (écriture image)
    output reg         img_wr_en,
    output reg  [9:0]  img_wr_addr,
    output reg  [7:0]  img_wr_data,

    // vers/depuis layer_ctrl
    output reg         start,
    input  wire        busy,
    input  wire        done,

    // depuis result_buf
    output reg  [4:0]  result_rd_addr,
    input  wire [7:0]  result_rd_data,

    // GPIO
    output wire        o_ready
);

    // Dimensions figées par le modèle (= CONV1_H_IN*CONV1_W_IN*CONV1_C_IN et DENSE2_C_OUT)
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
    reg       dummy_sent;

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
            dummy_sent     <= 0;
        end else begin
            // pulses par défaut à 0
            img_wr_en <= 0;
            start     <= 0;
            tx_dv     <= 0;

            // done latché jusqu'à lecture
            if (done) done_latch <= 1;

            // CS_n haut = fin de trame
            if (cs_n) begin
                state      <= IDLE;
                byte_cnt   <= 0;
                dummy_sent <= 0;
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
                            dummy_sent     <= 0;
                            result_rd_addr <= 0;
                        end else state <= S_IGNORE;

                        CMD_GET_STAT: begin
                            state      <= S_TX_STATUS;
                            dummy_sent <= 0;
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

S_TX_RESULT: if (rx_dv) begin
    if (!dummy_sent) begin
        tx_byte    <= result_rd_data;
        tx_dv      <= 1;
        dummy_sent <= 1;
        result_rd_addr <= 1;
        byte_cnt   <= 1;
    end else begin
        if (byte_cnt == RES_SIZE - 1) begin
            state      <= S_IGNORE;
            done_latch <= 0;
        end else begin
            tx_byte        <= result_rd_data;
            tx_dv          <= 1;
            result_rd_addr <= byte_cnt + 1;
            byte_cnt       <= byte_cnt + 1;
        end
    end
end

                S_TX_STATUS: if (rx_dv) begin
                    if (!dummy_sent) begin
                        tx_byte    <= {busy, done_latch, 6'b0};
                        tx_dv      <= 1;
                        dummy_sent <= 1;
                    end else begin
                        state <= S_IGNORE;
                    end
                end

                S_IGNORE: ; // attendre CS_n haut
            endcase
        end
    end

endmodule