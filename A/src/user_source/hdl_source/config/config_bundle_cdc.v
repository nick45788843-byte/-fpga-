// 一份配置从源时钟域传到目标域；数据保持到确认，目标域复位后会重新请求。
module config_bundle_cdc #(parameter WIDTH=32,NO_DATA_RESET=0,TRIGGERED_CAPTURE=0,DST_DATA_PHASE=0)(
 input src_clk,src_rst_n,input [WIDTH-1:0] src_data,input src_valid,
 output reg [WIDTH-1:0] applied_data,output reg applied_valid,
 input dst_clk,dst_rst_n,input dst_capture,output [WIDTH-1:0] dst_data,output dst_valid
);
// Assert immediately, release at the receiving domain's own negative edges.
// A 25MHz source reset must not deassert directly on a 50MHz positive edge.
(*async_reg=1,preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [1:0] src_release,dst_release;
always @(negedge src_clk or negedge src_rst_n)
 if(!src_rst_n)src_release<=0;else src_release<={src_release[0],1'b1};
always @(negedge dst_clk or negedge dst_rst_n)
 if(!dst_rst_n)dst_release<=0;else dst_release<={dst_release[0],1'b1};
wire src_reset_local_n=src_release[1],dst_reset_local_n=dst_release[1];

// 按安路SWUG106保留握手采样边界，避免合并后时序约束失去目标寄存器。
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [WIDTH-1:0] capture_word;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg capture_valid;
assign dst_data=capture_word;assign dst_valid=capture_valid;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [WIDTH-1:0] held_data;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg request_toggle,ack_toggle,in_flight,ever_sent;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [2:0] request_sync;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [1:0] sent_sync;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [1:0] ack_sync,valid_sync;
// Retain the original two synchronizers AFTER this opposite-edge phase tap.
(*async_reg=1,preserve=1*) reg ack_phase,valid_phase;
always @(negedge src_clk or negedge src_reset_local_n)begin
 if(!src_reset_local_n)begin ack_phase<=0;valid_phase<=0;end
 else begin ack_phase<=ack_toggle;valid_phase<=dst_valid;end
end
always @(posedge src_clk or negedge src_reset_local_n)begin
 if(!src_reset_local_n)begin
  request_toggle<=0;in_flight<=0;ever_sent<=0;
  ack_sync<=0;valid_sync<=0;applied_data<=0;applied_valid<=0;
 end else begin
  ack_sync<={ack_sync[0],ack_phase};valid_sync<={valid_sync[0],valid_phase};
  if(!valid_sync[1])applied_valid<=0;
  if(in_flight && ack_sync[1]==request_toggle && valid_sync[1])begin
   applied_data<=held_data;applied_valid<=1;in_flight<=0;
  end else if(!in_flight && src_valid && (!ever_sent || src_data!=held_data))begin
   request_toggle<=!request_toggle;in_flight<=1;ever_sent<=1;
  end else if(!in_flight && ever_sent && valid_sync[1] && ack_sync[1]==request_toggle)begin
   applied_data<=held_data;applied_valid<=1;
  end
 end
end
// 宽回执可只复位有效状态；源数据保持寄存器在首次有效请求时才写入。
generate if(NO_DATA_RESET)begin: g_data_without_reset
 always @(posedge src_clk)begin
  if(src_reset_local_n&&!in_flight&&src_valid&&(!ever_sent||src_data!=held_data))held_data<=src_data;
 end
end else begin: g_data_with_reset
 always @(posedge src_clk or negedge src_reset_local_n)begin
  if(!src_reset_local_n)held_data<=0;
  else if(!in_flight&&src_valid&&(!ever_sent||src_data!=held_data))held_data<=src_data;
 end
end endgenerate
// The source holds this complete bus until the real ACK. A memory-bound
// instance can sample it on the opposite edge before its original capture.
wire [WIDTH-1:0] capture_input;
generate if(DST_DATA_PHASE)begin: data_phase
 (*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [WIDTH-1:0] held_phase;
 always @(negedge dst_clk)held_phase<=held_data;
 assign capture_input=held_phase;
end else begin: direct_data
 assign capture_input=held_data;
end endgenerate
// 数据只有capture_valid置位后才被消费；完整捕获前无需逐位复位。
always @(posedge dst_clk)begin
 if((!TRIGGERED_CAPTURE || dst_capture) && (request_sync[2]!=ack_toggle || (!capture_valid && sent_sync[1])))capture_word<=capture_input;
end
(*async_reg=1,preserve=1*) reg request_phase,sent_phase;
always @(negedge dst_clk or negedge dst_reset_local_n)begin
 if(!dst_reset_local_n)begin request_phase<=0;sent_phase<=0;end
 else begin request_phase<=request_toggle;sent_phase<=ever_sent;end
end
always @(posedge dst_clk or negedge dst_reset_local_n)begin
 if(!dst_reset_local_n)begin request_sync<=0;sent_sync<=0;ack_toggle<=0;capture_valid<=0;end
 else begin
  request_sync<={request_sync[1:0],request_phase};
  sent_sync<={sent_sync[0],sent_phase};
  // 目标复位后即使请求号恰好为零，也重新捕获稳定的已发送配置。
  if((!TRIGGERED_CAPTURE || dst_capture) && (request_sync[2]!=ack_toggle || (!capture_valid && sent_sync[1])))begin
   capture_valid<=1;ack_toggle<=request_sync[2];
  end
 end
end
endmodule
