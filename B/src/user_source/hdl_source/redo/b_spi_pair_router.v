// Two valid/ready descriptor owners share a scheduler source. Selection remains
// immutable through physical done; both producers keep their own payload RAM.
module b_spi_pair_router(input clk,rst_n,
 input a_valid,output a_ready,input [7:0] a_kind,input [6:0] a_count,input [15:0] a_sequence,a_tag,input [31:0] a_value,
 output a_done,output [5:0] a_address,input [31:0] a_word,
 input b_valid,output b_ready,input [7:0] b_kind,input [6:0] b_count,input [15:0] b_sequence,b_tag,input [31:0] b_value,
 output b_done,output [5:0] b_address,input [31:0] b_word,
 output valid,input ready,output [7:0] kind,output [6:0] count,output [15:0] sequence_id,tag,output [31:0] value,
 input done,input [5:0] address,output [31:0] word);
reg owned,owner_b,turn_b;
wire choose_b=b_valid&&(!a_valid||turn_b);
assign valid=!owned&&(a_valid||b_valid);
assign a_ready=valid&&ready&&!choose_b;assign b_ready=valid&&ready&&choose_b;
assign kind=choose_b?b_kind:a_kind;assign count=choose_b?b_count:a_count;
assign sequence_id=choose_b?b_sequence:a_sequence;assign tag=choose_b?b_tag:a_tag;assign value=choose_b?b_value:a_value;
assign a_done=owned&&!owner_b&&done;assign b_done=owned&&owner_b&&done;
assign a_address=owner_b?6'd0:address;assign b_address=owner_b?address:6'd0;assign word=owner_b?b_word:a_word;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin owned<=0;owner_b<=0;turn_b<=0;end
 else begin
  if(valid&&ready)begin owned<=1;owner_b<=choose_b;turn_b<=!choose_b;end
  if(owned&&done)owned<=0;
 end
end
endmodule
