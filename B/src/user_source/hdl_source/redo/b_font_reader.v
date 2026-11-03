// Unicode BMP lookup in external Flash; release a whole glyph only after CRC.
// Glyph CRC binds codepoint + size + glyph ID, so a wrong directory cannot swap glyphs.
module b_font_reader(
 input clk,rst_n,request_valid,output request_ready,
 input [15:0] request_codepoint,input [1:0] request_size,input [31:0] request_token,input cancel,
 output reg initialized,output reg [7:0] boot_error,
 output glyph_valid,input glyph_ready,output [7:0] glyph_byte,output [8:0] glyph_index,
 output glyph_first,glyph_last,output reg [31:0] glyph_token,
 output reg complete,output reg [7:0] result,
 output mem_valid,input mem_ready,output reg [23:0] mem_address,output [6:0] mem_length,
 input mem_done,mem_error,input [7:0] mem_error_code,
 input mem_byte_valid,input [7:0] mem_byte,input [5:0] mem_index);
localparam HREQ=0,HWAIT=1,IDLE=2,DREQ=3,DWAIT=4,CREQ=5,CWAIT=6,
 SEED=7,FREQ=8,FWAIT=9,CHECK=10,PREFETCH=11,STREAM=12,DISABLED=13;
reg [3:0] state;
reg [15:0] character,glyph_id,font_count,header_crc,stored_crc,crc;
reg [1:0] size;
reg [2:0] seed_index;
reg [9:0] chunk_offset;
reg [6:0] burst_count;
reg bad_header,bad_burst,cancelled;
reg [7:0] id_low,crc_low;
reg [8:0] out_index;
(* force_ram=1,ram_style="bram" *) reg [7:0] cache[0:511];
reg [7:0] cache_byte;
wire [9:0] total=size==0?10'd32:size==1?10'd128:10'd512;
wire [6:0] fill_length=size==0?7'd32:7'd64;
wire [6:0] expected_length=state==HWAIT?7'd64:(state==DWAIT||state==CWAIT)?7'd2:fill_length;
wire [7:0] received={1'b0,burst_count}+(mem_byte_valid?8'd1:8'd0);
wire burst_ok=!bad_burst&&received==expected_length&&(!mem_byte_valid||mem_index==burst_count[5:0]);
wire [15:0] completed_id=mem_byte_valid&&mem_index==1?{mem_byte,id_low}:glyph_id;
wire [15:0] completed_crc=mem_byte_valid&&mem_index==1?{mem_byte,crc_low}:stored_crc;
assign request_ready=initialized&&state==IDLE&&!cancel;
assign mem_valid=(state==HREQ||state==DREQ||state==CREQ||state==FREQ)&&(!cancel||state==HREQ);
assign mem_length=state==HREQ?7'd64:(state==DREQ||state==CREQ)?7'd2:fill_length;
assign glyph_valid=state==STREAM&&!cancel&&!cancelled;
assign glyph_byte=cache_byte;assign glyph_index=out_index;
assign glyph_first=out_index==0;assign glyph_last={1'b0,out_index}+10'd1==total;
function [15:0] crc_byte;
 input [15:0] previous;input [7:0] value;reg [15:0] c;integer k;
 begin c=previous^{value,8'd0};for(k=0;k<8;k=k+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
endfunction
function [7:0] expected_header;
 input [5:0] n;
 begin case(n)
  0:expected_header=8'h46;1:expected_header=8'h4e;2:expected_header=8'h54;3:expected_header=8'h31;
  4,44:expected_header=1;5:expected_header=7;
  9,10,13:expected_header=8'h10;14,18,22:expected_header=8'h12;
  17:expected_header=8'h50;21:expected_header=8'h90;
  26:expected_header=8'h13;30:expected_header=8'h18;34:expected_header=8'h28;38:expected_header=8'h68;
  62:expected_header=8'hff;default:expected_header=0;
 endcase end
endfunction
reg [7:0] seed_byte;
always @(*)begin
 case(seed_index)
  0:seed_byte=character[7:0];1:seed_byte=character[15:8];2:seed_byte={6'd0,size};
  3:seed_byte=glyph_id[7:0];default:seed_byte=glyph_id[15:8];
 endcase
 case(state)
  HREQ:mem_address=24'h100000;
  DREQ:mem_address=24'h101000+{7'd0,character,1'b0};
  CREQ:mem_address=(size==0?24'h121000:size==1?24'h125000:24'h129000)+{7'd0,glyph_id,1'b0};
  default:mem_address=(size==0?24'h130000:size==1?24'h180000:24'h280000)+
   (size==0?{6'd0,glyph_id[12:0],5'd0}:size==1?{4'd0,glyph_id[12:0],7'd0}:{2'd0,glyph_id[12:0],9'd0})+{14'd0,chunk_offset};
 endcase
end
always @(posedge clk)begin
 cache_byte<=cache[out_index];
 if(state==FWAIT&&mem_byte_valid&&!cancel&&!cancelled)cache[chunk_offset[8:0]+mem_index]<=mem_byte;
end
task finish;
 input [7:0] code;
 begin complete<=1;result<=code;state<=IDLE;cancelled<=0;end
endtask
task header_fail;
 input [7:0] code;
 begin boot_error<=code;initialized<=0;state<=DISABLED;end
endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=HREQ;initialized<=0;boot_error<=0;complete<=0;result<=0;
  character<=0;glyph_id<=0;font_count<=0;size<=0;glyph_token<=0;header_crc<=16'hffff;stored_crc<=0;crc<=16'hffff;
  seed_index<=0;chunk_offset<=0;burst_count<=0;bad_header<=0;bad_burst<=0;cancelled<=0;
  id_low<=0;crc_low<=0;out_index<=0;
 end else begin
  complete<=0;
  if(mem_byte_valid&&(state==HWAIT||state==DWAIT||state==CWAIT||state==FWAIT))begin
   burst_count<=burst_count+1'b1;
   if(mem_index!=burst_count[5:0])bad_burst<=1;
  end
  if(cancel&&state!=IDLE&&state!=HREQ&&state!=HWAIT&&state!=DISABLED)cancelled<=1;
  case(state)
   HREQ:if(mem_ready)begin state<=HWAIT;burst_count<=0;bad_burst<=0;end
   HWAIT:begin
    if(mem_byte_valid)begin
     if(mem_index<60)header_crc<=crc_byte(header_crc,mem_byte);
     if(mem_index==6)font_count[7:0]<=mem_byte;
     else if(mem_index==7)font_count[15:8]<=mem_byte;
     else if(mem_index==60)stored_crc[7:0]<=mem_byte;
     else if(mem_index==61)stored_crc[15:8]<=mem_byte;
     else if(mem_byte!=expected_header(mem_index))bad_header<=1;
    end
    if(mem_done)begin
     if(mem_error)header_fail(mem_error_code);
     else if(!burst_ok||bad_header||mem_byte_valid&&mem_byte!=expected_header(mem_index)||
       header_crc!=stored_crc||font_count==0||font_count>8192)header_fail(8'h70);
     else begin initialized<=1;boot_error<=0;state<=IDLE;end
    end
   end
   IDLE:if(request_valid&&request_ready)begin
    character<=request_codepoint;size<=request_size;glyph_token<=request_token;result<=0;cancelled<=0;
    if(request_size==3)finish(8'h72);else state<=DREQ;
   end
   DREQ,CREQ,FREQ:begin
    if(cancel||cancelled)finish(8'h75);
    else if(mem_ready)begin
     burst_count<=0;bad_burst<=0;
     state<=state==DREQ?DWAIT:state==CREQ?CWAIT:FWAIT;
    end
   end
   DWAIT:begin
    if(mem_byte_valid)begin if(mem_index==0)id_low<=mem_byte;else glyph_id<={mem_byte,id_low};end
    if(mem_done)begin
     if(cancel||cancelled)finish(8'h75);
     else if(mem_error)finish(mem_error_code);
     else if(!burst_ok)finish(8'h74);
     else if(completed_id>=font_count)finish(8'h71);
     else begin glyph_id<=completed_id;state<=CREQ;end
    end
   end
   CWAIT:begin
    if(mem_byte_valid)begin if(mem_index==0)crc_low<=mem_byte;else stored_crc<={mem_byte,crc_low};end
    if(mem_done)begin
     if(cancel||cancelled)finish(8'h75);
     else if(mem_error)finish(mem_error_code);
     else if(!burst_ok)finish(8'h74);
     else begin stored_crc<=completed_crc;crc<=16'hffff;seed_index<=0;chunk_offset<=0;state<=SEED;end
    end
   end
   SEED:begin
    if(cancel||cancelled)finish(8'h75);
    else begin crc<=crc_byte(crc,seed_byte);if(seed_index==4)state<=FREQ;else seed_index<=seed_index+1'b1;end
   end
   FWAIT:begin
    if(mem_byte_valid&&!cancel&&!cancelled)crc<=crc_byte(crc,mem_byte);
    if(mem_done)begin
     if(cancel||cancelled)finish(8'h75);
     else if(mem_error)finish(mem_error_code);
     else if(!burst_ok)finish(8'h74);
     else if(chunk_offset+fill_length==total)state<=CHECK;
     else begin chunk_offset<=chunk_offset+fill_length;state<=FREQ;end
    end
   end
   CHECK:begin
    if(cancel||cancelled)finish(8'h75);
    else if(crc!=stored_crc)finish(8'h73);
    else begin out_index<=0;state<=PREFETCH;end
   end
   PREFETCH:if(cancel||cancelled)finish(8'h75);else state<=STREAM;
   STREAM:begin
    if(cancel||cancelled)finish(8'h75);
    else if(glyph_ready)begin if(glyph_last)finish(0);else begin out_index<=out_index+1'b1;state<=PREFETCH;end end
   end
   default:begin end
  endcase
 end
end
endmodule
