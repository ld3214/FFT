module data_sram_system #(
  parameter DW = 32,
  parameter AW = 9
)(
  input  wire          clk ,
  input  wire    [3:0]      bank_sel, // Bank Select (0 or 1)

  input  wire [AW-1:0] rd_addr_0,
  output wire [DW-1:0] rd_dout_0,
    input  wire [AW-1:0] rd_addr_1,
    output wire [DW-1:0] rd_dout_1,


    input wire [3:0] wen_sel,
    input wire       rd_pair_sel,  // 0: read from banks{0,1}, 1: read from banks{2,3}
    input  wire [AW-1:0] wr_addr_0,
    input  wire [DW-1:0] wr_din_0,

    input  wire [AW-1:0] wr_addr_1,
    input  wire [DW-1:0] wr_din_1

);

wire [DW-1:0] dout_0, dout_1, dout_2, dout_3;

wire [AW-1:0] addr_0,
              addr_1,
              addr_2,
              addr_3;
assign addr_0 = wen_sel[0] ? rd_addr_0 : wr_addr_0;
assign addr_1 = wen_sel[1] ? rd_addr_1 : wr_addr_1;
assign addr_2 = wen_sel[2] ? rd_addr_0 : wr_addr_0;
assign addr_3 = wen_sel[3] ? rd_addr_1 : wr_addr_1;

// Read output mux: select based on which bank pair is the read source.
// rd_pair_sel=0: read from banks {0,1}; rd_pair_sel=1: read from banks {2,3}.
assign rd_dout_0 = rd_pair_sel ? dout_2 : dout_0;
assign rd_dout_1 = rd_pair_sel ? dout_3 : dout_1;

  data_sram_wrapper #(
    .DW(DW),
    .AW(AW)
  ) u_sram_0 (
    .clk (clk ),
    .cen (bank_sel[0] ), // Select Bank 0
    .addr(addr_0),
    .din (wr_din_0 ),
    .wen (wen_sel[0] ),
    .dout(dout_0)
  );

  data_sram_wrapper #(
    .DW(DW),
    .AW(AW)
  ) u_sram_1 (
    .clk (clk ),
    .cen (bank_sel[1] ), // Select Bank 1
    .addr(addr_1),
    .din (wr_din_1 ),
    .wen (wen_sel[1] ),
    .dout(dout_1)
  );

    data_sram_wrapper #(
    .DW(DW),
    .AW(AW)
  ) u_sram_2 (
    .clk (clk ),
    .cen (bank_sel[2] ), // Select Bank 2
    .addr(addr_2),
    .din (wr_din_0 ),
    .wen (wen_sel[2] ),
    .dout(dout_2)
  );

  data_sram_wrapper #(
    .DW(DW),
    .AW(AW)
  ) u_sram_3 (
    .clk (clk ),
    .cen (bank_sel[3] ), // Select Bank 3
    .addr(addr_3),
    .din (wr_din_1 ),
    .wen (wen_sel[3] ),
    .dout(dout_3)
  );


endmodule