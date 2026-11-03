// Use the already allocated PC operation UID. Cancellation targets that UID;
// it never borrows another sequence while the router is draining the old owner.
module a_pcm_control32(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_uid,input [7:0] request_id,
 input cancel_valid,input [31:0] cancel_uid,
 output command_valid,input command_ready,output reg [31:0] command_uid,output reg [7:0] command_id,
 output service_cancel,output [31:0] service_cancel_uid,
 input [31:0] acknowledged_uid,status,input playback_applied,service_drained,
 output reg applied_valid,output reg [31:0] applied_uid,output reg [7:0] applied_error,
 output reg cancel_done,output reg [31:0] cancel_done_uid);
localparam IDLE=0,SEND=1,EFFECT=2,DRAIN=3;
reg [1:0] state;
assign request_ready=state==IDLE&&request_uid!=0;
assign command_valid=state==SEND&&!(cancel_valid&&cancel_uid==command_uid);
assign service_cancel=state==DRAIN;
assign service_cancel_uid=command_uid;
wire abort_owner=cancel_valid&&cancel_uid==command_uid&&(state==SEND||state==EFFECT);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;command_uid<=0;command_id<=0;applied_valid<=0;applied_uid<=0;applied_error<=0;cancel_done<=0;cancel_done_uid<=0;end
 else begin
  applied_valid<=0;cancel_done<=0;
  case(state)
   IDLE:if(request_valid&&request_ready)begin command_uid<=request_uid;command_id<=request_id;state<=SEND;end
   SEND:if(command_valid&&command_ready)state<=EFFECT;
   EFFECT:if(!abort_owner&&acknowledged_uid==command_uid&&
     ((status[23:16]!=0&&service_drained)||(command_id==0&&status[7:0]==0&&service_drained)||
      (command_id!=0&&status[7:0]==command_id&&playback_applied&&status[23:16]==0)))begin
      applied_valid<=1;applied_uid<=command_uid;applied_error<=status[23:16];state<=IDLE;
     end
   DRAIN:if(acknowledged_uid==command_uid&&service_drained&&status[7:0]==0&&status[23:16]==0)begin
    cancel_done<=1;cancel_done_uid<=command_uid;state<=IDLE;
   end
  endcase
  if(abort_owner)begin
   // Before a command handshake there is no new service owner to cancel.
   if(state==SEND)begin cancel_done<=1;cancel_done_uid<=command_uid;state<=IDLE;end
   else state<=DRAIN;
  end
 end
end
endmodule
