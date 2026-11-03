`timescale 1ns/1ps
// FS2 glyph-stream packetizer: one stop-and-wait F2 receipt per command, no
// 4A/F3 second phase. Payload bytes form one linear stream: the raw UTF-8
// (zero padded to a word) at offset 0, then every glyph bitmap back to back.
// The SPI6 frame CRC16 protects each packet and the font reader has already
// checked each glyph's Flash CRC, so no per-glyph/aggregate CRC is carried.
// A replays its last receipt for a duplicate (uid,kind,sequence), so a lost
// receipt is recovered by resending the retained packet.
//   0x60 BEGIN  arg={4'h2,size,target} seq=glyph count tag=UTF-8 bytes
//   0x61 DATA   arg=size count=words   seq=byte offset  tag=0
//   0x65 COMMIT arg=1                  seq=total bytes  tag=0
//   0x64 ABORT  arg=1
module b_font_stream_packetizer #(parameter REPLY_TIMEOUT_CYCLES=2000000,parameter MAX_TRANSMISSIONS=32)(
 input clk,rst_n,
 input start_valid,output start_ready,input [31:0] start_uid,
 input [6:0] start_glyph_count,input [7:0] start_utf8_bytes,
 input [1:0] start_size,input [1:0] start_target,
 input raw_valid,output raw_ready,input [7:0] raw_byte,input raw_last,
 input source_done,input [7:0] source_error,
 input cancel_valid,
 input glyph_valid,output glyph_ready,input [7:0] glyph_data,
 input [8:0] glyph_byte_index,input glyph_first,glyph_last,
 input [6:0] glyph_character_index,input [15:0] glyph_codepoint,
 input [1:0] glyph_size,input [31:0] glyph_token,
 output tx_valid,input tx_ready,output wire [7:0] tx_kind,tx_arg,
 output wire [6:0] tx_count,output wire [15:0] tx_sequence,tx_tag,
 output wire [31:0] tx_value,input [5:0] tx_address,output wire [31:0] tx_word,
 input tx_done,input ack_valid,input [7:0] ack_marker,
 input [31:0] ack_uid,input [7:0] ack_kind,input [15:0] ack_sequence,
 input [7:0] ack_error,
 output wire busy,output reg complete,output reg [7:0] result_error,
 output reg blocked);
localparam IDLE=0,SEND=1,WAIT_F2=2,COLLECT_TEXT=3,COLLECT=4,WAIT_SOURCE=5,BLOCKED=6;
localparam FONT_FIELD=8'ha0,FONT_ORDER=8'ha2,FONT_FLASH=8'ha6,FONT_CANCEL=8'ha7;
reg [2:0] state;
reg [31:0] uid;
reg [6:0] job_glyph_count,glyph_index;
reg [7:0] utf8_bytes;
reg [1:0] size_code;
reg [8:0] fill;
reg [15:0] offset;
reg [23:0] acc;
reg [7:0] pending_error;
reg cancel_seen,tx_finished;
reg [31:0] elapsed;
reg [7:0] attempts;
reg [7:0] command_kind,command_arg;
reg [6:0] command_count;
reg [15:0] command_sequence,command_tag;
(* force_ram=1,ram_style="bram" *) reg [31:0] staging[0:63];
reg [31:0] word_q;

wire glyph_handshake=glyph_valid&&glyph_ready;
wire raw_handshake=raw_valid&&raw_ready;
wire byte_handshake=glyph_handshake||raw_handshake;
wire [7:0] stream_byte=glyph_handshake?glyph_data:raw_byte;
// A word is written on its fourth byte, or on the last raw byte (zero padded).
wire word_write=byte_handshake&&(fill[1:0]==2'd3||(raw_handshake&&raw_last));
wire [31:0] word_data=fill[1:0]==2'd3 ?{stream_byte,acc}:
 fill[1:0]==2'd2 ?{8'd0,stream_byte,acc[15:0]}:
 fill[1:0]==2'd1 ?{16'd0,stream_byte,acc[7:0]}:{24'd0,stream_byte};
always @(posedge clk)begin
 if(word_write)staging[fill[7:2]]<=word_data;
 word_q<=staging[tx_address];
end

wire f2_match=ack_valid&&ack_marker==8'hf2&&ack_uid==uid&&ack_kind==command_kind&&ack_sequence==command_sequence;
wire stop_requested=cancel_seen||cancel_valid||pending_error!=0;
wire last_glyph_byte=glyph_handshake&&glyph_last&&glyph_index+1'b1==job_glyph_count;

assign start_ready=state==IDLE&&!complete&&!blocked;
assign busy=state!=IDLE&&state!=BLOCKED;
assign glyph_ready=state==COLLECT&&!stop_requested&&fill<9'd256;
assign raw_ready=state==COLLECT_TEXT&&!stop_requested;
// While waiting, the shared SPI owner carries payload-free kind01 polls that
// read A's retained reply bank.
wire receipt_poll=state==WAIT_F2&&tx_finished;
assign tx_valid=state==SEND||receipt_poll;
assign tx_kind=receipt_poll?8'd1:command_kind;
assign tx_arg=receipt_poll?8'd0:command_arg;
assign tx_count=receipt_poll?7'd0:command_count;
assign tx_sequence=receipt_poll?16'd0:command_sequence;
assign tx_tag=receipt_poll?16'd0:command_tag;
assign tx_value=receipt_poll?32'd0:uid;
assign tx_word=word_q;

task issue;
 input [7:0] kind,arg;input [6:0] count;input [15:0] sequence_id,tag;
 begin
  command_kind<=kind;command_arg<=arg;command_count<=count;command_sequence<=sequence_id;command_tag<=tag;
  elapsed<=0;attempts<=0;tx_finished<=0;state<=SEND;
 end
endtask
task abort;
 begin fill<=0;acc<=0;issue(8'h64,8'h01,7'd0,16'd0,16'd0);end
endtask
task finish;
 input [7:0] code;
 begin result_error<=code;complete<=1;state<=IDLE;end
endtask
task fail_link;
 begin blocked<=1;result_error<=command_kind==8'h64&&pending_error!=0?pending_error:FONT_FLASH;complete<=1;state<=BLOCKED;end
endtask
// Next step after an accepted (error-free) receipt.
task retire;
 begin
  case(command_kind)
   8'h60:if(stop_requested)abort;else if(utf8_bytes!=0)state<=COLLECT_TEXT;
    else if(job_glyph_count!=0)state<=COLLECT;else state<=WAIT_SOURCE;
   8'h61:begin
    // Raw text is zero padded to a word; glyph packets are word multiples.
    offset<=offset+{(fill+9'd3)>>2,2'b00};fill<=0;acc<=0;
    if(stop_requested)abort;else if(glyph_index==job_glyph_count)state<=WAIT_SOURCE;else state<=COLLECT;
   end
   8'h65:finish(0);
   8'h64:finish(pending_error==0?FONT_CANCEL:pending_error);
   default:begin pending_error<=FONT_ORDER;abort;end
  endcase
 end
endtask

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;uid<=0;job_glyph_count<=0;glyph_index<=0;utf8_bytes<=0;size_code<=0;
  fill<=0;offset<=0;acc<=0;pending_error<=0;cancel_seen<=0;tx_finished<=0;elapsed<=0;attempts<=0;
  command_kind<=0;command_arg<=0;command_count<=0;command_sequence<=0;command_tag<=0;
  complete<=0;result_error<=0;blocked<=0;
 end else begin
  complete<=0;
  if(state!=IDLE&&state!=BLOCKED)begin
   if(source_done&&source_error!=0&&pending_error==0)pending_error<=source_error;
   if(cancel_valid)begin cancel_seen<=1;if(pending_error==0)pending_error<=FONT_CANCEL;end
  end
  if(byte_handshake)begin
   fill<=fill+1'b1;
   acc<=fill[1:0]==2'd3 ?24'd0:fill[1:0]==2'd2 ?{stream_byte,acc[15:0]}:
    fill[1:0]==2'd1 ?{8'd0,stream_byte,acc[7:0]}:{16'd0,stream_byte};
  end
  case(state)
   IDLE:if(start_valid&&start_ready)begin
    result_error<=0;pending_error<=0;cancel_seen<=0;
    uid<=start_uid;job_glyph_count<=start_glyph_count;utf8_bytes<=start_utf8_bytes;size_code<=start_size;
    glyph_index<=0;fill<=0;acc<=0;offset<=0;
    if(start_uid==0||start_size==3)finish(FONT_FIELD);
    else if(start_glyph_count>64||start_utf8_bytes>192||(start_glyph_count==0&&start_utf8_bytes!=0))finish(FONT_ORDER);
    else issue(8'h60,{4'h2,start_size,start_target},7'd0,{9'd0,start_glyph_count},{8'd0,start_utf8_bytes});
   end
   SEND:if(tx_valid&&tx_ready)begin
    state<=WAIT_F2;elapsed<=0;tx_finished<=0;if(attempts!=8'hff)attempts<=attempts+1'b1;
   end
   WAIT_F2:begin
    if(f2_match)begin
     if(ack_error!=0&&command_kind!=8'h64)begin pending_error<=ack_error;abort;end
     else if(ack_error!=0)finish(pending_error==0?ack_error:pending_error);
     else retire;
    end else if(!tx_finished)begin
     if(tx_done)begin tx_finished<=1;elapsed<=0;end
     else if(elapsed<REPLY_TIMEOUT_CYCLES)elapsed<=elapsed+1'b1;
     else fail_link;
    end else if(elapsed>=REPLY_TIMEOUT_CYCLES)begin
     if(attempts>=MAX_TRANSMISSIONS)fail_link;
     else begin state<=SEND;elapsed<=0;tx_finished<=0;end
    end else elapsed<=elapsed+1'b1;
   end
   COLLECT_TEXT:begin
    if(stop_requested)abort;
    else if(raw_handshake&&raw_last)begin
     if(fill+1'b1!={1'b0,utf8_bytes})begin pending_error<=FONT_ORDER;abort;end
     else begin
      // Glyph offsets begin at the word-aligned end of the raw text.
      issue(8'h61,{6'd0,size_code},(utf8_bytes+8'd3)>>2,16'd0,16'd0);
     end
    end else if(raw_handshake&&fill+1'b1>={1'b0,utf8_bytes})begin pending_error<=FONT_ORDER;abort;end
   end
   COLLECT:begin
    if(stop_requested)abort;
    else if(glyph_handshake)begin
     if(glyph_last)glyph_index<=glyph_index+1'b1;
     if(fill==9'd255||last_glyph_byte)
      issue(8'h61,{6'd0,size_code},(fill[8:2]+1'b1),offset,16'd0);
    end else if(source_done&&source_error==0&&glyph_index<job_glyph_count&&fill==0)begin
     pending_error<=FONT_ORDER;abort;
    end
   end
   WAIT_SOURCE:if(stop_requested)abort;
    else if(source_done)issue(8'h65,8'h01,7'd0,offset,16'd0);
   BLOCKED:blocked<=1;
   default:begin pending_error<=FONT_ORDER;abort;end
  endcase
 end
end
endmodule
