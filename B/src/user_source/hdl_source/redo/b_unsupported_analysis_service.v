// A stale or direct CMD17 still receives an owned, bounded unsupported reply.
module b_unsupported_analysis_service(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_token,input [7:0] request_command,
 output response_valid,input response_ready,output [31:0] response_token,
 output [191:0] response_payload,
 input notice_valid,notice_session,input [31:0] notice_token,input transport_idle,
 output control_done,output [31:0] control_token);
reg pending;reg [31:0] owner;reg [7:0] owner_command;
wire affected=notice_valid&&(notice_session||notice_token==owner);
assign request_ready=!pending&&!notice_valid;
assign response_valid=pending&&!affected;
assign response_token=owner;
assign response_payload={160'd0,8'd0,8'h40,8'd1,owner_command};
assign control_token=notice_token;
assign control_done=notice_valid&&transport_idle&&(!pending||affected);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin pending<=0;owner<=0;owner_command<=0;end
 else begin
  if(response_valid&&response_ready||affected)pending<=0;
  if(request_valid&&request_ready)begin pending<=1;owner<=request_token;owner_command<=request_command;end
 end
end
endmodule
