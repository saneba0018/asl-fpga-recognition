`timescale 1ns/1ps

module tb_spi_cmd_decoder;

    reg        clk = 0;
    reg        rst = 1;
    reg        rx_dv = 0;
    reg [7:0]  rx_byte = 0;
    reg        cs_n = 1;
    wire       tx_dv;
    wire [7:0] tx_byte;
    wire       img_wr_en;
    wire [9:0] img_wr_addr;
    wire [7:0] img_wr_data;
    wire       start;
    reg        busy = 0;
    reg        done = 0;
    wire [4:0] result_rd_addr;
    reg  [7:0] result_rd_data;
    wire       o_ready;

    // horloge 100 MHz
    always #5 clk = ~clk;

    // result_buf simulé : classe k retourne 8'hA0 + k
    always @(*) result_rd_data = 8'hA0 + result_rd_addr;

    spi_cmd_decoder dut (
        .clk(clk), .rst(rst),
        .rx_dv(rx_dv), .rx_byte(rx_byte), .cs_n(cs_n),
        .tx_dv(tx_dv), .tx_byte(tx_byte),
        .img_wr_en(img_wr_en), .img_wr_addr(img_wr_addr), .img_wr_data(img_wr_data),
        .start(start), .busy(busy), .done(done),
        .result_rd_addr(result_rd_addr), .result_rd_data(result_rd_data),
        .o_ready(o_ready)
    );

    // envoie un octet reçu (simule un pulse rx_dv du spi_slave)
    task send_byte(input [7:0] b);
        begin
            @(posedge clk); rx_byte <= b; rx_dv <= 1;
            @(posedge clk); rx_dv <= 0;
        end
    endtask

    // termine une trame : laisse un cycle pour traiter le dernier octet puis remonte cs_n
    task end_frame();
        begin
            @(posedge clk);
            @(posedge clk);
            cs_n = 1;
            @(posedge clk);
        end
    endtask

    initial begin
        // reset
        #20 rst = 0;
        #20;

        // ===== TEST 1 : START_CONV =====
        $display("[T=%0t] TEST 1 : START_CONV", $time);
        cs_n = 0;
        send_byte(8'h03);
        end_frame();
        #20;

        // ===== TEST 2 : SEND_IMAGE (3 octets pour vérifier) =====
        $display("[T=%0t] TEST 2 : SEND_IMAGE", $time);
        cs_n = 0;
        send_byte(8'h02);  // CMD
        send_byte(8'hAA);  // pixel 0
        send_byte(8'hBB);  // pixel 1
        send_byte(8'hCC);  // pixel 2
        end_frame();
        #20;

        // ===== TEST 3 : GET_STATUS =====
        $display("[T=%0t] TEST 3 : GET_STATUS", $time);
        cs_n = 0;
        send_byte(8'h05);  // CMD
        send_byte(8'h00);  // dummy
        end_frame();
        #20;

// ===== TEST 4 : READ_RESULT (24 logits complets) =====
$display("[T=%0t] TEST 4 : READ_RESULT", $time);
cs_n = 0;
send_byte(8'h04);  // CMD
send_byte(8'h00);  // dummy
begin : read_loop
    integer i;
    for (i = 0; i < 24; i = i + 1) send_byte(8'h00);
end
end_frame();
#20;

        // ===== TEST 5 : START_CONV ignoré pendant busy =====
        $display("[T=%0t] TEST 5 : START_CONV pendant busy", $time);
        busy = 1;
        cs_n = 0;
        send_byte(8'h03);
        end_frame();
        busy = 0;
        #20;

        $display("[T=%0t] Fin", $time);
        $finish;
    end

    // observateurs
    always @(posedge clk) begin
        if (start)     $display("[T=%0t]   -> START pulse", $time);
        if (img_wr_en) $display("[T=%0t]   -> IMG WRITE addr=%0d data=%h", $time, img_wr_addr, img_wr_data);
        if (tx_dv)     $display("[T=%0t]   -> TX byte=%h", $time, tx_byte);
    end

endmodule