//----------------------------------------------------------------------
//  FFT Top-Level  –  connects fft_ctr + data_sram_system + tw_sram
//----------------------------------------------------------------------
module fft_top #(
    parameter DW     = 32,
    parameter AW     = 9,
    parameter N      = 1024,
    parameter STAGES = 10
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire        done,

    // --- External load / readback interface ---
    // Active only when FFT is idle (before start or after done)
    input  wire        ext_wen,        // 1 = external write active
    input  wire        ext_rd_en,     // 1 = external read active
    input  wire [1:0]  ext_bank,       // which bank to write (0-3)
    input  wire [AW-1:0] ext_addr,
    input  wire [DW-1:0] ext_din,

    // Twiddle SRAM load interface
    input  wire        tw_ext_wen,     // 1 = external twiddle write
    input  wire [AW-1:0] tw_ext_addr,
    input  wire [DW-1:0] tw_ext_din,

    // Readback interface (directly peek into sram_system outputs)
    input  wire [AW-1:0] ext_rd_addr_0,
    input  wire [AW-1:0] ext_rd_addr_1,
    input  wire [1:0]    ext_rd_pair,  // 0: banks{0,1}, 1: banks{2,3}
    output wire [DW-1:0] ext_rd_dout_0,
    output wire [DW-1:0] ext_rd_dout_1
);

// ---- Wires between controller and data SRAM system ----
wire [3:0]    ctr_bank_sel;
wire [3:0]    ctr_wen_sel;
wire          ctr_rd_pair_sel;
wire [AW-1:0] ctr_rd_addr_0, ctr_rd_addr_1;
wire [AW-1:0] ctr_wr_addr_0, ctr_wr_addr_1;
wire [DW-1:0] ctr_wr_din_0,  ctr_wr_din_1;
wire [DW-1:0] rd_dout_0, rd_dout_1;

// ---- Wires between controller and twiddle SRAM ----
wire          ctr_tw_cen;
wire [AW-1:0] ctr_tw_addr;
wire [DW-1:0] tw_dout;

// ======================================================================
//  Mux: external vs external readback vs controller access
// ======================================================================

// Data SRAM signals
reg  [3:0]    mux_bank_sel;
reg  [3:0]    mux_wen_sel;
reg           mux_rd_pair_sel;
reg  [AW-1:0] mux_rd_addr_0, mux_rd_addr_1;
reg  [AW-1:0] mux_wr_addr_0, mux_wr_addr_1;
reg  [DW-1:0] mux_wr_din_0,  mux_wr_din_1;

always @(*) begin
    if (ext_wen) begin
        // 1. External write: 外部写模式 (加载数据)
        mux_bank_sel = 4'b1111;
        mux_wen_sel  = 4'b1111;
        mux_rd_pair_sel = 1'b0;
        mux_rd_addr_0 = {AW{1'b0}};
        mux_rd_addr_1 = {AW{1'b0}};
        mux_wr_addr_0 = ext_addr;
        mux_wr_addr_1 = ext_addr;
        mux_wr_din_0  = ext_din;
        mux_wr_din_1  = ext_din;
        // Enable only the target bank for write
        case (ext_bank)
            2'd0: begin mux_bank_sel = 4'b1110; mux_wen_sel = 4'b1110; end
            2'd1: begin mux_bank_sel = 4'b1101; mux_wen_sel = 4'b1101; end
            2'd2: begin mux_bank_sel = 4'b1011; mux_wen_sel = 4'b1011; end
            2'd3: begin mux_bank_sel = 4'b0111; mux_wen_sel = 4'b0111; end
        endcase
    end else if (ext_rd_en) begin
        // 2. External readback: 外部读模式 (FFT结束后，TB读取结果)
        // active-low: 0=enabled. pair0={bank0,1}, pair1={bank2,3}
        // ext_rd_pair=0 → enable banks 0,1 → bank_sel = 4'b1100
        // ext_rd_pair=1 → enable banks 2,3 → bank_sel = 4'b0011
        mux_bank_sel    = ext_rd_pair ? 4'b0011 : 4'b1100;
        mux_wen_sel     = 4'b1111; // 1 = read mode for all banks
        mux_rd_pair_sel = ext_rd_pair;
        mux_rd_addr_0   = ext_rd_addr_0;
        mux_rd_addr_1   = ext_rd_addr_1;
        mux_wr_addr_0   = {AW{1'b0}};
        mux_wr_addr_1   = {AW{1'b0}};
        mux_wr_din_0    = {DW{1'b0}};
        mux_wr_din_1    = {DW{1'b0}};
    end else begin
        // 3. Controller drives: FFT运算模式
        mux_bank_sel    = ctr_bank_sel;
        mux_wen_sel     = ctr_wen_sel;
        mux_rd_pair_sel = ctr_rd_pair_sel;
        mux_rd_addr_0   = ctr_rd_addr_0;
        mux_rd_addr_1   = ctr_rd_addr_1;
        mux_wr_addr_0   = ctr_wr_addr_0;
        mux_wr_addr_1   = ctr_wr_addr_1;
        mux_wr_din_0    = ctr_wr_din_0;
        mux_wr_din_1    = ctr_wr_din_1;
    end
end

// Twiddle SRAM signals
wire        tw_cen;
wire [AW-1:0] tw_addr;
wire [DW-1:0] tw_din;
wire        tw_wen;

assign tw_cen  = tw_ext_wen ? 1'b0      : ctr_tw_cen;
assign tw_addr = tw_ext_wen ? tw_ext_addr : ctr_tw_addr;
assign tw_din  = tw_ext_wen ? tw_ext_din  : {DW{1'b0}};
assign tw_wen  = tw_ext_wen ? 1'b0      : 1'b1;  // active-low: 0=write, 1=read

// ======================================================================
//  Instantiate data SRAM system
// ======================================================================
data_sram_system #(.DW(DW), .AW(AW)) u_data_sram (
    .clk        (clk),
    .bank_sel   (mux_bank_sel),
    .rd_addr_0  (mux_rd_addr_0),
    .rd_dout_0  (rd_dout_0),
    .rd_addr_1  (mux_rd_addr_1),
    .rd_dout_1  (rd_dout_1),
    .wen_sel    (mux_wen_sel),
    .rd_pair_sel(mux_rd_pair_sel),
    .wr_addr_0  (mux_wr_addr_0),
    .wr_din_0   (mux_wr_din_0),
    .wr_addr_1  (mux_wr_addr_1),
    .wr_din_1   (mux_wr_din_1)
);

assign ext_rd_dout_0 = rd_dout_0;
assign ext_rd_dout_1 = rd_dout_1;

// ======================================================================
//  Instantiate twiddle SRAM
// ======================================================================
tw_sram_wrapper #(.DW(DW), .AW(AW)) u_tw_sram (
    .clk  (clk),
    .cen  (tw_cen),
    .addr (tw_addr),
    .din  (tw_din),
    .wen  (tw_wen),
    .dout (tw_dout)
);

// ======================================================================
//  Instantiate FFT controller
// ======================================================================
fft_ctr #(
    .DW(DW), .AW(AW), .N(N), .STAGES(STAGES)
) u_fft_ctr (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (start),
    .bank_sel    (ctr_bank_sel),
    .wen_sel     (ctr_wen_sel),
    .rd_pair_sel (ctr_rd_pair_sel),
    .rd_addr_0   (ctr_rd_addr_0),
    .rd_addr_1   (ctr_rd_addr_1),
    .wr_addr_0   (ctr_wr_addr_0),
    .wr_addr_1   (ctr_wr_addr_1),
    .wr_din_0    (ctr_wr_din_0),
    .wr_din_1    (ctr_wr_din_1),
    .rd_dout_0   (rd_dout_0),
    .rd_dout_1   (rd_dout_1),
    .tw_cen      (ctr_tw_cen),
    .tw_addr     (ctr_tw_addr),
    .tw_dout     (tw_dout),
    .done        (done)
);

endmodule