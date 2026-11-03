// One descriptor lease through actual physical SPI done. The original staging
// RAM is retained; word0 adds UID and the old data RAM is read at address-1.
module b_media_uid_envelope(input clk,rst_n,input source_start,output source_busy,source_done,
 input [7:0] source_kind,source_arg,input [6:0] source_count,
 input [15:0] source_sequence,source_tag,input [31:0] source_value,source_uid,
 output [5:0] source_address,input [31:0] source_word,
 output tx_valid,input tx_ready,output [7:0] tx_kind,tx_arg,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,
 input [5:0] tx_address,output [31:0] tx_word,input tx_done,
 output reg descriptor_error);
localparam IDLE=0,OFFER=1,WAIT_DONE=2;
reg [1:0] state;reg media;reg [7:0] kind,arg;reg [6:0] count;
reg [15:0] sequence_id,tag;reg [31:0] value,uid;
wire is_media=(source_kind>=8'h10&&source_kind<=8'h13)||(source_kind>=8'h20&&source_kind<=8'h23);
assign source_busy=state!=IDLE;
assign source_done=state==WAIT_DONE&&tx_done;
assign tx_valid=state==OFFER;
assign tx_kind=kind;assign tx_arg=arg;assign tx_count=count;assign tx_sequence=sequence_id;assign tx_tag=tag;assign tx_value=value;
assign source_address=media?(tx_address==0?6'd0:tx_address-6'd1):tx_address;
assign tx_word=media&&tx_address==0?uid:source_word;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;media<=0;kind<=0;arg<=0;count<=0;sequence_id<=0;tag<=0;value<=0;uid<=0;descriptor_error<=0;end
 else case(state)
  IDLE:if(source_start)begin
   if(is_media&&(source_uid==0||source_count>63))descriptor_error<=1;
   else begin
    media<=is_media;kind<=source_kind;arg<=source_arg;count<=is_media?source_count+7'd1:source_count;
    sequence_id<=source_sequence;tag<=source_tag;value<=source_value;uid<=source_uid;state<=OFFER;
   end
  end
  OFFER:if(tx_ready)state<=WAIT_DONE;
  WAIT_DONE:if(tx_done)state<=IDLE;
 endcase
end
endmodule
