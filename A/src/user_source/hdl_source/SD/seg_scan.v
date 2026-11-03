module seg_scan #(
    parameter SCAN_FREQ = 200,             // 八位全部扫描一轮的频率
    parameter CLK_FREQ = 50000000,         // 输入时钟频率
    parameter SCAN_COUNT = CLK_FREQ / (SCAN_FREQ * 8) - 1,
    parameter BLANK_COUNT = CLK_FREQ / 500000 // 换位时约2微秒全灭
)(
    input              clk,
    input              rst_n,
    output reg [7:0]   seg_sel,             // 八路位选，低电平有效
    output reg [7:0]   seg_data,            // 段码，最高位为小数点
    input [7:0]        seg_data_0,
    input [7:0]        seg_data_1,
    input [7:0]        seg_data_2,
    input [7:0]        seg_data_3,
    input [7:0]        seg_data_4,
    input [7:0]        seg_data_5,
    input [7:0]        seg_data_6,
    input [7:0]        seg_data_7
);

reg [31:0] scan_timer;
reg [2:0] scan_sel;
reg [63:0] display_snapshot;

// 逐位扫描，完整刷新率仍为200赫兹。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_timer <= 32'd0;
        scan_sel   <= 3'd0;
    end else if (scan_timer >= SCAN_COUNT) begin
        scan_timer <= 32'd0;
        if (scan_sel == 3'd7)
            scan_sel <= 3'd0;
        else
            scan_sel <= scan_sel + 3'd1;
    end else begin
        scan_timer <= scan_timer + 32'd1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seg_sel          <= 8'hff;
        seg_data         <= 8'hff;
        display_snapshot <= 64'hffffffffffffffff;
    end else begin
        // 每轮开始锁存八位内容，避免一轮扫描混用新旧显示数据。
        if ((scan_sel == 3'd0) && (scan_timer == 32'd0))
            display_snapshot <= {seg_data_7, seg_data_6, seg_data_5, seg_data_4,
                                 seg_data_3, seg_data_2, seg_data_1, seg_data_0};

        case (scan_sel)
            3'd0: seg_data <= display_snapshot[7:0];
            3'd1: seg_data <= display_snapshot[15:8];
            3'd2: seg_data <= display_snapshot[23:16];
            3'd3: seg_data <= display_snapshot[31:24];
            3'd4: seg_data <= display_snapshot[39:32];
            3'd5: seg_data <= display_snapshot[47:40];
            3'd6: seg_data <= display_snapshot[55:48];
            3'd7: seg_data <= display_snapshot[63:56];
            default: seg_data <= 8'hff;
        endcase

        // 先关闭全部位选并准备新段码，再点亮新位置，降低换位重影。
        if ((scan_timer < BLANK_COUNT) || (scan_timer >= SCAN_COUNT))
            seg_sel <= 8'hff;
        else
            seg_sel <= ~(8'b00000001 << scan_sel);
    end
end

endmodule