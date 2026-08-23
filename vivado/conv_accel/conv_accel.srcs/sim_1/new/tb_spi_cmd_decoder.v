`timescale 1ns/1ps
// tb_spi_cmd_decoder - verifie START_CONV, SEND_IMAGE, GET_STATUS,
// READ_RESULT (24 logits complets) et le blocage de START_CONV pendant busy.
// Verdict automatique + watchdog.

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

    integer errors = 0;

    // horloge 100 MHz
    always #5 clk = ~clk;

    // result_buf simule : classe k retourne 8'hA0 + k (combinatoire, comme le
    // vrai result_buf devra l'etre - voir note en bas de fichier)
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

    // Mouchards : capturent ce que le DUT produit, pour verification differee
    reg        cap_en   = 0;
    integer    n_tx     = 0;      // nombre d'octets emis
    reg [7:0]  tx_log [0:63];     // octets emis
    integer    n_start  = 0;      // nombre de pulses start
    integer    n_wr     = 0;      // nombre d'ecritures image
    reg [9:0]  wr_addr_log [0:15];
    reg [7:0]  wr_data_log [0:15];

    always @(posedge clk) begin
        if (cap_en) begin
            if (tx_dv) begin
                if (n_tx < 64) tx_log[n_tx] = tx_byte;
                n_tx = n_tx + 1;
            end
            if (start) n_start = n_start + 1;
            if (img_wr_en) begin
                if (n_wr < 16) begin
                    wr_addr_log[n_wr] = img_wr_addr;
                    wr_data_log[n_wr] = img_wr_data;
                end
                n_wr = n_wr + 1;
            end
        end
    end

    task reset_mouchards();
        begin
            n_tx = 0; n_start = 0; n_wr = 0;
        end
    endtask

    task check(input condition, input [511:0] libelle);
        begin
            if (condition) begin
                $display("    OK   : %0s", libelle);
            end else begin
                $display("    ECHEC: %0s", libelle);
                errors = errors + 1;
            end
        end
    endtask

    // Stimuli
    task send_byte(input [7:0] b);
        begin
            @(posedge clk); rx_byte <= b; rx_dv <= 1;
            @(posedge clk); rx_dv <= 0;
        end
    endtask

    task end_frame();
        begin
            @(posedge clk);
            @(posedge clk);
            cs_n = 1;
            @(posedge clk);
        end
    endtask

    // Watchdog : evite une simulation qui tourne indefiniment
    initial begin
        #200000;
        $display("");
        $display("ERREUR FATALE : watchdog declenche, la simulation ne s'est");
        $display("                pas terminee dans le temps imparti.");
        $finish;
    end

    // Scenario
    integer i;

    initial begin
        $display("");
        $display("=== tb_spi_cmd_decoder ===");
        cap_en = 1;

        #20 rst = 0;
        #20;

        // ===== TEST 1 : START_CONV =====
        $display("");
        $display("TEST 1 : START_CONV");
        reset_mouchards();
        cs_n = 0;
        send_byte(8'h03);
        end_frame();
        #20;
        check(n_start == 1, "un seul pulse start genere");

        // ===== TEST 2 : SEND_IMAGE =====
        $display("");
        $display("TEST 2 : SEND_IMAGE (3 octets)");
        reset_mouchards();
        cs_n = 0;
        send_byte(8'h02);  // CMD
        send_byte(8'hAA);  // pixel 0
        send_byte(8'hBB);  // pixel 1
        send_byte(8'hCC);  // pixel 2
        end_frame();
        #20;
        check(n_wr == 3, "3 ecritures image");
        check(wr_addr_log[0] == 0 && wr_data_log[0] == 8'hAA, "pixel 0 : addr=0 data=AA");
        check(wr_addr_log[1] == 1 && wr_data_log[1] == 8'hBB, "pixel 1 : addr=1 data=BB");
        check(wr_addr_log[2] == 2 && wr_data_log[2] == 8'hCC, "pixel 2 : addr=2 data=CC");

        // ===== TEST 3 : GET_STATUS =====
        // busy=0 et done_latch=0 (efface par le START_CONV du test 1)
        $display("");
        $display("TEST 3 : GET_STATUS");
        reset_mouchards();
        cs_n = 0;
        send_byte(8'h05);  // CMD
        send_byte(8'h00);  // dummy
        end_frame();
        #20;
        check(n_tx == 1, "un seul octet de statut emis");
        check(tx_log[0] == 8'h00, "statut = 0x00 (ni busy ni done)");

        // ===== TEST 4 : READ_RESULT - le test qui attrape le bug =====
        // Trame reelle : CMD + 25 dummies = 26 octets.
        // Le decodeur doit emettre 24 octets : 0xA0 .. 0xB7
        $display("");
        $display("TEST 4 : READ_RESULT (24 logits)");
        reset_mouchards();
        cs_n = 0;
        send_byte(8'h04);              // CMD
        for (i = 0; i < 25; i = i + 1)
            send_byte(8'h00);          // 25 dummies
        end_frame();
        #20;

        check(n_tx == 24, "exactement 24 octets emis");

        for (i = 0; i < 24; i = i + 1) begin
            if (i < n_tx && tx_log[i] !== (8'hA0 + i)) begin
                $display("    ECHEC: logit %0d = %h, attendu %h",
                         i, tx_log[i], 8'hA0 + i);
                errors = errors + 1;
            end
        end
        if (n_tx == 24)
            check(tx_log[23] == 8'hB7, "dernier logit = 0xB7 (le 24e n'est pas perdu)");

        // ===== TEST 5 : START_CONV ignore pendant busy =====
        $display("");
        $display("TEST 5 : START_CONV pendant busy");
        reset_mouchards();
        busy = 1;
        cs_n = 0;
        send_byte(8'h03);
        end_frame();
        busy = 0;
        #20;
        check(n_start == 0, "aucun pulse start pendant busy");

        // ===== Verdict =====
        $display("");
        $display("==========================================");
        if (errors == 0)
            $display("  RESULTAT : TOUS LES TESTS PASSENT");
        else
            $display("  RESULTAT : %0d ERREUR(S)", errors);
        $display("==========================================");
        $display("");
        $finish;
    end

endmodule

// Note: result_buf doit etre combinatoire (banc de registres), pas une BRAM
// synchrone comme act_ram, sinon les logits sortiraient decales d'un cran.