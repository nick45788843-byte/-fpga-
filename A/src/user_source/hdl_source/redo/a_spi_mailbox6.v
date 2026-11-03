// Proven MOSI CRC/RAM/mailbox algorithm, independent of MISO reply storage.
module a_spi_mailbox6 #(parameter SERIAL_CRC=0,REGISTER_HEADER=0)(input clk,rst_n,spi_clk,cs_n,mosi,
 output ready,command_valid,input command_ready,
 output [7:0] command_kind,command_arg,output [6:0] command_count,
 output [15:0] command_sequence,command_tag,command_crc,output [31:0] command_value,
 input [5:0] read_address,output reg [31:0] read_word,output reg [15:0] bad_frames);
localparam [7:0] PROTOCOL_VERSION=6;
wire frame_reset=!rst_n||cs_n;
reg [8:0] byte_index;reg [2:0] bit_index;reg [7:0] shift,crc_low;
reg [15:0] crc;reg header_ok,reserved;reg [7:0] kind,arg;reg [6:0] count;
reg [15:0] sequence_id,tag;reg [31:0] value,payload_shift;
reg finished;reg request_toggle,ack_toggle;reg bad_toggle;reg [102:0] mailbox;
(* async_reg=1,preserve=1 *) reg ack_meta,ack_sync,request_meta,request_sync;
reg [31:0] words[0:63];
// These three bytes were received at least eight SCLK edges before the
// fourth-byte RAM write. Sampling their stable value on the negative SCLK
// edge removes a short positive-edge FF -> ERAM data hold path. The current
// MOSI byte, write address/enable, CRC and mailbox ownership are unchanged.
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [23:0] payload_phase;
always @(negedge spi_clk)payload_phase<=payload_shift[23:0];

wire [7:0] incoming={shift[6:0],mosi};wire byte_done=bit_index==7;
(*async_reg=1,preserve=1*) reg ack_phase,request_phase,bad_phase;
always @(negedge clk or negedge rst_n)begin
 if(!rst_n)begin ack_phase<=0;request_phase<=0;bad_phase<=0;end
 else begin ack_phase<=ack_toggle;request_phase<=request_toggle;bad_phase<=bad_toggle;end
end
// The SPI owner holds this entire CRC-validated header until the real ACK.
// The retained negative-edge input phase separates external SCLK from
// positive-edge consumers. The original request synchronizers delay valid
// until this CRC-qualified held header is stable. Source ownership still
// prevents reuse until the original ACK has crossed back to the SPI owner.
// The half-cycle phase-to-consumer paths require real full-board timing.
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg [102:0] mailbox_phase;
always @(negedge clk)mailbox_phase<=mailbox;

// The request crosses request_phase -> request_meta -> request_sync. Capture
// the already-held header before that valid becomes visible to consumers.
// Nonconstant data still traverses the original negative-edge phase; neither
// its timing path nor the SPI RAM lease is bypassed.
wire [102:0] visible_header;
generate if(REGISTER_HEADER)begin:g_registered_header
 (*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg[102:0] header;
 always @(posedge clk)header<=mailbox_phase;
 assign visible_header=header;
end else begin:g_legacy_header
 assign visible_header=mailbox_phase;
end endgenerate

wire room=request_toggle==ack_sync;
// Only a zero-payload heartbeat may use the bounded short frame.
// All media/RPC bodies keep their original complete 272-byte CRC lease.
wire short_frame=kind==8'd1&&count==0;
wire [8:0] frame_last=short_frame?9'd63:9'd271;
wire [8:0] crc_position=frame_last-9'd1;
wire complete=byte_done&&byte_index==frame_last&&!finished;
wire checksum_ok=header_ok&&crc=={incoming,crc_low};
function [15:0] step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;step={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
always @(posedge spi_clk or negedge rst_n)begin
 if(!rst_n)begin ack_meta<=0;ack_sync<=0;request_toggle<=0;mailbox<=0;end
 else begin
  ack_meta<=ack_phase;ack_sync<=ack_meta;
  if(!cs_n&&complete&&checksum_ok&&reserved)begin
   mailbox<={kind,arg,count,sequence_id,tag,value,crc};request_toggle<=!request_toggle;
  end
 end
end
always @(posedge spi_clk or posedge frame_reset)begin
 if(frame_reset)begin byte_index<=0;bit_index<=0;shift<=0;crc_low<=0;crc<=16'hffff;header_ok<=1;reserved<=0;kind<=0;arg<=0;count<=0;sequence_id<=0;tag<=0;value<=0;payload_shift<=0;finished<=0;end
 else begin
  // One polynomial step per received SCLK bit. The data-zone bound is the
  // same for both 64-byte polls and complete 272-byte retained-body frames.
  if(SERIAL_CRC&&!finished&&byte_index<crc_position)
   crc<={crc[14:0],1'b0}^((crc[15]^mosi)?16'h1021:16'd0);
  if(!finished)begin shift<=incoming;bit_index<=bit_index+1'b1;end
  if(byte_done&&!finished)begin
   if(byte_index==frame_last)finished<=1;
   if(byte_index<frame_last)byte_index<=byte_index+1'b1;
   if(!SERIAL_CRC&&byte_index<crc_position)crc<=step(crc,incoming);
   if(byte_index==crc_position)crc_low<=incoming;
   case(byte_index)
    0:if(incoming!=8'h43)header_ok<=0;
    1:if(incoming!=8'h4e)header_ok<=0;
    2:if(incoming!=PROTOCOL_VERSION)header_ok<=0;
    3:begin kind<=incoming;reserved<=room;end
    4:sequence_id[7:0]<=incoming;5:sequence_id[15:8]<=incoming;
    6:begin count<=incoming[6:0];if(incoming>64)header_ok<=0;end
    7:arg<=incoming;
    8:value[7:0]<=incoming;9:value[15:8]<=incoming;10:value[23:16]<=incoming;11:value[31:24]<=incoming;
    12:tag[7:0]<=incoming;13:tag[15:8]<=incoming;
   endcase
   if(byte_index>=14&&byte_index<crc_position)begin
    case((byte_index-14)&3)
     0:payload_shift[7:0]<=incoming;1:payload_shift[15:8]<=incoming;2:payload_shift[23:16]<=incoming;
     3:begin payload_shift[31:24]<=incoming;if(header_ok&&reserved&&((byte_index-14)>>2)<count)words[(byte_index-14)>>2]<={incoming,payload_phase};end
    endcase
   end
  end
 end
end
// 错误只作跨域计数提示；不拿未经校验的数据执行操作。
reg bad_seen;(* async_reg=1,preserve=1 *) reg bad_meta,bad_sync;
always @(posedge spi_clk or negedge rst_n)begin
 if(!rst_n)bad_toggle<=0;else if(!cs_n&&complete&&(!checksum_ok||!reserved))bad_toggle<=!bad_toggle;
end
assign command_valid=request_sync!=ack_toggle;
assign ready=request_sync==ack_toggle;
assign {command_kind,command_arg,command_count,command_sequence,command_tag,command_value,command_crc}=visible_header;
always @(posedge clk)read_word<=words[read_address];
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin request_meta<=0;request_sync<=0;ack_toggle<=0;bad_meta<=0;bad_sync<=0;bad_seen<=0;bad_frames<=0;end
 else begin
  request_meta<=request_phase;request_sync<=request_meta;bad_meta<=bad_phase;bad_sync<=bad_meta;
  if(command_valid&&command_ready)ack_toggle<=request_sync;
  if(bad_sync!=bad_seen)begin bad_seen<=bad_sync;if(bad_frames!=16'hffff)bad_frames<=bad_frames+1'b1;end
 end
end
endmodule
