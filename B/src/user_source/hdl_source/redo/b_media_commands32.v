// F8 eight-byte command: opcode, two bounded arguments and full operation UID.
// Image ticket is only a pending-request correlation; A allocates every actual
// image UID, including B scanning/prefetch/automatic work. No B UID counter.
module b_media_commands32 #(parameter RESTORE_ENABLED=0,RELOAD_START_ACK=0,PROGRAM_START_GUARD=0,ACTUAL_MODE_TAG=0)(input clk,rst_n,input reply_valid,input [255:0] fragment,
 input notice_valid,input [31:0] notice_token,input notice_session,
 input global_done,input reader_drained,producer_drained,image_reader_drained,image_producer_drained,transport_idle,image_req,image_control_idle,
 input [3:0] cached_mask,input display_valid,
 output reg [31:0] image_uid,audio_uid,output reg [7:0] audio_id,output reg audio_cancel,output reg image_granted,
 output reg next_image,previous_image,reload,auto_valid,auto_value,auto_toggle,
 output pause_action,output control_done,output [31:0] control_token,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 input text_grant_needed,output text_grant_valid,output reg [31:0] text_uid,input reload_accepted,output reg menu_toggle,menu_next,menu_plus,menu_minus,
 output reg play_mode_valid,output reg [1:0] play_mode,
 output reg program_audio_terminal,output reg [7:0] program_audio_id,input program_available,input [3:0] current_image,image_count,input program_prepared,actual_automatic,input [1:0] actual_play_mode);
reg [3:0] target_image,last_action_image;reg last_action_auto,start_pending,activation_sent;
reg [31:0] last_terminal_uid;
reg [31:0] last_menu_uid;reg [7:0] last_menu_code,last_menu_error;
reg session_live;reg [31:0] session_floor;reg [15:0] prefix,ticket;reg image_wait,image_seen;reg [7:0] last_action_error;
reg [15:0] image_ticket,text_ticket,last_text_ticket;reg text_wait,text_granted,grant_turn;
reg [31:0] action_uid,last_action_uid,last_audio_uid;reg [7:0] action_code;reg action_owned,action_cancelled;
reg [2:0] action_settle;
reg offer,accepted,request_again;reg [7:0] held_kind,held_opcode,held_error;reg [15:0] held_ticket;reg [31:0] held_uid;
reg response_pending;reg [7:0] response_opcode,response_error;reg [15:0] response_ticket;reg [31:0] response_uid;
// Isolate the retry/grant fanout from the raw cancellation notice. The direct
// notice path below still clears an offer in the same cycle; this registered
// copy only gates creation of a new retry offer and preserves cancellation
// behavior while removing the high-fanout timing path into retry_reg.
reg notice_valid_retry;
// all_owners performs the token fan-in for the cancellation barrier. Register
// its completion before reopening the media grant path so that this control
// fan-in cannot share the retry counter's same-cycle combinational cone.
reg global_done_q;
localparam RETRY_CYCLES=2048;
// Bounded delay; transaction UIDs and session namespace remain full 32 bits.
reg [$clog2(RETRY_CYCLES+1)-1:0] retry;
wire [7:0] opcode=fragment[247:240],arg0=fragment[239:232],arg1=fragment[231:224];
wire [31:0] uid={fragment[199:192],fragment[207:200],fragment[215:208],fragment[223:216]};
wire command=reply_valid&&fragment[255:248]==8'hf8&&uid>session_floor&&session_live&&uid[31:16]==prefix&&!notice_valid&&!response_pending;
wire affected=notice_valid&&(notice_session||notice_token==action_uid||notice_token==image_uid||notice_token==audio_uid);
wire reload_start=RELOAD_START_ACK&&action_code==8'h20&&!action_cancelled;
wire plan_action=action_code>=8'h12&&action_code<=8'h18&&!action_cancelled;
wire staged_start=PROGRAM_START_GUARD&&start_pending&&!action_cancelled;
wire programme_ready=!program_available||program_prepared;
wire enable_request=opcode==8'h12||opcode==8'h14||(opcode>=8'h16&&opcode<=8'h18)||(opcode==8'h15&&!actual_automatic);
wire selected_frame_complete=ACTUAL_MODE_TAG&&!action_cancelled&&!notice_valid&&(action_code==8'h10||action_code==8'h11)&&display_valid&&target_image!=0&&current_image==target_image;
wire action_complete=selected_frame_complete||(reload_start?reload_accepted:
 staged_start?(activation_sent&&actual_automatic&&programme_ready&&actual_play_mode==play_mode):plan_action?1'b1:image_reader_drained&&(action_cancelled||image_control_idle));
wire [7:0] action_error=action_cancelled?8'h43:reload_start?8'd0:
 (action_code==8'h10||action_code==8'h11)&&(!display_valid||target_image==0||current_image!=target_image)?8'h49:8'd0;
assign pause_action=action_owned&&action_cancelled;
assign control_done=notice_valid&&(!affected||reader_drained&&producer_drained&&!action_owned)&&transport_idle&&!offer&&!accepted;
assign control_token=notice_token;
assign tx_valid=offer;assign tx_kind=held_kind;assign tx_count=0;
assign tx_sequence={held_error,held_opcode};assign tx_tag=held_ticket;assign tx_value=held_uid;
assign text_grant_valid=RESTORE_ENABLED&&text_granted;
function [15:0] image_receipt;input [3:0] im;input am;begin image_receipt={11'd0,(ACTUAL_MODE_TAG&&am),im};end endfunction
task respond;input [7:0] op,err;input [15:0] tk;input [31:0] id;
begin response_pending<=1;end endtask

// The old response calls and held-publication sites are mutually exclusive.
// Preserve their guards and NBA priority; share only the wide data writers.
reg [9:0] response_event;
reg [2:0] publication_event;
always @(*)begin
 response_event=0;
 if(command)begin
  if(opcode==1&&image_wait&&{arg1,arg0}==image_ticket)response_event[0]=1;
  else if(opcode==1&&{arg1,arg0}==image_ticket&&uid==image_uid&&uid!=0)response_event[1]=1;
  else if(RESTORE_ENABLED&&opcode==3&&text_wait&&{arg1,arg0}==text_ticket)response_event[2]=1;
  else if(RESTORE_ENABLED&&opcode==3&&!text_wait&&{arg1,arg0}==last_text_ticket&&uid==text_uid&&uid!=0)response_event[3]=1;
  else if(opcode>=8'h30&&opcode<=8'h33)begin
   if(uid>last_menu_uid)response_event[4]=1;
   else if(uid==last_menu_uid&&opcode==last_menu_code)response_event[5]=1;
  end else if(opcode==2&&(uid>last_audio_uid||uid==audio_uid))response_event[6]=1;
  else if(opcode>=8'h10&&opcode<=8'h20)begin
   if(action_owned&&uid==action_uid)begin end
   else if(!action_owned&&uid==last_action_uid)response_event[7]=1;
   else if(!action_owned&&uid>last_action_uid)begin
    if((opcode==8'h16||(PROGRAM_START_GUARD&&opcode>=8'h17&&opcode<=8'h18))&&!program_available)response_event[8]=1;
   end
  end
 end
 if(action_owned&&!(staged_start&&!activation_sent)&&action_settle==7&&
    (plan_action||selected_frame_complete||image_producer_drained)&&action_complete&&!response_pending&&!command)
  response_event[9]=1;
 publication_event=0;
 if(!offer&&!accepted)begin
  if(response_pending&&!notice_valid_retry)publication_event[0]=1;
  else if(text_wait&&!notice_valid_retry&&retry==0&&(grant_turn||!image_wait))publication_event[1]=1;
  else if(image_wait&&!notice_valid_retry&&retry==0)publication_event[2]=1;
 end
end
wire [7:0] selected_response_opcode=({8{|response_event[8:0]}}&opcode)|({8{response_event[9]}}&action_code);
wire [7:0] selected_response_error=
 ({8{response_event[4]}}&(arg1[0]?8'h43:8'd0))|
 ({8{response_event[5]}}&last_menu_error)|
 ({8{response_event[7]}}&last_action_error)|
 ({8{response_event[8]}}&8'h57)|({8{response_event[9]}}&action_error);
wire [15:0] selected_response_ticket=
 ({16{|response_event[1:0]}}&image_ticket)|
 ({16{response_event[2]}}&text_ticket)|({16{response_event[3]}}&last_text_ticket)|
 ({16{response_event[6]}}&{arg1,arg0})|
 ({16{response_event[7]}}&image_receipt(last_action_image,last_action_auto))|
 ({16{response_event[8]}}&(ACTUAL_MODE_TAG?image_receipt(current_image,actual_automatic):16'd0))|
 ({16{response_event[9]}}&image_receipt(current_image,actual_automatic));
wire [31:0] selected_response_uid=({32{|response_event[8:0]}}&uid)|({32{response_event[9]}}&action_uid);
wire [7:0] selected_held_kind=({8{publication_event[0]}}&8'h4c)|({8{|publication_event[2:1]}}&8'h4b);
wire [7:0] selected_held_opcode=({8{publication_event[0]}}&response_opcode)|
 ({8{publication_event[1]}}&8'd3)|({8{publication_event[2]}}&8'd1);
wire [7:0] selected_held_error=({8{publication_event[0]}}&response_error);
wire [15:0] selected_held_ticket=({16{publication_event[0]}}&response_ticket)|
 ({16{publication_event[1]}}&text_ticket)|({16{publication_event[2]}}&image_ticket);
wire [31:0] selected_held_uid=({32{publication_event[0]}}&response_uid);

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  target_image<=0;last_action_image<=0;last_action_auto<=0;start_pending<=0;activation_sent<=0;last_terminal_uid<=0;play_mode_valid<=0;play_mode<=1;program_audio_terminal<=0;program_audio_id<=0;
  last_menu_uid<=0;last_menu_code<=0;last_menu_error<=0;menu_toggle<=0;menu_next<=0;menu_plus<=0;menu_minus<=0;
  session_live<=0;session_floor<=0;prefix<=0;ticket<=0;image_wait<=0;image_granted<=0;image_seen<=0;image_uid<=0;audio_uid<=0;audio_id<=0;audio_cancel<=1;
  image_ticket<=0;text_ticket<=0;last_text_ticket<=0;text_wait<=0;text_granted<=0;text_uid<=0;grant_turn<=0;
  action_uid<=0;last_action_uid<=0;last_audio_uid<=0;last_action_error<=0;action_code<=0;action_owned<=0;action_cancelled<=0;action_settle<=0;
  next_image<=0;previous_image<=0;reload<=0;auto_valid<=0;auto_value<=0;auto_toggle<=0;
  offer<=0;accepted<=0;held_kind<=0;held_opcode<=0;held_error<=0;held_ticket<=0;held_uid<=0;retry<=0;request_again<=0;
  response_pending<=0;response_opcode<=0;response_error<=0;response_ticket<=0;response_uid<=0;notice_valid_retry<=0;global_done_q<=0;
 end else begin
  notice_valid_retry<=notice_valid;
  global_done_q<=global_done;
  play_mode_valid<=0;program_audio_terminal<=0;next_image<=0;previous_image<=0;reload<=0;auto_valid<=0;auto_toggle<=0;menu_toggle<=0;menu_next<=0;menu_plus<=0;menu_minus<=0;
  if(offer&&tx_ready)begin offer<=0;accepted<=1;end
  if(accepted&&tx_done)begin accepted<=0;retry<=RETRY_CYCLES;end
  if(retry!=0)retry<=retry-1'b1;
  if(notice_valid&&notice_session)begin session_live<=0;image_wait<=0;image_granted<=0;image_seen<=0;response_pending<=0;audio_cancel<=1;audio_id<=0;
   text_wait<=0;text_granted<=0;text_uid<=0;end
  if(global_done_q&&notice_session)begin session_live<=1;session_floor<=notice_token;prefix<=notice_token[31:16];last_action_uid<=notice_token;last_audio_uid<=notice_token;last_menu_uid<=notice_token;end
  if(affected&&action_owned)action_cancelled<=1;
  if(!image_req)begin image_seen<=0;if(image_granted)image_granted<=0;end
  if(RESTORE_ENABLED&&!text_grant_needed)begin text_granted<=0;text_wait<=0;end
  if(session_live&&!notice_valid&&RESTORE_ENABLED&&text_grant_needed&&!text_wait&&!text_granted&&ticket!=16'hffff)begin
   ticket<=ticket+1'b1;text_ticket<=ticket+1'b1;text_wait<=1;retry<=0;
  end else if(session_live&&!notice_valid&&image_req&&!image_seen&&!image_wait&&!image_granted&&ticket!=16'hffff)begin
   ticket<=ticket+1'b1;image_ticket<=ticket+1'b1;image_wait<=1;image_seen<=1;retry<=0;
  end
  if(command)begin
   if(opcode==1&&image_wait&&{arg1,arg0}==image_ticket)begin image_uid<=uid;image_wait<=0;image_granted<=1;respond(1,0,image_ticket,uid);end
   else if(opcode==1&&{arg1,arg0}==image_ticket&&uid==image_uid&&uid!=0)respond(1,0,image_ticket,uid);
   else if(RESTORE_ENABLED&&opcode==3&&text_wait&&{arg1,arg0}==text_ticket)begin
    text_uid<=uid;last_text_ticket<=text_ticket;text_wait<=0;text_granted<=1;respond(3,0,text_ticket,uid);
   end else if(RESTORE_ENABLED&&opcode==3&&!text_wait&&{arg1,arg0}==last_text_ticket&&uid==text_uid&&uid!=0)respond(3,0,last_text_ticket,uid);
   else if(opcode>=8'h30&&opcode<=8'h33)begin
    if(uid>last_menu_uid)begin
     last_menu_uid<=uid;last_menu_code<=opcode;last_menu_error<=arg1[0]?8'h43:0;
     if(!arg1[0])case(opcode)
      8'h30:menu_toggle<=1;8'h31:menu_next<=1;8'h32:menu_plus<=1;8'h33:menu_minus<=1;
     endcase
     respond(opcode,arg1[0]?8'h43:0,0,uid);
    end else if(uid==last_menu_uid&&opcode==last_menu_code)respond(opcode,last_menu_error,0,uid);
   end else if(opcode==2&&(uid>last_audio_uid||uid==audio_uid))begin
    if(arg0==0&&(arg1[1]||arg1[2])&&uid!=last_terminal_uid)begin
     last_terminal_uid<=uid;program_audio_id<=audio_id;
     if(arg1[1]&&!arg1[2])program_audio_terminal<=1;
     else if(play_mode==0)begin auto_valid<=1;auto_value<=0;end
    end
    audio_uid<=uid;audio_id<=arg0;audio_cancel<=arg1[0]||arg0==0;last_audio_uid<=uid;respond(2,0,{arg1,arg0},uid);
   end else if(opcode>=8'h10&&opcode<=8'h20)begin
    if(action_owned&&uid==action_uid)begin if(arg1[0])action_cancelled<=1;end
    else if(!action_owned&&uid==last_action_uid)respond(opcode,last_action_error,image_receipt(last_action_image,last_action_auto),uid);
    else if(!action_owned&&uid>last_action_uid)begin
     action_owned<=1;action_uid<=uid;last_action_uid<=uid;action_code<=opcode;action_cancelled<=arg1[0];action_settle<=0;start_pending<=PROGRAM_START_GUARD&&enable_request;activation_sent<=0;
     target_image<=opcode==8'h10 ? (current_image>=image_count?4'd1:current_image+4'd1) :
                   opcode==8'h11 ? (current_image<=1?image_count:current_image-4'd1) : current_image;
     if((opcode==8'h16||(PROGRAM_START_GUARD&&opcode>=8'h17&&opcode<=8'h18))&&!program_available)begin
      action_owned<=0;last_action_error<=8'h57;last_action_image<=ACTUAL_MODE_TAG ? current_image : 4'd0;last_action_auto<=actual_automatic;
      respond(opcode,8'h57,ACTUAL_MODE_TAG ? image_receipt(current_image,actual_automatic) : 16'd0,uid);
     end else if(PROGRAM_START_GUARD&&enable_request&&!arg1[0])begin
      // Stop the running plan, republish fresh metadata and wait for its real
      // A release ACK before enabling picture/audio/subtitle consumption.
      auto_valid<=1;auto_value<=0;play_mode_valid<=1;
      play_mode<=(opcode==8'h14||opcode==8'h16) ? 2'd0 : opcode==8'h17 ? 2'd1 : opcode==8'h18 ? 2'd2 : actual_play_mode;
     end else if(!arg1[0])case(opcode)
      8'h10:next_image<=1;8'h11:previous_image<=1;
      8'h12:begin auto_valid<=1;auto_value<=1;end 8'h13:begin auto_valid<=1;auto_value<=0;end
      8'h15:auto_toggle<=1;
      8'h14,8'h16,8'h17,8'h18:begin
       play_mode_valid<=1;play_mode<=opcode==8'h14 ? 0 : opcode==8'h16 ? 0 : opcode==8'h17 ? 1 : 2;
       auto_valid<=1;auto_value<=1;
      end
      8'h20:reload<=1;
     endcase
    end
   end
  end
  if(action_owned)begin
   if(staged_start&&!activation_sent)begin
    if(action_settle<3)action_settle<=action_settle+1'b1;
    if(action_settle>=3&&programme_ready&&!actual_automatic&&actual_play_mode==play_mode)begin auto_valid<=1;auto_value<=1;activation_sent<=1;action_settle<=0;end
   end else begin
   if(!action_complete||(!plan_action&&!selected_frame_complete&&!image_producer_drained))action_settle<=0;
   else if(action_settle!=7)action_settle<=action_settle+1'b1;
   if(action_settle==7&&(plan_action||selected_frame_complete||image_producer_drained)&&action_complete&&!response_pending&&!command)begin
    action_owned<=0;last_action_error<=action_error;last_action_image<=current_image;last_action_auto<=actual_automatic;
    respond(action_code,action_error,image_receipt(current_image,actual_automatic),action_uid);
   end
  end
   end
  if(!offer&&!accepted)begin
   if(response_pending&&!notice_valid_retry)begin
    offer<=1;response_pending<=0;
   end else if(text_wait&&!notice_valid_retry&&retry==0&&(grant_turn||!image_wait))begin
    offer<=1;grant_turn<=0;
   end else if(image_wait&&!notice_valid_retry&&retry==0)begin
    offer<=1;grant_turn<=1;
   end
  end

  if(|response_event)begin
   response_opcode<=selected_response_opcode;response_error<=selected_response_error;
   response_ticket<=selected_response_ticket;response_uid<=selected_response_uid;
  end
  if(|publication_event)begin
   held_kind<=selected_held_kind;held_opcode<=selected_held_opcode;held_error<=selected_held_error;
   held_ticket<=selected_held_ticket;held_uid<=selected_held_uid;
  end
  if(notice_valid&&!accepted&&!(offer&&tx_ready))offer<=0;
 end
end
endmodule
