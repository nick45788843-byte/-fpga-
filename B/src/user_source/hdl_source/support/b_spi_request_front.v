// Dedicated consumer of the current CRC-qualified media_spi_master snapshot.
// The producer keeps the full snapshot stable for >4000 clocks between copies;
// this bounded byte worker borrows it for at most 70 clocks (checked in real top).
// This is not a generic input whose data may be discarded immediately on ready.
module b_spi_request_front #(parameter SHARED_HEADER=0)(input clk,rst_n,session_clear,
 input fragment_valid,output fragment_ready,input [255:0] fragment,
 input cancel_valid,input [31:0] cancel_token,
 input body_release_valid,input [31:0] body_release_token,output reg body_locked,
 output request_valid,input request_ready,output reg [31:0] request_token,
 output reg [7:0] request_command,request_length,output reg [47:0] request_arguments,
 input [7:0] read_address,output reg [7:0] read_byte,
 output reg ack_valid,input ack_ready,output reg [31:0] ack_token,
 output reg [7:0] ack_index,ack_error,output reg ack_captured,
 output reg cancel_notice_valid,output reg [31:0] cancel_notice_token,output reg cancel_notice_session,
 input cancel_done_valid,input [31:0] cancel_done_token,output snapshot_borrowed);
localparam IDLE=0,HEADER=1,COPY=2,DUP_ADDR=3,DUP_CHECK=4;
reg [2:0] state;
wire [7:0] in_command=fragment[255:248],in_length=fragment[247:240],in_index=fragment[239:232],in_count=fragment[231:224];
wire [31:0] in_token={fragment[199:192],fragment[207:200],fragment[215:208],fragment[223:216]};
reg [7:0] private_command,private_length,private_index,private_count;
reg [31:0] private_token;
wire [7:0] command=SHARED_HEADER?in_command:private_command,length=SHARED_HEADER?in_length:private_length,index=SHARED_HEADER?in_index:private_index,count=SHARED_HEADER?in_count:private_count;
wire [31:0] token=SHARED_HEADER?in_token:private_token;
reg shape_ok,control_packet,control_shape,duplicate,new_owner,fresh,first_ok,descriptor_ok,continuation_ok;
reg receiving,complete_pending,seen_token,last_valid;
wire [31:0] highest_token=request_token;
wire [31:0] body_owner=request_token;
reg [7:0] expected_index,received,copy_count,copy_base,last_index;
reg last_control_valid;wire last_control_session=cancel_notice_session;
wire [31:0] last_control_token=cancel_notice_token;
reg [4:0] cursor;
reg mismatch;
reg [7:0] last_byte;
(* force_ram=1,ram_style="bram" *) reg [7:0] body[0:255];
(* force_ram=1,ram_style="bram" *) reg [7:0] last_fragment[0:31];
wire [7:0] incoming_byte=fragment[{~cursor,3'b000}+:8];
wire cancel_owner=cancel_valid&&cancel_token==request_token;
wire control_arriving=(fragment_valid&&fragment_ready&&(in_command==8'hf0||in_command==8'hf1))||
 (state==HEADER&&control_packet);
wire body_control_bypass=fragment_valid&&(in_command==8'hf0||in_command==8'hf1);
assign request_valid=complete_pending&&!session_clear&&!cancel_owner&&!cancel_notice_valid&&!control_arriving;
assign fragment_ready=state==IDLE&&!ack_valid&&!session_clear&&!cancel_notice_valid&&(!body_locked||body_control_bypass);
assign snapshot_borrowed=state!=IDLE;
function known_shape;input [7:0] c,n;begin
 case(c)
  3,6,26:known_shape=n==0;
  4,24:known_shape=n==2;
  5,25:known_shape=n==6;
  11:known_shape=n<=192;
  12,16:known_shape=n==1;
  17:known_shape=n==3;
  18:known_shape=n==24;
  19:known_shape=n==0;
  22:known_shape=n>=6&&n<=198;
  default:known_shape=0;
 endcase
end endfunction
always @(posedge clk)begin
 read_byte<=body[read_address];last_byte<=last_fragment[cursor];
 if(rst_n&&state==COPY&&!session_clear&&!cancel_owner)begin
  last_fragment[cursor]<=incoming_byte;
  if(cursor>=8&&{3'd0,cursor}<8+copy_count)body[copy_base+{3'd0,cursor}-8'd8]<=incoming_byte;
 end
end
task acknowledge;input [31:0] t;input [7:0] i,e;input captured;begin
 ack_valid<=1;ack_token<=t;ack_index<=i;ack_error<=e;ack_captured<=captured;
end endtask
task start_copy;input [7:0] base;begin
 copy_base<=base;copy_count<=count;cursor<=0;state<=COPY;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;private_command<=0;private_length<=0;private_index<=0;private_count<=0;private_token<=0;body_locked<=0;
  shape_ok<=0;control_packet<=0;control_shape<=0;duplicate<=0;new_owner<=0;fresh<=0;first_ok<=0;descriptor_ok<=0;continuation_ok<=0;
  receiving<=0;complete_pending<=0;seen_token<=0;last_valid<=0;
  request_token<=0;request_command<=0;request_length<=0;request_arguments<=0;
  expected_index<=0;received<=0;copy_count<=0;copy_base<=0;last_index<=0;cursor<=0;mismatch<=0;
  ack_valid<=0;ack_token<=0;ack_index<=0;ack_error<=0;ack_captured<=0;
  cancel_notice_valid<=0;cancel_notice_token<=0;cancel_notice_session<=0;
  last_control_valid<=0;
 end else begin
  if(ack_valid&&ack_ready)ack_valid<=0;
  if(request_valid&&request_ready)complete_pending<=0;
  if(session_clear)begin
   state<=IDLE;receiving<=0;complete_pending<=0;seen_token<=0;last_valid<=0;ack_valid<=0;cancel_notice_valid<=0;last_control_valid<=0;body_locked<=0;
  end else if(cancel_owner)begin state<=IDLE;receiving<=0;complete_pending<=0;last_valid<=0;end
  else if(cancel_notice_valid)begin
   if(cancel_done_valid&&cancel_done_token==cancel_notice_token)begin
    cancel_notice_valid<=0;last_control_valid<=1;
    if(cancel_notice_session)begin seen_token<=0;last_valid<=0;end
     if(body_locked&&(cancel_notice_session||body_owner==cancel_notice_token))begin body_locked<=0;end
    acknowledge(cancel_notice_token,cancel_notice_session?8'hfe:8'hff,0,0);
   end
  end else case(state)
   IDLE:if(fragment_valid&&fragment_ready&&in_command!=0)begin
    private_command<=in_command;private_length<=in_length;private_index<=in_index;private_count<=in_count;private_token<=in_token;
    shape_ok<=known_shape(in_command,in_length);control_packet<=in_command==8'hf0||in_command==8'hf1;
    control_shape<=in_length==0&&in_index==0&&in_count==0&&in_token!=0;
    duplicate<=last_valid&&in_token==request_token&&in_index==last_index;
    new_owner<=in_token!=request_token||!receiving;
    fresh<=!seen_token||in_token>highest_token;
    first_ok<=in_index==0&&in_count==(in_length>24?8'd24:in_length);
    descriptor_ok<=in_command==request_command&&in_length==request_length;
    continuation_ok<=in_index==expected_index&&in_count!=0&&in_count<=24&&
      in_count==(request_length-received>24?8'd24:request_length-received);
    state<=HEADER;
   end
   HEADER:begin
    state<=IDLE;
    if(control_packet)begin
     if(!control_shape)acknowledge(token,index,8'h42,0);
     else if(last_control_valid&&last_control_token==token&&last_control_session==(command==8'hf0))
      acknowledge(token,command==8'hf0 ? 8'hfe : 8'hff,0,0);
     else begin
      cancel_notice_valid<=1;cancel_notice_token<=token;cancel_notice_session<=command==8'hf0;
      if(command==8'hf0||token==request_token)begin receiving<=0;complete_pending<=0;last_valid<=0;end
     end
    end else if(!shape_ok||token==0)acknowledge(token,index,token==0?8'h41:8'h42,0);
    else if(duplicate)begin cursor<=0;mismatch<=0;state<=DUP_ADDR;end
    else if(complete_pending)acknowledge(token,index,8'h43,0);
    else if(new_owner)begin
     if(!fresh)acknowledge(token,index,8'h46,0);
     else if(!first_ok)acknowledge(token,index,8'hd2,0);
     else begin
      request_token<=token;request_command<=command;request_length<=length;request_arguments<=0;
      seen_token<=1;expected_index<=0;received<=0;last_valid<=0;
      receiving<=length!=0;start_copy(0);
     end
    end else if(!descriptor_ok)acknowledge(token,index,8'hd4,0);
    else if(!continuation_ok)acknowledge(token,index,8'hd2,0);
    else start_copy(received);
   end
   COPY:begin
    if(copy_base==0&&cursor>=8&&{3'd0,cursor}<8+copy_count)case(cursor)
     8:request_arguments[7:0]<=incoming_byte;9:request_arguments[15:8]<=incoming_byte;
     10:request_arguments[23:16]<=incoming_byte;11:request_arguments[31:24]<=incoming_byte;
     12:request_arguments[39:32]<=incoming_byte;13:request_arguments[47:40]<=incoming_byte;
    endcase
    if(cursor==31)begin
     received<=copy_base+copy_count;expected_index<=length==0?8'd0:index+1'b1;
     last_index<=index;last_valid<=1;state<=IDLE;
     if(copy_base+copy_count==request_length&&command==8'd22)begin body_locked<=1;end
     if(copy_base+copy_count==request_length)begin receiving<=0;complete_pending<=1;end
     acknowledge(request_token,index,0,copy_base+copy_count==request_length);
    end else cursor<=cursor+1'b1;
   end
   DUP_ADDR:state<=DUP_CHECK;
   DUP_CHECK:begin
    mismatch<=mismatch||(last_byte!=incoming_byte);
    if(cursor==31)begin
     acknowledge(token,index,(mismatch||last_byte!=incoming_byte)?8'hd4:8'd0,
      !mismatch&&last_byte==incoming_byte&&received==request_length);state<=IDLE;
    end else begin cursor<=cursor+1'b1;state<=DUP_ADDR;end
   end
   default:state<=IDLE;
  endcase
  if(body_release_valid&&body_locked&&body_release_token==body_owner)begin body_locked<=0;end
 end
end
endmodule
