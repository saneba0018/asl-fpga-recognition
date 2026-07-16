// Activation RAM (ram_a / ram_b)
// Simple dual-port, byte-wide, lecture synchrone 1 cycle
// deux instances:
//   ram_a: DEPTH = 5408   (image 784 / pool1 5408 / pool2 1600 / logits 24) input
//   ram_b: DEPTH = 21632  (pour conv1) output

// Vivado place dans BRAM par les templates:
// https://www.xilinx.com/support/documents/sw_manuals/xilinx2022_2/ug901-vivado-synthesis.pdf ch4
// https://chipverify.com/verilog/verilog-single-port-ram

module act_ram #(
    parameter DEPTH = 21632,
    parameter AW    = $clog2(DEPTH)
) (
    input  wire          clk,
    input  wire          we,     // write enable
    input  wire [AW-1:0] waddr,
    input  wire [   7:0] wdata,  // int8 activation
    input  wire [AW-1:0] raddr,
    output reg  [   7:0] rdata   // valide 1 cycle apres raddr
);

    reg [7:0] mem[0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule
