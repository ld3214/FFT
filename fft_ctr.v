//----------------------------------------------------------------------
//  FFT Controller: Memory-based iterative radix-2 DIF FFT
//
//  Architecture (双端口 SRAM 版本):
//    - 两个双端口 SRAM 做 ping-pong: bank0 和 bank1
//    - 每个 bank 的 port_a/port_b 可同时读写
//    - 同一拍并行读 A 和 B; 同一拍并行写 Y0 和 Y1
//    - 5-cycle FSM per butterfly: RD → WAIT → LATCH → CALC → WR
//    - Total cycles = 5 * (N/2) * log2(N)
//----------------------------------------------------------------------
module fft_ctr #(
    parameter WIDTH = 16
)
(
    input  clk,
    input  rst_n,
    input  [9:0]  num_point,     // FFT点数 (4~1024, 须为2的幂)
    input  [9:0]  tw_resolution, // 旋转因子个数 (通常 = num_point/2)
    input  en,

    // ===== 双端口 Data SRAM 读接口 (同时读 A 和 B) =====
    input  [WIDTH*2-1:0] rd_data_a,      // port_a 读出的 A 节点 {im, re}
    input  [WIDTH*2-1:0] rd_data_b,      // port_b 读出的 B 节点 {im, re}
    output reg [9:0]     rd_addr_a,      // A 节点读地址
    output reg [9:0]     rd_addr_b,      // B 节点读地址
    output reg           rd_en,          // 读使能 (active high)

    // ===== 双端口 Data SRAM 写接口 (同时写 Y0 和 Y1) =====
    output reg [WIDTH*2-1:0] wr_data_a,  // port_a 写回 Y0 {im, re}
    output reg [WIDTH*2-1:0] wr_data_b,  // port_b 写回 Y1 {im, re}
    output reg [9:0]     wr_addr_a,      // Y0 写地址
    output reg [9:0]     wr_addr_b,      // Y1 写地址
    output reg           wr_en,          // 写使能 (active high)

    // ===== Bank 选择 =====
    // 0: 读 bank0 / 写 bank1
    // 1: 读 bank1 / 写 bank0
    output               bank_sel,

    // ===== Twiddle SRAM =====
    input  [WIDTH*2-1:0] tw_sram_rd_data,
    output reg [9:0]     tw_sram_addr,

    output reg           data_valid
);

    // ---------------------------------------------------------
    // 状态机定义 (5-cycle FSM per Butterfly)
    // ---------------------------------------------------------
    localparam S_IDLE  = 3'd0;
    localparam S_RD    = 3'd1; // 同时输出 A/B 读地址 + twiddle 地址
    localparam S_WAIT  = 3'd2; // 等待 SRAM 读延迟 (1-cycle synchronous SRAM)
    localparam S_LATCH = 3'd3; // 锁存 A、B、W 数据
    localparam S_CALC  = 3'd4; // Butterfly 组合逻辑 → 锁存 Y0, Y1_pre
    localparam S_WR    = 3'd5; // Multiply 组合逻辑 → 同时写回 Y0 和 Y1

    reg [2:0] state, next_state;

    // ---------------------------------------------------------
    // 动态参数寄存器
    // ---------------------------------------------------------
    reg [3:0] num_stages;  // log2(num_point)
    reg [8:0] half_n;      // num_point / 2

    // ---------------------------------------------------------
    // 级数与蝶形计数器
    // ---------------------------------------------------------
    reg [3:0] stage;       // 当前级数 0 to num_stages-1
    reg [8:0] bf_cnt;      // 蝶形对索引 0 to half_n-1

    // ---------------------------------------------------------
    // Ping-Pong Bank 选择 (偶数级读 bank0, 奇数级读 bank1)
    // ---------------------------------------------------------
    assign bank_sel = stage[0];

    // ---------------------------------------------------------
    // DIF 地址生成逻辑
    //   s_inv = num_stages - 1 - stage
    //   dist  = 1 << s_inv  (蝶形对两节点间距)
    //   A_idx = ((bf_cnt & ~lower_mask) << 1) | (bf_cnt & lower_mask)
    //   B_idx = A_idx | dist
    //   W_idx = (bf_cnt & lower_mask) << stage
    // ---------------------------------------------------------
    wire [3:0] s_inv = num_stages - 4'd1 - stage;
    wire [9:0] dist = 10'd1 << s_inv;
    wire [9:0] lower_mask = dist - 10'd1;

    wire [9:0] A_idx = (({1'b0, bf_cnt} & ~lower_mask) << 1) | ({1'b0, bf_cnt} & lower_mask);
    wire [9:0] B_idx = A_idx | dist;
    wire [9:0] W_idx = ({1'b0, bf_cnt} & lower_mask) << stage;

    // ---------------------------------------------------------
    // 完成标志
    // ---------------------------------------------------------
    wire last_bfly  = (bf_cnt == half_n - 9'd1);
    wire last_stage = (stage == num_stages - 4'd1);

    // ---------------------------------------------------------
    // 流水线数据寄存器
    // ---------------------------------------------------------
    reg [WIDTH*2-1:0] reg_A, reg_B, reg_W;
    reg [WIDTH*2-1:0] reg_Y0;     // Butterfly: A+B
    reg [WIDTH*2-1:0] reg_Y1_pre; // Butterfly: A-B (待乘 twiddle)

    // ---------------------------------------------------------
    // Butterfly 和 Multiply (组合逻辑)
    // ---------------------------------------------------------
    wire [WIDTH-1:0] bfy_y0_re, bfy_y0_im, bfy_y1_re, bfy_y1_im;
    wire [WIDTH-1:0] mult_m_re, mult_m_im;

    Butterfly #(.WIDTH(WIDTH), .RH(0)) u_bfy (
        .x0_re (reg_A[WIDTH*2-1:WIDTH]),  .x0_im (reg_A[WIDTH-1:0]),
        .x1_re (reg_B[WIDTH*2-1:WIDTH]),  .x1_im (reg_B[WIDTH-1:0]),
        .y0_re (bfy_y0_re),              .y0_im (bfy_y0_im),
        .y1_re (bfy_y1_re),              .y1_im (bfy_y1_im)
    );

    Multiply #(.WIDTH(WIDTH)) u_mult (
        .a_re  (reg_Y1_pre[WIDTH*2-1:WIDTH]),  .a_im  (reg_Y1_pre[WIDTH-1:0]),
        .b_re  (reg_W[WIDTH*2-1:WIDTH]),       .b_im  (reg_W[WIDTH-1:0]),
        .m_re  (mult_m_re),                    .m_im  (mult_m_im)
    );

    // ---------------------------------------------------------
    // FSM 状态转移 + 计数器更新
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            stage      <= 4'd0;
            bf_cnt     <= 9'd0;
            num_stages <= 4'd0;
            half_n     <= 9'd0;
        end else begin
            state <= next_state;

            case (state)
                S_IDLE: begin
                    if (en) begin
                        stage  <= 4'd0;
                        bf_cnt <= 9'd0;
                        half_n <= num_point[9:1];
                        case (num_point)
                            10'd4:    num_stages <= 4'd2;
                            10'd8:    num_stages <= 4'd3;
                            10'd16:   num_stages <= 4'd4;
                            10'd32:   num_stages <= 4'd5;
                            10'd64:   num_stages <= 4'd6;
                            10'd128:  num_stages <= 4'd7;
                            10'd256:  num_stages <= 4'd8;
                            10'd512:  num_stages <= 4'd9;
                            10'd1024: num_stages <= 4'd10;
                            default:  num_stages <= 4'd10;
                        endcase
                    end
                end
                S_WR: begin
                    if (last_bfly) begin
                        bf_cnt <= 9'd0;
                        if (!last_stage)
                            stage <= stage + 4'd1;
                    end else begin
                        bf_cnt <= bf_cnt + 9'd1;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------
    // 次态逻辑
    // ---------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:  if (en) next_state = S_RD;
            S_RD:    next_state = S_WAIT;
            S_WAIT:  next_state = S_LATCH;
            S_LATCH: next_state = S_CALC;
            S_CALC:  next_state = S_WR;
            S_WR: begin
                if (last_bfly && last_stage)
                    next_state = S_IDLE;
                else
                    next_state = S_RD;
            end
            default: next_state = S_IDLE;
        endcase
    end

    // ---------------------------------------------------------
    // 输出逻辑与数据流水线
    //
    // 时序:
    //   T+0 (S_RD):    rd_addr_a ← A, rd_addr_b ← B, tw_addr ← W
    //   T+1 (S_WAIT):  SRAM 采样地址, Q 在此拍结束时更新
    //   T+2 (S_LATCH): reg_A ← Q_a, reg_B ← Q_b, reg_W ← tw_Q
    //   T+3 (S_CALC):  Butterfly (组合) → 锁存 reg_Y0, reg_Y1_pre
    //   T+4 (S_WR):    Multiply (组合) → 同时写回 Y0 和 Y1
    // ---------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_a    <= 10'd0;
            rd_addr_b    <= 10'd0;
            rd_en        <= 1'b0;
            wr_addr_a    <= 10'd0;
            wr_addr_b    <= 10'd0;
            wr_data_a    <= {(WIDTH*2){1'b0}};
            wr_data_b    <= {(WIDTH*2){1'b0}};
            wr_en        <= 1'b0;
            tw_sram_addr <= 10'd0;
            data_valid   <= 1'b0;
            reg_A        <= {(WIDTH*2){1'b0}};
            reg_B        <= {(WIDTH*2){1'b0}};
            reg_W        <= {(WIDTH*2){1'b0}};
            reg_Y0       <= {(WIDTH*2){1'b0}};
            reg_Y1_pre   <= {(WIDTH*2){1'b0}};
        end else begin
            rd_en      <= 1'b0;
            wr_en      <= 1'b0;
            data_valid <= 1'b0;

            case (state)
                S_RD: begin
                    // 同时输出 A 和 B 的读地址 + twiddle 地址
                    rd_addr_a    <= A_idx;
                    rd_addr_b    <= B_idx;
                    tw_sram_addr <= W_idx;
                    rd_en        <= 1'b1;
                end

                // S_WAIT: 等待 SRAM 读延迟, 无操作

                S_LATCH: begin
                    // 同时锁存 A、B 数据和 twiddle 因子
                    reg_A <= rd_data_a;
                    reg_B <= rd_data_b;
                    reg_W <= tw_sram_rd_data;
                end

                S_CALC: begin
                    // Butterfly 组合输出 → 锁存  {re, im}
                    reg_Y0     <= {bfy_y0_re, bfy_y0_im};
                    reg_Y1_pre <= {bfy_y1_re, bfy_y1_im};
                end

                S_WR: begin
                    // Multiply 组合输出直接作为写数据
                    // 同时写 Y0 和 Y1 到 write bank 的两个端口
                    wr_addr_a <= A_idx;
                    wr_addr_b <= B_idx;
                    wr_data_a <= reg_Y0;                       // Y0 = (A+B)/2
                    wr_data_b <= {mult_m_re, mult_m_im};       // Y1 = (A-B)*W
                    wr_en     <= 1'b1;

                    if (last_bfly && last_stage)
                        data_valid <= 1'b1;
                end
            endcase
        end
    end

endmodule