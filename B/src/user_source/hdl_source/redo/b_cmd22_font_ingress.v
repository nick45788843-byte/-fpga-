module b_cmd22_font_ingress #(parameter MAX_UTF8_BYTES=192,DEGRADED_FONT_REJECT=0)(
 input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_token,input [7:0] request_command,request_length,input [47:0] request_arguments,
 input [7:0] body_byte,output [7:0] body_address,
 output start_valid,input start_ready,output [31:0] start_uid,output [6:0] start_glyph_count,
 output [7:0] start_utf8_bytes,output [1:0] start_size,start_target,
 output raw_valid,input raw_ready,output [7:0] raw_byte,output raw_last,input cancel_valid,
 input stream_complete,input [7:0] stream_error,input stream_blocked,
 input notice_valid,input [31:0] notice_token,input notice_session,input transport_idle,
 output control_done,output [31:0] control_done_token,
 output reg result_valid,output reg [31:0] result_token,output reg [7:0] result_error,
 output reg body_release_valid,output reg [31:0] body_release_token,
 output busy,output [31:0] owner_uid,
 input font_unavailable,input [7:0] font_unavailable_error);
localparam IDLE=0,READ_BODY=1,SEND_BODY=2,WAIT_STREAM=3,BLOCKED=4;
reg [2:0] state;
reg [31:0] active_uid;
reg [7:0] utf8_bytes,raw_index;
reg [6:0] glyph_count;
reg [1:0] size_code,target_code;
wire [15:0] declared_utf8_bytes=request_arguments[47:32];
wire [7:0] declared_version=request_arguments[7:0];
wire [7:0] declared_size=request_arguments[15:8];
wire [7:0] declared_target=request_arguments[23:16];
wire [7:0] declared_glyphs=request_arguments[31:24];
wire empty_request=declared_glyphs==0&&declared_utf8_bytes==0;
wire fields_valid=declared_version==8'd1&&declared_size<=8'd2&&declared_target<=8'd3&&
 (empty_request||(declared_glyphs>=8'd1&&declared_glyphs<=8'd64&&declared_utf8_bytes>=16'd1&&
 declared_utf8_bytes<=MAX_UTF8_BYTES))&&request_length==declared_utf8_bytes+16'd6;
wire request_is_font=request_command==8'd22;
wire active_font=state!=IDLE&&state!=BLOCKED;
wire cancel_match=notice_valid&&(notice_session||notice_token==active_uid);
wire unavailable=DEGRADED_FONT_REJECT&&font_unavailable&&!empty_request;
assign request_ready=request_is_font&&state==IDLE&&(!fields_valid||unavailable||start_ready);
assign start_valid=request_valid&&request_ready&&request_is_font&&fields_valid&&!unavailable;
assign start_uid=request_token;
assign start_glyph_count=declared_glyphs[6:0];
assign start_utf8_bytes=declared_utf8_bytes[7:0];
assign start_size=declared_size[1:0];
assign start_target=declared_target[1:0];
assign body_address=(state==READ_BODY||state==SEND_BODY)?8'd6+raw_index:8'd0;
assign raw_valid=state==SEND_BODY&&!cancel_valid;
assign raw_byte=body_byte;
assign raw_last=raw_index+8'd1==utf8_bytes;
assign busy=state!=IDLE;
assign owner_uid=active_uid;
assign control_done=notice_valid&&transport_idle&&(!cancel_match||(state==IDLE));
assign control_done_token=notice_token;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;active_uid<=0;utf8_bytes<=0;raw_index<=0;glyph_count<=0;size_code<=0;target_code<=0;
  result_valid<=0;result_token<=0;result_error<=0;body_release_valid<=0;body_release_token<=0;
 end else begin
  result_valid<=0;body_release_valid<=0;
  if(request_valid&&request_ready&&request_is_font)begin
   if(!fields_valid)begin
    result_valid<=1;result_token<=request_token;
    result_error<=declared_version!=8'd1||declared_size>8'd2||declared_target>8'd3||(declared_glyphs==0)!=(declared_utf8_bytes==0)||declared_glyphs>8'd64||declared_utf8_bytes>MAX_UTF8_BYTES?8'ha0:8'ha2;
    body_release_valid<=1;body_release_token<=request_token;
   end else if(unavailable)begin
    result_valid<=1;result_token<=request_token;result_error<=font_unavailable_error;
    body_release_valid<=1;body_release_token<=request_token;
   end else begin
    active_uid<=request_token;utf8_bytes<=declared_utf8_bytes[7:0];glyph_count<=declared_glyphs[6:0];
    size_code<=declared_size[1:0];target_code<=declared_target[1:0];raw_index<=0;state<=empty_request?WAIT_STREAM:READ_BODY;
   end
  end else if(active_font)begin
   if(stream_complete)begin
    result_valid<=1;result_token<=active_uid;result_error<=stream_error;
    if(stream_blocked)state<=BLOCKED;
    else begin
     body_release_valid<=1;body_release_token<=active_uid;state<=IDLE;
    end
   end else if(cancel_valid)state<=WAIT_STREAM;
   else case(state)
    READ_BODY:state<=SEND_BODY;
    SEND_BODY:if(raw_valid&&raw_ready)begin
     if(raw_last)state<=WAIT_STREAM;
     else begin raw_index<=raw_index+1'b1;state<=READ_BODY;end
    end
    default:;
   endcase
  end
 end
end
endmodule
