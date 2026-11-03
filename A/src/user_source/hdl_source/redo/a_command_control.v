// Flat control bookkeeping: one active operation, one old operation draining,
// and one small reject descriptor. Complete result bytes live in a_reply_store.
// Input packet body is a leased RX RAM bank, not copied to another payload RAM.
module a_command_control #(parameter EXEC_TIMEOUT_MS=20000,GEOMETRY_TIMEOUT_MS=35000,BORROW_DURING_LOCAL=0,PCM_ANALYSIS_ENABLED=1,BOARD_CONTROL_ENABLED=0)(input clk,rst_n,tick_ms,
 input packet_valid,output packet_ready,input [15:0] packet_session,packet_sequence,packet_length,
 input [7:0] packet_command,input [47:0] packet_arguments,input packet_bank,packet_has_bank,
 input peer_ready,input [31:0] first_execution_token,input initialize_valid,output initialize_ready,
 output request_valid,input request_ready,output reg request_remote,
 output reg [31:0] request_token,output reg [31:0] request_wire_id,
 output reg [7:0] request_command,output reg [15:0] request_length,output reg [47:0] request_arguments,output reg request_bank,request_has_bank,
 output reg release_valid,output reg release_bank,
 output cancel_valid,output cancel_remote,output [31:0] cancel_token,
 input cancel_done,input [31:0] cancel_done_token,
 output reg urgent_enter,output reg urgent_preset_valid,output reg [1:0] urgent_preset,
 input result_valid,output result_ready,input [31:0] result_token,
 output submit_valid,input submit_ready,output [31:0] submit_wire_id,submit_owner,
 output submit_synthetic,submit_cache_enable,output reg invalidate_cache,output [7:0] synthetic_command,synthetic_error,
 input captured,input [31:0] captured_owner,
 input cache_valid,input [31:0] cache_wire_id,
 output replay_valid,input replay_ready,
 output reply_remote,output reg exhausted,output idle,output [31:0] next_execution_token,
 input borrow_valid,output borrow_ready,output [31:0] borrowed_token,
 input board_request_valid,output board_request_ready,input [7:0] board_request_command,
 input [47:0] board_request_arguments,input board_cancel,
 output board_result_valid,input board_result_ready,output board_result_synthetic,
 output [7:0] board_result_command,board_result_error,output result_address_board);
reg open,seen_sequence;reg [15:0] session,last_sequence;
reg active,issued,body_owned,draining,drain_remote,drain_body_owned,drain_bank;
reg request_board,board_failure;reg [7:0] board_failure_command,board_failure_error;
reg [31:0] drain_token,counter;
assign next_execution_token=counter;
assign borrowed_token=counter;
wire board_command_ok=board_request_command>=24&&board_request_command<=26;
reg rejected,reply_building,build_synthetic,build_remote;reg [31:0] reject_wire;
wire [31:0] build_owner=build_synthetic?32'd0:request_token;
assign board_request_ready=BOARD_CONTROL_ENABLED&&!initialize_valid&&!packet_valid&&!borrow_valid&&!exhausted&&peer_ready&&
 !active&&!draining&&!rejected&&!reply_building&&!board_failure&&!board_cancel&&board_command_ok;
// Auxiliary IDs never change an active or draining owner's identity. The
// production arbiter also needs a fresh F0 cookie during recovery, so the
// optional mode permits this independent allocation while an owner drains.
assign borrow_ready=!initialize_valid&&!packet_valid&&!exhausted&&
 ((!active&&!draining)||BORROW_DURING_LOCAL)&&!rejected&&!reply_building;
reg [7:0] reject_command,reject_error;reg [71:0] cache_identity;
reg urgent_seen;
localparam MAX_EXEC_MS=GEOMETRY_TIMEOUT_MS>EXEC_TIMEOUT_MS?GEOMETRY_TIMEOUT_MS:EXEC_TIMEOUT_MS;
localparam AW=$clog2(MAX_EXEC_MS+1);
wire geometry_operation=(request_command==5||(BOARD_CONTROL_ENABLED&&request_command==25))&&request_length==6&&request_arguments[15:0]==16'h0204;
wire [AW-1:0] execution_deadline=geometry_operation?GEOMETRY_TIMEOUT_MS:EXEC_TIMEOUT_MS;
reg [AW-1:0] age;reg abort_pending;reg [7:0] abort_error;
wire [31:0] wire_id={packet_session,packet_sequence};
wire [71:0] identity={packet_command,packet_length,packet_arguments};
// Every CMD16 reads A's committed UTF8 store locally: pages 80..BB select a
// CMD22 target, other arguments are legacy offsets into the subtitle target.
// CMD12 glyph readback is retired with the legacy text path.
wire local_stream_query=packet_command==16;
wire remote_command=packet_command==3||packet_command==4||packet_command==5||packet_command==6||packet_command==11||packet_command==22||(PCM_ANALYSIS_ENABLED&&packet_command==17);
wire local_command=local_stream_query||packet_command==1||packet_command==2||packet_command==7||packet_command==8||packet_command==9||packet_command==10||packet_command==13||packet_command==14||packet_command==15||packet_command==20||packet_command==21;
wire panic=(packet_command==7&&packet_arguments[7:0]==1)||(packet_command==8&&packet_arguments[7:0]<=3);
wire stop_active_pcm=packet_command==14&&active&&!request_remote&&request_command==13;
wire preempt=panic||stop_active_pcm;
reg shape;always @(*)case(packet_command)
 1,2,3,6,9,14,15:shape=packet_length==0;
 4:shape=packet_length==2;5:shape=packet_length==6;
 7,8,10,12,13,16:shape=packet_length==1;
 11:shape=packet_length<=192;17:shape=packet_length==3;22:shape=packet_length>=6&&packet_length<=198;
 20:shape=packet_length>=6&&packet_length<=192;21:shape=packet_length==1;
 18:shape=packet_length==24;19:shape=packet_length==0;default:shape=0;
endcase
wire valid_session=packet_command==1?packet_session!=0:open&&packet_session==session&&packet_session!=0;
wire cache_match=cache_valid&&cache_wire_id==wire_id;
wire same_identity=packet_command!=11&&!(packet_command==20&&packet_length>6)&&!(packet_command==22&&packet_length>6)&&cache_identity==identity;
wire replay_candidate=valid_session&&shape&&cache_match&&same_identity;
wire old_sequence=packet_command!=1&&seen_sequence&&packet_sequence<=last_sequence;
wire acceptable=valid_session&&shape&&(remote_command||local_command)&&!cache_match&&!old_sequence&&!exhausted;
wire allowed=!active&&(!draining||panic)||(active&&preempt&&!draining&&!reply_building);
wire busy=!allowed||(remote_command&&!peer_ready)||(packet_length>6&&!packet_has_bank)||abort_pending;
wire reject_packet=!replay_candidate&&(!acceptable||busy);
assign initialize_ready=!active&&!draining&&!rejected&&!reply_building&&first_execution_token!=0&&first_execution_token>counter;
assign packet_ready=!initialize_valid&&!rejected&&!reply_building&&(replay_candidate?replay_ready:1'b1);
assign replay_valid=packet_valid&&!initialize_valid&&!rejected&&!reply_building&&replay_candidate;
assign request_valid=active&&!issued;assign cancel_valid=draining;assign cancel_token=drain_token;assign cancel_remote=drain_remote;
wire matching_result=result_valid&&active&&issued&&result_token==request_token;
wire preempt_accept=packet_valid&&packet_ready&&acceptable&&!busy&&preempt&&active;
assign submit_valid=!reply_building&&!preempt_accept&&(rejected||matching_result&&!request_board);
assign board_result_valid=BOARD_CONTROL_ENABLED&&(board_failure||matching_result&&request_board&&!preempt_accept);
assign board_result_synthetic=board_failure;
assign board_result_command=board_failure_command;assign board_result_error=board_failure_error;
// The current owner kind is held from acceptance through real result credit.
assign result_address_board=request_board;
assign submit_wire_id=reply_building?(build_synthetic?reject_wire:request_wire_id):rejected?reject_wire:request_wire_id;
assign submit_owner=reply_building?build_owner:rejected?32'd0:request_token;
assign submit_synthetic=reply_building?build_synthetic:rejected;assign submit_cache_enable=!rejected;
assign reply_remote=reply_building?build_remote:request_remote;
assign synthetic_command=reject_command;assign synthetic_error=reject_error;
// Source ownership ends after the complete 36-byte frame/CRC is in reply RAM.
// Unknown/late results are discarded without consuming a new response bank.
assign result_ready=board_result_valid&&!board_failure&&board_result_ready||reply_building&&!build_synthetic&&captured&&captured_owner==build_owner||
 (!reply_building&&(!active||result_token!=request_token));
// Exact projection of the SAME next-state as the five owner flags.
// New requests, replies, preemption and cancel completion are included below.
(* preserve=1 *) reg idle_projection;
reg next_active,next_draining,next_rejected,next_reply_building,next_board_failure;
assign idle=idle_projection;
always @(*)begin
 next_active=active;next_draining=draining;next_rejected=rejected;
 next_reply_building=reply_building;next_board_failure=board_failure;
 if(board_failure&&board_result_ready)next_board_failure=0;
 if(board_result_valid&&!board_failure&&board_result_ready)next_active=0;
 if(board_request_valid&&board_request_ready)next_active=1;
 if(cancel_done&&draining&&cancel_done_token==drain_token)next_draining=0;
 if(submit_valid&&submit_ready)begin next_reply_building=1;if(!rejected)next_active=0;end
 if(reply_building&&captured&&captured_owner==build_owner)begin
  next_reply_building=0;if(build_synthetic)next_rejected=0;
 end
 if(packet_valid&&packet_ready)begin
  if(replay_candidate)begin end
  else if(reject_packet)next_rejected=1;
  else begin
   if(active)begin
    next_draining=1;
    if(request_board)next_board_failure=1;else next_rejected=1;
   end
   next_active=1;
  end
 end
 if(active&&abort_pending&&!draining&&!rejected&&!reply_building&&!preempt_accept&&!matching_result)begin
  next_draining=1;if(request_board)next_board_failure=1;else next_rejected=1;next_active=0;
 end
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  active<=0;draining<=0;rejected<=0;reply_building<=0;board_failure<=0;idle_projection<=1;
 end else begin
  active<=next_active;draining<=next_draining;rejected<=next_rejected;
  reply_building<=next_reply_building;board_failure<=next_board_failure;
  idle_projection<=!(next_active||next_draining||next_rejected||next_reply_building||next_board_failure);
 end
end
task release_packet;begin if(packet_has_bank)begin release_valid<=1;release_bank<=packet_bank;end end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  open<=0;seen_sequence<=0;session<=0;last_sequence<=0;;issued<=0;body_owned<=0;;
  drain_remote<=0;drain_body_owned<=0;drain_bank<=0;drain_token<=0;counter<=1;exhausted<=0;
  ;reject_wire<=0;reject_command<=0;reject_error<=0;;build_synthetic<=0;build_remote<=0;invalidate_cache<=0;
  cache_identity<=0;urgent_seen<=0;urgent_enter<=0;urgent_preset_valid<=0;urgent_preset<=0;
  request_remote<=0;request_token<=0;request_wire_id<=0;request_command<=0;request_length<=0;request_arguments<=0;request_bank<=0;request_has_bank<=0;
  request_board<=0;;board_failure_command<=0;board_failure_error<=0;
  release_valid<=0;release_bank<=0;age<=0;abort_pending<=0;abort_error<=0;
 end else begin
  release_valid<=0;urgent_enter<=0;urgent_preset_valid<=0;invalidate_cache<=0;
  if(active&&tick_ms&&age<execution_deadline)age<=age+1'b1;
  if(active&&((request_remote&&!peer_ready)||age>=execution_deadline-1||BOARD_CONTROL_ENABLED&&request_board&&board_cancel))begin
   abort_pending<=1;abort_error<=request_remote&&!peer_ready?8'hc0:BOARD_CONTROL_ENABLED&&request_board&&board_cancel?8'h43:8'h48;
  end
  if(!packet_valid)urgent_seen<=0;
  if(packet_valid&&valid_session&&shape&&panic&&!old_sequence&&!urgent_seen)begin
   urgent_seen<=1;urgent_enter<=packet_command==7;urgent_preset_valid<=packet_command==8;urgent_preset<=packet_arguments[1:0];
  end
  if(initialize_valid&&initialize_ready)begin counter<=first_execution_token;exhausted<=0;end
  if(borrow_valid&&borrow_ready)begin
   if(counter==32'hffffffff)exhausted<=1;else counter<=counter+1'b1;
  end
  if(board_failure&&board_result_ready);
  if(board_result_valid&&!board_failure&&board_result_ready)begin ;issued<=0;request_board<=0;age<=0;abort_pending<=0;end
  if(board_request_valid&&board_request_ready)begin
   ;issued<=0;body_owned<=0;request_bank<=0;request_has_bank<=0;request_board<=1;request_remote<=1;
   request_token<=counter;request_wire_id<=0;request_command<=board_request_command;
   request_length<=board_request_command==24?2:board_request_command==25?6:0;request_arguments<=board_request_arguments;age<=0;abort_pending<=0;
   if(counter==32'hffffffff)exhausted<=1;else counter<=counter+1'b1;
  end
  if(request_valid&&request_ready)begin issued<=1;
   if(body_owned)begin release_valid<=1;release_bank<=request_bank;body_owned<=0;end
  end
  if(cancel_done&&draining&&cancel_done_token==drain_token)begin
   ;if(drain_body_owned)begin release_valid<=1;release_bank<=drain_bank;drain_body_owned<=0;end
  end
  if(submit_valid&&submit_ready)begin
   ;build_synthetic<=rejected;build_remote<=request_remote;
   // During reply_building packet/replay/board/seed acceptance is blocked.
   // A real request_token is immutable until capture; synthetic owner is zero.
   // Store its cache key now, in the existing single identity record. It only
   // becomes observable when the complete frame's cache lease commits.
   if(!rejected)cache_identity<={request_command,request_length,request_arguments};
   if(!rejected);
   if(!rejected)begin age<=0;abort_pending<=0;end
  end
  if(reply_building&&captured&&captured_owner==build_owner)begin
   ;if(build_synthetic);
  end
  if(packet_valid&&packet_ready)begin
   urgent_seen<=0;
   if(replay_candidate)release_packet();
   else if(reject_packet)begin
    ;reject_wire<=wire_id;reject_command<=packet_command;
    reject_error<=!(local_command||remote_command)?8'h40:!shape?8'h42:!valid_session?8'h41:
     cache_match||old_sequence?8'h46:exhausted?8'h48:remote_command&&!peer_ready?8'hc0:8'h43;
    release_packet();
   end else begin
    if(active)begin
     ;drain_token<=request_token;drain_remote<=request_remote;drain_bank<=request_bank;
     drain_body_owned<=body_owned&&!(request_valid&&request_ready);
     if(request_board)begin ;board_failure_command<=request_command;board_failure_error<=8'h43;end
     else begin ;reject_wire<=request_wire_id;reject_command<=request_command;reject_error<=8'h43;end
    end
    ;issued<=0;body_owned<=packet_has_bank;request_bank<=packet_bank;request_has_bank<=packet_has_bank;request_board<=0;invalidate_cache<=1;age<=0;abort_pending<=0;
    request_token<=counter;request_wire_id<=wire_id;request_command<=packet_command;request_length<=packet_length;
    request_arguments<=packet_arguments;request_remote<=remote_command;
    if(counter==32'hffffffff)exhausted<=1;else counter<=counter+1'b1;
    if(packet_command==1)begin open<=1;session<=packet_session;seen_sequence<=0;last_sequence<=0;end
    else begin seen_sequence<=1;last_sequence<=packet_sequence;end
   end
  end
  if(active&&abort_pending&&!draining&&!rejected&&!reply_building&&!preempt_accept&&!matching_result)begin
   ;drain_token<=request_token;drain_remote<=request_remote;drain_bank<=request_bank;
   drain_body_owned<=body_owned&&!(request_valid&&request_ready);
   if(request_board)begin ;board_failure_command<=request_command;board_failure_error<=abort_error;end
   else begin ;reject_wire<=request_wire_id;reject_command<=request_command;reject_error<=abort_error;end
   ;issued<=0;body_owned<=0;request_board<=0;age<=0;abort_pending<=0;
  end
 end
end
endmodule
