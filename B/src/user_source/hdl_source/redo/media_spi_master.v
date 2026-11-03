// Private RX byte RAM is stable while a CRC-qualified reply is copied.
// The sole parallel result is valid only after the complete copy, during MOSI.
module media_spi_master #(parameter HALF_CYCLES=3,parameter [7:0] PROTOCOL_VERSION=4,
 parameter REPLY_BYTES=(PROTOCOL_VERSION>=6 ? 64 : 32),SHORT_POLL=0)(input clk,rst_n,start,
 input [7:0] kind,arg,input [6:0] count,input [15:0] sequence_id,tag,input [31:0] value,
 output reg [5:0] read_address,input [31:0] read_word,input miso,
 output reg cs_n,sclk,mosi,busy,done,output reg reply_valid,
 output reg [(REPLY_BYTES-2)*8-1:0] reply_body,output reg [15:0] bad_replies);
localparam BODY_BITS=(REPLY_BYTES-2)*8;
localparam W=$clog2(HALF_CYCLES+1);
reg [W-1:0] divider;
reg [2:0] state,bit_index;
reg [8:0] byte_index;
reg [7:0] tx_shift,rx_shift,rx_crc_low;
reg [15:0] crc,rx_crc;
reg [31:0] held_word,received_header;
reg [7:0] held_kind,held_arg;
reg [6:0] held_count;
reg [15:0] held_seq,held_tag;
reg [31:0] held_value;
(* force_ram=1,ram_style="bram" *) reg [7:0] received_bytes[0:REPLY_BYTES-3];
reg [7:0] received_byte;
reg [5:0] copy_index;
reg [1:0] copy_state;
wire edge_tick=state==4&&divider==HALF_CYCLES-1;
wire [7:0] received={rx_shift[6:0],miso};
wire receive_byte=edge_tick&&!sclk&&bit_index==7&&byte_index<REPLY_BYTES-2;
wire reply_complete=edge_tick&&!sclk&&bit_index==7&&byte_index==REPLY_BYTES-1;
wire qualified_reply=received_header=={16'h434e,PROTOCOL_VERSION,8'h81}&&rx_crc=={received,rx_crc_low};
wire short_frame=SHORT_POLL&&held_kind==8'd1&&held_count==0;
wire [8:0] frame_last=short_frame?9'd63:9'd271;
wire [8:0] crc_position=frame_last-9'd1;
function [7:0] tx_byte;input [8:0] position;
reg [8:0] payload_position;
begin
 payload_position=position-9'd14;
 if(position==crc_position)tx_byte=crc[7:0];
 else if(position==frame_last)tx_byte=crc[15:8];
 else case(position)
  0:tx_byte=8'h43;1:tx_byte=8'h4e;2:tx_byte=PROTOCOL_VERSION;3:tx_byte=held_kind;
  4:tx_byte=held_seq[7:0];5:tx_byte=held_seq[15:8];6:tx_byte={1'b0,held_count};7:tx_byte=held_arg;
  8:tx_byte=held_value[7:0];9:tx_byte=held_value[15:8];10:tx_byte=held_value[23:16];11:tx_byte=held_value[31:24];
  12:tx_byte=held_tag[7:0];13:tx_byte=held_tag[15:8];
  default:tx_byte=payload_position[8:2]<held_count ? held_word[{payload_position[1:0],3'b000}+:8] : 8'd0;
 endcase
end endfunction
always @(posedge clk)begin
 if(rst_n&&receive_byte)received_bytes[byte_index[5:0]]<=received;
 received_byte<=received_bytes[copy_index];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  cs_n<=1;sclk<=0;mosi<=0;busy<=0;done<=0;reply_valid<=0;reply_body<=0;bad_replies<=0;
  divider<=0;state<=0;bit_index<=0;byte_index<=0;read_address<=0;held_word<=0;
  held_kind<=0;held_arg<=0;held_count<=0;held_seq<=0;held_tag<=0;held_value<=0;
  tx_shift<=0;rx_shift<=0;crc<=16'hffff;rx_crc<=16'hffff;rx_crc_low<=0;
  received_header<=0;copy_index<=0;copy_state<=0;
 end else begin
  done<=0;reply_valid<=0;
  case(copy_state)
   0:if(reply_complete&&qualified_reply)begin copy_index<=0;copy_state<=1;end
   1:copy_state<=2;
   2:begin
    reply_body<={reply_body[BODY_BITS-9:0],received_byte};
    if(copy_index==REPLY_BYTES-3)begin copy_state<=0;reply_valid<=1;end
    else begin copy_index<=copy_index+1'b1;copy_state<=1;end
   end
  endcase
  case(state)
   0:if(start&&!busy)begin
    held_kind<=kind;held_arg<=arg;held_count<=count;held_seq<=sequence_id;held_tag<=tag;held_value<=value;
    byte_index<=0;bit_index<=0;crc<=16'hffff;rx_crc<=16'hffff;received_header<=0;
    cs_n<=0;sclk<=0;busy<=1;read_address<=0;state<=1;
   end
   1:state<=2;
   2:begin held_word<=read_word;state<=3;end
   3:begin tx_shift<=tx_byte(byte_index);mosi<=tx_byte(byte_index)>>7;bit_index<=0;rx_shift<=0;divider<=0;state<=4;end
   4:if(divider==HALF_CYCLES-1)begin
    divider<=0;
    if(!sclk)begin
     sclk<=1;rx_shift<=received;
     if(byte_index<crc_position)crc<={crc[14:0],1'b0}^((crc[15]^mosi) ? 16'h1021 : 16'd0);
     if(byte_index<REPLY_BYTES-2)rx_crc<={rx_crc[14:0],1'b0}^((rx_crc[15]^miso) ? 16'h1021 : 16'd0);
     if(bit_index==7)begin
      if(byte_index<4)received_header<={received_header[23:0],received};
      if(byte_index==REPLY_BYTES-2)rx_crc_low<=received;
      if(reply_complete&&!qualified_reply&&bad_replies!=16'hffff)bad_replies<=bad_replies+1'b1;
     end
    end else begin
     sclk<=0;
     if(bit_index==7)begin
      if(byte_index==frame_last)begin
       cs_n<=1;mosi<=0;
       if(short_frame)state<=5;
       else begin busy<=0;done<=1;state<=0;end
      end
      else begin
       byte_index<=byte_index+1'b1;
       if(byte_index>=13&&byte_index<269)read_address<=(byte_index-9'd13)>>2;
       state<=1;
      end
     end else begin bit_index<=bit_index+1'b1;tx_shift<=tx_shift<<1;mosi<=tx_shift[6];end
    end
   end else divider<=divider+1'b1;
   // A 64-byte reply finishes on the last wire byte. Retain the physical
   // owner until its synchronous RX RAM copy and reply pulse have retired.
   5:if(copy_state==0)begin busy<=0;done<=1;state<=0;end
  endcase
 end
end
endmodule
