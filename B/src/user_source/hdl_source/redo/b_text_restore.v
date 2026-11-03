// Rebuild only the canonical UTF8 accepted by subtitle_decoder. The real text
// transaction validates it again and commits only after A's frame receipt.
module b_text_restore #(parameter ROM_FILE="unicode.mem")(
 input clk,rst_n,storage_ready,storage_busy,input [15:0] descriptor,
 output storage_lock,output reg [5:0] glyph_address,input [7:0] glyph_byte,
 output grant_needed,input grant_valid,input [31:0] granted_uid,
 output request_valid,input request_ready,output [31:0] request_token,
 output [7:0] request_length,input [7:0] source_address,output reg [7:0] source_byte,
 input response_valid,input [31:0] response_token,input [7:0] response_error,
 output response_ready,output reg restore_ack,output reg [15:0] restored_descriptor,
 output restored,output control_done,input notice_valid,notice_session,input [31:0] notice_token,input text_drained);
localparam PENDING=0,ADDR=1,WAIT_GLYPH=2,LOOKUP=3,ENCODE=4,EMIT=5,GRANT=6,REQUEST=7,OWNED=8,DONE=9,CODE_WAIT=10;
reg [3:0] state;reg [15:0] held_descriptor;reg [6:0] count,cursor;
reg [7:0] length,write_cursor;reg [31:0] uid;
reg [15:0] codes[0:255];reg [15:0] code;reg [7:0] glyph;
reg [23:0] encoded;reg [1:0] remaining;
reg [7:0] raw[0:255];
initial $readmemh(ROM_FILE,codes);
always @(posedge clk)begin code<=codes[glyph];source_byte<=raw[source_address];end
assign storage_lock=(state>=ADDR&&state<=EMIT)||state==CODE_WAIT;
assign grant_needed=state==GRANT||state==REQUEST;
assign request_valid=state==REQUEST&&!notice_valid;
assign request_token=uid;assign request_length=length;
assign response_ready=state==OWNED;
assign restored=state==DONE;
wire affected=notice_valid&&(notice_session||notice_token==uid&&uid!=0);
assign control_done=notice_valid&&(!affected||state!=OWNED||text_drained);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=PENDING;held_descriptor<=0;count<=0;cursor<=0;length<=0;write_cursor<=0;uid<=0;
  glyph_address<=0;glyph<=0;encoded<=0;remaining<=0;restore_ack<=0;restored_descriptor<=0;
 end else begin
  restore_ack<=0;
  if(affected)begin
   if(state!=OWNED||text_drained)begin
    if(notice_session||state!=DONE)state<=PENDING;
    uid<=0;
   end
  end else case(state)
   PENDING:if(storage_ready&&!storage_busy)begin
    held_descriptor<=descriptor;count<=descriptor[6:0];cursor<=0;length<=0;write_cursor<=0;
    if(descriptor[15:8]==0)begin restored_descriptor<=descriptor;restore_ack<=1;state<=DONE;end
    else state<=descriptor[6:0]==0?GRANT:ADDR;
   end
   ADDR:begin glyph_address<=cursor[5:0];state<=WAIT_GLYPH;end
   WAIT_GLYPH:state<=LOOKUP;
   LOOKUP:begin glyph<=glyph_byte;state<=ENCODE;end
   ENCODE:begin
    // The ROM read uses the previous cycle's glyph index.
    if(glyph<95)begin encoded<={glyph+8'd32,16'd0};remaining<=1;state<=EMIT;end
    else state<=CODE_WAIT;
   end
   CODE_WAIT:begin
    if(code<16'h800)begin encoded<={(8'hc0|{3'd0,code[10:6]}),(8'h80|{2'd0,code[5:0]}),8'd0};remaining<=2;end
    else begin encoded<={(8'he0|{4'd0,code[15:12]}),(8'h80|{2'd0,code[11:6]}),(8'h80|{2'd0,code[5:0]})};remaining<=3;end
    state<=EMIT;
   end
   EMIT:begin
    raw[write_cursor]<=encoded[23:16];encoded<=encoded<<8;write_cursor<=write_cursor+1'b1;length<=length+1'b1;
    if(remaining==1)begin
     if(cursor+1==count)state<=GRANT;else begin cursor<=cursor+1'b1;state<=ADDR;end
    end else remaining<=remaining-1'b1;
   end
   GRANT:if(grant_valid&&granted_uid!=0)begin uid<=granted_uid;state<=REQUEST;end
   REQUEST:if(request_valid&&request_ready)state<=OWNED;
   OWNED:if(response_valid&&response_token==uid)begin
    if(response_error==0)begin restored_descriptor<=held_descriptor;restore_ack<=1;state<=DONE;end
    else state<=PENDING;
   end
   DONE:state<=DONE;
   default:state<=PENDING;
  endcase
 end
end
endmodule
