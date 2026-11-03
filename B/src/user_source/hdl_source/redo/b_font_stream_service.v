module b_font_stream_service #(parameter REPLY_TIMEOUT_CYCLES=2000000,MAX_TRANSMISSIONS=32)(
 input clk,rst_n,input start_valid,output start_ready,input [31:0] start_uid,
 input [6:0] start_glyph_count,input [7:0] start_utf8_bytes,input [1:0] start_size,start_target,
 input raw_valid,output raw_ready,input [7:0] raw_byte,input raw_last,input cancel_valid,
 input font_initialized,input font_request_ready,output font_request_valid,output [15:0] font_request_codepoint,
 output [1:0] font_request_size,output [31:0] font_request_token,output font_request_cancel,
 input font_glyph_valid,output font_glyph_ready,input [7:0] font_glyph_byte,input [8:0] font_glyph_index,
 input font_glyph_first,font_glyph_last,input [31:0] font_glyph_token,input font_request_complete,input [7:0] font_request_result,
 output tx_valid,input tx_ready,output [7:0] tx_kind,tx_arg,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input [5:0] tx_address,output [31:0] tx_word,
 input tx_done,input ack_valid,input [7:0] ack_marker,input [31:0] ack_uid,input [7:0] ack_kind,
 input [15:0] ack_sequence,input [7:0] ack_error,output complete,output [7:0] result_error,output blocked,output drained);
localparam IDLE=0,WAIT_CODEPOINT=1,REQUEST_FONT=2,READ_FONT=3,SOURCE_DONE=4,PREFETCH_CODEPOINT=5;
reg [2:0] state;
reg reader_inflight;
wire packetizer_busy;
reg [31:0] owner_uid;
reg [6:0] glyph_count,glyph_index;
reg [1:0] size_code;
reg [15:0] active_codepoint;
reg [7:0] source_error;
wire packetizer_start_ready,packetizer_complete,packetizer_blocked,packetizer_glyph_ready;
wire [7:0] packetizer_error,decoder_error,packetizer_source_error;
wire [15:0] decoded_codepoint;
wire decoded_valid,decoded_ready,decoder_byte_ready,decoder_done;
wire packetizer_raw_ready,source_done,request_fire,source_stall;
reg [31:0] source_stall_cycles;
wire [15:0] codepoint_fifo_word;
reg [5:0] codepoint_write_ptr,codepoint_read_ptr;
reg [6:0] codepoint_fifo_count;
wire decoded_push=decoded_valid&&decoded_ready;
wire decoded_pop=state==WAIT_CODEPOINT&&packetizer_glyph_ready&&codepoint_fifo_count!=0;
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) codepoint_ram(
 .doa(),.dia(decoded_codepoint),.addra({5'd0,codepoint_write_ptr}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(decoded_push),.clka(clk),.rsta(1'b0),.ocea(1'b1),
 .dob(codepoint_fifo_word),.dib(16'd0),.addrb({5'd0,codepoint_read_ptr}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
assign drained=state==IDLE&&!packetizer_busy&&!reader_inflight&&!packetizer_blocked;
always @(posedge clk or negedge rst_n)
 if(!rst_n)reader_inflight<=0;
 else if(font_request_complete)reader_inflight<=0;
 else if(request_fire)reader_inflight<=1;
assign source_done=state==SOURCE_DONE;
assign request_fire=font_request_valid&&font_request_ready;
assign source_stall=(state==WAIT_CODEPOINT)&&packetizer_glyph_ready&&codepoint_fifo_count==0&&!decoder_done;
assign packetizer_source_error=source_error!=0?source_error:decoder_error;
function [7:0] map_reader_error;
 input [7:0] reader_error;
 begin
  case(reader_error)
   8'h00:map_reader_error=8'h00;
   8'h70:map_reader_error=8'ha0;
   8'h71:map_reader_error=8'ha4;
   8'h72:map_reader_error=8'ha0;
   8'h73:map_reader_error=8'ha5;
   8'h74:map_reader_error=8'ha6;
   8'h75:map_reader_error=8'ha7;
   default:map_reader_error=8'ha6;
  endcase
 end
endfunction
assign start_ready=(font_initialized||(start_glyph_count==0&&start_utf8_bytes==0))&&state==IDLE&&!reader_inflight&&packetizer_start_ready&&!packetizer_blocked;
assign decoded_ready=codepoint_fifo_count<7'd64;
assign font_request_valid=state==REQUEST_FONT;
assign font_request_codepoint=active_codepoint;
assign font_request_size=size_code;
assign font_request_token=owner_uid;
assign font_request_cancel=cancel_valid;
assign font_glyph_ready=state==READ_FONT&&packetizer_glyph_ready;
assign raw_ready=packetizer_raw_ready&&decoder_byte_ready;
assign complete=packetizer_complete;
assign result_error=packetizer_error;
assign blocked=packetizer_blocked;

b_font_stream_packetizer #(.REPLY_TIMEOUT_CYCLES(REPLY_TIMEOUT_CYCLES),.MAX_TRANSMISSIONS(MAX_TRANSMISSIONS)) packetizer(
 .clk(clk),.rst_n(rst_n),.start_valid(start_valid&&start_ready),.start_ready(packetizer_start_ready),.start_uid(start_uid),
 .start_glyph_count(start_glyph_count),.start_utf8_bytes(start_utf8_bytes),.start_size(start_size),.start_target(start_target),
 .raw_valid(raw_valid&&decoder_byte_ready),.raw_ready(packetizer_raw_ready),.raw_byte(raw_byte),.raw_last(raw_last),
 .source_done(source_done),.source_error(packetizer_source_error),.cancel_valid(cancel_valid),
 .glyph_valid(state==READ_FONT&&font_glyph_valid),.glyph_ready(packetizer_glyph_ready),.glyph_data(font_glyph_byte),
 .glyph_byte_index(font_glyph_index),.glyph_first(font_glyph_first),.glyph_last(font_glyph_last),
 .glyph_character_index(glyph_index),.glyph_codepoint(active_codepoint),.glyph_size(size_code),.glyph_token(font_glyph_token),
 .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_kind(tx_kind),.tx_arg(tx_arg),.tx_count(tx_count),
 .tx_sequence(tx_sequence),.tx_tag(tx_tag),.tx_value(tx_value),.tx_address(tx_address),.tx_word(tx_word),
 .tx_done(tx_done),.ack_valid(ack_valid),.ack_marker(ack_marker),.ack_uid(ack_uid),.ack_kind(ack_kind),
 .ack_sequence(ack_sequence),.ack_error(ack_error),.busy(packetizer_busy),.complete(packetizer_complete),
 .result_error(packetizer_error),.blocked(packetizer_blocked));

b_utf8_codepoint_stream utf8(
 .clk(clk),.rst_n(rst_n),.start_valid(start_valid&&start_ready),.start_byte_count(start_utf8_bytes),
 .start_codepoint_count(start_glyph_count),.cancel(cancel_valid),.byte_valid(raw_valid&&packetizer_raw_ready),
 .byte_ready(decoder_byte_ready),.byte_data(raw_byte),.byte_last(raw_last),
 .codepoint_valid(decoded_valid),.codepoint_ready(decoded_ready),.codepoint(decoded_codepoint),
 .done(decoder_done),.error_code(decoder_error));

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;owner_uid<=0;glyph_count<=0;glyph_index<=0;size_code<=0;active_codepoint<=0;source_error<=0;source_stall_cycles<=0;
  codepoint_write_ptr<=0;codepoint_read_ptr<=0;codepoint_fifo_count<=0;
 end else begin
  if(decoded_push)codepoint_write_ptr<=codepoint_write_ptr+1'b1;
  if(decoded_pop)codepoint_read_ptr<=codepoint_read_ptr+1'b1;
  case({decoded_push,decoded_pop})
   2'b10:codepoint_fifo_count<=codepoint_fifo_count+1'b1;
   2'b01:codepoint_fifo_count<=codepoint_fifo_count-1'b1;
   default:;
  endcase
  if(start_valid&&start_ready)begin
   owner_uid<=start_uid;glyph_count<=start_glyph_count;glyph_index<=0;size_code<=start_size;source_error<=0;
   state<=start_glyph_count==0?SOURCE_DONE:WAIT_CODEPOINT;source_stall_cycles<=0;
   codepoint_write_ptr<=0;codepoint_read_ptr<=0;codepoint_fifo_count<=0;
  end else begin
   if(cancel_valid&&state!=IDLE)begin state<=SOURCE_DONE;source_error<=8'ha7;end
   else case(state)
    WAIT_CODEPOINT:if(decoded_pop)begin state<=PREFETCH_CODEPOINT;source_stall_cycles<=0;end
     else if(decoded_valid&&!decoded_ready)begin source_error<=8'ha2;state<=SOURCE_DONE;end
     else if(decoder_done&&decoder_error!=0)begin source_error<=decoder_error;state<=SOURCE_DONE;end
     else if(source_stall)begin
      if(source_stall_cycles>=REPLY_TIMEOUT_CYCLES)begin state<=SOURCE_DONE;source_error<=8'ha6;end
      else source_stall_cycles<=source_stall_cycles+1'b1;
     end
    PREFETCH_CODEPOINT:begin active_codepoint<=codepoint_fifo_word;state<=REQUEST_FONT;end
    REQUEST_FONT:if(request_fire)state<=READ_FONT;
    READ_FONT:if(font_request_complete)begin
     if(font_request_result!=0)begin source_error<=map_reader_error(font_request_result);state<=SOURCE_DONE;end
     else if(glyph_index+1'b1>=glyph_count)state<=SOURCE_DONE;
     else begin glyph_index<=glyph_index+1'b1;state<=WAIT_CODEPOINT;end
    end
    SOURCE_DONE:if(packetizer_complete)begin state<=IDLE;source_error<=0;source_stall_cycles<=0;end
    default:;
   endcase
   if(packetizer_complete)begin state<=IDLE;source_error<=0;source_stall_cycles<=0;codepoint_fifo_count<=0;codepoint_write_ptr<=0;codepoint_read_ptr<=0;end
  end
 end
end
endmodule
