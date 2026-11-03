// cmd11 owner adapter. request_ready releases the assembler body ONLY after validation.
// Response is validation status, never an A display/persistence success acknowledgement.
module b_text_request_owner #(parameter ROM_FILE="unicode.mem")(
 input clk,rst_n,input request_valid,output request_ready,
 input [31:0] request_token,input [7:0] request_command,request_length,
 output [7:0] source_address,input [7:0] source_byte,
 input cancel_notice_valid,input [31:0] cancel_notice_token,input cancel_notice_session,
 output cancel_done_valid,output [31:0] cancel_done_token,
 output response_valid,input response_ready,output [31:0] response_token,
 output [7:0] response_error,response_position,
 output cache_valid,output [7:0] cache_length,output [6:0] cache_glyph_count,
 input [7:0] raw_address,output [7:0] raw_byte,input [5:0] glyph_address,output [7:0] glyph_byte
);
 localparam IDLE=0,RUN=1,RESULT=2,RELEASE=3;
 reg [1:0] state;reg [31:0] owner;
 wire ready,valid;wire [31:0] token;wire [7:0] error,position;
 wire affected=cancel_notice_valid&&(cancel_notice_session||cancel_notice_token==owner);
 wire accept=request_valid&&request_command==11&&state==IDLE&&!cancel_notice_valid;
 assign request_ready=state==RUN&&valid&&!affected;
 assign response_valid=(state==RUN||state==RESULT)&&valid&&!affected;
 assign response_token=token;assign response_error=error;assign response_position=position;
 assign cancel_done_token=cancel_notice_token;
 // A stale F1 leaves unrelated work and its reply intact. F0 drains any owner.
 assign cancel_done_valid=cancel_notice_valid&&(!affected||state==IDLE||state==RELEASE);
 b_text_validate #(.ROM_FILE(ROM_FILE)) validate(clk,rst_n,accept,ready,request_token,{8'd0,request_length},
  source_address,source_byte,affected,owner,valid,affected||response_ready,token,error,position,
  cache_valid,cache_length,cache_glyph_count,raw_address,raw_byte,glyph_address,glyph_byte);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;owner<=0;end
  else case(state)
   IDLE:if(accept&&ready)begin owner<=request_token;state<=RUN;end
   RUN:if(valid)begin
    if(affected||response_ready)state<=RELEASE;else state<=RESULT;
   end
   RESULT:if(valid&&(affected||response_ready))state<=RELEASE;
   RELEASE:if(!valid&&(!request_valid||request_token!=owner))state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
