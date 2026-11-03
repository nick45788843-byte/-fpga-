// A owns only physical key routing and one bounded B request descriptor.
// Parameter ranges, defaults and reply interpretation are exclusively on B.
module a_menu_front(input clk,rst_n,emergency,peer_ready,
 input toggle,next_item,plus,minus,output reg visible,output reg [2:0] item,
 output key_valid,output [7:0] key_code,
 input packet_valid,input [7:0] packet_arg,input [6:0] packet_count,
 input [15:0] packet_sequence,packet_tag,input [31:0] packet_value,
 output request_valid,input request_ready,output [7:0] request_command,
 output [47:0] request_arguments,input result_valid,output result_ready,
 output board_cancel,output idle);
reg pending,leased,closing;reg [15:0] ticket,parameter_id,setting;
reg [3:0] command;
wire shape=packet_arg==0&&packet_count==0&&packet_tag!=0&&packet_value[23:16]==0&&
 (packet_value[27:24]==0||packet_value[27:24]>=4&&packet_value[27:24]<=6);
wire fresh=packet_valid&&shape&&packet_tag>ticket&&peer_ready&&!emergency;
assign key_valid=peer_ready&&!emergency&&(toggle||next_item||plus||minus);
assign key_code=toggle?8'h30:next_item?8'h31:plus?8'h32:8'h33;
assign request_valid=pending&&!leased&&visible&&peer_ready&&!emergency;
assign request_command={4'd0,command}+8'd20;
assign request_arguments={16'd0,setting,parameter_id};
// The original portal owns the entire verified RPC result. B has already
// interpreted the identical config result; no second A body copy is needed.
assign result_ready=leased;
assign board_cancel=!visible||!peer_ready||emergency;
assign idle=!pending&&!leased;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin visible<=0;item<=0;pending<=0;leased<=0;closing<=0;ticket<=0;parameter_id<=0;setting<=0;command<=0;end
 else begin
  if(request_valid&&request_ready)begin pending<=0;leased<=1;end
  if(result_valid&&result_ready)leased<=0;
  if(fresh)begin
   ticket<=packet_tag;visible<=packet_value[31]&&!closing;item<=packet_value[30:28];
   if(!packet_value[31])closing<=0;
   if(packet_value[31]&&!closing&&packet_value[27:24]!=0)begin
    pending<=1;command<=packet_value[27:24];parameter_id<=packet_sequence;setting<=packet_value[15:0];
   end
   if(!packet_value[31])pending<=0;
  end
  // Immediate local closure preserves ordinary exit/F1 and independent KEY3.
  if(toggle&&peer_ready&&!emergency&&!closing)begin visible<=!visible;if(visible)begin pending<=0;closing<=1;end end
  if(!peer_ready||emergency)begin visible<=0;pending<=0;ticket<=0;closing<=0;end
 end
end
endmodule
