//----------------------------------------------------------------------
//  FFT Top Module
//
//  Connects:
//    - fft_ctr          (FFT controller, 5-cycle radix-2 DIF)
//    - 2x data_sram_wrapper (dual-port SRAM, ping-pong bank0/bank1)
//    - 1x tw_sram_wrapper   (single-port SRAM, twiddle factors)
//
//  Usage:
//    1. Load input data   → ext_d_en=1, ext_d_wen=1, provide addr/din
//    2. Load twiddle       → ext_tw_en=1, ext_tw_wen=1, provide addr/din
//    3. Start FFT          → pulse fft_en
//    4. Wait data_valid    → results ready
//    5. Read results       → ext_d_en=1, ext_d_wen=0, provide addr
//----------------------------------------------------------------------
`timescale 1ns/1ps

module FFT_top #(
    parameter WIDTH = 16
) (
    input  wire                clk,
    input  wire                rst_n,

    // FFT Control
    input  wire                fft_en,
    input  wire [9:0]          num_point,
    input  wire [9:0]          tw_resolution,
    output wire                data_valid,
    output wire                fft_busy,

    // External Data Port (load input to bank0 / read result)
    input  wire                ext_d_en,       // access enable (active high)
    input  wire                ext_d_wen,      // 1=write(load), 0=read(result)
    input  wire [9:0]          ext_d_addr,
    input  wire [WIDTH*2-1:0]  ext_d_din,
    output wire [WIDTH*2-1:0]  ext_d_dout,

    // External Twiddle Port (load twiddle factors)
    input  wire                ext_tw_en,
    input  wire                ext_tw_wen,
    input  wire [8:0]          ext_tw_addr,
    input  wire [WIDTH*2-1:0]  ext_tw_din
);

    // =========================================================
    //  FFT busy & result-bank tracking
    // =========================================================
    reg r_fft_busy;
    reg r_result_bank;  // 0: results in bank0, 1: results in bank1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_fft_busy    <= 1'b0;
            r_result_bank <= 1'b0;
        end else begin
            if (fft_en && !r_fft_busy) begin
                r_fft_busy <= 1'b1;
                // result_bank = num_stages % 2
                case (num_point)
                    10'd4:    r_result_bank <= 1'b0;  // 2 stages
                    10'd8:    r_result_bank <= 1'b1;  // 3 stages
                    10'd16:   r_result_bank <= 1'b0;  // 4 stages
                    10'd32:   r_result_bank <= 1'b1;  // 5 stages
                    10'd64:   r_result_bank <= 1'b0;  // 6 stages
                    10'd128:  r_result_bank <= 1'b1;  // 7 stages
                    10'd256:  r_result_bank <= 1'b0;  // 8 stages
                    10'd512:  r_result_bank <= 1'b1;  // 9 stages
                    10'd1024: r_result_bank <= 1'b0;  // 10 stages
                    default:  r_result_bank <= 1'b0;
                endcase
            end else if (data_valid) begin
                r_fft_busy <= 1'b0;
            end
        end
    end

    assign fft_busy = r_fft_busy;

    // =========================================================
    //  FFT Controller
    // =========================================================
    wire [WIDTH*2-1:0] fft_rd_data_a, fft_rd_data_b;
    wire [9:0]         fft_rd_addr_a, fft_rd_addr_b;
    wire               fft_rd_en;
    wire [WIDTH*2-1:0] fft_wr_data_a, fft_wr_data_b;
    wire [9:0]         fft_wr_addr_a, fft_wr_addr_b;
    wire               fft_wr_en;
    wire               fft_bank_sel;
    wire [9:0]         fft_tw_addr;
    wire [WIDTH*2-1:0] fft_tw_rd_data;

    // =========================================================
    //  Write-side bank_sel (delayed 1 cycle)
    //
    //  fft_bank_sel = stage[0] 在 S_WR posedge 与 stage 同时翻转,
    //  但写数据要到下一个 posedge 才被 SRAM 锁存.
    //  用 1 拍延迟保证写侧 mux 在 SRAM 锁存前保持旧 bank_sel.
    // =========================================================
    reg wr_bank_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wr_bank_sel <= 1'b0;
        else
            wr_bank_sel <= fft_bank_sel;
    end

    fft_ctr #(.WIDTH(WIDTH)) u_fft_ctr (
        .clk             (clk),
        .rst_n           (rst_n),
        .num_point       (num_point),
        .tw_resolution   (tw_resolution),
        .en              (fft_en),
        .rd_data_a       (fft_rd_data_a),
        .rd_data_b       (fft_rd_data_b),
        .rd_addr_a       (fft_rd_addr_a),
        .rd_addr_b       (fft_rd_addr_b),
        .rd_en           (fft_rd_en),
        .wr_data_a       (fft_wr_data_a),
        .wr_data_b       (fft_wr_data_b),
        .wr_addr_a       (fft_wr_addr_a),
        .wr_addr_b       (fft_wr_addr_b),
        .wr_en           (fft_wr_en),
        .bank_sel        (fft_bank_sel),
        .tw_sram_rd_data (fft_tw_rd_data),
        .tw_sram_addr    (fft_tw_addr),
        .data_valid      (data_valid)
    );

    // =========================================================
    //  Bank 0 — Dual-Port Data SRAM
    // =========================================================
    reg         bank0_cena, bank0_wena;
    reg  [9:0]  bank0_addra;
    reg  [WIDTH*2-1:0] bank0_dina;
    wire [WIDTH*2-1:0] bank0_douta;

    reg         bank0_cenb, bank0_wenb;
    reg  [9:0]  bank0_addrb;
    reg  [WIDTH*2-1:0] bank0_dinb;
    wire [WIDTH*2-1:0] bank0_doutb;

    // Bank0 Port A mux
    always @(*) begin
        if (r_fft_busy) begin
            if (!fft_bank_sel && fft_rd_en) begin
                // read A from bank0 (bank_sel=0)
                bank0_cena  = 1'b0;
                bank0_wena  = 1'b1;
                bank0_addra = fft_rd_addr_a;
                bank0_dina  = {(WIDTH*2){1'b0}};
            end else if (wr_bank_sel && fft_wr_en) begin
                // write Y0 to bank0 (wr_bank_sel=1)
                bank0_cena  = 1'b0;
                bank0_wena  = 1'b0;
                bank0_addra = fft_wr_addr_a;
                bank0_dina  = fft_wr_data_a;
            end else begin
                bank0_cena  = 1'b1;
                bank0_wena  = 1'b1;
                bank0_addra = 10'd0;
                bank0_dina  = {(WIDTH*2){1'b0}};
            end
        end else if (ext_d_en && ext_d_wen) begin
            // External write to bank0 (load input data)
            bank0_cena  = 1'b0;
            bank0_wena  = 1'b0;
            bank0_addra = ext_d_addr;
            bank0_dina  = ext_d_din;
        end else if (ext_d_en && !ext_d_wen && !r_result_bank) begin
            // External read from bank0 (result in bank0)
            bank0_cena  = 1'b0;
            bank0_wena  = 1'b1;
            bank0_addra = ext_d_addr;
            bank0_dina  = {(WIDTH*2){1'b0}};
        end else begin
            bank0_cena  = 1'b1;
            bank0_wena  = 1'b1;
            bank0_addra = 10'd0;
            bank0_dina  = {(WIDTH*2){1'b0}};
        end
    end

    // Bank0 Port B mux
    always @(*) begin
        if (r_fft_busy) begin
            if (!fft_bank_sel && fft_rd_en) begin
                // read B from bank0 (bank_sel=0)
                bank0_cenb  = 1'b0;
                bank0_wenb  = 1'b1;
                bank0_addrb = fft_rd_addr_b;
                bank0_dinb  = {(WIDTH*2){1'b0}};
            end else if (wr_bank_sel && fft_wr_en) begin
                // write Y1 to bank0 (wr_bank_sel=1)
                bank0_cenb  = 1'b0;
                bank0_wenb  = 1'b0;
                bank0_addrb = fft_wr_addr_b;
                bank0_dinb  = fft_wr_data_b;
            end else begin
                bank0_cenb  = 1'b1;
                bank0_wenb  = 1'b1;
                bank0_addrb = 10'd0;
                bank0_dinb  = {(WIDTH*2){1'b0}};
            end
        end else begin
            bank0_cenb  = 1'b1;
            bank0_wenb  = 1'b1;
            bank0_addrb = 10'd0;
            bank0_dinb  = {(WIDTH*2){1'b0}};
        end
    end

    data_sram_wrapper #(.DW(WIDTH*2), .AW(10)) u_bank0 (
        .clka  (clk),
        .cena  (bank0_cena),
        .wena  (bank0_wena),
        .addra (bank0_addra),
        .dina  (bank0_dina),
        .douta (bank0_douta),
        .clkb  (clk),
        .cenb  (bank0_cenb),
        .wenb  (bank0_wenb),
        .addrb (bank0_addrb),
        .dinb  (bank0_dinb),
        .doutb (bank0_doutb)
    );

    // =========================================================
    //  Bank 1 — Dual-Port Data SRAM
    // =========================================================
    reg         bank1_cena, bank1_wena;
    reg  [9:0]  bank1_addra;
    reg  [WIDTH*2-1:0] bank1_dina;
    wire [WIDTH*2-1:0] bank1_douta;

    reg         bank1_cenb, bank1_wenb;
    reg  [9:0]  bank1_addrb;
    reg  [WIDTH*2-1:0] bank1_dinb;
    wire [WIDTH*2-1:0] bank1_doutb;

    // Bank1 Port A mux
    always @(*) begin
        if (r_fft_busy) begin
            if (fft_bank_sel && fft_rd_en) begin
                // read A from bank1 (bank_sel=1)
                bank1_cena  = 1'b0;
                bank1_wena  = 1'b1;
                bank1_addra = fft_rd_addr_a;
                bank1_dina  = {(WIDTH*2){1'b0}};
            end else if (!wr_bank_sel && fft_wr_en) begin
                // write Y0 to bank1 (wr_bank_sel=0)
                bank1_cena  = 1'b0;
                bank1_wena  = 1'b0;
                bank1_addra = fft_wr_addr_a;
                bank1_dina  = fft_wr_data_a;
            end else begin
                bank1_cena  = 1'b1;
                bank1_wena  = 1'b1;
                bank1_addra = 10'd0;
                bank1_dina  = {(WIDTH*2){1'b0}};
            end
        end else if (ext_d_en && !ext_d_wen && r_result_bank) begin
            // External read from bank1 (result in bank1)
            bank1_cena  = 1'b0;
            bank1_wena  = 1'b1;
            bank1_addra = ext_d_addr;
            bank1_dina  = {(WIDTH*2){1'b0}};
        end else begin
            bank1_cena  = 1'b1;
            bank1_wena  = 1'b1;
            bank1_addra = 10'd0;
            bank1_dina  = {(WIDTH*2){1'b0}};
        end
    end

    // Bank1 Port B mux
    always @(*) begin
        if (r_fft_busy) begin
            if (fft_bank_sel && fft_rd_en) begin
                // read B from bank1 (bank_sel=1)
                bank1_cenb  = 1'b0;
                bank1_wenb  = 1'b1;
                bank1_addrb = fft_rd_addr_b;
                bank1_dinb  = {(WIDTH*2){1'b0}};
            end else if (!wr_bank_sel && fft_wr_en) begin
                // write Y1 to bank1 (wr_bank_sel=0)
                bank1_cenb  = 1'b0;
                bank1_wenb  = 1'b0;
                bank1_addrb = fft_wr_addr_b;
                bank1_dinb  = fft_wr_data_b;
            end else begin
                bank1_cenb  = 1'b1;
                bank1_wenb  = 1'b1;
                bank1_addrb = 10'd0;
                bank1_dinb  = {(WIDTH*2){1'b0}};
            end
        end else begin
            bank1_cenb  = 1'b1;
            bank1_wenb  = 1'b1;
            bank1_addrb = 10'd0;
            bank1_dinb  = {(WIDTH*2){1'b0}};
        end
    end

    data_sram_wrapper #(.DW(WIDTH*2), .AW(10)) u_bank1 (
        .clka  (clk),
        .cena  (bank1_cena),
        .wena  (bank1_wena),
        .addra (bank1_addra),
        .dina  (bank1_dina),
        .douta (bank1_douta),
        .clkb  (clk),
        .cenb  (bank1_cenb),
        .wenb  (bank1_wenb),
        .addrb (bank1_addrb),
        .dinb  (bank1_dinb),
        .doutb (bank1_doutb)
    );

    // =========================================================
    //  FFT Read-Data Mux (read bank → controller)
    // =========================================================
    assign fft_rd_data_a = fft_bank_sel ? bank1_douta : bank0_douta;
    assign fft_rd_data_b = fft_bank_sel ? bank1_doutb : bank0_doutb;

    // =========================================================
    //  External Read-Data Mux (result bank → ext port)
    // =========================================================
    assign ext_d_dout = r_result_bank ? bank1_douta : bank0_douta;

    // =========================================================
    //  Twiddle Factor SRAM (Single-Port)
    // =========================================================
    wire        tw_cen;
    wire        tw_wen;
    wire [8:0]  tw_addr;
    wire [WIDTH*2-1:0] tw_din;
    wire [WIDTH*2-1:0] tw_dout;

    assign tw_cen  = r_fft_busy ? ~fft_rd_en
                                : (ext_tw_en ? 1'b0 : 1'b1);
    assign tw_wen  = r_fft_busy ? 1'b1
                                : ((ext_tw_en && ext_tw_wen) ? 1'b0 : 1'b1);
    assign tw_addr = r_fft_busy ? fft_tw_addr[8:0] : ext_tw_addr;
    assign tw_din  = r_fft_busy ? {(WIDTH*2){1'b0}} : ext_tw_din;

    assign fft_tw_rd_data = tw_dout;

    tw_sram_wrapper #(.DW(WIDTH*2), .AW(9)) u_tw_sram (
        .clk  (clk),
        .cen  (tw_cen),
        .wen  (tw_wen),
        .addr (tw_addr),
        .din  (tw_din),
        .dout (tw_dout)
    );

endmodule
