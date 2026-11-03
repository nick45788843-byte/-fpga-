// reply_valid must be the physical SPI master's full header/CRC-valid pulse.
// Other pages retain the last nonce; cold/B-only reset clears echo_seen.
module b_link_proof_echo #(parameter BODY_BYTES=62)(input clk,rst_n,input reply_valid,input [BODY_BYTES*8-1:0] reply_body,
 output reg echo_seen,output reg [15:0] echo_nonce);
function [7:0] byte_at;input [BODY_BYTES*8-1:0] bytes;input integer position;begin byte_at=bytes[(BODY_BYTES-1-position)*8+:8];end endfunction
wire [7:0] flags=byte_at(reply_body,18);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin echo_seen<=0;echo_nonce<=0;end
 else if(reply_valid&&reply_body[BODY_BYTES*8-1-:32]==32'h434e0681&&
         flags[2:0]==3'd3&&byte_at(reply_body,29)==8'ha6)begin
  echo_nonce<={byte_at(reply_body,28),byte_at(reply_body,27)};echo_seen<=1;
 end
end
endmodule
