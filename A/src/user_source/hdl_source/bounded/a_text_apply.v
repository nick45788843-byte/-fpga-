// Copies only decoded glyphs. Never acknowledges display before the actual frame CDC ACK.
// Cancellation after publish drains that frame and restores the prior descriptor at another frame.
module a_text_apply #(parameter TWO_PHASE=0,CUSTOM_SELECT_ENABLED=0)(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_token,input [6:0] request_count,
 output reg [5:0] source_address,input [7:0] source_glyph,
 input cancel_valid,input [31:0] cancel_token,
 output reg char_we,output reg char_bank,output reg [5:0] char_address,output reg [7:0] char_data,
 output reg publish_valid,output reg [31:0] publish_token,output reg [15:0] publish_descriptor,
 input applied_valid,input [31:0] applied_token,input [15:0] applied_descriptor,
 output reg response_valid,input response_ready,output reg [31:0] response_token,output reg [7:0] response_error,
 input finalize_valid,input [31:0] finalize_token,output result_revoke_valid,input request_custom);
 localparam IDLE=0,ADDR=1,WAIT_DATA=2,COPY=3,ISSUE=4,APPLY=5,ROLLBACK=6,PREPARED=7;
 reg [2:0] state;reg [31:0] owner,next_token;reg [6:0] count;reg [5:0] cursor;
 reg [15:0] current_descriptor,old_descriptor;reg cancelled,custom;reg [7:0] generation;
 wire cancel_match=cancel_valid&&cancel_token==owner&&state!=IDLE;
 assign result_revoke_valid=TWO_PHASE&&cancel_match&&state==PREPARED;
 assign request_ready=state==IDLE&&!response_valid;
 task finish;input [7:0] error;begin
  response_valid<=1;response_token<=owner;response_error<=error;state<=IDLE;publish_valid<=0;
 end endtask
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;owner<=0;next_token<=1;count<=0;cursor<=0;source_address<=0;
   char_we<=0;char_bank<=0;char_address<=0;char_data<=0;publish_valid<=0;publish_token<=0;publish_descriptor<=0;
   current_descriptor<=0;old_descriptor<=0;cancelled<=0;custom<=1;generation<=1;
   response_valid<=0;response_token<=0;response_error<=0;end
  else begin
   char_we<=0;if(response_valid&&response_ready)response_valid<=0;
   if(cancel_match)cancelled<=1;
   if(cancel_match&&(state==ADDR||state==WAIT_DATA||state==COPY||state==ISSUE))finish(8'h43);
   else case(state)
    IDLE:if(request_valid&&request_ready)begin
     owner<=request_token;count<=request_count;cursor<=0;cancelled<=0;old_descriptor<=current_descriptor;
     custom<=CUSTOM_SELECT_ENABLED?request_custom:1'b1;
     char_bank<=!current_descriptor[7];
     if(request_count>64||next_token>=32'hfffffffe||(CUSTOM_SELECT_ENABLED&&!request_custom&&request_count!=0))begin
      response_valid<=1;response_token<=request_token;response_error<=request_count>64?8'h52:
       next_token>=32'hfffffffe ? 8'h48 : 8'h42;
     end else if(request_count==0)state<=ISSUE;else state<=ADDR;
    end
    ADDR:begin source_address<=cursor;state<=WAIT_DATA;end
    WAIT_DATA:state<=COPY;
    COPY:begin char_we<=1;char_address<=cursor;char_data<=source_glyph;
     if({1'b0,cursor}+1==count)state<=ISSUE;else begin cursor<=cursor+1'b1;state<=ADDR;end
    end
    ISSUE:begin publish_valid<=1;publish_token<=next_token;next_token<=next_token+1'b1;
     publish_descriptor<=custom?{generation,char_bank,count}:16'd0;generation<=generation==255?8'd1:generation+1'b1;state<=APPLY;
    end
    APPLY:if(applied_valid&&applied_token==publish_token&&applied_descriptor==publish_descriptor)begin
     current_descriptor<=publish_descriptor;
     if(cancelled||cancel_match)begin
      publish_descriptor<=old_descriptor;publish_token<=next_token;next_token<=next_token+1'b1;state<=ROLLBACK;
     end else if(TWO_PHASE)begin
      response_valid<=1;response_token<=owner;response_error<=0;publish_valid<=0;state<=PREPARED;
     end else finish(0);
    end
    PREPARED:if(cancel_match)begin
     response_valid<=0;publish_valid<=1;publish_descriptor<=old_descriptor;
     publish_token<=next_token;next_token<=next_token+1'b1;state<=ROLLBACK;
    end else if(finalize_valid&&finalize_token==owner)state<=IDLE;
    ROLLBACK:if(applied_valid&&applied_token==publish_token&&applied_descriptor==old_descriptor)begin
     current_descriptor<=old_descriptor;finish(8'h43);
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
