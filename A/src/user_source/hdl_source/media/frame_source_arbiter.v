// 启动时先让固定图片使用写入口，结束且内存写事务空闲后交回普通媒体。
module frame_source_arbiter #(parameter [20:0] ASSET_BASE=21'd1667072)(
 input clk,rst_n,asset_finished,writer_busy,core_busy,
 input asset_req,asset_valid,asset_abort,input [31:0] asset_word,
 input normal_req,normal_valid,normal_abort,input [31:0] normal_word,input [20:0] normal_base,
 input req_ack,input_ready,abort_done,
 output reg asset_owner,output req,valid,abort,output [31:0] word,output [20:0] base,
 output asset_ack,asset_input_ready,asset_abort_done,normal_ack,normal_input_ready,normal_abort_done);
reg release_pending;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin asset_owner<=1;release_pending<=0;end
 else begin
  if(asset_finished)release_pending<=1;
  if(release_pending&&!writer_busy&&!core_busy)begin asset_owner<=0;release_pending<=0;end
 end
end
assign req=asset_owner?asset_req:normal_req;
// 输入背压时不重复写入保持中的像素，源端只在同一次握手后前进。
assign valid=(asset_owner?asset_valid:normal_valid)&&input_ready;
assign abort=asset_owner?asset_abort:normal_abort;
assign word=asset_owner?asset_word:normal_word;
assign base=asset_owner?ASSET_BASE:normal_base;
assign asset_ack=req_ack&&asset_owner;
assign asset_input_ready=input_ready&&asset_owner;
assign asset_abort_done=abort_done&&asset_owner;
assign normal_ack=req_ack&&!asset_owner;
assign normal_input_ready=input_ready&&!asset_owner;
assign normal_abort_done=abort_done&&!asset_owner;
endmodule
