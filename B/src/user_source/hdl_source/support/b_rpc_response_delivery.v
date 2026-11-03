// Fixed result delivery. RESPONSE_LEASE keeps the actual producer's complete
// result until F5 plus physical idle; the producer snapshot is not copied here.
// Default mode retains the old independent snapshot interface for other users.
module b_rpc_response_delivery #(parameter CONTROL_ENABLED=0,RESPONSE_LEASE=0)(input clk,rst_n,input response_valid,output response_ready,
 input [31:0] response_token,input [191:0] response_payload,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 input [5:0] read_address,output reg [31:0] read_word,
 input reply_valid,input [255:0] reply_fragment,
 output reg done_valid,input done_ready,output [31:0] done_token,output reg [7:0] done_error,
 input cancel_notice_valid,input [31:0] cancel_notice_token,input cancel_notice_session,input transport_idle,
 output reg cancel_done_valid,output reg [31:0] cancel_done_token,
 output lease_accept,lease_busy);
localparam IDLE=0,SEND=1,WAIT=2,DONE=3,FLUSH=4;
reg [2:0] state;
reg received,flush_pending;
reg [31:0] snapshot_owner,result_owner;
reg [191:0] snapshot_payload;
reg [15:0] sequence_id;
reg [7:0] error;
// The UID is captured at the real lease claim. A dynamic producer mux must
// not feed the scheduler eligibility equality or the held transfer owner.
wire [31:0] owner=snapshot_owner;
wire [191:0] payload=RESPONSE_LEASE?response_payload:snapshot_payload;
wire control=CONTROL_ENABLED&&cancel_notice_valid;
wire affected=control&&(cancel_notice_session||cancel_notice_token==owner);
wire [31:0] token={reply_fragment[199:192],reply_fragment[207:200],reply_fragment[215:208],reply_fragment[223:216]};
wire qualified=reply_valid&&reply_fragment[247:240]==0&&reply_fragment[231:224]==8'h40&&token==owner;
wire complete=state==DONE&&done_valid&&done_ready&&(!RESPONSE_LEASE||transport_idle)&&!affected;
assign lease_accept=state==IDLE&&response_valid&&!control;
assign lease_busy=state!=IDLE||flush_pending;
assign response_ready=RESPONSE_LEASE?(complete||(state==FLUSH&&transport_idle&&flush_pending)):(state==IDLE&&!control);
assign tx_valid=state==SEND;
assign tx_kind=received?8'h41:8'h40;
assign tx_count=received?7'd0:7'd6;
assign tx_sequence=sequence_id;
assign tx_tag=0;
assign tx_value=owner;
assign done_token=RESPONSE_LEASE?owner:result_owner;
always @(posedge clk)read_word<=read_address<6?payload[read_address*32+:32]:32'd0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;received<=0;flush_pending<=0;snapshot_owner<=0;result_owner<=0;snapshot_payload<=0;
  sequence_id<=0;error<=0;done_valid<=0;done_error<=0;cancel_done_valid<=0;cancel_done_token<=0;
 end else begin
  if(!control&&!flush_pending)cancel_done_valid<=0;
  if(lease_accept)begin
   snapshot_owner<=response_token;
   if(!RESPONSE_LEASE)snapshot_payload<=response_payload;
   received<=0;sequence_id<=sequence_id+1'b1;state<=SEND;
  end else if(state==SEND&&tx_ready)state<=WAIT;
  else if(state==WAIT&&tx_done)state<=SEND;
  if((state==SEND||state==WAIT)&&qualified)begin
   if(reply_fragment[255:248]==8'hf4)begin received<=1;error<=reply_fragment[239:232];end
   else if(reply_fragment[255:248]==8'hf5&&received)begin
    if(flush_pending||affected)begin done_valid<=0;state<=FLUSH;end
    else begin
     if(!RESPONSE_LEASE)begin done_valid<=1;result_owner<=owner;end
     done_error<=error;state<=DONE;
    end
   end
  end
  if(RESPONSE_LEASE&&state==DONE&&!done_valid&&transport_idle&&!affected&&!flush_pending)done_valid<=1;
  if(complete)begin done_valid<=0;state<=IDLE;end
  if(control&&!cancel_done_valid&&!flush_pending)begin
   cancel_done_token<=cancel_notice_token;
   if(!affected||state==IDLE)cancel_done_valid<=1;
   else begin flush_pending<=1;done_valid<=0;if(state==DONE)state<=FLUSH;end
  end
  // Keep the original payload and full UID leased while polling for actual F5.
  // The global cancel quorum cannot acknowledge until the shared SPI is idle.
  if(state==FLUSH&&transport_idle)begin
   done_valid<=0;cancel_done_valid<=1;
   if(!control)begin state<=IDLE;flush_pending<=0;cancel_done_valid<=0;end
  end
 end
end
endmodule
