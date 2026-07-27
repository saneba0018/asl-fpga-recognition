`timescale 1ns/1ps
// Maitre SPI comportemental mode 0, 1 MHz, MSB first.
module tb_link;
  reg clk = 0; always #41.666 clk = ~clk;   // 12 MHz

  reg sck = 0, mosi = 0, cs_n = 1;
  wire miso;
  pullup(miso);

  wire rx_dv; wire [7:0] rx_byte; wire tx_dv; wire [7:0] tx_byte;
  reg  rst = 1;

  SPI_Slave #(.SPI_MODE(0)) u_spi (
    .i_Rst_L(~rst), .i_Clk(clk),
    .o_RX_DV(rx_dv), .o_RX_Byte(rx_byte),
    .i_TX_DV(tx_dv), .i_TX_Byte(tx_byte),
    .i_SPI_Clk(sck), .o_SPI_MISO(miso), .i_SPI_MOSI(mosi), .i_SPI_CS_n(cs_n));

  wire img_we; wire [9:0] img_a; wire [7:0] img_d;
  wire start; wire [4:0] res_a;
  reg  busy = 0, done = 0;
  wire o_ready;
  reg [7:0] echo [0:23];
  wire [7:0] res_d = echo[res_a];

  spi_cmd_decoder u_dec (
    .clk(clk), .rst(rst), .rx_dv(rx_dv), .rx_byte(rx_byte), .cs_n(cs_n),
    .tx_dv(tx_dv), .tx_byte(tx_byte),
    .img_wr_en(img_we), .img_wr_addr(img_a), .img_wr_data(img_d),
    .start(start), .busy(busy), .done(done),
    .result_rd_addr(res_a), .result_rd_data(res_d), .o_ready(o_ready));

  // un octet, mode 0 : MOSI stable avant le front montant, echantillon MISO sur front montant
  integer SAMPLE_DELAY = 10;
  task xfer(input [7:0] d, output [7:0] q);
    integer i;
    begin
      for (i=7; i>=0; i=i-1) begin
        mosi = d[i];
        #250;                       // demi-periode basse
        sck = 1;
        #SAMPLE_DELAY; q[i] = miso; // le maitre echantillonne apres le front
        #(250 - SAMPLE_DELAY);      // reste de la demi-periode haute
        sck = 0;
      end
    end
  endtask

  reg [7:0] r; integer k; integer bad;

  initial begin
    for (k=0;k<24;k=k+1) echo[k] = k*7+13;   // meme motif que le firmware
    #1000 rst = 0; #1000;

    // ---- GET_STATUS ----
    busy = 0; done = 0;
    cs_n = 0; #500;
    xfer(8'h05, r);
    xfer(8'h00, r);
    xfer(8'h00, r);
    #500; cs_n = 1; #2000;
    $display("GET_STATUS  attendu 0x00  recu 0x%02h  %s", r, (r===8'h00)?"OK":"FAIL");

    // ---- READ_RESULT ----
    cs_n = 0; #500;
    xfer(8'h04, r);
    xfer(8'h00, r);
    bad = 0;
    for (k=0;k<24;k=k+1) begin
      xfer(8'h00, r);
      if (r !== echo[k]) begin
        bad = bad + 1;
        if (bad <= 4) $display("  logit[%0d] attendu 0x%02h recu 0x%02h", k, echo[k], r);
      end
    end
    #500; cs_n = 1; #2000;
    $display("READ_RESULT %0d divergences sur 24", bad);

    // ---- GET_STATUS avec busy=1 et done=1 ----
    busy = 1; done = 1; #500; done = 0; #500;
    cs_n = 0; #500;
    xfer(8'h05, r); xfer(8'h00, r); xfer(8'h00, r);
    #500; cs_n = 1; #2000;
    $display("STATUS busy=1  attendu 0xC0  recu 0x%02h  %s", r, (r===8'hC0)?"OK":"FAIL");

    // ---- SEND_IMAGE : les 24 premiers octets doivent atterrir ----
    busy = 0; #1000;
    cs_n = 0; #500;
    xfer(8'h02, r);
    for (k=0;k<784;k=k+1) xfer(k[7:0], r);
    #500; cs_n = 1; #2000;
    $display("SEND_IMAGE termine, dernier img_wr_addr = %0d", u_dec.byte_cnt);

    $finish;
  end
endmodule