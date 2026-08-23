`timescale 1ns / 1ps
// tb_act_ram_wide - ecrit octet par octet puis relit en large (LANES octets)
// et en octet (rdata_byte), compare a un modele de reference ; verifie aussi
// l'isolation entre bancs.
module tb_act_ram_wide;

    localparam LANES = 32;
    localparam DEPTH = 21632;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg              we = 1'b0;
    reg [14:0]       waddr = 0;
    reg [7:0]        wdata = 0;
    reg [14:0]       raddr = 0;
    wire [LANES*8-1:0] rdata;
    wire [7:0]       rdata_byte;

    act_ram_wide #(.DEPTH(DEPTH), .LANES(LANES)) u_dut (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata), .rdata_byte(rdata_byte));

    reg [7:0] ref_mem [0:DEPTH-1];   // modele de reference
    integer i, k, errors, trial, base;
    reg [7:0] got, exp;

    initial begin
        errors = 0;
        $display("\n=== tb_act_ram_wide : %0d bancs, %0d octets ===", LANES, DEPTH);

        // --- remplissage octet par octet ---
        for (i = 0; i < DEPTH; i = i + 1) begin
            ref_mem[i] = (i * 7 + (i >> 5) * 31) & 8'hff;
            waddr = i[14:0]; wdata = ref_mem[i]; we = 1'b1;
            @(posedge clk); #1;
        end
        we = 1'b0;
        $display("  %0d octets ecrits", DEPTH);

        // --- lectures larges alignees ---
        for (trial = 0; trial < 300; trial = trial + 1) begin
            base = (({$random} % (DEPTH / LANES)) * LANES);
            raddr = base[14:0];
            @(posedge clk); #1;
            for (k = 0; k < LANES; k = k + 1) begin
                got = rdata[k*8 +: 8];
                exp = ref_mem[base + k];
                if (got !== exp) begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("    large  base=%0d voie=%0d  attendu %02h recu %02h",
                                 base, k, exp, got);
                end
            end
        end
        $display("  300 lectures larges de %0d octets verifiees", LANES);

        // --- lectures octet a adresse quelconque ---
        for (trial = 0; trial < 300; trial = trial + 1) begin
            base = {$random} % DEPTH;
            raddr = base[14:0];
            @(posedge clk); #1;
            if (rdata_byte !== ref_mem[base]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("    octet  addr=%0d  attendu %02h recu %02h",
                             base, ref_mem[base], rdata_byte);
            end
        end
        $display("  300 lectures octet verifiees");

        // --- une ecriture ne doit toucher qu'un banc ---
        base = 32 * 100;
        waddr = base + 13; wdata = 8'hA5; we = 1'b1;
        ref_mem[base + 13] = 8'hA5;
        @(posedge clk); #1; we = 1'b0;
        raddr = base[14:0];
        @(posedge clk); #1;
        for (k = 0; k < LANES; k = k + 1) begin
            if (rdata[k*8 +: 8] !== ref_mem[base + k]) begin
                errors = errors + 1;
                $display("    ecriture croisee : voie %0d alteree", k);
            end
        end
        $display("  isolation des bancs verifiee");

        $display("\n==========================================");
        if (errors == 0) $display("  RESULTAT : RAM en bancs coherente");
        else             $display("  RESULTAT : %0d ERREUR(S)", errors);
        $display("==========================================\n");
        $finish;
    end
endmodule
