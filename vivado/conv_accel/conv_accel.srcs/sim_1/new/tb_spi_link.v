`timescale 1ns/1ps
// tb_spi_link - maitre SPI comportemental mode 0, MSB first. Rejoue la trame
// du firmware (spi_comm.cpp) contre SPI_Slave + spi_cmd_decoder a 50 MHz
// clk / 1 MHz SCK (meme ratio que le materiel), ou le prechargement gagne et
// les donnees commencent a l'octet MISO 1 (MISO_DATA_OFFSET=1). Verdict
// automatique en fin de simulation.
module tb_link;

  // 50 MHz : identique a la sortie du MMCM
  reg clk = 0; always #10 clk = ~clk;

  // 1 MHz : demi-periode 500 ns
  localparam real SPI_HALF = 500.0;

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

  // un octet, mode 0 : MOSI stable avant le front montant, MISO echantillonne
  // par le maitre juste apres le front montant
  integer SAMPLE_DELAY = 10;
  task xfer(input [7:0] d, output [7:0] q);
    integer i;
    begin
      for (i=7; i>=0; i=i-1) begin
        mosi = d[i];
        #SPI_HALF;
        sck = 1;
        #SAMPLE_DELAY; q[i] = miso;
        #(SPI_HALF - SAMPLE_DELAY);
        sck = 0;
      end
    end
  endtask

  // Mouchard d'ecriture image (byte_cnt du decodeur est remis a 0 par cs_n,
  // inutilisable comme verification post-trame).
  integer   img_writes   = 0;
  reg [9:0] last_img_addr = 10'd0;

  always @(posedge clk) begin
    if (img_we) begin
      img_writes    = img_writes + 1;
      last_img_addr = img_a;
    end
  end

  reg [7:0] r; integer k; integer bad; integer errors;

  task check(input cond, input [8*48:1] name);
    begin
      if (!cond) errors = errors + 1;
      $display("  %-42s %s", name, cond ? "OK" : "FAIL");
    end
  endtask

  initial begin
    errors = 0;
    for (k=0;k<24;k=k+1) echo[k] = k*7+13;   // meme motif que le firmware
    #1000 rst = 0; #1000;

    $display("\n=== tb_spi_link : clk 50 MHz, SCK 1 MHz, offset attendu 1 ===");

    // ---- GET_STATUS au repos : [CMD][status] ----
    busy = 0; done = 0;
    cs_n = 0; #500;
    xfer(8'h05, r);          // octet 0 : commande
    xfer(8'h00, r);          // octet 1 : status (offset 1)
    #500; cs_n = 1; #2000;
    check(r === 8'h00, "GET_STATUS repos = 0x00");

    // ---- READ_RESULT : [CMD][result 0..23] ----
    cs_n = 0; #500;
    xfer(8'h04, r);          // octet 0 : commande
    bad = 0;
    for (k=0;k<24;k=k+1) begin
      xfer(8'h00, r);        // octets 1..24 : les 24 logits
      if (r !== echo[k]) begin
        bad = bad + 1;
        if (bad <= 4)
          $display("    logit[%0d] attendu 0x%02h recu 0x%02h", k, echo[k], r);
      end
    end
    #500; cs_n = 1; #2000;
    check(bad == 0, "READ_RESULT : 24 logits alignes sur offset 1");

    // ---- GET_STATUS avec busy=1 et done latche ----
    busy = 1; done = 1; #500; done = 0; #500;
    cs_n = 0; #500;
    xfer(8'h05, r); xfer(8'h00, r);
    #500; cs_n = 1; #2000;
    check(r === 8'hC0, "GET_STATUS busy+done = 0xC0");

    // ---- SEND_IMAGE : les 784 octets doivent atterrir ----
    busy = 0; #1000;
    cs_n = 0; #500;
    xfer(8'h02, r);
    for (k=0;k<784;k=k+1) xfer(k[7:0], r);
    #500; cs_n = 1; #2000;
    check(img_writes == 784,      "SEND_IMAGE : 784 ecritures act_ram");
    check(last_img_addr == 783,   "SEND_IMAGE : derniere adresse = 783");

    $display("\n==========================================");
    if (errors == 0) $display("  RESULTAT : TOUS LES TESTS PASSENT");
    else             $display("  RESULTAT : %0d TEST(S) EN ECHEC", errors);
    $display("==========================================\n");
    $finish;
  end
endmodule
