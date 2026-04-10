//----------------------------------------------------------------------
//  SdfUnit_Radix2: Radix-2 Single-Path Delay Feedback Unit for N-Point FFT
//----------------------------------------------------------------------
module SdfUnit_Radix2 #(
    parameter   N = 64,     //  Number of FFT Point
    parameter   M = 64,     //  Twiddle Resolution
    parameter   WIDTH = 16  //  Data Bit Length
)(
    input               clock,  //  Master Clock
    input               reset,  //  Active High Asynchronous Reset
    input               di_en,  //  Input Data Enable
    input   [WIDTH-1:0] di_re,  //  Input Data (Real)
    input   [WIDTH-1:0] di_im,  //  Input Data (Imag)
    output              do_en,  //  Output Data Enable
    output  [WIDTH-1:0] do_re,  //  Output Data (Real)
    output  [WIDTH-1:0] do_im   //  Output Data (Imag)
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
//  Input Counter
reg [LOG_N-1:0] di_count;   //  Input Data Count

//  Butterfly Stage
wire            bf_en;      //  Butterfly Enable
wire[WIDTH-1:0] bf_x0_re;   //  Data #0 to Butterfly (Real)
wire[WIDTH-1:0] bf_x0_im;   //  Data #0 to Butterfly (Imag)
wire[WIDTH-1:0] bf_x1_re;   //  Data #1 to Butterfly (Real)
wire[WIDTH-1:0] bf_x1_im;   //  Data #1 to Butterfly (Imag)
wire[WIDTH-1:0] bf_y0_re;   //  Data #0 from Butterfly (Real)
wire[WIDTH-1:0] bf_y0_im;   //  Data #0 from Butterfly (Imag)
wire[WIDTH-1:0] bf_y1_re;   //  Data #1 from Butterfly (Real)
wire[WIDTH-1:0] bf_y1_im;   //  Data #1 from Butterfly (Imag)

//  Delay Buffer Stage
wire[WIDTH-1:0] db_di_re;   //  Data to DelayBuffer (Real)
wire[WIDTH-1:0] db_di_im;   //  Data to DelayBuffer (Imag)
wire[WIDTH-1:0] db_do_re;   //  Data from DelayBuffer (Real)
wire[WIDTH-1:0] db_do_im;   //  Data from DelayBuffer (Imag)

//  Single-Path Output
wire[WIDTH-1:0] sp_re;      //  Single-Path Data Output (Real)
wire[WIDTH-1:0] sp_im;      //  Single-Path Data Output (Imag)
reg             sp_en;      //  Single-Path Data Enable
reg [LOG_N-1:0] sp_count;   //  Single-Path Data Count

//  Control Signals
wire            bf_start;   //  Single-Path Output Trigger
wire            bf_end;     //  End of Single-Path Data
wire            bf_mj;      //  Twiddle (-j) Enable (optional)

//  Output from Butterfly
reg [WIDTH-1:0] bf_do_re;   //  Butterfly Output Data (Real)
reg [WIDTH-1:0] bf_do_im;   //  Butterfly Output Data (Imag)

//  Multiplication (Twiddle Factor)
wire[LOG_N-2:0] tw_num;     //  Twiddle Number (n)
wire[LOG_N-1:0] tw_addr;    //  Twiddle Table Address
wire[WIDTH-1:0] tw_re;      //  Twiddle Factor (Real)
wire[WIDTH-1:0] tw_im;      //  Twiddle Factor (Imag)
reg             mu_en;      //  Multiplication Enable
wire[WIDTH-1:0] mu_a_re;    //  Multiplier Input (Real)
wire[WIDTH-1:0] mu_a_im;    //  Multiplier Input (Imag)
wire[WIDTH-1:0] mu_m_re;    //  Multiplier Output (Real)
wire[WIDTH-1:0] mu_m_im;    //  Multiplier Output (Imag)
reg [WIDTH-1:0] mu_do_re;   //  Multiplication Output Data (Real)
reg [WIDTH-1:0] mu_do_im;   //  Multiplication Output Data (Imag)
reg             mu_do_en;   //  Multiplication Output Data Enable

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
//  Butterfly Control and Data Selection
//----------------------------------------------------------------------
//  Butterfly Enable: Toggle at M/2 boundary
assign  bf_en = di_count[LOG_M-1];

//  Set unknown value x for verification
assign  bf_x0_re = bf_en ? db_do_re : {WIDTH{1'bx}};
assign  bf_x0_im = bf_en ? db_do_im : {WIDTH{1'bx}};
assign  bf_x1_re = bf_en ? di_re : {WIDTH{1'bx}};
assign  bf_x1_im = bf_en ? di_im : {WIDTH{1'bx}};

//  Butterfly: Simple Radix-2 Add/Sub
Butterfly #(.WIDTH(WIDTH),.RH(0)) BF (
    .x0_re  (bf_x0_re  ),  //  i
    .x0_im  (bf_x0_im  ),  //  i
    .x1_re  (bf_x1_re  ),  //  i
    .x1_im  (bf_x1_im  ),  //  i
    .y0_re  (bf_y0_re  ),  //  o: y0 = x0 + x1
    .y0_im  (bf_y0_im  ),  //  o
    .y1_re  (bf_y1_re  ),  //  o: y1 = x0 - x1
    .y1_im  (bf_y1_im  )   //  o
);

//----------------------------------------------------------------------
//  Delay Buffer
//----------------------------------------------------------------------
//  Depth = M/2 for Radix-2
DelayBuffer #(.DEPTH(2**(LOG_M-1)),.WIDTH(WIDTH)) DB (
    .clock  (clock      ),  //  i
    .di_re  (db_di_re   ),  //  i
    .di_im  (db_di_im   ),  //  i
    .do_re  (db_do_re   ),  //  o
    .do_im  (db_do_im   )   //  o
);

//  Delay buffer input: feedback or input
assign  db_di_re = bf_en ? bf_y1_re : di_re;
assign  db_di_im = bf_en ? bf_y1_im : di_im;

//----------------------------------------------------------------------
//  Single-Path Output with Optional -j Modulation
//----------------------------------------------------------------------
//  Optional: Apply -j factor at specific cycles (for higher radix simulation)
assign  bf_mj = (sp_count[LOG_M-1:LOG_M-2] == 2'd3);

//  Single-path output: Butterfly result or delayed data
assign  sp_re = bf_en ? bf_y0_re : (bf_mj ? db_do_im : db_do_re);
assign  sp_im = bf_en ? bf_y0_im : (bf_mj ? -db_do_re : db_do_im);

//----------------------------------------------------------------------
//  Single-Path Counter Control
//----------------------------------------------------------------------
always @(posedge clock or posedge reset) begin
    if (reset) begin
        sp_en <= 1'b0;
        sp_count <= {LOG_N{1'b0}};
    end else begin
        sp_en <= bf_start ? 1'b1 : bf_end ? 1'b0 : sp_en;
        sp_count <= sp_en ? (sp_count + 1'b1) : {LOG_N{1'b0}};
    end
end

//  Start when first M/2 inputs are received
assign  bf_start = (di_count == (2**(LOG_M-1)-1));

//  End when all N outputs are sent
assign  bf_end = (sp_count == (2**LOG_N-1));

//  Register butterfly output
always @(posedge clock) begin
    bf_do_re <= sp_re;
    bf_do_im <= sp_im;
end

//----------------------------------------------------------------------
//  Twiddle Factor Multiplication
//----------------------------------------------------------------------
//  Twiddle address calculation for Radix-2
assign  tw_num = sp_count;
assign  tw_addr = tw_num;  //  Direct mapping for Radix-2

Twiddle TW (
    .clock  (clock  ),  //  i
    .addr   (tw_addr),  //  i
    .tw_re  (tw_re  ),  //  o
    .tw_im  (tw_im  )   //  o
);

//  Multiplication enable when address is not zero
always @(posedge clock) begin
    mu_en <= (tw_addr != {LOG_N{1'b0}});
end

//  Set unknown value x for verification
assign  mu_a_re = mu_en ? bf_do_re : {WIDTH{1'bx}};
assign  mu_a_im = mu_en ? bf_do_im : {WIDTH{1'bx}};

//  Complex Multiplier
Multiply #(.WIDTH(WIDTH)) MU (
    .a_re   (mu_a_re),  //  i
    .a_im   (mu_a_im),  //  i
    .b_re   (tw_re  ),  //  i
    .b_im   (tw_im  ),  //  i
    .m_re   (mu_m_re),  //  o
    .m_im   (mu_m_im)   //  o
);

//  Multiply output: use result if enabled, else pass through
always @(posedge clock) begin
    mu_do_re <= mu_en ? mu_m_re : bf_do_re;
    mu_do_im <= mu_en ? mu_m_im : bf_do_im;
end

//  Output data enable
always @(posedge clock or posedge reset) begin
    if (reset) begin
        mu_do_en <= 1'b0;
    end else begin
        mu_do_en <= sp_en;
    end
end

//----------------------------------------------------------------------
//  Final Output
//----------------------------------------------------------------------
//  No multiplication required at final stage (M=2)
assign  do_en = (LOG_M == 2) ? sp_en : mu_do_en;
assign  do_re = (LOG_M == 2) ? bf_do_re : mu_do_re;
assign  do_im = (LOG_M == 2) ? bf_do_im : mu_do_im;

endmodule
