// fragment is SPI6 reply bytes30..61, network byte order. Valid is CRC-qualified.
// request_ready means the service captured all needed body bytes, not just header.
module b_request_fragments(input clk,rst_n,session_clear,
 input fragment_valid,output fragment_ready,input [255:0] fragment,
 input cancel_valid,input [31:0] cancel_token,
 output request_valid,input request_ready,output reg [31:0] request_token,
 output reg [7:0] request_command,request_length,output reg [47:0] request_arguments,
 input [7:0] read_address,output reg [7:0] read_byte,
 output reg ack_valid,input ack_ready,output reg [31:0] ack_token,
 output reg [7:0] ack_index,ack_error,output reg ack_captured,
 output reg cancel_notice_valid,output reg [31:0] cancel_notice_token,output reg cancel_notice_session,
 input cancel_done_valid,input [31:0] cancel_done_token);
function [7:0] byte_at;input [255:0] bytes;input integer pos;begin byte_at=bytes[(31-pos)*8+:8];end endfunction
wire [7:0] command=fragment[255:248],length=fragment[247:240],index=fragment[239:232],count=fragment[231:224];
wire [31:0] token={byte_at(fragment,7),byte_at(fragment,6),byte_at(fragment,5),byte_at(fragment,4)};
reg receiving,copying,complete_pending,seen_token;reg [31:0] highest_token;
reg [7:0] expected_index,received,copy_index,copy_count,copy_base;
reg [255:0] held_fragment;reg last_valid;
reg [7:0] last_index;
reg last_control_valid,last_control_session;reg [31:0] last_control_token;
reg shape_ok;
always @(*)begin
 case(command)
  3,6,26:shape_ok=length==0;
  4,24:shape_ok=length==2;
  5,25:shape_ok=length==6;
  11:shape_ok=length<=192;
  12,16:shape_ok=length==1;
  17:shape_ok=length==3;
  18:shape_ok=length==24;
  19:shape_ok=length==0;
  default:shape_ok=0;
 endcase
end
wire cancel_owner=cancel_valid&&cancel_token==request_token;
wire control_arriving=fragment_valid&&fragment_ready&&(command==8'hf0||command==8'hf1);
assign request_valid=complete_pending&&!session_clear&&!cancel_owner&&!cancel_notice_valid&&!control_arriving;
assign fragment_ready=!copying&&!ack_valid&&!session_clear&&!cancel_notice_valid;
(* force_ram=1,ram_style="bram" *) reg [7:0] body[0:255];
always @(posedge clk)begin
 read_byte<=body[read_address];
 if(copying&&!session_clear&&!cancel_owner)body[copy_base+copy_index]<=byte_at(held_fragment,8+copy_index);
end
task acknowledge;input [31:0] t;input [7:0] i,e;input captured;begin
 ack_valid<=1;ack_token<=t;ack_index<=i;ack_error<=e;ack_captured<=captured;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  receiving<=0;copying<=0;complete_pending<=0;seen_token<=0;highest_token<=0;
  request_token<=0;request_command<=0;request_length<=0;request_arguments<=0;
  expected_index<=0;received<=0;copy_index<=0;copy_count<=0;copy_base<=0;
  held_fragment<=0;last_valid<=0;last_index<=0;
  ack_valid<=0;ack_token<=0;ack_index<=0;ack_error<=0;ack_captured<=0;
  cancel_notice_valid<=0;cancel_notice_token<=0;cancel_notice_session<=0;
  last_control_valid<=0;last_control_session<=0;last_control_token<=0;
 end else begin
  if(ack_valid&&ack_ready)ack_valid<=0;
  if(request_valid&&request_ready)complete_pending<=0;
  if(session_clear)begin
   receiving<=0;copying<=0;complete_pending<=0;seen_token<=0;highest_token<=0;last_valid<=0;ack_valid<=0;cancel_notice_valid<=0;last_control_valid<=0;
  end else if(cancel_owner)begin
   receiving<=0;copying<=0;complete_pending<=0;last_valid<=0;
  end else if(cancel_notice_valid)begin
   if(cancel_done_valid&&cancel_done_token==cancel_notice_token)begin
    cancel_notice_valid<=0;
    last_control_valid<=1;last_control_token<=cancel_notice_token;last_control_session<=cancel_notice_session;
    if(cancel_notice_session)begin seen_token<=0;highest_token<=0;last_valid<=0;end
    acknowledge(cancel_notice_token,cancel_notice_session?8'hfe:8'hff,0,0);
   end
  end else if(copying)begin
   if(copy_base+copy_index<6)request_arguments[(copy_base+copy_index)*8+:8]<=byte_at(held_fragment,8+copy_index);
   if(copy_index+1==copy_count)begin
    copying<=0;received<=copy_base+copy_count;expected_index<=expected_index+1'b1;
    last_index<=expected_index;last_valid<=1;
    if(copy_base+copy_count==request_length)begin receiving<=0;complete_pending<=1;end
    acknowledge(request_token,expected_index,0,copy_base+copy_count==request_length);
   end else copy_index<=copy_index+1'b1;
  end else if(fragment_valid&&fragment_ready&&command!=0)begin
   if(command==8'hf0||command==8'hf1)begin
    if(length!=0||index!=0||count!=0||token==0)acknowledge(token,index,8'h42,0);
    else if(last_control_valid&&last_control_token==token&&last_control_session==(command==8'hf0))
     acknowledge(token,command==8'hf0 ? 8'hfe : 8'hff,0,0);
    else begin
     cancel_notice_valid<=1;cancel_notice_token<=token;cancel_notice_session<=command==8'hf0;
     if(command==8'hf0||token==request_token)begin receiving<=0;complete_pending<=0;last_valid<=0;end
    end
   end else if(!shape_ok||token==0)acknowledge(token,index,token==0?8'h41:8'h42,0);
   else if(last_valid&&token==request_token&&index==last_index)begin
    // No new fragment is accepted during copy. The completed copy source is
    // already the immutable last fragment used for exact duplicate checks.
    acknowledge(token,index,fragment==held_fragment?8'd0:8'hd4,fragment==held_fragment&&received==request_length);
   end else if(complete_pending)acknowledge(token,index,8'h43,0);
   else if(token!=request_token||!receiving)begin
    if(seen_token&&token<=highest_token)acknowledge(token,index,8'h46,0);
    else if(index!=0||count!=(length>24?8'd24:length))acknowledge(token,index,8'hd2,0);
    else begin
     request_token<=token;request_command<=command;request_length<=length;request_arguments<=0;
     highest_token<=token;seen_token<=1;expected_index<=0;received<=0;last_valid<=0;
     if(length==0)begin
      receiving<=0;complete_pending<=1;held_fragment<=fragment;last_index<=0;last_valid<=1;
      acknowledge(token,0,0,1);
     end else begin
      receiving<=1;copying<=1;copy_index<=0;copy_count<=count;copy_base<=0;held_fragment<=fragment;
     end
    end
   end else if(command!=request_command||length!=request_length)acknowledge(token,index,8'hd4,0);
   else if(index!=expected_index||count==0||count>24||count!=(request_length-received>24?8'd24:request_length-received))
    acknowledge(token,index,8'hd2,0);
   else begin copying<=1;copy_index<=0;copy_count<=count;copy_base<=received;held_fragment<=fragment;end
  end
 end
end
endmodule
