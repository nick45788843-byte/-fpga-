// Thin A execution endpoint only: 96-bit setting body + one colour word.
// RPC is owned by the separate direct byte port. Legacy kind42 discovery is
// CRC/shape-qualified and acknowledged without a 192-bit status/RPC copy.
module a_settings_colour_port #(parameter CLOCK_HZ=50000000,GAMMA_ENABLED=0,SCALE_ENABLED=0)(
 input clk,rst_n,clear,valid,output reg consume,input [7:0] kind,arg,input [6:0] count,
 input [15:0] tag,packet_crc,input [31:0] token,output reg [5:0] read_address,input [31:0] read_word,
 output reg acknowledged_valid,output reg [15:0] acknowledged_tag,output reg [7:0] result,
 output apply_valid,input apply_ready,output [31:0] apply_token,output [71:0] apply_values,
 output reg [23:0] remote_jedec,
 output reg table_start,output table_cancel,output [31:0] table_token,
 output [7:0] brightness,contrast,output [15:0] expected_crc,
 output byte_valid,output [7:0] byte_index,byte_data,
 input table_ready,table_byte_ready,table_done,table_error,input [7:0] table_error_code,
 output reg [7:0] gamma,output [2:0] apply_scale,apply_previous_scale,input geometry_normal);
localparam IDLE=0,ADDR=1,WAIT_WORD=2,COPY=3,CHECK=4,APPLY=5,META=6,EMIT=7,COMMIT=8,ACK=9;
localparam TW=$clog2(CLOCK_HZ+1);
reg [3:0] state;reg [TW-1:0] timer;
reg [31:0] owner,curve_word,meta_word,meta_owner;reg [95:0] settings;
reg [15:0] active_tag,active_crc;reg [7:0] active_kind,active_arg;reg [1:0] byte_part;
reg seen_settings,seen_colour;reg [31:0] last_settings_uid,last_colour_uid;
reg [15:0] last_settings_crc,last_colour_crc;reg [7:0] last_colour_kind,last_settings_error,last_colour_error;
wire is_colour=kind==8'h43||kind==8'h44;
wire active_colour=active_kind==8'h43||active_kind==8'h44;
assign apply_scale=SCALE_ENABLED?settings[74:72]:3'd0;
assign apply_previous_scale=SCALE_ENABLED?settings[77:75]:3'd0;
assign apply_valid=state==APPLY&&!clear;assign apply_token=owner;assign apply_values=settings[71:0];
assign table_cancel=clear;assign table_token=meta_owner;
assign brightness=meta_word[15:8];assign contrast=meta_word[7:0];assign expected_crc=meta_word[31:16];
assign byte_valid=state==EMIT&&table_byte_ready&&!clear;
assign byte_index={read_address,byte_part};
assign byte_data=byte_part==0?curve_word[7:0]:byte_part==1?curve_word[15:8]:byte_part==2?curve_word[23:16]:curve_word[31:24];
function good;input [71:0] v;begin
 good=v[71:64]<=100&&v[63:56]>=20&&v[63:56]<=100&&v[55:48]<=200&&v[47:40]<=200&&
 v[39:24]==0&&v[23:8]>=1000&&v[23:8]<=60000&&v[7:0]<=1;
end endfunction
task finish;input [7:0] error;begin result<=error;state<=ACK;end endtask
// Values are overwritten by three complete CRC-qualified words before APPLY.
always @(posedge clk)if(rst_n&&!clear&&state==COPY&&active_kind==8'h41)settings<={read_word,settings[95:32]};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;timer<=0;owner<=0;active_tag<=0;active_crc<=0;active_kind<=0;active_arg<=0;gamma<=2;byte_part<=0;read_address<=0;
  consume<=0;acknowledged_valid<=0;acknowledged_tag<=0;result<=0;remote_jedec<=0;
  meta_word<=0;meta_owner<=0;curve_word<=0;table_start<=0;
  seen_settings<=0;seen_colour<=0;last_settings_uid<=0;last_colour_uid<=0;
  last_settings_crc<=0;last_colour_crc<=0;last_colour_kind<=0;last_settings_error<=0;last_colour_error<=0;
 end else begin
  consume<=0;table_start<=0;
  if(state!=IDLE&&timer<CLOCK_HZ)timer<=timer+1'b1;
  case(state)
   IDLE:if(valid&&!consume&&!clear)begin
    owner<=token;active_tag<=tag;active_crc<=packet_crc;active_kind<=kind;active_arg<=arg;read_address<=0;byte_part<=0;timer<=0;
    if((GAMMA_ENABLED&&kind==8'h43 ? arg>=8:arg!=0)||!((kind==8'h41&&count==3)||(kind==8'h42&&count==6)||(kind==8'h43&&count==1)||(kind==8'h44&&count==64)))finish(8'h47);
    else if(kind==8'h41&&seen_settings&&token==last_settings_uid)finish(packet_crc==last_settings_crc?last_settings_error:8'hd4);
    else if(is_colour&&seen_colour&&kind==last_colour_kind&&token==last_colour_uid)finish(packet_crc==last_colour_crc?last_colour_error:8'hd4);
    else if(kind==8'h42)begin remote_jedec<=token[23:0];finish(0);end
    else if(kind==8'h43&&!table_ready)finish(8'hd9);
    else if(kind==8'h44&&(!table_byte_ready||token!=meta_owner))finish(8'hd9);
    else state<=ADDR;
   end
   ADDR:state<=WAIT_WORD;
   WAIT_WORD:state<=COPY;
   COPY:case(active_kind)
    8'h41:if(read_address==2)state<=CHECK;else begin read_address<=read_address+1'b1;state<=ADDR;end
    8'h43:begin meta_word<=read_word;state<=META;end
    8'h44:begin curve_word<=read_word;byte_part<=0;state<=EMIT;end
    default:finish(8'h40);
   endcase
   CHECK:if((SCALE_ENABLED?(settings[95:78]!=0||settings[74:72]>4||settings[77:75]>4):settings[95:72]!=0)||!good(settings[71:0]))finish(8'h47);
    else if(SCALE_ENABLED&&settings[74:72]!=settings[77:75]&&!geometry_normal)finish(8'h4b);else state<=APPLY;
   APPLY:if(apply_ready)finish(0); // actual private capture, frame ACK remains separate
   META:if(meta_word[15:8]>200||meta_word[7:0]>200)finish(8'h47);
    else if(table_ready)begin meta_owner<=owner;gamma<=GAMMA_ENABLED?active_arg:8'd2;table_start<=1;finish(0);end else finish(8'hd9);
   EMIT:if(table_byte_ready)begin
    if(byte_part==3)begin
     if(read_address==63)state<=COMMIT;else begin read_address<=read_address+1'b1;state<=ADDR;end
    end else byte_part<=byte_part+1'b1;
   end
   COMMIT:if(table_done)finish(!table_error?8'd0:table_error_code==8'he3 ?8'hd8:table_error_code==8'he4 ?8'h48:8'h47);
   ACK:begin
    acknowledged_valid<=1;acknowledged_tag<=active_tag;consume<=1;state<=IDLE;
    if(active_kind==8'h41)begin seen_settings<=1;last_settings_uid<=owner;last_settings_crc<=active_crc;last_settings_error<=result;end
    if(active_colour)begin seen_colour<=1;last_colour_uid<=owner;last_colour_crc<=active_crc;last_colour_kind<=active_kind;last_colour_error<=result;end
   end
  endcase
  if(state!=IDLE&&state!=ACK&&timer>=CLOCK_HZ-1)finish(8'h48);
  if(clear)begin
   state<=IDLE;seen_settings<=0;seen_colour<=0;timer<=0;acknowledged_valid<=0;
   // A retained CRC-qualified input cannot block every future heartbeat/flush.
   if(valid)begin consume<=1;acknowledged_valid<=1;acknowledged_tag<=tag;result<=8'h43;end
  end
 end
end
endmodule
