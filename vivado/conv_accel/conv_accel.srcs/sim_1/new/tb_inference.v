`timescale 1ns / 1ps
// tb_inference - auto-test bout-en-bout : charge l'image de reference dans
// ram_a, lance conv1 -> ... -> dense2, compare les 24 logits a
// GOLDEN_LOGITS. Seul banc qui exerce le sequenceur complet (ping-pong,
// layout, adressage ROM, requant) ; le SPI est court-circuite (image ecrite
// directement, start force). Compiler avec -DNO_MMCM, lancer depuis
// vivado/conv_accel/mem/ pour que $readmemh trouve les .mem.
module tb_inference;

    reg sysclk = 1'b0;
    always #10 sysclk = ~sysclk;          // 50 MHz

    wire spi_miso, o_ready, led, led_g, led_b;

    memory_streamer u_dut (
        .sysclk  (sysclk),
        .spi_sck (1'b0),
        .spi_mosi(1'b0),
        .spi_miso(spi_miso),
        .spi_cs_n(1'b1),                  // SPI au repos tout du long
        .o_ready (o_ready),
        .led     (led),
        .led_g   (led_g),
        .led_b   (led_b)
    );

    reg [7:0] expected [0:23];
    reg [7:0] image    [0:783];
    integer   k, bad, cycles;

    initial begin
        $readmemh("golden_logits.mem", expected);

        // Laisser passer le reset POR (256 cycles) avec de la marge
        repeat (400) @(posedge sysclk);

        // Image deja quantifiee (XOR 0x80). u_ram_a est un act_ram_wide (pas
        // de mem[] plat a poker), on ecrit donc octet par octet via
        // we/waddr/wdata. force est applique apres un front DESCENDANT (pas
        // juste apres le montant) pour eviter une course avec l'ecriture
        // synchrone du meme front.
        $readmemh("golden_image.mem", image);
        @(negedge sysclk);
        for (k = 0; k < 784; k = k + 1) begin
            force u_dut.u_ram_a.we    = 1'b1;
            force u_dut.u_ram_a.waddr = k[12:0];
            force u_dut.u_ram_a.wdata = image[k];
            @(posedge sysclk);
            @(negedge sysclk);
        end
        force u_dut.u_ram_a.we = 1'b0;
        @(posedge sysclk);
        release u_dut.u_ram_a.we;
        release u_dut.u_ram_a.waddr;
        release u_dut.u_ram_a.wdata;
        @(posedge sysclk);

        $display("\n=== tb_inference : inference complete sur l'image de reference ===");

        // Impulsion start (normalement emise par spi_cmd_decoder)
        force u_dut.start = 1'b1;
        @(posedge sysclk);
        release u_dut.start;

        // Attendre la prise en compte puis la fin, avec chien de garde
        cycles = 0;
        while (u_dut.busy !== 1'b1 && cycles < 100) begin
            @(posedge sysclk); cycles = cycles + 1;
        end
        if (u_dut.busy !== 1'b1) begin
            $display("  ECHEC : busy n'est jamais monte apres start");
            $finish;
        end

        cycles = 0;
        while (u_dut.busy === 1'b1 && cycles < 20_000_000) begin
            @(posedge sysclk); cycles = cycles + 1;
        end
        if (u_dut.busy === 1'b1) begin
            $display("  ECHEC : chien de garde, busy toujours haut apres %0d cycles", cycles);
            $finish;
        end

        $display("  inference terminee en %0d cycles (%0.1f ms a 50 MHz)",
                 cycles, cycles / 50000.0);

        bad = 0;
        for (k = 0; k < 24; k = k + 1) begin
            if (u_dut.logit_buf[k] !== expected[k]) begin
                bad = bad + 1;
                if (bad <= 6)
                    $display("    logit[%2d] attendu %4d  recu %4d",
                             k, $signed(expected[k]), $signed(u_dut.logit_buf[k]));
            end
        end

        $display("\n==========================================");
        if (bad == 0)
            $display("  RESULTAT : 24/24 logits identiques a GOLDEN_LOGITS");
        else
            $display("  RESULTAT : %0d / 24 logits divergents", bad);
        $display("==========================================\n");

        $finish;
    end
endmodule
