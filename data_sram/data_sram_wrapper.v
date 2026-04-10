`include "data_sram.v"
`timescale 1ns/1ps
`define DELAY #1
module data_sram_wrapper #(
  parameter DW = 32,
  parameter AW = 10
) (
  // Port A
  input  wire          clka ,
  input  wire          cena , // Chip Enable A (active low)
  input  wire          wena , // Write Enable A (active low)
  input  wire [AW-1:0] addra,
  input  wire [DW-1:0] dina ,
  output wire [DW-1:0] douta,
  // Port B
  input  wire          clkb ,
  input  wire          cenb , // Chip Enable B (active low)
  input  wire          wenb , // Write Enable B (active low)
  input  wire [AW-1:0] addrb,
  input  wire [DW-1:0] dinb ,
  output wire [DW-1:0] doutb
);

  // Port A delayed signals
  wire          cena_delayed ;
  wire          wena_delayed ;
  wire [AW-1:0] addra_delayed;
  wire [DW-1:0] dina_delayed ;

  assign `DELAY cena_delayed  = cena;
  assign `DELAY wena_delayed  = wena;
  assign `DELAY addra_delayed = addra;
  assign `DELAY dina_delayed  = dina;

  // Port B delayed signals
  wire          cenb_delayed ;
  wire          wenb_delayed ;
  wire [AW-1:0] addrb_delayed;
  wire [DW-1:0] dinb_delayed ;

  assign `DELAY cenb_delayed  = cenb;
  assign `DELAY wenb_delayed  = wenb;
  assign `DELAY addrb_delayed = addrb;
  assign `DELAY dinb_delayed  = dinb;

  wire [31:0] w_douta;
  wire [31:0] w_doutb;
  assign douta = w_douta[DW-1:0];
  assign doutb = w_doutb[DW-1:0];

  // Dual-Port SRAM Instantiation
  data_sram sram_inst (
    .CLKA (clka          ),
    .CENA (cena_delayed  ),
    .WENA (wena_delayed  ),
    .AA   (addra_delayed ),
    .DA   (dina_delayed  ),
    .QA   (w_douta       ),
    .EMAA (3'b000        ),
    .CLKB (clkb          ),
    .CENB (cenb_delayed  ),
    .WENB (wenb_delayed  ),
    .AB   (addrb_delayed ),
    .DB   (dinb_delayed  ),
    .QB   (w_doutb       ),
    .EMAB (3'b000        ),
    .RETN (1'b1          )
  );

endmodule