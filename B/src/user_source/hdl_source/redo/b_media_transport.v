`timescale 1ns/1ps
// B按块发送真实媒体；数据块在确认前保留，重发不能重新弹出FIFO。
module b_media_transport #(parameter CLOCK_HZ=50000000,FRAME_WORDS=307200,HALF_CYCLES=3,MANAGEMENT=0,COLOUR=0,PROTOCOL_VERSION=4,MEDIA_WORDS=64,MEDIA_UID32=0,CONTROLLED=0,EXTERNAL_REQUEST=0,GAMMA_ENABLED=0,DIMENSIONS_ENABLED=0,IMAGE_SUSPEND_ENABLED=0,GEOMETRY_ENABLED=0)(
 input curve_meta_request,curve_data_request,curve_prepared,input [31:0] curve_token,curve_meta_word,curve_read_word,output [5:0] curve_read_address,output reg curve_done,output reg [7:0] curve_error,
 output reg curve_status_strobe,curve_status_valid,output reg [31:0] curve_status_token,output reg [15:0] curve_status_style,
 output reg host_request_valid,input host_request_ready,output reg [31:0] host_request_token,output reg [7:0] host_request_cmd,output reg [15:0] host_request_length,output reg [47:0] host_request_args,
 input host_reply_valid,input [31:0] host_reply_token,input [191:0] host_reply_payload,output reg host_reply_ready,
 input actuation_request,input [31:0] actuation_token,input [71:0] actuation_values,output reg actuation_done,output reg [7:0] actuation_error,
 input snapshot_valid,input [191:0] snapshot_payload,input [23:0] snapshot_jedec,output reg snapshot_ready,
 output reg [7:0] legacy_flags,legacy_text_summary,output reg [71:0] legacy_values,
 input clk,rst_n,miso,output cs_n,sclk,mosi,
 input image_req,image_valid,input [31:0] image_word,input [1:0] write_bank,display_bank,input display_valid,input [3:0] image_code,
 output reg image_ack,output reg frame_finish_toggle,output image_sector_room,
 output reg next_image,previous_image,reload,auto_valid,auto_value,auto_toggle,emergency,
 output reg [31:0] period_ms,output reg period_valid,
 input pcm_valid,pcm_last,input [31:0] pcm_word,output pcm_ready,
 input audio_metadata,input [31:0] audio_frames,input audio_busy,audio_done,input [7:0] audio_error,
 output reg audio_start,output audio_cancel,output reg [7:0] audio_id,output audio_urgent,
 input event_valid,input [127:0] event_data,
 output reg online,output reg [15:0] dropped,output reg [7:0] link_error,
 output request_start,output [7:0] request_kind,request_arg,output [6:0] request_count,
 output [15:0] request_sequence,request_tag,output [31:0] request_value,
 input [5:0] request_read_address,output [31:0] request_read_word,
 input transport_busy,transport_done,input reply_pulse,input [495:0] full_reply_body,input [15:0] bad_reply_count,
 input pause_media,output media_drained,
 // UID32 mode receives authorized operations from the paired command service.
 // Legacy defaults preserve existing callers; UID32 cannot use the old echo.
 input [31:0] image_operation_uid,audio_request_uid,
 input [7:0] audio_request_id,input audio_request_cancel,
 output [31:0] request_uid,output curve_inflight,
 input pause_control,output actuation_inflight,image_drained,
 input [7:0] curve_gamma,output reg [7:0] curve_status_gamma,output image_word_ready,input [7:0] playback_info,input [1:0] image_extent,input [25:0] image_dims,input image_suspend,input [2:0] image_geometry,input [7:0] actuation_scale,geometry_previous_scale);
localparam IDLE=0,FILL=1,SEND=2,WAIT_SEND=3,GAP=4,POLL=5,WAIT_POLL=6,COMPLETE=7,HEARTBEAT=8,WAIT_HEARTBEAT=9,CURVE_WAIT=10;
localparam POLL_LIMIT=CLOCK_HZ/2,HB_PERIOD=CLOCK_HZ/50;
// B108: the 0x12 tail carries the original BMP size; bit31 marks it (A93 and
// older accept only FRAME_WORDS, whose bit31 is 0).
reg [25:0] sent_dims;wire [31:0] tail_value=DIMENSIONS_ENABLED?{1'b1,5'd0,sent_dims}:FRAME_WORDS;
reg [3:0] state;reg [31:0] hb_timer;
localparam RETRY_TIMER_WIDTH=$clog2(POLL_LIMIT+1);
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [RETRY_TIMER_WIDTH-1:0] retry_timer;reg [7:0] gap;reg [3:0] poll_retries;
reg [7:0] op_kind,op_arg;reg [6:0] op_count;reg [31:0] op_value;reg [15:0] op_tag,op_seq,next_tag,next_seq;
reg [5:0] fill_index;(* force_ram=1,ram_style="bram" *) reg [31:0] staging[0:63];reg [31:0] tx_word;wire [5:0] tx_address;
reg seen_host,actuation_sent,actuation_reported;reg [31:0] seen_host_token;
wire [239:0] reply_body;
function [7:0] rb;input integer i;begin rb=reply_body[239-i*8-:8];end endfunction
// 连续连线直接引用回执总线，保证回执变化时重新计算编号。
wire [31:0] received_host_token={reply_body[55:48],reply_body[63:56],reply_body[71:64],reply_body[79:72]};
wire [31:0] received_apply_token={reply_body[55:48],reply_body[63:56],reply_body[71:64],reply_body[79:72]};
integer li;
reg tx_start;reg [7:0] tx_kind,tx_arg;reg [6:0] tx_count;reg [31:0] tx_value;reg [15:0] tx_seq,tx_tag;
wire tx_busy,tx_done,reply_valid;wire [15:0] bad_replies;
reg [15:0] ack_tag;reg [7:0] ack_result,seen_action;
reg [(MEDIA_UID32?32:8)-1:0] requested_epoch,active_epoch;
reg [31:0] image_owner_uid,op_uid,tx_uid;
wire op_media=(op_kind>=8'h10&&op_kind<=8'h13)||(op_kind>=8'h20&&op_kind<=8'h23);
wire [255:0] media_fragment=full_reply_body[255:0];
wire [31:0] media_reply_uid={media_fragment[199:192],media_fragment[207:200],media_fragment[215:208],media_fragment[223:216]};
wire [15:0] media_reply_tag={media_fragment[231:224],media_fragment[239:232]};
assign request_uid=tx_uid;
assign curve_inflight=state!=IDLE&&(op_kind==8'h43||op_kind==8'h44);
assign actuation_inflight=(state!=IDLE&&op_kind==8'h41)||(actuation_sent&&!actuation_reported);
wire control_paused=CONTROLLED&&pause_control;
reg [7:0] requested_id;reg requested_cancel;reg memory_ready;(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg got_reply;
reg image_active,begin_pending,end_pending,abort_pending;reg [31:0] image_captured,image_sent;
reg restart_audio;reg image_clear,audio_clear;reg audio_started,meta_sent,meta_pending,audio_final,reader_failed;
reg [31:0] captured_audio,sent_audio,held_audio_frames;reg [7:0] held_audio_error;
wire image_fifo_ready,image_fifo_valid,pcm_fifo_valid;wire [9:0] image_space,pcm_space;wire [32:0] image_fifo_data,pcm_fifo_data;
// Public ready must acknowledge the same write that the live FIFO accepts.
// A clear pulse asynchronously resets the FIFO; pause must not admit a word.
wire pcm_fifo_ready;
assign pcm_ready=pcm_fifo_ready&&!audio_clear&&!pause_media;
wire image_pause=pause_media||(IMAGE_SUSPEND_ENABLED&&image_suspend);
wire image_pop=state==FILL&&op_kind==8'h11;
wire pcm_pop=state==FILL&&(op_kind==8'h21||op_kind==8'h22);
media_block_fifo image_fifo(.clk(clk),.rst_n(rst_n&&!image_clear),.write_valid(image_valid&&!image_pause),.write_data(image_word),.write_ready(image_fifo_ready),.write_space(image_space),
 .read_ready(image_pop),.read_valid(image_fifo_valid),.read_data(image_fifo_data[31:0]));
assign image_fifo_data[32]=0;
media_block_fifo pcm_fifo(.clk(clk),.rst_n(rst_n&&!audio_clear),.write_valid(pcm_valid&&!audio_clear&&!pause_media),.write_data(pcm_word),.write_ready(pcm_fifo_ready),.write_space(pcm_space),
 .read_ready(pcm_pop),.read_valid(pcm_fifo_valid),.read_data(pcm_fifo_data[31:0]));
assign pcm_fifo_data[32]=0;
assign image_sector_room=image_space>=256;
assign image_word_ready=image_fifo_ready&&!image_clear&&!image_pause;
assign audio_urgent=audio_started&&pcm_space>255;
assign audio_cancel=pause_media||restart_audio||requested_cancel||requested_id==0||(audio_started&&active_epoch!=requested_epoch);
// Count predicates are evaluated on an IDLE edge, after COMPLETE updated all
// counters. They can only gain input data while IDLE; no source FIFO is popped
// until FILL. Invalidate the decision outside IDLE, including every cancel.
reg audio_block_ready,audio_tail_ready,image_block_ready,image_tail_ready;
reg [6:0] audio_tail_words,image_block_words;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin audio_block_ready<=0;audio_tail_ready<=0;audio_tail_words<=0;image_block_ready<=0;image_tail_ready<=0;image_block_words<=0;end
 else begin
  audio_block_ready<=state==IDLE&&!audio_cancel&&audio_started&&meta_sent&&pcm_fifo_valid&&
   (captured_audio-sent_audio>=MEDIA_WORDS||(captured_audio==held_audio_frames&&captured_audio>sent_audio));
  audio_tail_ready<=captured_audio==held_audio_frames&&held_audio_frames-sent_audio<=MEDIA_WORDS;
  audio_tail_words<=held_audio_frames-sent_audio;
  image_block_ready<=state==IDLE&&!image_pause&&image_active&&image_fifo_valid&&
   (image_captured-image_sent>=MEDIA_WORDS||(image_captured==FRAME_WORDS&&image_captured>image_sent));
  image_tail_ready<=state==IDLE&&!image_pause&&image_active&&image_sent==FRAME_WORDS;
  image_block_words<=FRAME_WORDS-image_sent<MEDIA_WORDS?FRAME_WORDS-image_sent:MEDIA_WORDS;
 end
end
(* force_ram=1,ram_style="bram" *) reg [127:0] events[0:3];
reg [127:0] event_head;reg event_head_valid;reg [1:0] ew,er;reg [2:0] ec;reg event_pop;
wire event_push=event_valid&&(ec<4||event_pop);
always @(posedge clk)begin
 if(rst_n&&event_push)events[ew]<=event_data;
 event_head<=events[er];
end
always @(posedge clk or negedge rst_n)
 if(!rst_n)event_head_valid<=0;
 else event_head_valid<=!event_pop&&!(event_push&&ec==0);
assign curve_read_address=fill_index;
wire staging_write=state==FILL&&((image_pop&&image_fifo_valid)||(pcm_pop&&pcm_fifo_valid)||op_kind==8'h30||op_kind==8'h40||op_kind==8'h41||op_kind==8'h42||(COLOUR&&(op_kind==8'h43||op_kind==8'h44)));
wire [31:0] event_word=fill_index==0?event_head[95:64]:fill_index==1?event_head[63:32]:event_head[31:0];
wire [95:0] apply_words={18'd0,(GEOMETRY_ENABLED?geometry_previous_scale[2:0]:3'd0),(GEOMETRY_ENABLED?actuation_scale[2:0]:3'd0),actuation_values};
wire [31:0] staging_input=COLOUR&&op_kind==8'h43 ? curve_meta_word : COLOUR&&op_kind==8'h44 ? curve_read_word : op_kind==8'h40 ?host_reply_payload[fill_index*32+:32]:op_kind==8'h41 ?apply_words[fill_index*32+:32]:op_kind==8'h42 ?snapshot_payload[fill_index*32+:32]:op_kind==8'h30 ?event_word:op_kind==8'h11 ?image_fifo_data[31:0]:pcm_fifo_data[31:0];
// 事件也逐字准备，统一为一个RAM写端口，禁止三个地址同拍写入造成寄存器展开。
always @(posedge clk)begin
 if(staging_write)staging[fill_index]<=staging_input;
 tx_word<=staging[tx_address];
end
// The shared physical SPI engine owns this request's staging RAM through done.
assign request_start=tx_start;assign request_kind=tx_kind;assign request_arg=tx_arg;
assign request_count=tx_count;assign request_sequence=tx_seq;assign request_tag=tx_tag;assign request_value=tx_value;
assign tx_address=request_read_address;assign request_read_word=tx_word;
assign tx_busy=transport_busy;assign tx_done=transport_done;assign reply_valid=reply_pulse;
assign reply_body=full_reply_body[495:256];assign bad_replies=bad_reply_count;
assign cs_n=1'b1;assign sclk=1'b0;assign mosi=1'b1;
assign media_drained=!image_active&&!abort_pending&&!audio_started&&!audio_busy&&!image_fifo_valid&&!pcm_fifo_valid&&state==IDLE;
assign image_drained=!image_active&&!abort_pending&&!image_fifo_valid&&
 !(state!=IDLE&&op_kind>=8'h10&&op_kind<=8'h13);

// Idle clears do not depend on the 15-way operation arbitration. The stale
// values while idle are unobservable: every next operation starts from zero.
// A timeout still clears on the same actual completed-poll edge as before.
wire retry_timeout=state==WAIT_POLL&&tx_done&&!(got_reply&&ack_tag==op_tag)&&retry_timer>=POLL_LIMIT-1;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin retry_timer<=0;got_reply<=0;end
 else begin
  if(state==IDLE||retry_timeout)retry_timer<=0;
  else if(retry_timer<POLL_LIMIT)retry_timer<=retry_timer+1'b1;
  if(state==IDLE)got_reply<=0;
  else if(reply_valid)begin
   if(!MEDIA_UID32||!op_media)got_reply<=reply_body[80];
   else if(media_fragment[255:248]==8'hf7&&media_reply_uid==op_uid&&media_reply_tag==op_tag)got_reply<=1;
  end
 end
end
// The original arbitration and priority are retained verbatim below.
// One shared wide data selector avoids replicating a 32-bit priority chain
// at every inlined operation task call. No descriptor or lease cycle changes.
reg [13:0] operation_grant;
always @(*)begin
 operation_grant=0;
 if(state==IDLE)if(!event_pop&&!host_reply_ready&&!snapshot_ready&&!curve_done)begin
    if(abort_pending)operation_grant[0]=1'b1;
    // Once cancellation has drained this staging owner, retain that credit.
    // In-flight transactions and required image aborts still finish above.
    // Queued events and periodic heartbeats resume only after notice release;
    // they cannot reacquire the shared source on the join's completion edge.
    // An unrelated ordinary F1 must keep image/audio scheduling independent.
    else if(control_paused&&pause_media)begin end
    else if(ec!=0&&event_head_valid)operation_grant[1]=1'b1;
    else if(reader_failed)operation_grant[2]=1'b1;
    else if(meta_pending&&audio_started)operation_grant[3]=1'b1;
    else if(audio_block_ready&&!audio_cancel)begin
     if(audio_tail_ready)operation_grant[4]=1'b1;
     else operation_grant[5]=1'b1;
    end else if(COLOUR&&curve_meta_request&&!control_paused)operation_grant[6]=1'b1;
    else if(COLOUR&&curve_data_request&&!control_paused)operation_grant[7]=1'b1;
    else if(MANAGEMENT&&actuation_request&&!control_paused&&(!COLOUR||curve_prepared)&&!actuation_sent)operation_grant[8]=1'b1;
    else if(MANAGEMENT&&host_reply_valid)operation_grant[9]=1'b1;
    else if(MANAGEMENT&&snapshot_valid&&!control_paused)operation_grant[10]=1'b1;
    else if(!image_pause&&image_req&&!image_active&&memory_ready&&(!MEDIA_UID32||image_operation_uid!=0))operation_grant[11]=1'b1;
    else if(!image_pause&&image_block_ready)
     operation_grant[12]=1'b1;
    else if(image_tail_ready)operation_grant[13]=1'b1;
    else if(hb_timer>=HB_PERIOD)begin end
   end
end
wire [31:0] selected_operation_value=
 ({32{operation_grant[0]}}&32'd0)|
 ({32{operation_grant[1]}}&event_head[127:96])|
 ({32{operation_grant[2]}}&{24'd0,held_audio_error})|
 ({32{operation_grant[3]}}&held_audio_frames)|
 ({32{operation_grant[4]}}&sent_audio)|
 ({32{operation_grant[5]}}&sent_audio)|
 ({32{operation_grant[6]}}&curve_token)|
 ({32{operation_grant[7]}}&curve_token)|
 ({32{operation_grant[8]}}&actuation_token)|
 ({32{operation_grant[9]}}&host_reply_token)|
 ({32{operation_grant[10]}}&{8'd0,snapshot_jedec})|
 ({32{operation_grant[11]}}&FRAME_WORDS)|
 ({32{operation_grant[12]}}&image_sent)|
 ({32{operation_grant[13]}}&tail_value);
// All descriptors are selected by the same unchanged one-hot grant.
wire [7:0] selected_operation_kind=
 ({8{operation_grant[0]}}&(8'h13))|
 ({8{operation_grant[1]}}&(8'h30))|
 ({8{operation_grant[2]}}&(8'h23))|
 ({8{operation_grant[3]}}&(8'h20))|
 ({8{operation_grant[4]}}&(8'h22))|
 ({8{operation_grant[5]}}&(8'h21))|
 ({8{operation_grant[6]}}&(8'h43))|
 ({8{operation_grant[7]}}&(8'h44))|
 ({8{operation_grant[8]}}&(8'h41))|
 ({8{operation_grant[9]}}&(8'h40))|
 ({8{operation_grant[10]}}&(8'h42))|
 ({8{operation_grant[11]}}&(8'h10))|
 ({8{operation_grant[12]}}&(8'h11))|
 ({8{operation_grant[13]}}&(8'h12));
wire [7:0] selected_operation_arg=
 ({8{operation_grant[0]}}&(0))|
 ({8{operation_grant[1]}}&(0))|
 ({8{operation_grant[2]}}&(MEDIA_UID32?8'd0:active_epoch))|
 ({8{operation_grant[3]}}&(MEDIA_UID32?8'd0:active_epoch))|
 ({8{operation_grant[4]}}&(MEDIA_UID32?8'd0:active_epoch))|
 ({8{operation_grant[5]}}&(MEDIA_UID32?8'd0:active_epoch))|
 ({8{operation_grant[6]}}&(GAMMA_ENABLED?curve_gamma:8'd0))|
 ({8{operation_grant[7]}}&(0))|
 ({8{operation_grant[8]}}&(0))|
 ({8{operation_grant[9]}}&(0))|
 ({8{operation_grant[10]}}&(0))|
 ({8{operation_grant[11]}}&({1'b0,(GEOMETRY_ENABLED?image_geometry:3'd0),(DIMENSIONS_ENABLED?image_extent:2'd0),write_bank}))|
 ({8{operation_grant[12]}}&({6'd0,write_bank}))|
 ({8{operation_grant[13]}}&({6'd0,write_bank}));
wire [6:0] selected_operation_count=
 ({7{operation_grant[0]}}&(0))|
 ({7{operation_grant[1]}}&(3))|
 ({7{operation_grant[2]}}&(0))|
 ({7{operation_grant[3]}}&(0))|
 ({7{operation_grant[4]}}&(audio_tail_words))|
 ({7{operation_grant[5]}}&(MEDIA_WORDS))|
 ({7{operation_grant[6]}}&(1))|
 ({7{operation_grant[7]}}&(64))|
 ({7{operation_grant[8]}}&(3))|
 ({7{operation_grant[9]}}&(6))|
 ({7{operation_grant[10]}}&(6))|
 ({7{operation_grant[11]}}&(0))|
 ({7{operation_grant[12]}}&(image_block_words))|
 ({7{operation_grant[13]}}&(0));
wire [31:0] selected_operation_uid=
 ({32{operation_grant[0]}}&image_owner_uid)|
 ({32{operation_grant[1]}}&32'd0)|
 ({32{operation_grant[2]}}&active_epoch)|
 ({32{operation_grant[3]}}&active_epoch)|
 ({32{operation_grant[4]}}&active_epoch)|
 ({32{operation_grant[5]}}&active_epoch)|
 ({32{operation_grant[6]}}&32'd0)|
 ({32{operation_grant[7]}}&32'd0)|
 ({32{operation_grant[8]}}&32'd0)|
 ({32{operation_grant[9]}}&32'd0)|
 ({32{operation_grant[10]}}&32'd0)|
 ({32{operation_grant[11]}}&image_operation_uid)|
 ({32{operation_grant[12]}}&image_owner_uid)|
 ({32{operation_grant[13]}}&image_owner_uid);
task operation;input [7:0] k,a;input [6:0] n;input [31:0] v;
begin
 op_uid<=selected_operation_uid;
 if(MEDIA_UID32&&k==8'h10)image_owner_uid<=image_operation_uid;
 poll_retries<=0;
 op_kind<=selected_operation_kind;op_arg<=selected_operation_arg;op_count<=selected_operation_count;op_value<=selected_operation_value;op_tag<=next_tag;op_seq<=next_seq;next_tag<=next_tag+1'b1;next_seq<=next_seq+1'b1;fill_index<=0;
 state<=COLOUR&&k==8'h44 ? CURVE_WAIT : k==8'h11||k==8'h21||k==8'h22||k==8'h30||k==8'h40||k==8'h41||k==8'h42||(COLOUR&&k==8'h43) ? FILL : SEND;end endtask
task heartbeat;begin
 tx_kind<=1;tx_count<=0;tx_arg<={display_valid,5'd0,display_bank};tx_value<={16'd0,(MEDIA_UID32?playback_info:seen_action),4'd0,image_code};tx_tag<=16'h2311;tx_seq<=next_seq;next_seq<=next_seq+1'b1;tx_start<=1;hb_timer<=0;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  poll_retries<=0;
  host_request_valid<=0;host_request_token<=0;host_request_cmd<=0;host_request_length<=0;host_request_args<=0;host_reply_ready<=0;actuation_done<=0;actuation_error<=0;snapshot_ready<=0;seen_host<=0;seen_host_token<=0;actuation_sent<=0;actuation_reported<=0;legacy_flags<=0;legacy_values<=0;legacy_text_summary<=0;
  state<=SEND;hb_timer<=0;gap<=0;op_kind<=2;op_arg<=0;op_count<=0;op_value<=0;op_tag<=0;op_seq<=0;next_tag<=1;next_seq<=1;fill_index<=0;
  curve_done<=0;curve_error<=0;curve_status_strobe<=0;curve_status_valid<=0;curve_status_token<=0;curve_status_style<=16'h6464;curve_status_gamma<=2;tx_start<=0;tx_kind<=0;tx_arg<=0;tx_count<=0;tx_value<=0;tx_seq<=0;tx_tag<=0;
  online<=0;image_owner_uid<=0;op_uid<=0;tx_uid<=0;ack_tag<=16'hffff;ack_result<=0;seen_action<=0;memory_ready<=0;requested_epoch<=0;active_epoch<=0;requested_id<=0;requested_cancel<=0;
  image_ack<=0;frame_finish_toggle<=0;image_active<=0;sent_dims<=0;begin_pending<=0;end_pending<=0;abort_pending<=0;image_captured<=0;image_sent<=0;image_clear<=0;
  next_image<=0;previous_image<=0;reload<=0;auto_valid<=0;auto_value<=0;auto_toggle<=0;emergency<=0;period_ms<=3000;period_valid<=0;
  restart_audio<=0;audio_start<=0;audio_id<=0;audio_clear<=0;audio_started<=0;meta_sent<=0;meta_pending<=0;audio_final<=0;reader_failed<=0;captured_audio<=0;sent_audio<=0;held_audio_frames<=0;held_audio_error<=0;
  ew<=0;er<=0;ec<=0;event_pop<=0;dropped<=0;link_error<=0;
 end else begin
  curve_done<=0;curve_status_strobe<=0;
  host_reply_ready<=0;snapshot_ready<=0;actuation_done<=0;
  if(MANAGEMENT&&host_request_valid&&host_request_ready)begin host_request_valid<=0;seen_host<=1;seen_host_token<=host_request_token;end
  if(!actuation_request)begin actuation_sent<=0;actuation_reported<=0;end
  tx_start<=0;image_clear<=0;audio_clear<=0;audio_start<=0;event_pop<=0;
  next_image<=0;previous_image<=0;reload<=0;auto_valid<=0;auto_toggle<=0;period_valid<=0;
  if(hb_timer<HB_PERIOD)hb_timer<=hb_timer+1'b1;
  if(!image_req)image_ack<=0;
  if(image_valid&&!image_pause)begin
   if(image_fifo_ready)image_captured<=image_captured+1'b1;
   else begin dropped<=dropped==16'hffff ?dropped:dropped+1'b1;abort_pending<=1;link_error<=8'hd5;end
  end
  if(pcm_valid&&pcm_ready&&!pause_media)captured_audio<=captured_audio+1'b1;
  if(audio_metadata&&audio_started&&!meta_sent)begin held_audio_frames<=audio_frames;meta_pending<=1;end
  if(audio_done&&audio_error!=0&&audio_started)begin reader_failed<=1;held_audio_error<=audio_error;end
  if(event_push)ew<=ew+1'b1;
  if(event_pop)er<=er+1'b1;
  case({event_push,event_pop})2'b10:ec<=ec+1'b1;2'b01:ec<=ec-1'b1;default:ec<=ec;endcase
  if(event_valid&&!event_push&&dropped!=16'hffff)dropped<=dropped+1'b1;
  // 此入口来自图片控制器；加载中出现错误必须结束A的未提交事务。
  if(event_valid&&event_data[127:120]==1&&event_data[119:112]>=1&&event_data[119:112]<=3&&image_active)abort_pending<=1;
  if(MEDIA_UID32)begin
   requested_id<=audio_request_id;requested_epoch<=audio_request_uid;requested_cancel<=audio_request_cancel;
  end
  if(reply_valid)begin
   if(COLOUR&&(MEDIA_UID32?reply_body[90:88]==3:reply_body[89:88]==3))begin curve_status_strobe<=1;curve_status_valid<=((rb(26)&8'd1)!=0);curve_status_token<={rb(23),rb(22),rb(21),rb(20)};curve_status_style<={rb(25),rb(24)};curve_status_gamma<=GAMMA_ENABLED?{5'd0,reply_body[30:28]}:8'd2;end
   if(MANAGEMENT)begin
    legacy_text_summary<={(reply_body[87:81]!=0),reply_body[87:81]};
    if(MEDIA_UID32?reply_body[90:88]==0:reply_body[89:88]==0)begin
     legacy_flags<=rb(20);for(li=0;li<9;li=li+1)legacy_values[li*8+:8]<=rb(21+li);
    end
    if(!reply_body[90])seen_host<=0;
    if(!EXTERNAL_REQUEST&&reply_body[89:88]==1&&reply_body[90]&&!host_request_valid&&(!seen_host||seen_host_token!=received_host_token))begin
     host_request_valid<=1;host_request_token<=received_host_token;host_request_cmd<=8'd3+{6'd0,reply_body[92:91]};
     host_request_length<=reply_body[92:91]==1?16'd2:reply_body[92:91]==2?16'd6:16'd0;
     for(li=0;li<6;li=li+1)host_request_args[li*8+:8]<=rb(24+li);
    end
    if((MEDIA_UID32?reply_body[90:88]==2:reply_body[89:88]==2)&&actuation_request&&actuation_sent&&!actuation_reported&&reply_body[93]&&received_apply_token==actuation_token)begin actuation_done<=1;actuation_error<=rb(24);actuation_reported<=1;end
   end
   online<=1;
   if(!MEDIA_UID32||!op_media)begin
    ack_tag<={reply_body[199:192],reply_body[207:200]};ack_result<=reply_body[191:184];
   end else if(media_fragment[255:248]==8'hf7&&media_reply_uid==op_uid&&media_reply_tag==op_tag)begin
    ack_tag<=media_reply_tag;ack_result<=media_fragment[247:240];
   end
   memory_ready<=reply_body[177];emergency<=reply_body[176];frame_finish_toggle<=reply_body[179];
   period_ms<={reply_body[119:112],reply_body[127:120],reply_body[135:128],reply_body[143:136]};period_valid<=1;
   if(!MEDIA_UID32)begin requested_id<=reply_body[159:152];requested_epoch<=reply_body[151:144];requested_cancel<=reply_body[104];end
   if(!MEDIA_UID32&&reply_body[167:160]!=seen_action)begin
    seen_action<=reply_body[167:160];case(reply_body[175:168])
     8'h10:next_image<=1;8'h11:previous_image<=1;
     8'h12:begin auto_valid<=1;auto_value<=1;end 8'h13:begin auto_valid<=1;auto_value<=0;end
     8'h15:auto_toggle<=1;
     8'h20:begin reload<=1;abort_pending<=image_active;image_clear<=1;image_ack<=0;end
    endcase
   end
  end
  // 文件请求由A稳定的代号/编号触发，不依赖一个20ns的跨板脉冲。
  if(restart_audio&&!audio_busy)restart_audio<=0;
  if(audio_cancel)begin audio_clear<=1;audio_started<=0;meta_sent<=0;meta_pending<=0;reader_failed<=0;captured_audio<=0;sent_audio<=0;end
  else if(!pause_media&&!audio_started&&!audio_busy&&requested_id!=0&&online&&(!MEDIA_UID32||requested_epoch!=0))begin
   audio_id<=requested_id;active_epoch<=requested_epoch;audio_started<=1;audio_start<=1;audio_clear<=1;captured_audio<=0;sent_audio<=0;meta_sent<=0;meta_pending<=0;reader_failed<=0;audio_final<=0;
  end
  case(state)
   IDLE:if(!event_pop&&!host_reply_ready&&!snapshot_ready&&!curve_done)begin
    if(abort_pending)operation(8'h13,0,0,0);
    // Once cancellation has drained this staging owner, retain that credit.
    // In-flight transactions and required image aborts still finish above.
    // Queued events and periodic heartbeats resume only after notice release;
    // they cannot reacquire the shared source on the join's completion edge.
    // An unrelated ordinary F1 must keep image/audio scheduling independent.
    else if(control_paused&&pause_media)begin end
    else if(ec!=0&&event_head_valid)operation(8'h30,0,3,event_head[127:96]);
    else if(reader_failed)operation(8'h23,MEDIA_UID32?8'd0:active_epoch,0,{24'd0,held_audio_error});
    else if(meta_pending&&audio_started)operation(8'h20,MEDIA_UID32?8'd0:active_epoch,0,held_audio_frames);
    else if(audio_block_ready&&!audio_cancel)begin
     if(audio_tail_ready)operation(8'h22,MEDIA_UID32?8'd0:active_epoch,audio_tail_words,sent_audio);
     else operation(8'h21,MEDIA_UID32?8'd0:active_epoch,MEDIA_WORDS,sent_audio);
    end else if(COLOUR&&curve_meta_request&&!control_paused)operation(8'h43,GAMMA_ENABLED?curve_gamma:8'd0,1,curve_token);
    else if(COLOUR&&curve_data_request&&!control_paused)operation(8'h44,0,64,curve_token);
    else if(MANAGEMENT&&actuation_request&&!control_paused&&(!COLOUR||curve_prepared)&&!actuation_sent)operation(8'h41,0,3,actuation_token);
    else if(MANAGEMENT&&host_reply_valid)operation(8'h40,0,6,host_reply_token);
    else if(MANAGEMENT&&snapshot_valid&&!control_paused)operation(8'h42,0,6,{8'd0,snapshot_jedec});
    else if(!image_pause&&image_req&&!image_active&&memory_ready&&(!MEDIA_UID32||image_operation_uid!=0))operation(8'h10,{1'b0,(GEOMETRY_ENABLED?image_geometry:3'd0),(DIMENSIONS_ENABLED?image_extent:2'd0),write_bank},0,FRAME_WORDS);
    else if(!image_pause&&image_block_ready)
     operation(8'h11,{6'd0,write_bank},image_block_words,image_sent);
    else if(image_tail_ready)operation(8'h12,{6'd0,write_bank},0,tail_value);
    else if(hb_timer>=HB_PERIOD)begin state<=HEARTBEAT;end
   end
   CURVE_WAIT:state<=FILL;
   FILL:if(staging_write)begin
    if(fill_index+1==op_count)state<=SEND;else begin fill_index<=fill_index+1'b1;if(COLOUR&&op_kind==8'h44)state<=CURVE_WAIT;end
   end
   SEND:if(!tx_busy)begin
    tx_kind<=op_kind;tx_uid<=op_uid;tx_count<=op_count;tx_arg<=op_arg;tx_value<=op_value;tx_seq<=op_seq;tx_tag<=op_tag;tx_start<=1;state<=WAIT_SEND;
   end
   WAIT_SEND:if(tx_done)begin gap<=0;state<=GAP;end
   GAP:if(gap==127)state<=POLL;else gap<=gap+1'b1;
   POLL:if(!tx_busy)begin heartbeat;state<=WAIT_POLL;end
   WAIT_POLL:if(tx_done)begin
    if(got_reply&&ack_tag==op_tag)state<=COMPLETE;
    else if(retry_timer>=POLL_LIMIT-1)begin online<=0;link_error<=8'hc0;state<=SEND;end
    // The first poll often captured the previous immutable reply bank.
    // Do not resend a 272-byte PCM packet solely for that publication delay.
    // A lost packet/overwritten receipt must recover within the SD and PCM
    // service budgets. Eight short polls, then the exact retained packet.
    else if(poll_retries==7)begin poll_retries<=0;state<=SEND;end
    else begin poll_retries<=poll_retries+1'b1;state<=POLL;end
   end
   COMPLETE:begin
    if(ack_result!=0)begin
     // A may reject a retained audio lease after the caller has canceled
     // or superseded it. Retire that exact F749 lease without poisoning the
     // link diagnostic; current-operation failures and every other result
     // keep their existing diagnostic and recovery behavior.
     if(!(MEDIA_UID32&&ack_result==8'h49&&
          (op_kind==8'h20||op_kind==8'h21||op_kind==8'h22||op_kind==8'h23)&&
          (pause_media||requested_cancel||requested_id==0||op_uid!=requested_epoch)))link_error<=ack_result;
     if(op_kind==8'h10&&ack_result==8'h43)begin image_active<=0;state<=IDLE;end
     else if(op_kind==8'h21||op_kind==8'h22||op_kind==8'h20||op_kind==8'h23)begin
      if(MEDIA_UID32?op_uid==active_epoch:op_arg==active_epoch)begin audio_started<=0;audio_clear<=1;restart_audio<=1;end
      state<=IDLE;end
     else if(op_kind==8'h41)begin actuation_done<=1;actuation_error<=ack_result;actuation_reported<=1;state<=IDLE;end
     else if(COLOUR&&(op_kind==8'h43||op_kind==8'h44))begin curve_done<=1;curve_error<=ack_result;state<=IDLE;end
     else if(op_kind==8'h40||op_kind==8'h42)begin state<=IDLE;end
     else begin abort_pending<=1;state<=IDLE;end
    end else begin
     case(op_kind)
      2:begin link_error<=0;end
      8'h10:begin image_ack<=1;image_active<=1;image_clear<=1;image_captured<=0;image_sent<=0;sent_dims<=image_dims;end
      8'h11:image_sent<=image_sent+op_count;
      8'h12:image_active<=0;
      8'h13:begin image_active<=0;image_ack<=0;abort_pending<=0;image_clear<=1;image_captured<=0;image_sent<=0;end
      8'h20:begin meta_sent<=1;meta_pending<=0;end
      8'h21:sent_audio<=sent_audio+op_count;
      8'h22:begin sent_audio<=sent_audio+op_count;audio_final<=1;end
      8'h23:reader_failed<=0;
      8'h30:event_pop<=1;
      8'h40:host_reply_ready<=1;
      8'h41:actuation_sent<=1;
      8'h42:snapshot_ready<=1;
      8'h43,8'h44:if(COLOUR)begin curve_done<=1;curve_error<=0;end
     endcase
     state<=IDLE;
    end
   end
   HEARTBEAT:if(!tx_busy)begin heartbeat;state<=WAIT_HEARTBEAT;end
   WAIT_HEARTBEAT:if(tx_done)state<=IDLE;
  endcase
  if(image_pause)begin if(image_active)abort_pending<=1;else begin image_clear<=1;image_ack<=0;image_captured<=0;image_sent<=0;end end
  if(audio_cancel&&state==FILL&&(op_kind==8'h21||op_kind==8'h22))state<=IDLE;
  if(abort_pending&&state==FILL&&op_kind==8'h11)state<=IDLE;
 end
end
endmodule
