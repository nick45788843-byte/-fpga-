// No second 24-byte RPC buffer. The CRC-qualified slave RAM stays owned until
// the portal has copied the full reply and CRC into its shared response bank.
module a_remote_reply_port #(parameter CLEAR_ENABLED=0)(input clk,rst_n,
 input command_valid,output command_ready,input [7:0] kind,arg,input [6:0] count,
 input [15:0] tag,packet_crc,input [31:0] token,
 output [5:0] word_address,input [31:0] word,
 output result_valid,input result_ready,output [31:0] result_token,
 input [4:0] byte_address,output [7:0] result_byte,
 output reg receipt_valid,input receipt_ready,output reg [31:0] receipt_token,output reg [7:0] receipt_error,input clear);
reg last_valid;reg [31:0] last_token;reg [15:0] last_crc;
wire shape=arg==0&&count==6&&tag==0&&token!=0;
wire duplicate=last_valid&&token==last_token&&packet_crc==last_crc;
wire receipt_space=!receipt_valid||receipt_ready;
assign result_valid=command_valid&&kind==8'h40&&shape&&!duplicate&&receipt_space;
assign result_token=token;
assign word_address={3'd0,byte_address[4:2]};
assign result_byte=word[{byte_address[1:0],3'b000}+:8];
// The original F4/F5 descriptor remains held until its paired receipt. A retry
// must not queue another F4 behind it: that would hold this SPI mailbox while
// B's following kind41 is needed to free the descriptor, creating a cycle.
assign command_ready=command_valid&&kind==8'h40&&
 (shape&&duplicate||receipt_space&&(!shape||result_ready));
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin last_valid<=0;last_token<=0;last_crc<=0;receipt_valid<=0;receipt_token<=0;receipt_error<=0;end
 else if(CLEAR_ENABLED&&clear)begin last_valid<=0;receipt_valid<=0;end
 else begin
  if(receipt_valid&&receipt_ready)receipt_valid<=0;
  if(command_valid&&command_ready&&!(shape&&duplicate))begin
   receipt_valid<=1;receipt_token<=token;receipt_error<=shape?8'd0:8'h42;
   if(shape&&!duplicate)begin last_valid<=1;last_token<=token;last_crc<=packet_crc;end
  end
 end
end
endmodule
