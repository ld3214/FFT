`include "tw_sram.v"
`timescale 1ns/1ps
`define DELAY #1
module sram_wrapper #(
  parameter DW = 32,
  parameter AW = 9
) (
  input  wire          clk ,
  input  wire          cen , // Chip Enable (active low)
  input  wire [AW-1:0] addr,
  input  wire [DW-1:0] din ,
  input  wire          wen , // Byte Write Enable (active low)
  output wire [DW-1:0] dout
);

  wire          cen_delayed ;
  wire          wen_delayed ;
  wire [AW-1:0] addr_delayed;
  wire [DW-1:0] din_delayed ;

  assign `DELAY cen_delayed  = cen;
  assign `DELAY wen_delayed  = wen;
  assign `DELAY addr_delayed = addr;
  assign `DELAY din_delayed  = din;

  wire [31:0] w_dout;
  assign dout = w_dout[DW-1:0];

  // Dummy Instantiation - replace with your vendor's macro
  tw_sram sram_inst (
    .CLK (clk         ),
    .CEN (cen_delayed ),
    .WEN (wen_delayed ),
    .A   (addr_delayed),
    .D   (din_delayed ),
    .EMA (3'b000      ),
    .RETN(1'b1        ),
    .Q   (w_dout      )
  );

endmodule
