//----------------------------------------------------------------------
//  SdfUnit_SRAM: Radix-2 SDF Unit with Twiddle from SRAM
//----------------------------------------------------------------------
//  Streaming Radix-2 single butterfly stage.
//  Delay feedback uses register-based DelayBuffer.
//  Twiddle factors read from external synchronous SRAM
//  (1-cycle read latency, aligned with bf_do pipeline).
//
//  For 1024-point FFT, 10 stages are cascaded with:
//    Stage  M     Delay   tw_addr = bf_count << (LOG_N - LOG_M)
//      1   1024    512
//      2    512    256
//      3    256    128
//      4    128     64
//      5     64     32
//      6     32     16
//      7     16      8
//      8      8      4
//      9      4      2
//     10      2      1   (no multiplication needed)
//----------------------------------------------------------------------
module SdfUnit_SRAM #(
    parameter   N = 1024,       //  Number of FFT Point
    parameter   M = 1024,       //  Stage Resolution (M = N, N/2, ..., 2)
    parameter   WIDTH = 16      //  Data Bit Length
)(
    input               clock,  //  Master Clock
    input               reset,  //  Active High Asynchronous Reset
    input               di_en,  //  Input Data Enable
    input   [WIDTH-1:0] di_re,  //  Input Data (Real)
    input   [WIDTH-1:0] di_im,  //  Input Data (Imag)
    output              do_en,  //  Output Data Enable
    output  [WIDTH-1:0] do_re,  //  Output Data (Real)
    output  [WIDTH-1:0] do_im,  //  Output Data (Imag)

    //  Twiddle SRAM Read Interface
    output  [9:0]       tw_addr,    //  Twiddle SRAM Address
    input   [WIDTH-1:0] tw_re,      //  Twiddle Real from SRAM (1-cycle latency)
    input   [WIDTH-1:0] tw_im       //  Twiddle Imag from SRAM (1-cycle latency)
);

//  log2 constant function
function integer log2;
    input integer x;
    integer value;
    begin
        value = x-1;
        for (log2=0; value>0; log2=log2+1)
            value = value>>1;
    end
endfunction

localparam  LOG_N = log2(N);    //  Bit Length of N
localparam  LOG_M = log2(M);    //  Bit Length of M

//----------------------------------------------------------------------
//  Internal Regs and Nets
//----------------------------------------------------------------------
reg [LOG_N-1:0] di_count;       //  Input Data Count

//  Butterfly
wire            bf_en;          //  Butterfly Add/Sub Enable
wire[WIDTH-1:0] bf_x0_re;
wire[WIDTH-1:0] bf_x0_im;
wire[WIDTH-1:0] bf_x1_re;
wire[WIDTH-1:0] bf_x1_im;
wire[WIDTH-1:0] bf_y0_re;
wire[WIDTH-1:0] bf_y0_im;
wire[WIDTH-1:0] bf_y1_re;
wire[WIDTH-1:0] bf_y1_im;
wire[WIDTH-1:0] db_di_re;
wire[WIDTH-1:0] db_di_im;
wire[WIDTH-1:0] db_do_re;
wire[WIDTH-1:0] db_do_im;
wire[WIDTH-1:0] bf_sp_re;      //  Single-Path Output (Real)
wire[WIDTH-1:0] bf_sp_im;      //  Single-Path Output (Imag)
reg             bf_sp_en;       //  Single-Path Enable
reg [LOG_N-1:0] bf_count;       //  Single-Path Count
wire            bf_start;
wire            bf_end;
reg [WIDTH-1:0] bf_do_re;
reg [WIDTH-1:0] bf_do_im;
reg             bf_do_en;

//  Twiddle & Multiplication
wire[LOG_N-1:0] tw_num;         //  Twiddle index for this stage
reg             mu_en;
wire[WIDTH-1:0] mu_a_re;
wire[WIDTH-1:0] mu_a_im;
wire[WIDTH-1:0] mu_m_re;
wire[WIDTH-1:0] mu_m_im;
reg [WIDTH-1:0] mu_do_re;
reg [WIDTH-1:0] mu_do_im;
reg             mu_do_en;

//----------------------------------------------------------------------
//  Input Counter
//----------------------------------------------------------------------
always @(posedge clock or posedge reset) begin
    if (reset) begin
        di_count <= {LOG_N{1'b0}};
    end else begin
        di_count <= di_en ? (di_count + 1'b1) : {LOG_N{1'b0}};
    end
end

//----------------------------------------------------------------------
//  Butterfly (Radix-2)
//----------------------------------------------------------------------
assign  bf_en = di_count[LOG_M-1];

assign  bf_x0_re = bf_en ? db_do_re : {WIDTH{1'bx}};
assign  bf_x0_im = bf_en ? db_do_im : {WIDTH{1'bx}};
assign  bf_x1_re = bf_en ? di_re : {WIDTH{1'bx}};
assign  bf_x1_im = bf_en ? di_im : {WIDTH{1'bx}};

Butterfly #(.WIDTH(WIDTH),.RH(0)) BF (
    .x0_re  (bf_x0_re  ),
    .x0_im  (bf_x0_im  ),
    .x1_re  (bf_x1_re  ),
    .x1_im  (bf_x1_im  ),
    .y0_re  (bf_y0_re  ),
    .y0_im  (bf_y0_im  ),
    .y1_re  (bf_y1_re  ),
    .y1_im  (bf_y1_im  )
);

DelayBuffer #(.DEPTH(2**(LOG_M-1)),.WIDTH(WIDTH)) DB (
    .clock  (clock      ),
    .di_re  (db_di_re   ),
    .di_im  (db_di_im   ),
    .do_re  (db_do_re   ),
    .do_im  (db_do_im   )
);

assign  db_di_re = bf_en ? bf_y1_re : di_re;
assign  db_di_im = bf_en ? bf_y1_im : di_im;
assign  bf_sp_re = bf_en ? bf_y0_re : db_do_re;
assign  bf_sp_im = bf_en ? bf_y0_im : db_do_im;

always @(posedge clock or posedge reset) begin
    if (reset) begin
        bf_sp_en <= 1'b0;
        bf_count <= {LOG_N{1'b0}};
    end else begin
        bf_sp_en <= bf_start ? 1'b1 : bf_end ? 1'b0 : bf_sp_en;
        bf_count <= bf_sp_en ? (bf_count + 1'b1) : {LOG_N{1'b0}};
    end
end
assign  bf_start = (di_count == (2**(LOG_M-1)-1));
assign  bf_end   = (bf_count == (2**LOG_N-1));

always @(posedge clock) begin
    bf_do_re <= bf_sp_re;
    bf_do_im <= bf_sp_im;
end

always @(posedge clock or posedge reset) begin
    if (reset) begin
        bf_do_en <= 1'b0;
    end else begin
        bf_do_en <= bf_sp_en;
    end
end

//----------------------------------------------------------------------
//  Twiddle Factor Address (to external SRAM)
//----------------------------------------------------------------------
//  Radix-2 twiddle address:
//    tw_addr = bf_count * (N/M) = bf_count << (LOG_N - LOG_M)
//
//  Timing: tw_addr driven combinationally from bf_count.
//    Cycle T  : bf_count valid → tw_addr valid → SRAM captures address
//    Cycle T+1: SRAM outputs tw_re/tw_im ; bf_do_re/im also valid
//    → tw data and bf_do are naturally aligned at T+1.
assign  tw_num  = bf_count << (LOG_N - LOG_M);
assign  tw_addr = tw_num[9:0];

//----------------------------------------------------------------------
//  Multiplication
//----------------------------------------------------------------------
//  Multiplication bypassed when twiddle address is 0 (W^0 = 1+j0)
always @(posedge clock) begin
    mu_en <= (tw_num != {LOG_N{1'b0}});
end

assign  mu_a_re = mu_en ? bf_do_re : {WIDTH{1'bx}};
assign  mu_a_im = mu_en ? bf_do_im : {WIDTH{1'bx}};

Multiply #(.WIDTH(WIDTH)) MU (
    .a_re   (mu_a_re),
    .a_im   (mu_a_im),
    .b_re   (tw_re  ),  //  From external SRAM (1-cycle latency aligned)
    .b_im   (tw_im  ),
    .m_re   (mu_m_re),
    .m_im   (mu_m_im)
);

always @(posedge clock) begin
    mu_do_re <= mu_en ? mu_m_re : bf_do_re;
    mu_do_im <= mu_en ? mu_m_im : bf_do_im;
end

always @(posedge clock or posedge reset) begin
    if (reset) begin
        mu_do_en <= 1'b0;
    end else begin
        mu_do_en <= bf_do_en;
    end
end

//----------------------------------------------------------------------
//  Output
//----------------------------------------------------------------------
//  No multiplication required at final stage (M=2)
assign  do_en = (LOG_M == 1) ? bf_do_en : mu_do_en;
assign  do_re = (LOG_M == 1) ? bf_do_re : mu_do_re;
assign  do_im = (LOG_M == 1) ? bf_do_im : mu_do_im;

endmodule
