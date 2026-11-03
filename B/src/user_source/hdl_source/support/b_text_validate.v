// Complete validated cache only. Display and persistence acknowledgements are separate.
module b_text_validate #(parameter ROM_FILE="unicode.mem")(
 input clk,rst_n,request_valid,output request_ready,
 input [31:0] request_token,input [15:0] request_length,
 output reg [7:0] source_address,input [7:0] source_byte,
 input cancel_valid,input [31:0] cancel_token,
 output reg response_valid,input response_ready,
 output reg [31:0] response_token,output reg [7:0] response_error,response_position,
 output reg cache_valid,output reg [7:0] cache_length,output reg [6:0] cache_glyph_count,
 input [7:0] raw_address,output reg [7:0] raw_byte,
 input [5:0] glyph_address,output reg [7:0] glyph_byte
);
 localparam IDLE=0,ADDR=1,WAIT_DATA=2,COPY=3,START=4,DECODE=5;
 reg [2:0] state;reg bank;reg [7:0] cursor,length;
 reg [31:0] owner;reg decoder_start;
 reg [7:0] raw[0:511];reg [7:0] glyph[0:127];
 wire decoder_busy,decoder_done,glyph_we;wire [7:0] dec_addr,dec_glyph,error_code,error_position;
 wire [5:0] dec_glyph_addr;wire [6:0] dec_count;reg [7:0] dec_byte;
 wire cancel_match=cancel_valid && cancel_token==owner && state!=IDLE;
 wire decoder_reset=rst_n && !cancel_match;
 assign request_ready=state==IDLE && !response_valid;
 subtitle_decoder #(.ROM_FILE(ROM_FILE)) decoder(clk,decoder_reset,decoder_start,{8'd0,length},
  dec_addr,dec_byte,glyph_we,dec_glyph_addr,dec_glyph,decoder_busy,decoder_done,error_code,error_position,dec_count);
 always @(posedge clk)begin
  raw_byte<=raw[{bank,raw_address}];glyph_byte<=glyph[{bank,glyph_address}];
  dec_byte<=raw[{!bank,dec_addr}];
  if(glyph_we && !cancel_match)glyph[{!bank,dec_glyph_addr}]<=dec_glyph;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;bank<=0;cursor<=0;length<=0;owner<=0;source_address<=0;decoder_start<=0;
   response_valid<=0;response_token<=0;response_error<=0;response_position<=0;
   cache_valid<=0;cache_length<=0;cache_glyph_count<=0;end
  else begin
   decoder_start<=0;
   if(response_valid && response_ready)response_valid<=0;
   if(cancel_match)begin state<=IDLE;response_valid<=1;response_token<=owner;response_error<=8'h43;response_position<=0;end
   else case(state)
    IDLE:if(request_valid && request_ready)begin
     owner<=request_token;length<=request_length[7:0];cursor<=0;
     if(request_length>192)begin response_valid<=1;response_token<=request_token;response_error<=8'h52;response_position<=0;end
     else if(request_length==0)state<=START;else state<=ADDR;
    end
    ADDR:begin source_address<=cursor;state<=WAIT_DATA;end
    WAIT_DATA:state<=COPY;
    COPY:begin raw[{!bank,cursor}]<=source_byte;
     if(cursor+1==length)state<=START;else begin cursor<=cursor+1'b1;state<=ADDR;end
    end
    START:begin decoder_start<=1;state<=DECODE;end
    DECODE:if(decoder_done)begin
     response_valid<=1;response_token<=owner;response_error<=error_code;response_position<=error_position;state<=IDLE;
     if(error_code==0)begin bank<=!bank;cache_valid<=1;cache_length<=length;cache_glyph_count<=dec_count;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
