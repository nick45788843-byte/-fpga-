// Fixed text flow: one working bank and one committed bank, without full-bank
// copies between validation, glyph delivery, persistence and original queries.
// Physical F2/F3 delivery remains a separate real owner; F2 never commits text.
module b_text_service #(parameter ROM_FILE="unicode.mem",parameter RETRY_LIMIT=1000,PERSISTENCE_ENABLED=0)(
 input clk,rst_n,input request_valid,output request_ready,
 input [31:0] request_token,input [7:0] request_command,request_length,
 output reg [7:0] source_address,input [7:0] source_byte,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 input [5:0] tx_read_address,output [31:0] tx_read_word,
 input reply_valid,input [255:0] reply_fragment,
 output reg response_valid,input response_ready,output [31:0] response_token,
 output reg [7:0] response_error,response_position,output timed_out,output display_inflight,
 input [7:0] raw_address,output [7:0] raw_byte,
 input query_begin,output query_ready,input [31:0] query_token,input query_end,input [31:0] query_end_token,
 output reg query_active,output reg [7:0] query_length,output reg [31:0] query_generation,
 output reg committed_valid,output reg [7:0] committed_length,
 input [5:0] query_glyph_address,output [7:0] query_glyph_byte,output reg [6:0] committed_glyph_count,
 input notice_valid,input [31:0] notice_token,input notice_session,input transport_idle,
 output control_done,output [31:0] control_done_token,
 output persist_valid,output [31:0] persist_token,output [6:0] persist_count,
 input [5:0] persist_address,output [7:0] persist_byte,input persist_done,input [7:0] persist_error,input persistence_bypass);

localparam IDLE=0,BODY_ADDR=1,BODY_WAIT=2,BODY_COPY=3,START=4,DECODE=5,
 VALIDATED=6,DELIVERY=7,COMMIT=8,PERSIST=9,RESULT=10,FLUSH=11;
reg [3:0] state;
reg [31:0] active_owner,query_owner,committed_generation;
reg committed_bank,work_bank;
reg [7:0] cursor,work_length;
reg [6:0] work_glyph_count;
reg decoder_start,frame_valid;
wire affected=notice_valid&&(notice_session||notice_token==active_owner);
wire cancel_query=notice_valid&&query_active&&(notice_session||notice_token==query_owner);
wire cancel_validation=affected&&state>=BODY_ADDR&&state<=VALIDATED;
wire decoder_busy,decoder_done,glyph_we;
wire [7:0] decoder_address,decoder_glyph,decoder_error,decoder_position;
wire [5:0] decoder_glyph_address;
wire [6:0] decoder_count;
reg [7:0] decoder_byte;
reg [31:0] glyph_pack;
reg [31:0] assembled_word;

assign request_ready=state==VALIDATED&&!notice_valid;
assign response_token=active_owner;
assign display_inflight=state!=IDLE;
assign query_ready=!query_active&&query_token!=0&&!notice_valid;
assign persist_valid=PERSISTENCE_ENABLED&&state==PERSIST;
assign persist_token=active_owner;
assign persist_count=work_glyph_count;
assign control_done_token=notice_token;

// Each array has two physical ports. Decoder/body capture shares the raw work
// port. Delivery and persistence share the glyph work port in disjoint phases.
(* force_ram=1,ram_style="bram" *) reg [7:0] raw[0:511];
(* force_ram=1,ram_style="bram" *) reg [31:0] glyph[0:31];
wire [8:0] raw_work_address={work_bank,state==BODY_COPY?cursor:decoder_address};
wire [4:0] glyph_work_address=glyph_we?{work_bank,decoder_glyph_address[5:2]}:
 state==PERSIST?{committed_bank,persist_address[5:2]}:{work_bank,tx_read_address[3:0]};
reg [7:0] raw_read;
reg [31:0] glyph_work_read,glyph_query_read;
reg raw_read_valid,glyph_query_valid,tx_read_valid;
reg [1:0] persist_lane,query_lane;
assign raw_byte=raw_read_valid?raw_read:8'd0;
assign query_glyph_byte=glyph_query_valid?(glyph_query_read>>(query_lane*8)):8'd0;
assign persist_byte=glyph_work_read>>(persist_lane*8);
assign tx_read_word=tx_read_valid?glyph_work_read:32'd0;
always @(*)begin
 case(decoder_glyph_address[1:0])
  0:assembled_word={24'd0,decoder_glyph};
  1:assembled_word={16'd0,decoder_glyph,glyph_pack[7:0]};
  2:assembled_word={8'd0,decoder_glyph,glyph_pack[15:0]};
  default:assembled_word={decoder_glyph,glyph_pack[23:0]};
 endcase
end
always @(posedge clk)begin
 decoder_byte<=raw[raw_work_address];
 raw_read<=raw[{committed_bank,raw_address}];
 raw_read_valid<=query_active&&raw_address<query_length;
 if(rst_n&&state==BODY_COPY&&!cancel_validation)raw[raw_work_address]<=source_byte;
 glyph_work_read<=glyph[glyph_work_address];
 glyph_query_read<=glyph[{committed_bank,query_glyph_address[5:2]}];
 query_lane<=query_glyph_address[1:0];
 persist_lane<=persist_address[1:0];
 tx_read_valid<=tx_read_address<16;
 glyph_query_valid<=query_active&&query_glyph_address<committed_glyph_count;
 if(rst_n&&state==DECODE&&glyph_we&&!cancel_validation)glyph[glyph_work_address]<=assembled_word;
end

subtitle_decoder #(.ROM_FILE(ROM_FILE)) decoder(clk,rst_n&&!cancel_validation,decoder_start,{8'd0,work_length},
 decoder_address,decoder_byte,glyph_we,decoder_glyph_address,decoder_glyph,
 decoder_busy,decoder_done,decoder_error,decoder_position,decoder_count);

wire frame_release,delivered,delivery_cancel_done;
wire [31:0] delivered_token,delivery_cancel_token;
wire [7:0] delivered_error;
b_glyph_delivery_control #(.RETRY_LIMIT(RETRY_LIMIT)) delivery(clk,rst_n,frame_valid,active_owner,work_glyph_count,frame_release,
 tx_valid,tx_ready,tx_kind,tx_count,tx_sequence,tx_tag,tx_value,tx_done,reply_valid,reply_fragment,
 delivered,state==DELIVERY,delivered_token,delivered_error,timed_out,
 notice_valid,notice_token,notice_session,transport_idle,delivery_cancel_done,delivery_cancel_token);
assign control_done=notice_valid&&transport_idle&&!cancel_query&&
 (!affected||state==IDLE||(state==FLUSH&&!frame_valid&&!delivered&&delivery_cancel_done));

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;active_owner<=0;query_owner<=0;committed_generation<=0;
  committed_bank<=0;work_bank<=1;cursor<=0;work_length<=0;work_glyph_count<=0;
  source_address<=0;decoder_start<=0;glyph_pack<=0;frame_valid<=0;
  response_valid<=0;response_error<=0;response_position<=0;
  query_active<=0;query_length<=0;query_generation<=0;
  committed_valid<=0;committed_length<=0;committed_glyph_count<=0;
 end else begin
  decoder_start<=0;
  if(frame_release)frame_valid<=0;
  if(state==DECODE&&glyph_we&&!cancel_validation)glyph_pack<=assembled_word;
  if(query_begin&&query_ready)begin
   query_active<=1;query_owner<=query_token;query_length<=committed_length;query_generation<=committed_generation;
  end
  if(query_active&&((query_end&&query_end_token==query_owner)||cancel_query))query_active<=0;
  // Before publishing a frame there is no physical transaction to drain. Once
  // started, the unchanged delivery controller must obtain actual F3 and idle.
  if(cancel_validation)begin state<=FLUSH;response_valid<=0;end
  else case(state)
   IDLE:if(request_valid&&request_command==11&&!response_valid&&!notice_valid)begin
    active_owner<=request_token;work_bank<=!committed_bank;work_length<=request_length;
    cursor<=0;work_glyph_count<=0;glyph_pack<=0;response_error<=0;response_position<=0;
    if(request_length>192)begin response_error<=8'h52;state<=VALIDATED;end
    else state<=request_length==0?START:BODY_ADDR;
   end
   BODY_ADDR:begin source_address<=cursor;state<=BODY_WAIT;end
   BODY_WAIT:state<=BODY_COPY;
   BODY_COPY:if(cursor+1==work_length)state<=START;else begin cursor<=cursor+1'b1;state<=BODY_ADDR;end
   START:begin decoder_start<=1;state<=DECODE;end
   DECODE:if(decoder_done)begin
    response_error<=decoder_error;response_position<=decoder_position;work_glyph_count<=decoder_count;state<=VALIDATED;
   end
   VALIDATED:if(response_error!=0)begin response_valid<=1;state<=RESULT;end
    else begin frame_valid<=1;state<=DELIVERY;end
   DELIVERY:if(delivered&&delivered_token==active_owner)begin
    response_error<=delivered_error;response_position<=0;
    if(delivered_error==0)state<=COMMIT;else begin response_valid<=1;state<=RESULT;end
   end else if(affected&&delivery_cancel_done&&!frame_valid&&!delivered)state<=FLUSH;
   // An old paged query pins the old generation. Validation and physical
   // delivery may run beside it, but the committed bank cannot flip past it.
   COMMIT:if(!query_active&&!query_begin&&committed_generation!=32'hffffffff)begin
    committed_bank<=work_bank;committed_generation<=committed_generation+1'b1;
    committed_valid<=1;committed_length<=work_length;committed_glyph_count<=work_glyph_count;
    if(PERSISTENCE_ENABLED&&!persistence_bypass)state<=PERSIST;
    else begin response_valid<=1;state<=RESULT;end
   end
   PERSIST:if(persist_done)begin response_error<=persist_error;response_valid<=1;state<=RESULT;end
   RESULT:if(response_valid&&(response_ready||affected))begin response_valid<=0;state<=affected?FLUSH:IDLE;end
   FLUSH:if(!notice_valid&&!frame_valid&&!delivered&&transport_idle)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
end
endmodule
