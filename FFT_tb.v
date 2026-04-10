//----------------------------------------------------------------------
//  FFT Testbench
//
//  1. 从 hex 文件读入数据和旋转因子
//  2. input 只有实部 (16-bit), 虚部补零, 组成 {im, re} = {16'h0, real}
//  3. twiddle 文件格式 {re, im}, 加载时交换为 {im, re}
//  4. 启动 FFT, 等 data_valid, 读出结果
//----------------------------------------------------------------------
`timescale 1ns/1ps

module FFT_tb;

    parameter WIDTH     = 16;
    parameter N         = 1024;     // FFT 点数
    parameter TW_NUM    = 512;      // 旋转因子个数 = N/2
    parameter CLK_PERIOD = 10;      // 10ns → 100MHz

    // -------------------------------------------------------
    //  Clock & Reset
    // -------------------------------------------------------
    reg clk, rst_n;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------
    //  DUT Signals
    // -------------------------------------------------------
    reg               fft_en;
    reg  [9:0]        num_point;
    reg  [9:0]        tw_resolution;
    wire              data_valid;
    wire              fft_busy;

    reg               ext_d_en;
    reg               ext_d_wen;
    reg  [9:0]        ext_d_addr;
    reg  [WIDTH*2-1:0] ext_d_din;
    wire [WIDTH*2-1:0] ext_d_dout;

    reg               ext_tw_en;
    reg               ext_tw_wen;
    reg  [8:0]        ext_tw_addr;
    reg  [WIDTH*2-1:0] ext_tw_din;

    // -------------------------------------------------------
    //  DUT
    // -------------------------------------------------------
    FFT_top #(.WIDTH(WIDTH)) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .fft_en        (fft_en),
        .num_point     (num_point),
        .tw_resolution (tw_resolution),
        .data_valid    (data_valid),
        .fft_busy      (fft_busy),
        .ext_d_en      (ext_d_en),
        .ext_d_wen     (ext_d_wen),
        .ext_d_addr    (ext_d_addr),
        .ext_d_din     (ext_d_din),
        .ext_d_dout    (ext_d_dout),
        .ext_tw_en     (ext_tw_en),
        .ext_tw_wen    (ext_tw_wen),
        .ext_tw_addr   (ext_tw_addr),
        .ext_tw_din    (ext_tw_din)
    );

    // -------------------------------------------------------
    //  Memory for hex data
    // -------------------------------------------------------
    reg [15:0]         input_mem  [0:N-1];
    reg [31:0]         twiddle_mem[0:TW_NUM-1];
    reg [WIDTH*2-1:0]  result_mem [0:N-1];

    // -------------------------------------------------------
    //  Load hex files
    // -------------------------------------------------------
    initial begin
        $readmemh("FFT_input/input_q1_15_v3.hex", input_mem, 0, N-1);
        $readmemh("FFT_input/twiddle_q15.hex",     twiddle_mem, 0, TW_NUM-1);
    end

    // -------------------------------------------------------
    //  Main test flow
    // -------------------------------------------------------
    integer i;

    initial begin
        // Init
        rst_n         = 0;
        fft_en        = 0;
        num_point     = N;
        tw_resolution = TW_NUM;
        ext_d_en      = 0;
        ext_d_wen     = 0;
        ext_d_addr    = 0;
        ext_d_din     = 0;
        ext_tw_en     = 0;
        ext_tw_wen    = 0;
        ext_tw_addr   = 0;
        ext_tw_din    = 0;

        // Reset
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ====================================================
        //  Phase 1: Load input data into bank0
        //           input 只有实部, 虚部补零
        //           SRAM 格式: {im[15:0], re[15:0]}
        // ====================================================
        $display("[%0t] Loading input data ...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            ext_d_en   <= 1'b1;
            ext_d_wen  <= 1'b1;            // write
            ext_d_addr <= i[9:0];
            ext_d_din  <= {16'h0000, input_mem[i]};  // {im=0, re=data}
        end
        @(posedge clk);
        ext_d_en  <= 1'b0;
        ext_d_wen <= 1'b0;

        // ====================================================
        //  Phase 2: Load twiddle factors into tw_sram
        //           文件格式: {re[31:16], im[15:0]}
        //           SRAM 格式: {im[31:16], re[15:0]}
        //           交换高低 16-bit
        // ====================================================
        $display("[%0t] Loading twiddle factors ...", $time);
        for (i = 0; i < TW_NUM; i = i + 1) begin
            @(posedge clk);
            ext_tw_en   <= 1'b1;
            ext_tw_wen  <= 1'b1;
            ext_tw_addr <= i[8:0];
            ext_tw_din  <= {twiddle_mem[i][15:0], twiddle_mem[i][31:16]};  // swap → {im, re}
        end
        @(posedge clk);
        ext_tw_en  <= 1'b0;
        ext_tw_wen <= 1'b0;

        repeat(2) @(posedge clk);

        // ====================================================
        //  Phase 3: Start FFT
        // ====================================================
        $display("[%0t] Starting %0d-point FFT ...", $time, N);
        @(posedge clk);
        fft_en <= 1'b1;
        @(posedge clk);
        fft_en <= 1'b0;

        // ====================================================
        //  Phase 4: Wait for completion
        // ====================================================
        @(posedge data_valid);
        $display("[%0t] FFT done! data_valid asserted.", $time);
        repeat(3) @(posedge clk);

        // ====================================================
        //  Phase 5: Read results
        //           SRAM read latency: addr set → 2 cycles later dout valid
        //           (1 cycle for registered addr + 1 cycle SRAM latency)
        // ====================================================
        $display("[%0t] Reading results ...", $time);
        for (i = 0; i < N + 2; i = i + 1) begin
            @(posedge clk);
            if (i < N) begin
                ext_d_en   <= 1'b1;
                ext_d_wen  <= 1'b0;
                ext_d_addr <= i[9:0];
            end else begin
                ext_d_en   <= 1'b0;
            end
            // Capture result from 2 cycles ago
            if (i >= 2) begin
                result_mem[i-2] = ext_d_dout;
            end
        end

        // ====================================================
        //  Phase 6: Dump results
        // ====================================================
        $display("========== FFT Results ==========");
        for (i = 0; i < N; i = i + 1) begin
            $display("X[%4d] = re: %6d, im: %6d",
                     i,
                     $signed(result_mem[i][WIDTH-1:0]),
                     $signed(result_mem[i][WIDTH*2-1:WIDTH]));
        end

        // Save to file
        begin : SAVE_RESULTS
            integer fd;
            fd = $fopen("fft_output.txt", "w");
            for (i = 0; i < N; i = i + 1) begin
                $fwrite(fd, "%04h%04h\n",
                        result_mem[i][WIDTH*2-1:WIDTH],
                        result_mem[i][WIDTH-1:0]);
            end
            $fclose(fd);
            $display("Results saved to fft_output.txt");
        end

        $display("[%0t] Simulation complete.", $time);
        #100;
        $finish;
    end

    // -------------------------------------------------------
    //  Timeout watchdog
    // -------------------------------------------------------
    initial begin
        #(CLK_PERIOD * (N * 10 * 5 + 50000));
        $display("[ERROR] Simulation timed out!");
        $finish;
    end

    // -------------------------------------------------------
    //  Waveform dump
    // -------------------------------------------------------
    initial begin
        $dumpfile("fft_tb.vcd");
        $dumpvars(0, FFT_tb);
    end

endmodule
