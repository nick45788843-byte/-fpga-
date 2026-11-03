// CMD17: capture=4, release=5, L/R wave=0/1, L/R L1 spectrum=2/3.
// Three arguments are kind, offset and count (1..8 words for read pages).
module b_pcm_analysis_service(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_length,input [47:0] request_arguments,
 output response_valid,input response_ready,output [31:0] response_token,output [191:0] response_payload,
 input reply_valid,input [255:0] reply_fragment,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 input notice_valid,notice_session,input [31:0] notice_token,input transport_idle,
 output control_done,output [31:0] control_token);
localparam IDLE=0,CAPTURE=1,QUERY_BEGIN=2,READ_ADDR=3,READ_WAIT=4,READ_COPY=5,RESPONSE=6,ABORT=7;
reg [2:0] state;
reg [31:0] owner,capture_owner,lease_owner;
reg [191:0] payload;
reg [1:0] read_kind;
reg [7:0] offset,page_count,read_position,next_block,last_index,ack_index;
reg copying,first_received,released,ack_valid,tx_owned,tx_was_ack,abort_sent,capture_owned;
reg [7:0] tx_ack_index;
reg [255:0] held_fragment,last_fragment;
reg [2:0] copy_position,copy_count;
wire [31:0] fragment_token={reply_fragment[199:192],reply_fragment[207:200],reply_fragment[215:208],reply_fragment[223:216]};
wire [7:0] incoming_index=reply_fragment[239:232],incoming_count=reply_fragment[231:224];
wire incoming=reply_valid&&reply_fragment[255:248]==8'hf9&&reply_fragment[247:240]==0&&
 fragment_token==capture_owner&&capture_owner!=0;
wire [7:0] wanted_count=next_block==42?8'd16:8'd24;
wire [7:0] requested_kind=request_arguments[7:0],requested_offset=request_arguments[15:8],requested_count=request_arguments[23:16];
wire shape=request_length==3&&request_arguments[47:24]==0&&
 (requested_kind<4&&requested_count>=1&&requested_count<=8&&
  (requested_kind<2?{1'b0,requested_offset}+requested_count<=256:{1'b0,requested_offset}+requested_count<=128)||
  (requested_kind==4||requested_kind==5)&&requested_offset==0&&requested_count==0);
wire affected=notice_valid&&(notice_session||notice_token==owner||notice_token==capture_owner||notice_token==lease_owner);
wire analysis_start_ready,analysis_sample_ready,analysis_busy,analysis_done,analysis_failed,analysis_result_valid;
wire [31:0] analysis_token;wire [15:0] generation,read_value;
wire query_ready,query_active,analysis_control;
wire start_analysis=request_valid&&request_ready&&shape&&requested_kind==4&&analysis_start_ready;
wire query_begin=state==QUERY_BEGIN&&!query_active;
wire query_end=request_valid&&request_ready&&shape&&requested_kind==5||affected;
wire sample_valid=copying&&!affected&&state==CAPTURE;
wire [31:0] sample_word={held_fragment[167-copy_position*32-:8],held_fragment[175-copy_position*32-:8],
 held_fragment[183-copy_position*32-:8],held_fragment[191-copy_position*32-:8]};
assign request_ready=state==IDLE&&!notice_valid&&!tx_owned&&!ack_valid;
assign response_valid=state==RESPONSE&&!affected;assign response_token=owner;assign response_payload=payload;
assign tx_valid=!tx_owned&&(ack_valid||(state==CAPTURE&&!first_received&&!affected)||(state==ABORT&&!released));
assign tx_kind=ack_valid?8'h4e:8'h4d;assign tx_count=0;
assign tx_sequence=ack_valid?16'd0:state==ABORT?16'd1:16'd0;
assign tx_tag=ack_valid?{8'd0,ack_index}:16'd0;assign tx_value=capture_owner;
assign control_token=notice_token;
assign control_done=notice_valid&&analysis_control&&(!affected||state==IDLE&&!capture_owned)&&
 !copying&&!tx_owned&&!ack_valid&&transport_idle;
b_pcm_analysis analysis(clk,rst_n,start_analysis,analysis_start_ready,request_token,
 sample_valid,sample_word,analysis_sample_ready,analysis_busy,analysis_done,analysis_failed,analysis_token,
 analysis_result_valid,generation,query_begin,query_ready,owner,query_end,lease_owner,query_active,
 read_kind,offset+read_position,read_value,notice_valid,notice_session,notice_token,analysis_control);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;owner<=0;capture_owner<=0;lease_owner<=0;payload<=0;
  read_kind<=0;offset<=0;page_count<=0;read_position<=0;next_block<=0;last_index<=8'hff;ack_index<=0;
  copying<=0;first_received<=0;released<=0;ack_valid<=0;tx_owned<=0;tx_was_ack<=0;abort_sent<=0;capture_owned<=0;
  tx_ack_index<=0;held_fragment<=0;last_fragment<=0;copy_position<=0;copy_count<=0;end
 else begin
  if(tx_valid&&tx_ready)begin tx_owned<=1;tx_was_ack<=ack_valid;tx_ack_index<=ack_index;
   if(ack_valid)ack_valid<=0;else if(state==ABORT)abort_sent<=1;end
  if(tx_owned&&tx_done)tx_owned<=0;
  if(request_valid&&request_ready)begin
   owner<=request_token;payload<=0;payload[7:0]<=17;payload[31:24]<=requested_kind;
   payload[39:32]<=requested_offset;payload[47:40]<=requested_count;payload[63:48]<=generation;
   if(!shape)begin payload[15:8]<=1;payload[23:16]<=8'h42;state<=RESPONSE;end
   else if(requested_kind==4)begin
    if(!analysis_start_ready)begin payload[15:8]<=1;payload[23:16]<=8'h43;state<=RESPONSE;end
    else begin capture_owner<=request_token;capture_owned<=1;first_received<=0;released<=0;
     next_block<=0;last_index<=8'hff;abort_sent<=0;state<=CAPTURE;end
   end else if(requested_kind==5)begin state<=RESPONSE;lease_owner<=0;end
   else if(!analysis_result_valid)begin payload[15:8]<=1;payload[23:16]<=8'h43;state<=RESPONSE;end
   else begin read_kind<=requested_kind[1:0];offset<=requested_offset;page_count<=requested_count;read_position<=0;
    if(query_active)state<=READ_ADDR;else begin lease_owner<=request_token;state<=QUERY_BEGIN;end
   end
  end
  if(state==QUERY_BEGIN&&(query_active||query_ready))state<=READ_ADDR;
  if(state==READ_ADDR)state<=READ_WAIT;
  if(state==READ_WAIT)state<=READ_COPY;
  if(state==READ_COPY)begin
   payload[64+read_position*16+:16]<=read_value;
   if(read_position+1==page_count)state<=RESPONSE;else begin read_position<=read_position+1'b1;state<=READ_ADDR;end
  end
  if(state==RESPONSE&&response_valid&&response_ready)state<=IDLE;
  if(incoming&&!copying)begin
   if(incoming_count==0&&(incoming_index==8'hfe||incoming_index==8'hff))begin
    if(state==ABORT&&incoming_index==8'hfe||state==CAPTURE&&next_block==43&&incoming_index==8'hff||
       released&&incoming_index==last_index)begin
     released<=1;capture_owned<=0;last_index<=incoming_index;ack_valid<=1;ack_index<=incoming_index;
    end
   end else if(state==CAPTURE&&incoming_index==next_block&&next_block<=42&&incoming_count==wanted_count&&!affected)begin
    first_received<=1;held_fragment<=reply_fragment;copy_position<=0;copy_count<=incoming_count==16?4:6;copying<=1;
   end else if(incoming_index==last_index&&reply_fragment==last_fragment)begin ack_valid<=1;ack_index<=incoming_index;end
  end
  if(sample_valid&&analysis_sample_ready)begin
   if(copy_position+1==copy_count)begin
    copying<=0;last_fragment<=held_fragment;last_index<=next_block;ack_index<=next_block;ack_valid<=1;next_block<=next_block+1'b1;
   end else copy_position<=copy_position+1'b1;
  end
  if(state==CAPTURE&&analysis_result_valid&&released&&!ack_valid&&!tx_owned)begin
   payload[63:48]<=generation;state<=RESPONSE;
  end
  if(affected)begin
   copying<=0;
   if(capture_owned||state==CAPTURE)state<=ABORT;
   else if(state!=ABORT)state<=IDLE;
  end
  // A's release marker is required even after the FFT itself has drained.
  if(state==ABORT&&released&&!tx_owned&&!ack_valid&&!analysis_busy&&transport_idle)begin
   state<=IDLE;capture_owned<=0;abort_sent<=0;
  end
 end
end
endmodule
