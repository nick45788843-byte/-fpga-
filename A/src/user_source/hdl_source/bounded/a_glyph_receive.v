// SPI6 kind49: value=owner32, tag=0..64 glyph count, count=ceil(glyph_count/4).
// CRC-qualified command and synchronous word RAM must remain held until command_ready.
module a_glyph_receive #(parameter REVOKE_ENABLED=0)(input clk,rst_n,input command_valid,output command_ready,
 input [7:0] command_kind,command_arg,input [6:0] command_count,input [15:0] command_tag,command_crc,
 input [31:0] command_token,output reg [5:0] read_address,input [31:0] read_word,
 output apply_valid,input apply_ready,output reg [31:0] apply_token,output reg [6:0] apply_count,
 input [5:0] glyph_address,output reg [7:0] glyph_byte,
 input apply_response_valid,output apply_response_ready,input [31:0] apply_response_token,input [7:0] apply_response_error,
 output reg response_valid,input response_ready,output reg [31:0] response_token,output reg [7:0] response_error,
 input revoke_valid,input [31:0] revoke_token);
 localparam IDLE=0,ADDR=1,WAIT_WORD=2,COPY=3,RELEASE=4,SUBMIT=5,RESULT=6;
 reg [2:0] state;reg [5:0] cursor;reg [1:0] lane;reg [15:0] held_crc;
 // The cursor changes on the write edge. Hold its address from the preceding
 // falling edge so DRAM has a real half-cycle of address setup and hold.
 // COPY is entered only after ADDR/WAIT_WORD, including after reset; the
 // address presented at every original rising-edge write is unchanged.
 (* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg [5:0] write_cursor_phase;
 always @(negedge clk) write_cursor_phase<=cursor;
 reg [7:0] glyph[0:63];reg seen;reg [31:0] highest,last_token;reg [15:0] last_crc;reg [6:0] last_count;reg [7:0] last_error;
 reg result_suspended;
 wire shape=command_arg==0&&command_tag<=64&&command_count==((command_tag+3)>>2)&&command_token!=0;
 wire held_retry=state==IDLE&&(response_valid||result_suspended)&&shape&&command_token==response_token&&
  command_token==last_token&&command_crc==last_crc&&command_tag==last_count;
 // A repeated kind49 must not occupy the SPI mailbox while its F2 result is held;
 // otherwise B's following kind4A receipt cannot reach the result scheduler.
 assign command_ready=command_kind==8'h49&&((state==RELEASE)||held_retry||
  (state==IDLE&&!response_valid&&command_valid&&(!shape||(seen&&command_token<=highest))));
 assign apply_valid=state==SUBMIT;
 wire late_cancel=state==IDLE&&apply_response_token==last_token&&apply_response_error==8'h43;
 assign apply_response_ready=state==RESULT||late_cancel;
 always @(posedge clk)glyph_byte<=glyph[glyph_address];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;cursor<=0;lane<=0;read_address<=0;apply_token<=0;apply_count<=0;held_crc<=0;
   response_valid<=0;response_token<=0;response_error<=0;seen<=0;highest<=0;last_token<=0;last_crc<=0;last_count<=0;last_error<=0;result_suspended<=0;end
  else begin
   if(response_valid&&response_ready)response_valid<=0;
   if(apply_response_valid&&late_cancel)begin
    response_valid<=1;response_token<=last_token;response_error<=8'h43;last_error<=8'h43;result_suspended<=0;
   end
   if(REVOKE_ENABLED&&revoke_valid&&revoke_token==last_token)begin result_suspended<=1;response_valid<=0;end
   case(state)
    IDLE:if(command_valid&&command_kind==8'h49&&!response_valid&&!result_suspended)begin
     if(!shape||(seen&&command_token<=highest))begin
      response_valid<=1;response_token<=command_token;
      response_error<=!shape?8'h42:command_token==last_token&&command_crc==last_crc&&command_tag==last_count?last_error:8'h46;
     end else begin
      seen<=1;highest<=command_token;apply_token<=command_token;apply_count<=command_tag[6:0];held_crc<=command_crc;cursor<=0;lane<=0;
      state<=command_tag==0?RELEASE:ADDR;
     end
    end
    ADDR:begin read_address<=cursor>>2;state<=WAIT_WORD;end
    WAIT_WORD:state<=COPY;
    COPY:begin glyph[write_cursor_phase]<=read_word[lane*8+:8];
     if({1'b0,cursor}+1==apply_count)state<=RELEASE;
     else begin cursor<=cursor+1'b1;lane<=lane+1'b1;if(lane==3)state<=ADDR;end
    end
    RELEASE:if(command_valid&&command_ready)state<=SUBMIT;
    SUBMIT:if(apply_ready)state<=RESULT;
    RESULT:if(apply_response_valid&&apply_response_token==apply_token)begin
     response_valid<=1;response_token<=apply_token;response_error<=apply_response_error;
     last_token<=apply_token;last_crc<=held_crc;last_count<=apply_count;last_error<=apply_response_error;state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
