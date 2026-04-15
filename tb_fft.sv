`timescale 1ns/1ps

module testbench;

    parameter DW     = 32;
    parameter AW     = 9;
    parameter N      = 1024;
    parameter STAGES = 10;

    // Clock & reset
    reg  clk, rst_n;
    reg  start;
    wire done;

    // External load interface
    reg        ext_wen;
    reg        ext_rd_en;      // 外部读使能信号
    reg  [1:0] ext_bank;
    reg  [AW-1:0] ext_addr;
    reg  [DW-1:0] ext_din;

    // Twiddle load
    reg        tw_ext_wen;
    reg  [AW-1:0] tw_ext_addr;
    reg  [DW-1:0] tw_ext_din;

    // Readback
    reg  [AW-1:0] ext_rd_addr_0, ext_rd_addr_1;
    reg  [1:0]    ext_rd_pair;
    wire [DW-1:0] ext_rd_dout_0, ext_rd_dout_1;

    // DUT 实例化
    fft_top #(
        .DW(DW), .AW(AW), .N(N), .STAGES(STAGES)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .done         (done),
        .ext_wen      (ext_wen),
        .ext_rd_en    (ext_rd_en),   
        .ext_bank     (ext_bank),
        .ext_addr     (ext_addr),
        .ext_din      (ext_din),
        .tw_ext_wen   (tw_ext_wen),
        .tw_ext_addr  (tw_ext_addr),
        .tw_ext_din   (tw_ext_din),
        .ext_rd_addr_0(ext_rd_addr_0),
        .ext_rd_addr_1(ext_rd_addr_1),
        .ext_rd_pair  (ext_rd_pair),
        .ext_rd_dout_0(ext_rd_dout_0),
        .ext_rd_dout_1(ext_rd_dout_1)
    );

    // ---- Clock generation: 10 ns period ----
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- Input data storage (16-bit real only) ----
    reg [15:0] input_data [0:N-1];

    // ---- Twiddle data storage (32-bit: {re,im}) ----
    reg [31:0] twiddle_data [0:511];

    // ---- XOR parity helper ----
    function [0:0] parity10;
        input [9:0] idx;
        parity10 = ^idx;
    endfunction

    // ---- 10-bit 位反转函数 (用于将自然顺序转为倒位序地址) ----
    function [9:0] bit_reverse;
        input [9:0] in;
        integer k;
        begin
            for (k = 0; k < 10; k = k + 1) begin
                bit_reverse[k] = in[9-k];
            end
        end
    endfunction

    // ---- Task: write one word to data SRAM via external port ----
    task write_data_sram;
        input [1:0]    bank;
        input [AW-1:0] addr;
        input [DW-1:0] data;
        begin
            @(posedge clk);
            ext_wen  <= 1'b1;
            ext_bank <= bank;
            ext_addr <= addr;
            ext_din  <= data;
            @(posedge clk);
            ext_wen  <= 1'b0;
        end
    endtask

    // ---- Task: write one word to twiddle SRAM ----
    task write_tw_sram;
        input [AW-1:0] addr;
        input [DW-1:0] data;
        begin
            @(posedge clk);
            tw_ext_wen  <= 1'b1;
            tw_ext_addr <= addr;
            tw_ext_din  <= data;
            @(posedge clk);
            tw_ext_wen  <= 1'b0;
        end
    endtask

    // ---- Task: 读取标准接口 (配合 ext_rd_en 使用) ----
    // 10级FFT后结果在 banks 0,1 (Pair 0)
    // bank_id=0 → port 0 (bank 0), bank_id=1 → port 1 (bank 1)
    task read_data_sram_ext;
        input [1:0]    bank;
        input [AW-1:0] addr;
        output [DW-1:0] data;
        begin
            // 1. 下降沿驱动，拉高读使能，分配地址
            @(negedge clk);
            ext_rd_en   <= 1'b1;             
            ext_rd_pair <= 2'd0;  // 始终从 Pair 0 (banks 0,1) 读取结果
            
            if (bank[0] == 1'b0) begin
                ext_rd_addr_0 <= addr;
            end else begin
                ext_rd_addr_1 <= addr;
            end
            
            // 2. 跨过第一个上升沿：SRAM 采样地址
            @(posedge clk); 
            
            // 3. 跨过第二个上升沿：SRAM 数据输出
            @(posedge clk); 
            #1; // 延迟 1ns 避开时钟边沿的毛刺/竞争
            
            // 采样结果
            if (bank[0] == 1'b0) begin
                data = ext_rd_dout_0;
            end else begin
                data = ext_rd_dout_1;
            end

            // 4. 清理地址线并撤销使能信号
            @(negedge clk);
            ext_rd_en     <= 1'b0;           
            ext_rd_addr_0 <= 0;
            ext_rd_addr_1 <= 0;
            ext_rd_pair   <= 0;
        end
    endtask

    // ---- Main test ----
    integer i;
    integer fp_out;
    reg [9:0] point_idx;
    reg       bank_id;
    reg [15:0] val16;
    reg [31:0] val32;

    initial begin
        // Initialise
        rst_n       = 0;
        start       = 0;
        ext_wen     = 0;
        ext_rd_en   = 0;   
        ext_bank    = 0;
        ext_addr    = 0;
        ext_din     = 0;
        tw_ext_wen  = 0;
        tw_ext_addr = 0;
        tw_ext_din  = 0;
        ext_rd_addr_0 = 0;
        ext_rd_addr_1 = 0;
        ext_rd_pair   = 0;

        // Read input file (16-bit hex, real-only)
        $readmemh("FFT_input/input_q1_15_v3.hex", input_data);

        // Read twiddle file (32-bit hex: {re[15:0], im[15:0]})
        $readmemh("FFT_input/twiddle_q15.hex", twiddle_data);

        // Reset
        #20;
        rst_n = 1;
        #20;

        // ============================================================
        //  Step 1: Load twiddle factors
        // ============================================================
        $display("[TB] Loading twiddle factors ...");
        for (i = 0; i < 512; i = i + 1) begin
            write_tw_sram(i[AW-1:0], twiddle_data[i]);
        end
        $display("[TB] Twiddle loading done.");

        // ============================================================
        //  Step 2: Load input data into data SRAM banks 0 & 1
        // ============================================================
        $display("[TB] Loading input data ...");
        for (i = 0; i < N; i = i + 1) begin
            point_idx = i[9:0];
            bank_id   = parity10(point_idx);  // 0 → bank0, 1 → bank1
            val16     = input_data[i];
            val32     = {val16, 16'h0000};    // real part only, imag = 0
            write_data_sram({1'b0, bank_id}, point_idx[AW-1:0], val32);
        end
        $display("[TB] Input loading done.");

        // ============================================================
        //  Step 3: Start FFT
        // ============================================================
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        $display("[TB] FFT started, waiting for done ...");

        // Wait for done
        wait (done == 1'b1);
        @(posedge clk);
        $display("[TB] FFT done!");

        // ============================================================
        //  Step 4: Read back results & write to file (Natural Order)
        // ============================================================
        $display("[TB] Reading back results using ext_rd_en...");

        fp_out = $fopen("fft_output.txt", "w");
        if (fp_out == 0) begin
            $display("[TB] ERROR: cannot open fft_output.txt");
            $finish;
        end

        // 按自然频域顺序 i=0~1023 进行输出
        for (i = 0; i < N; i = i + 1) begin
            // 把自然索引 i 转换为倒位序物理地址 point_idx
            point_idx = bit_reverse(i[9:0]); 
            
            // 根据实际的物理地址计算 bank 和 内部偏移 addr
            bank_id   = parity10(point_idx);
            
            // 从对应的 bank 和 address 读出数据 (结果在 Pair 0)
            read_data_sram_ext({1'b0, bank_id}, point_idx[AW-1:0], val32);
            
            // 写入文件，此时第0行对应X(0), 第1行对应X(1)...
            $fwrite(fp_out, "%04x%04x\n", val32[31:16] & 16'hFFFF, val32[15:0] & 16'hFFFF);
        end

        $fclose(fp_out);
        $display("[TB] Results written to fft_output.txt (Natural Order)");

        #100;
        $display("[TB] Simulation complete.");
        $finish;
    end

    // ---- Timeout watchdog ----
    initial begin
        #5_000_000;
        $display("[TB] TIMEOUT!");
        $finish;
    end

    // ---- Waveform dump ----
    initial begin
        $dumpfile("testbench.vcd");
        $dumpvars(0, testbench); 
    end

endmodule
