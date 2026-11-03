// 复用已有可参数化FIFO，不改IP源码；末帧标记随32位左右样本一起跨域。
module pcm_frame_fifo(
 input arst_n,write_clk,write_valid,input [32:0] write_data,
 output write_ready,output [9:0] write_space,
 input read_clk,read_ready,output read_valid,output [32:0] read_data
);
wire full,empty;wire [8:0] used;
reg [3:0] write_settle,read_settle;
always @(negedge write_clk or negedge arst_n)if(!arst_n)write_settle<=0;else write_settle<={write_settle[2:0],1'b1};
always @(negedge read_clk or negedge arst_n)if(!arst_n)read_settle<=0;else read_settle<={read_settle[2:0],1'b1};
assign write_ready=write_settle[3] && !full;
// Four negative edges retain at least the original three positive-edge settling cycles.
// IP按511字边界判断满，采用保守剩余空间，避免把九位计数误当512。
assign write_space=write_settle[3] && !full ? 10'd511-{1'b0,used}:10'd0;
assign read_valid=read_settle[3] && !empty;
wfifo_32_32_512 #(.DATA_WIDTH_W(33),.DATA_WIDTH_R(33)) storage(
 .rst(!arst_n),.clkw(write_clk),.clkr(read_clk),.we(write_valid && write_ready),.di(write_data),
 .re(read_ready && read_valid),.dout(read_data),.valid(),.full_flag(full),.empty_flag(empty),
 .afull(),.aempty(),.wrusedw(used),.rdusedw());
endmodule
