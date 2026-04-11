//----------------------------------------------------------------------
//  FFT Controller  –  1024-point Radix-2 DIF
//      • 4-bank ping-pong data SRAM (each 512×32, single-port)
//      • 1-bank twiddle SRAM (512×32)
//      • XOR-bit banking: bank = XOR(all 10 index bits), addr = index[8:0]
//      • Pipeline: RD → BF/MUL → WR  (3-stage, 1 butterfly/cycle steady)
//
//  Data loading convention (before asserting 'start'):
//      For input point p (0..1023, real-only):
//          bank = ^{p[9:0]}         (reduction XOR of all 10 bits)
//          addr = p[8:0]
//          data = {x_re[15:0], 16'h0000}
//      Points with parity=0 go to bank 0, parity=1 go to bank 1.
//      Banks 2 & 3 are the initial write-side (no pre-load needed).
//
//  After completion (done=1), results are in the last-written bank pair.
//  Result layout: same XOR banking, data = {Y_re, Y_im} in 
//  bit-reversed order (standard DIF output).
//----------------------------------------------------------------------
module fft_ctr #(
    parameter DW    = 32,       // data width (16-bit re + 16-bit im)
    parameter AW    = 9,        // SRAM address width (512 words)
    parameter N     = 1024,     // FFT length
    parameter STAGES= 10        // log2(N)
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,      // pulse to begin FFT

    // ---------- data SRAM system ----------
    output reg  [3:0]        bank_sel,   // chip-enable per bank (active-low)
    output reg  [3:0]        wen_sel,    // write-enable per bank (active-low)
    output reg               rd_pair_sel,// 0: read from {0,1}; 1: read from {2,3} (registered)
    output reg  [AW-1:0]     rd_addr_0,
    output reg  [AW-1:0]     rd_addr_1,
    output reg  [AW-1:0]     wr_addr_0,
    output reg  [AW-1:0]     wr_addr_1,
    output reg  [DW-1:0]     wr_din_0,
    output reg  [DW-1:0]     wr_din_1,
    input  wire [DW-1:0]     rd_dout_0,  // read data from bank-pair port 0
    input  wire [DW-1:0]     rd_dout_1,  // read data from bank-pair port 1

    // ---------- twiddle SRAM ----------
    output reg               tw_cen,     // active-low chip enable
    output reg  [AW-1:0]     tw_addr,
    input  wire [DW-1:0]     tw_dout,    // {tw_re[15:0], tw_im[15:0]}

    // ---------- status ----------
    output reg               done        // pulse when FFT complete
);

// ======================================================================
//  Internal signals
// ======================================================================

// --- FSM ---
localparam S_IDLE   = 3'd0,
           S_RUN    = 3'd1,
           S_WAIT   = 3'd2,  // flush pipeline between stages
           S_FLUSH  = 3'd3,  // flush pipeline after last stage
           S_DONE   = 3'd4;

reg  [2:0]  state, nxt_state;
reg  [3:0]  stage_cnt;       // current FFT stage (0..9)
reg  [8:0]  bf_cnt;          // butterfly counter within stage (0..511)
reg         ping;            // 0: read from {0,1}, write to {2,3}; 1: swap
reg  [1:0]  wait_cnt;        // counts flush cycles between stages

// --- pipeline registers (3-stage: RD / MUL / WR) ---
// Stage 1 → 2  (after SRAM read latency)
reg         p1_valid;
reg  [3:0]  p1_stage;
reg  [8:0]  p1_bf;
reg         p1_swap;         // need to swap rd_dout_0/1 for butterfly order
reg         p1_ping;

// Stage 2 → 3  (after multiply, before write)
reg         p2_valid;
reg  [3:0]  p2_stage;
reg  [8:0]  p2_bf;
reg         p2_ping;
// Butterfly + multiply results
reg  signed [15:0] p2_y0_re, p2_y0_im;
reg  signed [15:0] p2_y1_re, p2_y1_im;
// Write address & bank info
reg  [AW-1:0] p2_wr_addr_0, p2_wr_addr_1;
reg            p2_wr_swap;   // which dest bank gets y0 vs y1

// --- Read data after swap ---
wire signed [15:0] x0_re, x0_im, x1_re, x1_im;

// --- Twiddle pipeline ---
reg  signed [15:0] p2_tw_re, p2_tw_im;

// --- Butterfly outputs ---
wire signed [15:0] bf_y0_re, bf_y0_im, bf_y1_re, bf_y1_im;

// --- Multiply outputs ---
wire signed [15:0] mul_re, mul_im;

// ======================================================================
//  Helper: parity (XOR of all 10 bits) — determines bank select
// ======================================================================
function [0:0] parity10;
    input [9:0] idx;
    parity10 = ^idx;   // reduction XOR
endfunction

// ======================================================================
//  Address generation combinational logic
// ======================================================================
// For stage s, butterfly bf (0..511):
//   a_idx = bf with '0' inserted at bit position (9-s) in a 10-bit field
//   b_idx = a_idx | (1 << (9-s))
//
// Read address = index[8:0]
// Bank select  = parity of all 10 index bits

reg [9:0] a_idx_comb, b_idx_comb;
reg [8:0] tw_idx_comb;
reg       a_bank_comb, b_bank_comb;    // XOR-parity bank assignment
reg       swap_comb;                    // 1 if a is in bank 1 (need swap)

always @(*) begin : addr_gen
    reg [3:0] sbit;     // bit position = 9 - stage_cnt
    reg [9:0] lo, hi;
    sbit = 4'd9 - stage_cnt;

    // insert 0 at bit position sbit
    lo = bf_cnt & ((1 << sbit) - 1);               // bits below sbit
    hi = ({1'b0, bf_cnt} >> sbit) << (sbit + 1);   // bits above sbit, shifted up (10-bit to avoid overflow)
    a_idx_comb = hi[9:0] | lo[9:0];                // bit sbit = 0
    b_idx_comb = a_idx_comb | (10'd1 << sbit);     // bit sbit = 1

    // Bank assignment via parity
    a_bank_comb = parity10(a_idx_comb);
    b_bank_comb = parity10(b_idx_comb);  // always = ~a_bank_comb

    // If a is in bank 1, we need to swap the read outputs
    swap_comb = a_bank_comb;   // 0 → a in bank0(normal), 1 → a in bank1(swap)

    // Twiddle index
    tw_idx_comb = (bf_cnt & ((9'd1 << sbit) - 9'd1)) << stage_cnt;
end

// ======================================================================
//  Write address generation (for pipeline stage outputting results)
//  Computed from p1 butterfly info (available when p1 is valid)
// ======================================================================
reg [9:0]  p1_a_idx, p1_b_idx;
reg        p1_a_bank, p1_b_bank;

always @(*) begin : wr_addr_gen
    reg [3:0] sbit;
    reg [9:0] lo, hi;
    sbit = 4'd9 - p1_stage;

    lo = p1_bf & ((1 << sbit) - 1);
    hi = ({1'b0, p1_bf} >> sbit) << (sbit + 1);
    p1_a_idx = hi[9:0] | lo[9:0];
    p1_b_idx = p1_a_idx | (10'd1 << sbit);

    p1_a_bank = parity10(p1_a_idx);
    p1_b_bank = parity10(p1_b_idx);
end

// ======================================================================
//  Read data swap (butterfly x0 = operand A, x1 = operand B)
// ======================================================================
// p1_swap was registered; when SRAM data comes back, swap if needed.
// SRAM has 1-cycle read latency, so rd_dout is valid when p1 is valid.
assign x0_re = p1_swap ? rd_dout_1[31:16] : rd_dout_0[31:16];
assign x0_im = p1_swap ? rd_dout_1[15:0]  : rd_dout_0[15:0];
assign x1_re = p1_swap ? rd_dout_0[31:16] : rd_dout_1[31:16];
assign x1_im = p1_swap ? rd_dout_0[15:0]  : rd_dout_1[15:0];

// ======================================================================
//  Butterfly (Add/Sub with >>1 scaling)
// ======================================================================
Butterfly #(.WIDTH(16), .RH(0)) u_bf (
    .x0_re(x0_re), .x0_im(x0_im),
    .x1_re(x1_re), .x1_im(x1_im),
    .y0_re(bf_y0_re), .y0_im(bf_y0_im),
    .y1_re(bf_y1_re), .y1_im(bf_y1_im)
);

// ======================================================================
//  Complex Multiply (y1 * twiddle)
//  Both p2_y1 and p2_tw are registered from the same pipeline stage,
//  so the multiplier output is valid combinationally in the p2 cycle.
// ======================================================================
Multiply #(.WIDTH(16)) u_mul (
    .a_re(p2_y1_re), .a_im(p2_y1_im),
    .b_re(p2_tw_re),  .b_im(p2_tw_im),
    .m_re(mul_re),    .m_im(mul_im)
);

// ======================================================================
//  FSM
// ======================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= S_IDLE;
    else
        state <= nxt_state;
end

always @(*) begin
    nxt_state = state;
    case (state)
        S_IDLE:  if (start)      nxt_state = S_RUN;
        S_RUN:   if (bf_cnt == 9'd511) begin
                     if (stage_cnt == STAGES-1)
                         nxt_state = S_FLUSH;
                     else
                         nxt_state = S_WAIT;
                 end
        S_WAIT:  if (wait_cnt == 2'd2)
                                 nxt_state = S_RUN;
        S_FLUSH: if (!p1_valid && !p2_valid)
                                 nxt_state = S_DONE;
        S_DONE:                  nxt_state = S_IDLE;
        default:                 nxt_state = S_IDLE;
    endcase
end

// ======================================================================
//  Stage & butterfly counters
// ======================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stage_cnt <= 4'd0;
        bf_cnt    <= 9'd0;
        ping      <= 1'b0;
        wait_cnt  <= 2'd0;
    end else if (state == S_IDLE && start) begin
        stage_cnt <= 4'd0;
        bf_cnt    <= 9'd0;
        ping      <= 1'b0;
        wait_cnt  <= 2'd0;
    end else if (state == S_RUN) begin
        if (bf_cnt == 9'd511) begin
            bf_cnt   <= 9'd0;
            wait_cnt <= 2'd0;
        end else begin
            bf_cnt <= bf_cnt + 9'd1;
        end
    end else if (state == S_WAIT) begin
        wait_cnt <= wait_cnt + 2'd1;
        if (wait_cnt == 2'd2) begin
            // Pipeline fully drained — safe to switch banks
            stage_cnt <= stage_cnt + 4'd1;
            ping      <= ~ping;
        end
    end
end

// ======================================================================
//  Pipeline stage 0 → 1: Issue read addresses & twiddle address
// ======================================================================
wire rd_issue = (state == S_RUN);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p1_valid    <= 1'b0;
        p1_stage    <= 4'd0;
        p1_bf       <= 9'd0;
        p1_swap     <= 1'b0;
        p1_ping     <= 1'b0;
        rd_pair_sel <= 1'b0;
    end else begin
        p1_valid <= rd_issue;
        if (rd_issue) begin
            p1_stage    <= stage_cnt;
            p1_bf       <= bf_cnt;
            p1_swap     <= swap_comb;
            p1_ping     <= ping;
            rd_pair_sel <= ping;  // select read pair for next cycle's data
        end else begin
            rd_pair_sel <= 1'b0;
        end
    end
end

// Read address outputs (active when state == S_RUN)
// Bank with parity=0 uses rd_addr_0, bank with parity=1 uses rd_addr_1
// a has lower parity value determined by swap_comb
always @(*) begin
    if (rd_issue) begin
        if (!swap_comb) begin
            // a in bank0 (port 0), b in bank1 (port 1)
            rd_addr_0 = a_idx_comb[8:0];
            rd_addr_1 = b_idx_comb[8:0];
        end else begin
            // a in bank1 (port 1), b in bank0 (port 0)
            rd_addr_0 = b_idx_comb[8:0];
            rd_addr_1 = a_idx_comb[8:0];
        end
        tw_addr = tw_idx_comb;
        tw_cen  = 1'b0;  // active low — enable
    end else begin
        rd_addr_0 = {AW{1'b0}};
        rd_addr_1 = {AW{1'b0}};
        tw_addr   = {AW{1'b0}};
        tw_cen    = 1'b1;  // disabled
    end
end

// ======================================================================
//  Pipeline stage 1 → 2: Capture twiddle, compute butterfly & multiply
// ======================================================================
// Twiddle arrives 1 cycle after address is issued (same cycle as p1_valid)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p2_tw_re <= 16'd0;
        p2_tw_im <= 16'd0;
    end else if (p1_valid) begin
        p2_tw_re <= tw_dout[31:16];
        p2_tw_im <= tw_dout[15:0];
    end
end

// The butterfly is combinational; the multiply needs the twiddle which 
// arrives in the same cycle as p1_valid data. We register the butterfly
// y0 directly, and y1 goes through the multiplier in the SAME cycle
// (combinational multiply). Results are captured in p2.

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        p2_valid    <= 1'b0;
        p2_stage    <= 4'd0;
        p2_bf       <= 9'd0;
        p2_ping     <= 1'b0;
        p2_y0_re    <= 16'd0;
        p2_y0_im    <= 16'd0;
        p2_y1_re    <= 16'd0;
        p2_y1_im    <= 16'd0;
        p2_wr_addr_0<= {AW{1'b0}};
        p2_wr_addr_1<= {AW{1'b0}};
        p2_wr_swap  <= 1'b0;
    end else begin
        p2_valid <= p1_valid;
        if (p1_valid) begin
            p2_stage <= p1_stage;
            p2_bf    <= p1_bf;
            p2_ping  <= p1_ping;

            // Butterfly result (combinational from rd_dout in this cycle)
            p2_y0_re <= bf_y0_re;
            p2_y0_im <= bf_y0_im;

            // y1 is registered; multiply with twiddle happens next cycle
            // (combinational from p2_y1 and p2_tw, both registered)
            p2_y1_re <= bf_y1_re;
            p2_y1_im <= bf_y1_im;

            // Write address: y0 goes to bank with parity of a_idx
            //                y1 goes to bank with parity of b_idx
            // Bank with lower parity → port 0
            if (!p1_a_bank) begin
                // y0 → dest port 0, y1 → dest port 1
                p2_wr_addr_0 <= p1_a_idx[8:0];
                p2_wr_addr_1 <= p1_b_idx[8:0];
                p2_wr_swap   <= 1'b0;
            end else begin
                // y0 → dest port 1, y1 → dest port 0
                p2_wr_addr_0 <= p1_b_idx[8:0];
                p2_wr_addr_1 <= p1_a_idx[8:0];
                p2_wr_swap   <= 1'b1;
            end
        end
    end
end

// ======================================================================
//  Pipeline stage 2: Multiply (combinational) and Write
// ======================================================================
// The multiplier uses p2_y1 and p2_tw (both registered), so output is
// purely combinational from registered values → available same cycle.
// We wire the multiply result directly to the write data mux.

wire signed [15:0] final_y1_re = mul_re;
wire signed [15:0] final_y1_im = mul_im;

// ======================================================================
//  Bank select & write-enable generation
// ======================================================================
always @(*) begin
    // Default: all banks disabled (active-low: 1 = disabled)
    bank_sel    = 4'b1111;
    wen_sel     = 4'b1111;
    wr_addr_0   = {AW{1'b0}};
    wr_addr_1   = {AW{1'b0}};
    wr_din_0    = {DW{1'b0}};
    wr_din_1    = {DW{1'b0}};

    // --- Read bank enable ---
    if (rd_issue) begin
        if (!ping) begin
            // read from banks 0,1
            bank_sel[0] = 1'b0;  // enable bank 0
            bank_sel[1] = 1'b0;  // enable bank 1
        end else begin
            // read from banks 2,3
            bank_sel[2] = 1'b0;
            bank_sel[3] = 1'b0;
        end
    end

    // --- Write bank enable & data ---
    if (p2_valid) begin
        if (!p2_ping) begin
            // write to banks 2,3
            bank_sel[2] = 1'b0;
            bank_sel[3] = 1'b0;
            wen_sel[2]  = 1'b0;  // enable write
            wen_sel[3]  = 1'b0;
        end else begin
            // write to banks 0,1
            bank_sel[0] = 1'b0;
            bank_sel[1] = 1'b0;
            wen_sel[0]  = 1'b0;
            wen_sel[1]  = 1'b0;
        end

        if (!p2_wr_swap) begin
            // y0 → port 0, y1 → port 1
            wr_addr_0 = p2_wr_addr_0;
            wr_addr_1 = p2_wr_addr_1;
            wr_din_0  = {p2_y0_re, p2_y0_im};
            wr_din_1  = {final_y1_re, final_y1_im};
        end else begin
            // y1 → port 0, y0 → port 1
            wr_addr_0 = p2_wr_addr_0;
            wr_addr_1 = p2_wr_addr_1;
            wr_din_0  = {final_y1_re, final_y1_im};
            wr_din_1  = {p2_y0_re, p2_y0_im};
        end
    end
end

// ======================================================================
//  Done signal
// ======================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        done <= 1'b0;
    else
        done <= (state == S_DONE);
end

endmodule