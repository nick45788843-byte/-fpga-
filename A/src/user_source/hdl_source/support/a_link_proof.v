// 两轮新鲜往返才建立在线证明；重复回显不刷新看门狗。
module a_link_proof(input clk,rst_n,offline,input heartbeat,input echo_valid,input [15:0] echo_nonce,
 output reg [15:0] challenge,output reg valid_peer);
reg primed,offline_previous;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin challenge<=16'h1;primed<=0;offline_previous<=0;valid_peer<=0;end
 else begin
  valid_peer<=0;offline_previous<=offline;
  if(offline&&!offline_previous)primed<=0;
  else if(heartbeat&&echo_valid&&echo_nonce==challenge)begin
   challenge<=challenge==16'hffff ? 16'h1 : challenge+1'b1;
   if(primed)valid_peer<=1;else primed<=1;
  end
 end
end
endmodule
