// A bounded tap of the actual 24-bit HDMI PCM output, after gain and envelope.
// Four-phase arm/echo prevents a cancelled CDC request from becoming a ghost.
module a_pcm_capture(input clk,rst_n,video_clk,video_rst_n,
 input pcm_valid,input [23:0] pcm_left,pcm_right,
 input session_ready,identity_known,input [15:0] namespace_prefix,input [31:0] next_uid,
 input command_valid,output command_ready,input [7:0] kind,arg,input [6:0] count,
 input [15:0] sequence_id,tag,input [31:0] value,
 input cancel_valid,input [31:0] cancel_token,input flush,
 output fragment_valid,output [63:0] fragment_header,input fragment_locked,
 input [4:0] fragment_address,output [7:0] fragment_byte,output drained);
localparam IDLE=0,ARM=1,CAPTURE=2,DRAIN=3,SEND=4;
reg [2:0] state;
reg armed,aborting,abort_pending,complete;
reg [31:0] owner,last_owner;
reg [7:0] block_index;
reg [31:0] read_word;
(* force_ram=1,ram_style="bram" *) reg [31:0] samples[0:255];
(* async_reg=1,preserve=1 *) reg [1:0] arm_sync,echo_sync,done_sync,idle_sync;
reg video_working,video_done;
reg [7:0] video_index;
wire video_idle=!video_working&&!arm_sync[1];
wire abort_command=kind==8'h4d&&sequence_id==1&&arg==0&&count==0&&tag==0&&value!=0;
wire begin_command=kind==8'h4d&&sequence_id==0&&arg==0&&count==0&&tag==0&&
 value!=0&&session_ready&&identity_known&&value[31:16]==namespace_prefix&&value<next_uid;
wire ack_command=kind==8'h4e&&arg==0&&count==0&&sequence_id==0&&tag[15:8]==0&&value==owner;
wire affected=flush||cancel_valid&&cancel_token==owner||abort_pending;
wire abort_owner=command_valid&&abort_command&&state!=IDLE&&value==owner;
assign command_ready=command_valid&&(kind==8'h4d||kind==8'h4e);
assign fragment_valid=state==SEND&&!fragment_locked;
wire [7:0] send_index=aborting?8'hfe:block_index;
wire [7:0] send_count=(aborting||block_index==8'hff) ? 8'd0 : (block_index==8'd42 ? 8'd16 : 8'd24);
assign fragment_header={8'hf9,8'd0,send_index,send_count,owner[7:0],owner[15:8],owner[23:16],owner[31:24]};
wire [7:0] read_index=block_index*8'd6+{5'd0,fragment_address[4:2]}-8'd2;
always @(posedge clk)read_word<=samples[read_index];
assign fragment_byte=fragment_address>=8&&fragment_address-8<send_count&&!aborting?
 read_word[{fragment_address[1:0],3'b000}+:8]:8'd0;
assign drained=state==IDLE&&!armed&&!echo_sync[1]&&!done_sync[1]&&idle_sync[1];
always @(posedge video_clk or negedge video_rst_n)begin
 if(!video_rst_n)begin arm_sync<=0;video_working<=0;video_done<=0;video_index<=0;end
 else begin
  arm_sync<={arm_sync[0],armed};
  if(!arm_sync[1])begin video_working<=0;video_done<=0;video_index<=0;end
  else if(!video_working&&!video_done)begin video_working<=1;video_index<=0;end
  else if(video_working&&pcm_valid)begin
   if(video_index==255)begin video_working<=0;video_done<=1;end
   else video_index<=video_index+1'b1;
  end
 end
end
always @(posedge video_clk)if(video_rst_n&&arm_sync[1]&&video_working&&pcm_valid)
 samples[video_index]<={pcm_right[23:8],pcm_left[23:8]};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin echo_sync<=0;done_sync<=0;idle_sync<=0;state<=IDLE;armed<=0;
  aborting<=0;abort_pending<=0;complete<=0;owner<=0;last_owner<=0;block_index<=0;end
 else begin
  echo_sync<={echo_sync[0],arm_sync[1]};done_sync<={done_sync[0],video_done};idle_sync<={idle_sync[0],video_idle};
  if((affected||abort_owner)&&state!=IDLE)begin
   abort_pending<=1;
   // Keep synchronous sample bytes immutable until the publisher finishes.
   if(!fragment_locked)aborting<=1;
  end
  case(state)
   IDLE:if(command_valid&&begin_command&&value>last_owner&&drained)begin
    owner<=value;last_owner<=value;armed<=1;aborting<=0;abort_pending<=0;complete<=0;block_index<=0;state<=ARM;
   end else if(command_valid&&abort_command&&drained)begin
    owner<=value;armed<=0;aborting<=1;abort_pending<=1;complete<=0;state<=DRAIN;
   end
   ARM:if(echo_sync[1])begin
    if(aborting||affected)begin armed<=0;state<=DRAIN;end else state<=CAPTURE;
   end
   CAPTURE:if(done_sync[1]||aborting||affected)begin
    complete<=done_sync[1]&&!aborting&&!affected;armed<=0;state<=DRAIN;
   end
   DRAIN:if(!echo_sync[1]&&!done_sync[1]&&idle_sync[1])begin
    if(complete||aborting||affected)state<=SEND;else state<=IDLE;
   end
   SEND:if(command_valid&&ack_command&&tag[7:0]==send_index&&!fragment_locked&&
           (aborting||!affected&&!abort_owner))begin
    if(aborting||block_index==8'hff)begin state<=IDLE;aborting<=0;abort_pending<=0;complete<=0;end
    else if(block_index==42)begin block_index<=8'hff;complete<=0;end
    else block_index<=block_index+1'b1;
   end
  endcase
 end
end
endmodule
