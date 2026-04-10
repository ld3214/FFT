//----------------------------------------------------------------------
//  TB_FFT1024: Testbench for 1024-Point Radix-2 SDF FFT
//----------------------------------------------------------------------
`timescale 1ns/1ps

module TB_FFT1024;

parameter   WIDTH = 16;
parameter   N     = 1024;

//  Clock & Reset
reg             clock;
reg             reset;

//  FFT I/O
reg             di_en;
reg  [WIDTH-1:0] di_re;
reg  [WIDTH-1:0] di_im;
wire            do_en;
wire [WIDTH-1:0] do_re;
wire [WIDTH-1:0] do_im;

//  Twiddle Init
reg             tw_init;
reg  [9:0]      tw_init_addr;
reg  [WIDTH-1:0] tw_init_re;
reg  [WIDTH-1:0] tw_init_im;

//  Input / Twiddle Storage
reg  [WIDTH-1:0] input_data [0:N-1];
reg  [31:0]      twiddle_data [0:511];  //  32-bit: [31:16]=re, [15:0]=im

//  Output Capture
reg  [WIDTH-1:0] out_re [0:N-1];
reg  [WIDTH-1:0] out_im [0:N-1];
integer          out_count;

//----------------------------------------------------------------------
//  Clock Generation (10ns period = 100MHz)
//----------------------------------------------------------------------
initial clock = 0;
always #5 clock = ~clock;

//----------------------------------------------------------------------
//  DUT
//----------------------------------------------------------------------
FFT1024 #(.WIDTH(WIDTH)) DUT (
    .clock          (clock          ),
    .reset          (reset          ),
    .di_en          (di_en          ),
    .di_re          (di_re          ),
    .di_im          (di_im          ),
    .do_en          (do_en          ),
    .do_re          (do_re          ),
    .do_im          (do_im          ),
    .tw_init        (tw_init        ),
    .tw_init_addr   (tw_init_addr   ),
    .tw_init_re     (tw_init_re     ),
    .tw_init_im     (tw_init_im     )
);

//----------------------------------------------------------------------
//  Output Capture
//----------------------------------------------------------------------
always @(posedge clock) begin
    if (reset) begin
        out_count <= 0;
    end else if (do_en) begin
        out_re[out_count] <= do_re;
        out_im[out_count] <= do_im;
        out_count <= out_count + 1;
    end
end

//----------------------------------------------------------------------
//  Test Stimulus
//----------------------------------------------------------------------
integer i;
integer fd;

initial begin
    //  Load data files
    $readmemh("input_q1_15_v3.hex", input_data);
    $readmemh("twiddle_q15.hex", twiddle_data);

    //  Initialize
    reset = 1;
    di_en = 0;
    di_re = 0;
    di_im = 0;
    tw_init = 0;
    tw_init_addr = 0;
    tw_init_re = 0;
    tw_init_im = 0;

    //  Hold reset
    repeat(10) @(posedge clock);
    reset = 0;
    repeat(5) @(posedge clock);

    //------------------------------------------------------------
    //  Phase 1: Load twiddle factors into all tw_sram
    //------------------------------------------------------------
    tw_init = 1;
    for (i = 0; i < 512; i = i + 1) begin
        @(posedge clock);
        tw_init_addr = i[9:0];
        tw_init_re   = twiddle_data[i][31:16];
        tw_init_im   = twiddle_data[i][15:0];
    end
    @(posedge clock);
    tw_init = 0;
    tw_init_addr = 0;
    tw_init_re = 0;
    tw_init_im = 0;
    repeat(5) @(posedge clock);

    //------------------------------------------------------------
    //  Phase 2: Feed one frame of 1024 samples
    //------------------------------------------------------------
    for (i = 0; i < N; i = i + 1) begin
        @(posedge clock);
        di_en = 1;
        di_re = input_data[i];
        di_im = 16'h0000;
    end
    @(posedge clock);
    di_en = 0;
    di_re = 0;
    di_im = 0;

    //  Wait for output
    wait(out_count == N);
    repeat(10) @(posedge clock);

    //  Dump output
    fd = $fopen("fft_output.txt", "w");
    for (i = 0; i < N; i = i + 1) begin
        $fwrite(fd, "%04h %04h\n", out_re[i], out_im[i]);
    end
    $fclose(fd);

    $display("=== FFT1024 Test Complete ===");
    $display("First 8 output bins (bit-reversed order):");
    for (i = 0; i < 8; i = i + 1) begin
        $display("  bin[%0d] = (%0d, %0d)", i,
                 $signed(out_re[i]), $signed(out_im[i]));
    end

    $finish;
end

//----------------------------------------------------------------------
//  Timeout watchdog
//----------------------------------------------------------------------
initial begin
    #10000000;  //  10ms timeout
    $display("ERROR: Simulation timed out!");
    $finish;
end

//----------------------------------------------------------------------
//  Optional: VCD waveform dump
//----------------------------------------------------------------------
initial begin
    $dumpfile("fft1024.vcd");
    $dumpvars(0, TB_FFT1024);
end

endmodule
