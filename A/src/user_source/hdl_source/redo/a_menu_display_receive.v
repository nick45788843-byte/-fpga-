// Complete CRC-qualified mailbox lease. ACK is capture, never configuration apply.
module a_menu_display_receive(input clk,rst_n,peer_ready,input [31:0] namespace_cookie,
 input packet_valid,output packet_ready,input [7:0] packet_arg,input [6:0] packet_count,
 input [15:0] packet_sequence,packet_tag,input [31:0] packet_value,
 output [5:0] read_address,input [31:0] read_word,
 output reg [34:0] descriptor,output reg [31:0] display_generation,
 output reg update_valid,output reg [15:0] rejected,output reg [7:0] capture_error);
localparam IDLE=0,WAIT0=1,COPY0=2,WAIT1=3,COPY1=4,DONE=5;
reg [2:0] state;reg [31:0] low_word,epoch;reg seen;
wire [31:0] incoming_generation={packet_tag,packet_sequence};
wire shape=packet_arg==0&&packet_count==2&&incoming_generation!=0;
wire [34:0] incoming_descriptor={read_word[2:0],low_word};
assign packet_ready=state==DONE;
assign read_address=state==WAIT1||state==COPY1?6'd1:6'd0;
task reject;input [7:0] e;begin capture_error<=e;if(rejected!=16'hffff)rejected<=rejected+1'b1;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;low_word<=0;epoch<=0;seen<=0;descriptor<=0;display_generation<=0;update_valid<=0;rejected<=0;capture_error<=0;end
 else begin
  update_valid<=0;
  if(epoch!=namespace_cookie)begin epoch<=namespace_cookie;seen<=0;descriptor<=0;display_generation<=0;end
  if(!peer_ready)descriptor[34]<=0;
  case(state)
   IDLE:if(packet_valid)begin
    capture_error<=0;
    if(shape)state<=WAIT0;else begin reject(8'h42);state<=DONE;end
   end
   WAIT0:state<=COPY0;
   COPY0:begin low_word<=read_word;state<=WAIT1;end
   WAIT1:state<=COPY1;
   COPY1:begin
    state<=DONE;
    if(!peer_ready||namespace_cookie==0||epoch!=namespace_cookie||packet_value!=namespace_cookie)reject(8'h46);
    else if(read_word[31:3]!=0)reject(8'h42);
    else if(seen&&incoming_generation<display_generation)reject(8'h46);
    else if(seen&&incoming_generation==display_generation)begin
     if(incoming_descriptor!=descriptor)reject(8'hd4);
    end else begin descriptor<=incoming_descriptor;display_generation<=incoming_generation;seen<=1;update_valid<=1;end
   end
   DONE:state<=IDLE;
   default:state<=IDLE;
  endcase
 end
end
endmodule
