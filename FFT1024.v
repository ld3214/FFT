//----------------------------------------------------------------------
//  FFT1024: 1024-Point FFT Using Radix-2 Single-Path Delay Feedback
//----------------------------------------------------------------------
//  10 cascaded Radix-2 SDF stages (M = 1024,512,...,2).
//  Twiddle factors stored in tw_sram (ARM IP, 1024x16, synchronous).
//  Each stage except stage 10 (M=2) has its own tw_sram pair (re+im).
//  All tw_sram share the same twiddle table, loaded via tw_init bus.
//
//  Data is input consecutively in natural order.
//  Result is scaled to 1/N and output in bit-reversed order.
//  Width = 16 bits (Q1.15 fixed-point)
//----------------------------------------------------------------------
module FFT1024 #(
    parameter   WIDTH = 16
)(
    input               clock,      //  Master Clock
    input               reset,      //  Active High Asynchronous Reset

    //  Data Interface
    input               di_en,      //  Input Data Enable
    input   [WIDTH-1:0] di_re,      //  Input Data (Real)
    input   [WIDTH-1:0] di_im,      //  Input Data (Imag)
    output              do_en,      //  Output Data Enable
    output  [WIDTH-1:0] do_re,      //  Output Data (Real)
    output  [WIDTH-1:0] do_im,      //  Output Data (Imag)

    //  Twiddle SRAM Initialization Interface
    //  Assert tw_init=1, then drive tw_init_addr/re/im to write
    //  twiddle factors into all tw_sram simultaneously.
    input               tw_init,        //  1=init mode, 0=FFT mode
    input   [9:0]       tw_init_addr,   //  Init write address (0..511)
    input   [WIDTH-1:0] tw_init_re,     //  Init write data (Real)
    input   [WIDTH-1:0] tw_init_im      //  Init write data (Imag)
);

//----------------------------------------------------------------------
//  Stage interconnects
//----------------------------------------------------------------------
wire            s1_do_en;
wire[WIDTH-1:0] s1_do_re;
wire[WIDTH-1:0] s1_do_im;

wire            s2_do_en;
wire[WIDTH-1:0] s2_do_re;
wire[WIDTH-1:0] s2_do_im;

wire            s3_do_en;
wire[WIDTH-1:0] s3_do_re;
wire[WIDTH-1:0] s3_do_im;

wire            s4_do_en;
wire[WIDTH-1:0] s4_do_re;
wire[WIDTH-1:0] s4_do_im;

wire            s5_do_en;
wire[WIDTH-1:0] s5_do_re;
wire[WIDTH-1:0] s5_do_im;

wire            s6_do_en;
wire[WIDTH-1:0] s6_do_re;
wire[WIDTH-1:0] s6_do_im;

wire            s7_do_en;
wire[WIDTH-1:0] s7_do_re;
wire[WIDTH-1:0] s7_do_im;

wire            s8_do_en;
wire[WIDTH-1:0] s8_do_re;
wire[WIDTH-1:0] s8_do_im;

wire            s9_do_en;
wire[WIDTH-1:0] s9_do_re;
wire[WIDTH-1:0] s9_do_im;

//----------------------------------------------------------------------
//  Twiddle SRAM wires (9 stages × addr/re/im)
//----------------------------------------------------------------------
wire [9:0]       s1_tw_addr, s2_tw_addr, s3_tw_addr, s4_tw_addr, s5_tw_addr;
wire [9:0]       s6_tw_addr, s7_tw_addr, s8_tw_addr, s9_tw_addr;
wire [WIDTH-1:0] s1_tw_re, s1_tw_im;
wire [WIDTH-1:0] s2_tw_re, s2_tw_im;
wire [WIDTH-1:0] s3_tw_re, s3_tw_im;
wire [WIDTH-1:0] s4_tw_re, s4_tw_im;
wire [WIDTH-1:0] s5_tw_re, s5_tw_im;
wire [WIDTH-1:0] s6_tw_re, s6_tw_im;
wire [WIDTH-1:0] s7_tw_re, s7_tw_im;
wire [WIDTH-1:0] s8_tw_re, s8_tw_im;
wire [WIDTH-1:0] s9_tw_re, s9_tw_im;

//----------------------------------------------------------------------
//  Twiddle SRAM address/control mux (init vs FFT)
//----------------------------------------------------------------------
wire [9:0]  tw1_addr  = tw_init ? tw_init_addr : s1_tw_addr;
wire [9:0]  tw2_addr  = tw_init ? tw_init_addr : s2_tw_addr;
wire [9:0]  tw3_addr  = tw_init ? tw_init_addr : s3_tw_addr;
wire [9:0]  tw4_addr  = tw_init ? tw_init_addr : s4_tw_addr;
wire [9:0]  tw5_addr  = tw_init ? tw_init_addr : s5_tw_addr;
wire [9:0]  tw6_addr  = tw_init ? tw_init_addr : s6_tw_addr;
wire [9:0]  tw7_addr  = tw_init ? tw_init_addr : s7_tw_addr;
wire [9:0]  tw8_addr  = tw_init ? tw_init_addr : s8_tw_addr;
wire [9:0]  tw9_addr  = tw_init ? tw_init_addr : s9_tw_addr;
wire        tw_wen    = tw_init ? 1'b0 : 1'b1;  //  0=write during init, 1=read during FFT

//----------------------------------------------------------------------
//  SDF Stages
//----------------------------------------------------------------------
SdfUnit_SRAM #(.N(1024),.M(1024),.WIDTH(WIDTH)) S1 (
    .clock(clock), .reset(reset),
    .di_en(di_en), .di_re(di_re), .di_im(di_im),
    .do_en(s1_do_en), .do_re(s1_do_re), .do_im(s1_do_im),
    .tw_addr(s1_tw_addr), .tw_re(s1_tw_re), .tw_im(s1_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(512),.WIDTH(WIDTH)) S2 (
    .clock(clock), .reset(reset),
    .di_en(s1_do_en), .di_re(s1_do_re), .di_im(s1_do_im),
    .do_en(s2_do_en), .do_re(s2_do_re), .do_im(s2_do_im),
    .tw_addr(s2_tw_addr), .tw_re(s2_tw_re), .tw_im(s2_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(256),.WIDTH(WIDTH)) S3 (
    .clock(clock), .reset(reset),
    .di_en(s2_do_en), .di_re(s2_do_re), .di_im(s2_do_im),
    .do_en(s3_do_en), .do_re(s3_do_re), .do_im(s3_do_im),
    .tw_addr(s3_tw_addr), .tw_re(s3_tw_re), .tw_im(s3_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(128),.WIDTH(WIDTH)) S4 (
    .clock(clock), .reset(reset),
    .di_en(s3_do_en), .di_re(s3_do_re), .di_im(s3_do_im),
    .do_en(s4_do_en), .do_re(s4_do_re), .do_im(s4_do_im),
    .tw_addr(s4_tw_addr), .tw_re(s4_tw_re), .tw_im(s4_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(64),.WIDTH(WIDTH)) S5 (
    .clock(clock), .reset(reset),
    .di_en(s4_do_en), .di_re(s4_do_re), .di_im(s4_do_im),
    .do_en(s5_do_en), .do_re(s5_do_re), .do_im(s5_do_im),
    .tw_addr(s5_tw_addr), .tw_re(s5_tw_re), .tw_im(s5_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(32),.WIDTH(WIDTH)) S6 (
    .clock(clock), .reset(reset),
    .di_en(s5_do_en), .di_re(s5_do_re), .di_im(s5_do_im),
    .do_en(s6_do_en), .do_re(s6_do_re), .do_im(s6_do_im),
    .tw_addr(s6_tw_addr), .tw_re(s6_tw_re), .tw_im(s6_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(16),.WIDTH(WIDTH)) S7 (
    .clock(clock), .reset(reset),
    .di_en(s6_do_en), .di_re(s6_do_re), .di_im(s6_do_im),
    .do_en(s7_do_en), .do_re(s7_do_re), .do_im(s7_do_im),
    .tw_addr(s7_tw_addr), .tw_re(s7_tw_re), .tw_im(s7_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(8),.WIDTH(WIDTH)) S8 (
    .clock(clock), .reset(reset),
    .di_en(s7_do_en), .di_re(s7_do_re), .di_im(s7_do_im),
    .do_en(s8_do_en), .do_re(s8_do_re), .do_im(s8_do_im),
    .tw_addr(s8_tw_addr), .tw_re(s8_tw_re), .tw_im(s8_tw_im)
);

SdfUnit_SRAM #(.N(1024),.M(4),.WIDTH(WIDTH)) S9 (
    .clock(clock), .reset(reset),
    .di_en(s8_do_en), .di_re(s8_do_re), .di_im(s8_do_im),
    .do_en(s9_do_en), .do_re(s9_do_re), .do_im(s9_do_im),
    .tw_addr(s9_tw_addr), .tw_re(s9_tw_re), .tw_im(s9_tw_im)
);

//  Stage 10: M=2, no twiddle multiplication needed
SdfUnit_SRAM #(.N(1024),.M(2),.WIDTH(WIDTH)) S10 (
    .clock(clock), .reset(reset),
    .di_en(s9_do_en), .di_re(s9_do_re), .di_im(s9_do_im),
    .do_en(do_en), .do_re(do_re), .do_im(do_im),
    .tw_addr(), .tw_re({WIDTH{1'b0}}), .tw_im({WIDTH{1'b0}})
);

//----------------------------------------------------------------------
//  Twiddle SRAM Instances (9 stages × 2 SRAMs = 18 tw_sram)
//  All loaded with the same 512-entry twiddle table.
//  Real parts in one SRAM, imaginary parts in the other.
//----------------------------------------------------------------------

//  Stage 1
tw_sram TW1_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw1_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s1_tw_re));
tw_sram TW1_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw1_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s1_tw_im));

//  Stage 2
tw_sram TW2_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw2_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s2_tw_re));
tw_sram TW2_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw2_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s2_tw_im));

//  Stage 3
tw_sram TW3_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw3_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s3_tw_re));
tw_sram TW3_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw3_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s3_tw_im));

//  Stage 4
tw_sram TW4_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw4_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s4_tw_re));
tw_sram TW4_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw4_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s4_tw_im));

//  Stage 5
tw_sram TW5_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw5_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s5_tw_re));
tw_sram TW5_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw5_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s5_tw_im));

//  Stage 6
tw_sram TW6_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw6_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s6_tw_re));
tw_sram TW6_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw6_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s6_tw_im));

//  Stage 7
tw_sram TW7_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw7_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s7_tw_re));
tw_sram TW7_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw7_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s7_tw_im));

//  Stage 8
tw_sram TW8_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw8_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s8_tw_re));
tw_sram TW8_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw8_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s8_tw_im));

//  Stage 9
tw_sram TW9_RE (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw9_addr), .D(tw_init_re), .EMA(3'b0), .RETN(1'b1), .Q(s9_tw_re));
tw_sram TW9_IM (.CLK(clock), .CEN(1'b0), .WEN(tw_wen), .A(tw9_addr), .D(tw_init_im), .EMA(3'b0), .RETN(1'b1), .Q(s9_tw_im));

endmodule
