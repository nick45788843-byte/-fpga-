// MISO extension arbitration must keep this descriptor until the paired receipt.
// F2: applied result; F3: confirms A received B's kind4A receipt. Byte3 identifies kind49.
module a_glyph_result_fragment #(parameter REVOKE_ENABLED=0,parameter [7:0] RESULT_MARKER=8'hf2,
 parameter [7:0] RECEIPT_MARKER=8'hf3,parameter [7:0] PAYLOAD_KIND=8'h49,parameter SOURCE_CLEAR_ATOMIC=0)(input clk,rst_n,input result_valid,output result_ready,
 input [31:0] result_token,input [7:0] result_error,
 input receipt_valid,input [31:0] receipt_token,
 output fragment_valid,output [255:0] fragment,input revoke_valid,input [31:0] revoke_token,input receipt_frame_captured);
 reg valid,received,receipt_published;reg [31:0] token;reg [7:0] error;
 wire revoke=REVOKE_ENABLED&&revoke_valid&&revoke_token==token;
 // Only legal when the source has the same dominating clear, and clear
 // excludes every new payload command. All fragment visibility and
 // synchronous revoke priority remain unchanged.
 assign result_ready=(!valid||(received&&receipt_published))&&(!revoke||SOURCE_CLEAR_ATOMIC);
 assign fragment_valid=valid&&!revoke;
 assign fragment={received?RECEIPT_MARKER:RESULT_MARKER,8'd0,received?8'd0:error,PAYLOAD_KIND,
  token[7:0],token[15:8],token[23:16],token[31:24],192'd0};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid<=0;received<=0;receipt_published<=0;token<=0;error<=0;end
  else if(revoke)begin valid<=0;received<=0;receipt_published<=0;end
  else if(result_valid&&result_ready)begin valid<=1;received<=0;receipt_published<=0;token<=result_token;error<=result_error;end
  else begin
   if(receipt_valid&&valid&&receipt_token==token)received<=1;
   if(receipt_frame_captured&&received)receipt_published<=1;
  end
 end
endmodule
