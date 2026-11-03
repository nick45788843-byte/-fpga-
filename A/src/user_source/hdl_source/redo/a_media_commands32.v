// Grants full image UID from A's shared forward allocator and publishes actual
// PCM source UID. Each F8 remains stable until matching real B kind4c capture.
module a_media_commands32 #(parameter FAIR_POLL=0)(input clk,rst_n,session_ready,identity_known,
 input packet_valid,output packet_consume,input [7:0] packet_kind,input [6:0] packet_count,
 input [15:0] packet_sequence,packet_tag,input [31:0] packet_value,
 output borrow_valid,input borrow_ready,input [31:0] borrowed_uid,
 input [31:0] pcm_uid,input [7:0] pcm_id,input pcm_cancel,
 input action_valid,input [63:0] action_header,
 output command_valid,output [63:0] command_header,output reg [31:0] image_uid,
 output action_done,output [31:0] action_done_uid,output [7:0] action_done_error,input poll_finished,input [31:0] pcm_completed_token,pcm_failed_token,output [31:0] text_uid,output [3:0] action_done_image,output action_done_automatic);
reg image_pending,image_offer;reg [15:0] ticket;reg [31:0] grant_uid;
reg restore_pending,restore_offer;reg [15:0] restore_ticket;reg [31:0] restore_uid;
assign text_uid=restore_uid;
reg audio_seen_complete,audio_seen_failed;
reg audio_offer;reg [31:0] audio_seen_uid;reg [7:0] audio_seen_id;reg audio_seen_cancel;
reg [1:0] selected;
wire image_request=packet_valid&&packet_kind==8'h4b&&packet_count==0&&packet_sequence[7:0]==1&&packet_value==0;
wire restore_request=packet_valid&&packet_kind==8'h4b&&packet_count==0&&packet_sequence[7:0]==3&&packet_value==0;
wire response=packet_valid&&packet_kind==8'h4c&&packet_count==0;
wire newer_image=image_request&&session_ready&&packet_tag>ticket;
wire newer_restore=restore_request&&session_ready&&packet_tag>restore_ticket;
assign packet_consume=packet_valid&&(packet_kind==8'h4b||packet_kind==8'h4c);
assign borrow_valid=(restore_pending||image_pending)&&session_ready&&!newer_image&&!newer_restore;
assign action_done=response&&(packet_sequence[7:0]>=8'h10&&packet_sequence[7:0]<=8'h20||packet_sequence[7:0]>=8'h30&&packet_sequence[7:0]<=8'h33);
assign action_done_image=packet_tag[3:0];assign action_done_automatic=packet_tag[4];
assign action_done_uid=packet_value;assign action_done_error=packet_sequence[15:8];
assign command_valid=identity_known&&(selected==0?image_offer:selected==1?audio_offer:selected==2?action_valid:restore_offer);
wire [63:0] image_header={8'hf8,8'd1,ticket[7:0],ticket[15:8],grant_uid[7:0],grant_uid[15:8],grant_uid[23:16],grant_uid[31:24]};
wire [63:0] audio_header={8'hf8,8'd2,audio_seen_id,5'd0,audio_seen_failed,audio_seen_complete,audio_seen_cancel,audio_seen_uid[7:0],audio_seen_uid[15:8],audio_seen_uid[23:16],audio_seen_uid[31:24]};
wire [63:0] restore_header={8'hf8,8'd3,restore_ticket[7:0],restore_ticket[15:8],restore_uid[7:0],restore_uid[15:8],restore_uid[23:16],restore_uid[31:24]};
// Change source only on actual acknowledgement so the snapshot has one owner.
assign command_header=selected==0?image_header:selected==1?audio_header:selected==2?action_header:restore_header;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin image_pending<=0;image_offer<=0;ticket<=0;grant_uid<=0;image_uid<=0;audio_offer<=0;audio_seen_uid<=0;audio_seen_complete<=0;audio_seen_failed<=0;audio_seen_id<=0;audio_seen_cancel<=1;selected<=0;
  restore_pending<=0;restore_offer<=0;restore_ticket<=0;restore_uid<=0;end
 else begin
  // A B reset can reuse its local ticket. Never replay a pre-F0 grant for it.
  if(!session_ready)begin image_pending<=0;image_offer<=0;grant_uid<=0;ticket<=0;
   restore_pending<=0;restore_offer<=0;restore_uid<=0;restore_ticket<=0;end
  if(image_request&&session_ready)begin
   if(packet_tag==ticket&&grant_uid!=0&&!image_pending)image_offer<=1;
   // B advances its nonwrapping ticket after consuming the previous grant.
   // Its capture ACK may have been lost; a newer request still needs a fresh UID.
   else if(newer_image)begin ticket<=packet_tag;image_pending<=1;image_offer<=0;grant_uid<=0;end
  end
  if(restore_request&&session_ready)begin
   if(packet_tag==restore_ticket&&restore_uid!=0&&!restore_pending)restore_offer<=1;
   else if(newer_restore)begin restore_ticket<=packet_tag;restore_pending<=1;restore_offer<=0;restore_uid<=0;end
  end
  if(borrow_valid&&borrow_ready)begin
   if(restore_pending)begin restore_pending<=0;restore_offer<=1;restore_uid<=borrowed_uid;end
   else begin image_pending<=0;image_offer<=1;grant_uid<=borrowed_uid;image_uid<=borrowed_uid;end
  end
  if(pcm_uid!=0&&(pcm_uid!=audio_seen_uid||pcm_id!=audio_seen_id||pcm_cancel!=audio_seen_cancel||(pcm_completed_token==pcm_uid&&pcm_id==0)!=audio_seen_complete||(pcm_failed_token==pcm_uid&&pcm_id==0)!=audio_seen_failed))begin
   audio_seen_uid<=pcm_uid;audio_seen_id<=pcm_id;audio_seen_cancel<=pcm_cancel;audio_seen_complete<=pcm_completed_token==pcm_uid&&pcm_id==0;audio_seen_failed<=pcm_failed_token==pcm_uid&&pcm_id==0;audio_offer<=1;
  end
  if(response&&packet_sequence[7:0]==1&&packet_tag==ticket&&packet_value==grant_uid)image_offer<=0;
  if(response&&packet_sequence[7:0]==2&&packet_value==audio_seen_uid&&packet_tag=={5'd0,audio_seen_failed,audio_seen_complete,audio_seen_cancel,audio_seen_id})audio_offer<=0;
  if(response&&packet_sequence[7:0]==3&&packet_value==restore_uid&&packet_tag==restore_ticket)restore_offer<=0;
  if(FAIR_POLL&&poll_finished)begin
   case(selected)
    0:selected<=audio_offer?1:action_valid?2:restore_offer?3:0;
    1:selected<=action_valid?2:restore_offer?3:image_offer?0:1;
    2:selected<=restore_offer?3:image_offer?0:audio_offer?1:2;
    3:selected<=image_offer?0:audio_offer?1:action_valid?2:3;
   endcase
  end else case(selected)
   0:if(!image_offer)selected<=audio_offer?1:action_valid?2:restore_offer?3:0;
   1:if(!audio_offer)selected<=action_valid?2:restore_offer?3:image_offer?0:1;
   2:if(!action_valid)selected<=restore_offer?3:image_offer?0:audio_offer?1:2;
   3:if(!restore_offer)selected<=image_offer?0:audio_offer?1:action_valid?2:3;
  endcase
 end
end
endmodule
