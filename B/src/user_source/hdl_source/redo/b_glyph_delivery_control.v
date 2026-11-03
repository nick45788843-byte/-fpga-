// Drives an existing SPI master through arbitration. Exact kind49 retries keep sequence.
// Does not free a frame on timeout: pending apply must be resolved or explicitly drained.
module b_glyph_delivery_control #(parameter RETRY_LIMIT=1000)(input clk,rst_n,
 input frame_valid,input [31:0] frame_token,input [6:0] frame_count,output reg frame_release,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 input reply_valid,input [255:0] reply_fragment,
 output reg response_valid,input response_ready,output reg [31:0] response_token,output reg [7:0] response_error,
 output reg timed_out,
 input notice_valid,input [31:0] notice_token,input notice_session,input transport_idle,
 output cancel_done,output [31:0] cancel_done_token);
 localparam IDLE=0,SEND=1,WAIT=2,HOLD=3,FLUSH=4;
 reg [2:0] state;reg receipt,started,cancelled;reg [31:0] owner;reg [6:0] count;
 reg [15:0] sequence_id;reg [31:0] attempts;
 wire [31:0] reply_token={reply_fragment[199:192],reply_fragment[207:200],reply_fragment[215:208],reply_fragment[223:216]};
 wire qualified=reply_valid&&reply_fragment[247:240]==0&&reply_fragment[231:224]==8'h49&&reply_token==owner;
 wire affected=notice_valid&&(notice_session||notice_token==owner||(state==IDLE&&frame_valid&&notice_token==frame_token));
assign tx_valid=state==SEND&&!(affected&&!started);
assign cancel_done=notice_valid&&transport_idle&&
 ((!affected)||(state==IDLE&&!frame_valid)||(state==FLUSH&&!frame_valid&&!response_valid));
assign cancel_done_token=notice_token;
 assign tx_kind=receipt?8'h4a:8'h49;assign tx_count=receipt?7'd0:(count+7'd3)>>2;
 assign tx_sequence=sequence_id;assign tx_tag=receipt?16'd0:{9'd0,count};assign tx_value=owner;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;receipt<=0;started<=0;cancelled<=0;owner<=0;count<=0;sequence_id<=0;attempts<=0;
   frame_release<=0;response_valid<=0;response_token<=0;response_error<=0;timed_out<=0;end
  else begin
   frame_release<=0;
   if(response_valid&&response_ready)response_valid<=0;
   if(state==IDLE&&frame_valid&&!response_valid&&!notice_valid)begin
    owner<=frame_token;count<=frame_count;sequence_id<=sequence_id+1'b1;attempts<=0;receipt<=0;started<=0;cancelled<=0;timed_out<=0;state<=SEND;
   end else if(state==SEND&&tx_valid&&tx_ready)begin
    state<=WAIT;started<=1;attempts<=attempts+1'b1;if(attempts>=RETRY_LIMIT)timed_out<=1;
   end else if(state==WAIT&&tx_done)state<=SEND;
   // F2 is a held actual application result, not transport-captured status.
   if((state==SEND||state==WAIT)&&qualified)begin
    if(reply_fragment[255:248]==8'hf2)begin
     receipt<=1;response_token<=owner;response_error<=reply_fragment[239:232];
    end else if(reply_fragment[255:248]==8'hf3&&receipt)begin
     frame_release<=1;response_valid<=1;state<=HOLD;
    end
   end
   // Wait for both consumer and snapshot ownership release before starting again.
   if(state==HOLD&&!response_valid&&!frame_valid)state<=cancelled||affected?FLUSH:IDLE;
   if(affected)begin
    cancelled<=1;
    if((state==IDLE&&frame_valid)||(state==SEND&&!started))begin
     frame_release<=1;response_valid<=0;state<=FLUSH;
    end
   end
   if(state==FLUSH&&!frame_valid&&!response_valid&&transport_idle&&!notice_valid)begin state<=IDLE;cancelled<=0;end
  end
 end
endmodule
