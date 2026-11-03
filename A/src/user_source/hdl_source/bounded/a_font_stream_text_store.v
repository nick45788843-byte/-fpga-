`timescale 1ns/1ps
// Retained UTF-8 for the four streamed font targets, one bank per target.
// A job's raw writes start after job_start hides the target (front_valid=0),
// and only a frame-committed target is readable. CMD16 arguments 80..BB
// select target/page (16 bytes). Other CMD16 arguments are the legacy offset
// query, answered from the subtitle target 0 in the legacy reply layout.
// The reply is captured before publication, so UART stalls cannot mix data.
module a_font_stream_text_store(
 input clk,rst_n,
 input raw_we,input [1:0] raw_target,input raw_bank,input job_start,
 input [7:0] raw_address,raw_byte,
 input commit_valid,input [1:0] commit_target,input commit_bank,
 input [7:0] commit_length,
 input request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_argument,
 input cancel_valid,input [31:0] cancel_token,
 output reg result_valid,input result_ready,output reg [31:0] result_token,
 input [4:0] result_address,output reg [7:0] result_byte,
 output reg cancelled,output reg [31:0] cancelled_token,output idle
);
 localparam IDLE=0,WAIT_READ=1,CAPTURE=2;
 reg [1:0] state;
 (* force_ram=1,ram_style="bram_9k" *) reg [7:0] raw_mem[0:1023];
 reg [3:0] front_valid;
 reg legacy;
 reg [7:0] length0,length1,length2,length3;
 reg [7:0] generation0,generation1,generation2,generation3;
 reg [1:0] selected_target;
 reg [7:0] offset,total,generation;
 reg [4:0] count;
 reg [3:0] cursor;
 reg [7:0] reply_error,read_byte;
 reg [127:0] captured;
 wire stream_query=request_argument[7:6]==2'b10;
 wire [1:0] requested_target=stream_query?request_argument[5:4]:2'd0;
 wire [7:0] requested_offset=stream_query?{request_argument[3:0],4'd0}:request_argument;
 wire [7:0] selected_length=requested_target==0?length0:
   requested_target==1?length1:requested_target==2?length2:length3;
 wire [7:0] selected_generation=requested_target==0?generation0:
   requested_target==1?generation1:requested_target==2?generation2:generation3;
 wire [7:0] read_offset=offset+{4'd0,cursor};
 wire [9:0] read_index={selected_target,read_offset};
 wire capture_collision=state!=IDLE&&raw_we&&raw_target==selected_target;
 assign request_ready=state==IDLE&&!result_valid;
 assign idle=state==IDLE&&!result_valid;
 always @(posedge clk)begin
  read_byte<=raw_mem[read_index];
  if(raw_we&&raw_address<192)raw_mem[{raw_target,raw_address}]<=raw_byte;
 end
 always @(*)begin
  case(result_address)
   0:result_byte=8'd16;
   1:result_byte=reply_error!=0;
   2:result_byte=reply_error;
   3:result_byte=legacy?8'd0:8'd5;
   4:result_byte=offset;
   5:result_byte=reply_error==0?{3'd0,count}:8'd0;
   6:result_byte=legacy?{7'd0,total!=0}:total;
   7:result_byte=legacy?total:generation;
   default:result_byte=result_address<24&&reply_error==0&&
     {1'b0,result_address}<({1'b0,count}+6'd8)?
     captured[(result_address-5'd8)*8+:8]:8'd0;
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;front_valid<=0;legacy<=0;
   length0<=0;length1<=0;length2<=0;length3<=0;
   generation0<=0;generation1<=0;generation2<=0;generation3<=0;
   selected_target<=0;offset<=0;total<=0;generation<=0;
   count<=0;cursor<=0;reply_error<=0;captured<=0;
   result_valid<=0;result_token<=0;cancelled<=0;cancelled_token<=0;
  end else begin
   cancelled<=0;
   if(job_start)front_valid[raw_target]<=0;
   if(commit_valid&&commit_length<=192)begin
    front_valid[commit_target]<=1;
    case(commit_target)
     0:begin length0<=commit_length;generation0<=generation0+1'b1;end
     1:begin length1<=commit_length;generation1<=generation1+1'b1;end
     2:begin length2<=commit_length;generation2<=generation2+1'b1;end
     3:begin length3<=commit_length;generation3<=generation3+1'b1;end
    endcase
   end
   if(result_valid&&result_ready)result_valid<=0;
   if(cancel_valid&&cancel_token==result_token&&(state!=IDLE||result_valid))begin
    state<=IDLE;result_valid<=0;cancelled<=1;cancelled_token<=result_token;
   end else begin
    if(capture_collision)reply_error<=8'ha1;
    case(state)
     IDLE:if(request_valid&&request_ready)begin
      result_token<=request_token;selected_target<=requested_target;
      offset<=requested_offset;legacy<=!stream_query;
      total<=front_valid[requested_target]?selected_length:8'd0;
      generation<=selected_generation;cursor<=0;captured<=0;
      reply_error<=0;count<=0;
      if(stream_query&&request_argument[3:0]>11)begin
       reply_error<=8'ha2;result_valid<=1;
      end else if(!stream_query&&request_argument>191)begin
       reply_error<=8'h47;result_valid<=1;
      end else if(!front_valid[requested_target])begin
       result_valid<=1;
      end else if(requested_offset>selected_length)begin
       reply_error<=stream_query?8'ha2:8'h47;result_valid<=1;
      end else if(requested_offset==selected_length)begin
       result_valid<=1;
      end else begin
       count<=selected_length-requested_offset>16?5'd16:selected_length-requested_offset;
       state<=WAIT_READ;
      end
     end
     WAIT_READ:state<=CAPTURE;
     CAPTURE:begin
      captured[cursor*8+:8]<=read_byte;
      if({1'b0,cursor}+5'd1>=count)begin state<=IDLE;result_valid<=1;end
      else begin cursor<=cursor+1'b1;state<=WAIT_READ;end
     end
     default:state<=IDLE;
    endcase
   end
  end
 end
endmodule
