// No payload copy: the CRC-qualified SPI RAM stays owned through actual data
// consumption. Media word0 is a full UID; original data words begin at word1.
module a_media_uid_guard #(parameter SESSION_GUARD=0)(input clk,rst_n,input packet_valid,output reg packet_consume,
 input [7:0] packet_kind,input [6:0] packet_count,input [15:0] packet_tag,
 input namespace_valid,input [15:0] namespace_prefix,
 input [31:0] expected_image_uid,expected_audio_uid,
 output [5:0] read_address,input [31:0] read_word,
 output core_valid,input core_consume,output [31:0] core_uid,output [6:0] core_count,
 input [5:0] core_read_address,
 output reg reject_valid,output reg [15:0] reject_tag,output reg [7:0] reject_error,output reg [31:0] reject_uid,
 input session_ready);
localparam IDLE=0,ADDR=1,WAIT_WORD=2,CHECK=3,FORWARD=4,REJECT=5,DRAIN=6;
reg [2:0] state;reg media;reg [31:0] uid;
wire image=packet_kind>=8'h10&&packet_kind<=8'h13;
wire audio=packet_kind>=8'h20&&packet_kind<=8'h23;
wire [31:0] expected=image?expected_image_uid:expected_audio_uid;
wire abort_only=packet_kind==8'h13&&packet_count==1;
assign core_valid=state==FORWARD&&packet_valid;
assign core_uid=media?uid:32'd0;
assign core_count=media?packet_count-7'd1:packet_count;
assign read_address=state==FORWARD?(media?core_read_address+6'd1:core_read_address):6'd0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;media<=0;uid<=0;packet_consume<=0;reject_valid<=0;reject_tag<=0;reject_error<=0;reject_uid<=0;end
 else begin
  packet_consume<=0;reject_valid<=0;
  case(state)
   IDLE:if(packet_valid)begin
    media<=image||audio;uid<=0;
    if(!(image||audio))begin uid<=0;state<=FORWARD;end
    else if(packet_count==0||packet_count>64)begin reject_error<=8'h42;state<=REJECT;end
    else state<=ADDR;
   end
   ADDR:state<=WAIT_WORD;
   WAIT_WORD:state<=CHECK;
   CHECK:begin
    uid<=read_word;
    // 取消只进入实际核心核对旧完整 owner 并排空；A 单复位后也能结束 B 的旧事务。
    if(read_word==0||(!abort_only&&(!namespace_valid||(SESSION_GUARD&&!session_ready)||
       read_word[31:16]!=namespace_prefix||expected==0||read_word!=expected)))begin reject_error<=8'h49;state<=REJECT;end
    else begin uid<=read_word;state<=FORWARD;end
   end
   FORWARD:if(core_consume)begin packet_consume<=1;state<=DRAIN;end
   REJECT:begin packet_consume<=1;reject_valid<=1;reject_tag<=packet_tag;reject_uid<=uid;state<=DRAIN;end
   DRAIN:if(!packet_valid)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
end
endmodule
