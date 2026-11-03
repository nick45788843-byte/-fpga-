// One real master and one immutable owner through every complete transaction.
// Legacy media emits a pulse, so its descriptor has a private pending latch.
// Other producers use valid/ready and keep their own synchronous payload RAM.
module b_spi6_scheduler #(parameter HALF_CYCLES=2)(input clk,rst_n,miso,
 output cs_n,sclk,mosi,output busy,transport_idle,
 input legacy_start,input [7:0] legacy_kind,legacy_arg,input [6:0] legacy_count,
 input [15:0] legacy_sequence,legacy_tag,input [31:0] legacy_value,
 output legacy_busy,legacy_done,output [5:0] legacy_address,input [31:0] legacy_word,
 input ack_valid,output ack_ready,input [31:0] ack_token,input [7:0] ack_index,ack_error,input ack_captured,
 input glyph_valid,output glyph_ready,input [7:0] glyph_kind,input [6:0] glyph_count,
 input [15:0] glyph_sequence,glyph_tag,input [31:0] glyph_value,
 output glyph_done,output [5:0] glyph_address,input [31:0] glyph_word,
 input rpc_valid,output rpc_ready,input [7:0] rpc_kind,rpc_arg,input [6:0] rpc_count,
 input [15:0] rpc_sequence,rpc_tag,input [31:0] rpc_value,
 output rpc_done,output [5:0] rpc_address,input [31:0] rpc_word,
 input echo_seen,input [15:0] echo_nonce,
 output reply_valid,output [495:0] reply_body,output [15:0] bad_replies,
 output reg descriptor_overflow);
localparam LEGACY=0,ACK=1,GLYPH=2,RPC=3;
reg [1:0] owner,round_robin;reg pending,starting,last_was_ack;
reg [7:0] held_kind,held_arg;reg [6:0] held_count;reg [15:0] held_sequence,held_tag;reg [31:0] held_value;
reg [1:0] selection;reg selected_valid;
wire master_done;wire [5:0] address;wire available=!busy&&!starting;
// A retained F0/F1 can generate an unlimited stream of duplicate ACK packets.
// Allow one ACK, then give another ready producer (including heartbeat) a turn.
always @(*)begin
 selection=LEGACY;selected_valid=0;
 // Fragment/capture ACKs precede the service result. Sending RPC first can
 // occupy A's held mailbox while A still waits for its final capture ACK.
 // Only the indefinitely replayable global FE/FF controls need an ACK budget.
 if(ack_valid&&(ack_index<8'hfe||!last_was_ack||!(pending||glyph_valid||rpc_valid)))begin selection=ACK;selected_valid=1;end
 else case(round_robin)
  0:if(pending)begin selection=LEGACY;selected_valid=1;end else if(glyph_valid)begin selection=GLYPH;selected_valid=1;end else if(rpc_valid)begin selection=RPC;selected_valid=1;end
  1:if(glyph_valid)begin selection=GLYPH;selected_valid=1;end else if(rpc_valid)begin selection=RPC;selected_valid=1;end else if(pending)begin selection=LEGACY;selected_valid=1;end
  default:if(rpc_valid)begin selection=RPC;selected_valid=1;end else if(pending)begin selection=LEGACY;selected_valid=1;end else if(glyph_valid)begin selection=GLYPH;selected_valid=1;end
 endcase
end
wire start=available&&selected_valid;
assign ack_ready=start&&selection==ACK;assign glyph_ready=start&&selection==GLYPH;assign rpc_ready=start&&selection==RPC;
// Producer credit is the private descriptor slot plus its actual in-flight
// owner, rather than unrelated SPI traffic. Otherwise an ACK stream prevents
// the heartbeat producer from ever queuing the proof needed to finish F0.
assign legacy_busy=pending||((busy||starting)&&owner==LEGACY);
assign legacy_done=master_done&&owner==LEGACY;
assign glyph_done=master_done&&owner==GLYPH;assign rpc_done=master_done&&owner==RPC;
assign transport_idle=!busy&&!starting&&!pending;
assign legacy_address=owner==LEGACY?address:6'd0;
assign glyph_address=owner==GLYPH?address:6'd0;assign rpc_address=owner==RPC?address:6'd0;
wire [31:0] word=owner==LEGACY?legacy_word:owner==GLYPH?glyph_word:owner==RPC?rpc_word:32'd0;
wire [7:0] kind=selection==ACK?8'h48:selection==GLYPH?glyph_kind:selection==RPC?rpc_kind:held_kind;
wire [7:0] arg=selection==ACK?{7'd0,ack_captured}:selection==RPC?rpc_arg:selection!=LEGACY?8'd0:
 held_kind==1?{held_arg[7:3],echo_seen,held_arg[1:0]}:held_arg;
wire [6:0] count=selection==ACK?7'd0:selection==GLYPH?glyph_count:selection==RPC?rpc_count:held_count;
wire [15:0] seq=selection==ACK?16'd0:selection==GLYPH?glyph_sequence:selection==RPC?rpc_sequence:held_sequence;
wire [15:0] tag=selection==ACK?{ack_error,ack_index}:selection==GLYPH?glyph_tag:selection==RPC?rpc_tag:held_tag;
wire [31:0] value=selection==ACK?ack_token:selection==GLYPH?glyph_value:selection==RPC?rpc_value:
 held_kind==1?{echo_nonce,held_value[15:0]}:held_value;
media_spi_master #(.PROTOCOL_VERSION(6),.HALF_CYCLES(HALF_CYCLES),.SHORT_POLL(1)) master(
 clk,rst_n,start,kind,arg,count,seq,tag,value,address,word,miso,cs_n,sclk,mosi,busy,master_done,reply_valid,reply_body,bad_replies);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin owner<=LEGACY;round_robin<=0;pending<=0;starting<=0;last_was_ack<=0;descriptor_overflow<=0;
  held_kind<=0;held_arg<=0;held_count<=0;held_sequence<=0;held_tag<=0;held_value<=0;
 end else begin
  starting<=start;
  if(start)begin
   owner<=selection;
   last_was_ack<=selection==ACK;
   if(selection==LEGACY)begin pending<=0;round_robin<=1;end
   if(selection==GLYPH)round_robin<=2;
   if(selection==RPC)round_robin<=0;
  end
  if(legacy_start)begin
   if(pending&&!(start&&selection==LEGACY))descriptor_overflow<=1;
   else begin pending<=1;held_kind<=legacy_kind;held_arg<=legacy_arg;held_count<=legacy_count;
    held_sequence<=legacy_sequence;held_tag<=legacy_tag;held_value<=legacy_value;
   end
  end
 end
end
endmodule
