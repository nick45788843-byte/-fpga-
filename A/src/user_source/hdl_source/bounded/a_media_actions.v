// Backends acknowledge EFFECT, not command reception. Cancel completion means
// all writes/playback from the old token have drained before another action.
module a_media_actions #(parameter TIMEOUT_MS=15000,MINIMAL_REPLY=0)(input clk,rst_n,tick_ms,
 input remote_online,actual_emergency,automatic_mode,
 input request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_command,request_argument,
 output action_valid,input action_ready,output reg action_audio,
 output reg [7:0] action_code,output reg [31:0] action_token,
 input applied_valid,input [31:0] applied_token,input [7:0] applied_error,
 input cancel_valid,input [31:0] cancel_token,
 output backend_cancel_valid,output [31:0] backend_cancel_token,
 input cancel_done_valid,input [31:0] cancel_done_token,
 input [191:0] actual_status_payload,
 output reg response_valid,input response_ready,output reg [31:0] response_token,
 output reg [191:0] response_payload,output draining);
localparam IDLE=0,DISPATCH=1,WAIT_APPLY=2,DRAIN=3;
localparam TW=TIMEOUT_MS>0?$clog2(TIMEOUT_MS+1):1;
reg [1:0] state;reg [TW-1:0] age;reg [7:0] command,drain_error;
wire supported=request_command==9||request_command==10||request_command==13||request_command==14;
wire abort_now=(cancel_valid&&cancel_token==action_token)||
               (!remote_online&&command!=14)||age>=TIMEOUT_MS-1;
assign request_ready=state==IDLE&&!response_valid&&supported;
assign action_valid=state==DISPATCH;
assign draining=state==DRAIN;
assign backend_cancel_valid=draining;assign backend_cancel_token=action_token;
task finish;input [7:0] error;begin
 response_valid<=1;response_token<=action_token;
 response_payload<={(MINIMAL_REPLY?168'd0:actual_status_payload[191:24]),error,7'd0,(error!=0),command};
 state<=IDLE;age<=0;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;age<=0;command<=0;drain_error<=0;action_audio<=0;action_code<=0;action_token<=0;
  response_valid<=0;response_token<=0;response_payload<=0;
 end else begin
  if(response_valid&&response_ready)response_valid<=0;
  if((state==DISPATCH||state==WAIT_APPLY)&&tick_ms&&age<TIMEOUT_MS)age<=age+1'b1;
  if(state==DISPATCH&&action_ready)state<=WAIT_APPLY;
  if(state==WAIT_APPLY&&!abort_now)begin
   if(applied_valid&&applied_token==action_token)finish(applied_error);
  end
  if(state==DRAIN&&cancel_done_valid&&cancel_done_token==action_token)finish(drain_error);
  if(state==DISPATCH||state==WAIT_APPLY)begin
   if(abort_now)begin
    drain_error<=(cancel_valid&&cancel_token==action_token)?8'h43:
                  (!remote_online&&command!=14)?8'hc0:8'h48;
    // A same-clock ready handshake may already have reached the backend.
    if(state==WAIT_APPLY||action_ready)state<=DRAIN;
    else finish((cancel_valid&&cancel_token==action_token)?8'h43:
                (!remote_online&&command!=14)?8'hc0:8'h48);
   end
  end
  if(request_valid&&request_ready)begin
   action_token<=request_token;command<=request_command;age<=0;
   action_audio<=request_command==13||request_command==14;
   action_code<=request_command==9?8'h20:request_command==10?(request_argument==4?8'h16:request_argument==5?8'h17:request_argument==6?8'h18:8'h10+request_argument):
                request_command==14?8'd0:request_argument;
   if((request_command!=14&&!remote_online)||
      (request_command==10&&(request_argument>6||actual_emergency||(automatic_mode&&request_argument<2)))||
      (request_command==13&&(request_argument<1||request_argument>12||automatic_mode||actual_emergency)))begin
    response_valid<=1;response_token<=request_token;
    response_payload<={(MINIMAL_REPLY?168'd0:actual_status_payload[191:24]),
      ((request_command!=14&&!remote_online)?8'hc0:request_command==10?8'h49:8'h47),8'd1,request_command};
   end else state<=DISPATCH;
  end
 end
end
endmodule
