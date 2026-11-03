module subtitle_decoder #(parameter ROM_FILE="unicode.mem")(
 input clk,rst_n,start,input [15:0] byte_length,
 output reg [7:0] payload_address,input [7:0] payload_byte,
 output reg glyph_we,output reg [5:0] glyph_address,output reg [7:0] glyph_data,
 output reg busy,done,output reg [7:0] error_code,error_position,
 output reg [6:0] glyph_count
);
localparam FETCH=0,WAIT_BYTE=1,DECODE=2,SEARCH=3,COMPARE=4,EMIT=5;
reg [2:0] state;reg [7:0] cursor,character_start,search_index;
reg [1:0] continuation;reg [15:0] unicode_value,minimum_value;
reg [7:0] next_glyph;reg [15:0] codes[0:255];reg [15:0] lookup_code;
initial $readmemh(ROM_FILE,codes);
always @(posedge clk)lookup_code<=codes[search_index];
// 正文最多64字、192编码字节；只允许可显示字符，不接收控制字符。
task fail;input [7:0] code,position;begin
 error_code<=code;error_position<=position;busy<=0;done<=1;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=FETCH;payload_address<=0;glyph_we<=0;glyph_address<=0;glyph_data<=0;
 busy<=0;done<=0;error_code<=0;error_position<=0;glyph_count<=0;
 cursor<=0;character_start<=0;search_index<=0;continuation<=0;unicode_value<=0;minimum_value<=0;next_glyph<=0;end
 else begin
  done<=0;glyph_we<=0;
  if(start&&!busy)begin
   glyph_count<=0;cursor<=0;payload_address<=0;continuation<=0;error_code<=0;error_position<=0;
   if(byte_length>192)begin done<=1;error_code<=8'h52;end
   else begin busy<=1;state<=FETCH;end
  end else if(busy)case(state)
   FETCH:begin
    if(cursor>=byte_length)begin
     if(continuation!=0)fail(8'h53,character_start);
     else begin busy<=0;done<=1;end
    end else begin payload_address<=cursor;state<=WAIT_BYTE;end
   end
   WAIT_BYTE:state<=DECODE;
   DECODE:begin
    cursor<=cursor+1'b1;
    if(continuation!=0)begin
     if(payload_byte[7:6]!=2'b10)fail(8'h53,cursor);
     else begin
      unicode_value<=(unicode_value<<6)|{10'd0,payload_byte[5:0]};
      continuation<=continuation-1'b1;
      if(continuation==1)begin
       if(((unicode_value<<6)|{10'd0,payload_byte[5:0]})<minimum_value ||
          (((unicode_value<<6)|{10'd0,payload_byte[5:0]})>=16'hd800 &&
           ((unicode_value<<6)|{10'd0,payload_byte[5:0]})<=16'hdfff))fail(8'h53,character_start);
       else begin search_index<=96;state<=SEARCH;end
      end else state<=FETCH;
     end
    end else begin
     character_start<=cursor;
     if(payload_byte>=32 && payload_byte<=126)begin next_glyph<=payload_byte-32;state<=EMIT;end
     else if(payload_byte>=8'hc2 && payload_byte<=8'hdf)begin
      unicode_value<={11'd0,payload_byte[4:0]};minimum_value<=16'h80;continuation<=1;state<=FETCH;
     end else if(payload_byte>=8'he0 && payload_byte<=8'hef)begin
      unicode_value<={12'd0,payload_byte[3:0]};minimum_value<=16'h800;continuation<=2;state<=FETCH;
     end else fail(8'h53,cursor);
    end
   end
   SEARCH:state<=COMPARE;
   COMPARE:begin
    if(lookup_code==unicode_value)begin next_glyph<=search_index;state<=EMIT;end
    else if(search_index==251)fail(8'h51,character_start);
    else begin search_index<=search_index+1'b1;state<=SEARCH;end
   end
   EMIT:begin
    if(glyph_count==64)fail(8'h52,character_start);
    else begin glyph_we<=1;glyph_address<=glyph_count[5:0];glyph_data<=next_glyph;
     glyph_count<=glyph_count+1'b1;state<=FETCH;end
   end
   default:fail(8'h53,cursor);
  endcase
 end
end
endmodule
