// 取消请求以翻转位跨到存储域；等待当前存储事务结束后再清写侧。
// 复位持续三拍，完成标记跨回控制域。读侧和SDRAM核心不被取消请求复位。
module frame_write_cancel(input ctrl_clk,mem_clk,rst_n,request,
 input write_busy,core_busy,output memory_reset,output done);
reg requested,completed,seen;reg [2:0] hold_reset;
(* async_reg=1,preserve=1 *) reg [1:0] request_sync,complete_sync;
(*async_reg=1,preserve=1*) reg requested_phase;
always @(negedge mem_clk or negedge rst_n)
 if(!rst_n)requested_phase<=0;else requested_phase<=requested;
assign memory_reset=hold_reset[2];
assign done=!request&&requested==complete_sync[1];
always @(posedge ctrl_clk or negedge rst_n)begin
 if(!rst_n)begin requested<=0;complete_sync<=0;end
 else begin complete_sync<={complete_sync[0],completed};if(request)requested<=!requested;end
end
always @(posedge mem_clk or negedge rst_n)begin
 if(!rst_n)begin request_sync<=0;completed<=0;seen<=0;hold_reset<=0;end
 else begin
  request_sync<={request_sync[0],requested_phase};hold_reset<={hold_reset[1:0],1'b0};
  if(hold_reset==3'b100)completed<=seen;
  if(hold_reset==0&&request_sync[1]!=seen&&!write_busy&&!core_busy)begin
   seen<=request_sync[1];hold_reset<=3'b111;
  end
 end
end
endmodule
