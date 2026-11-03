// Join actual service acknowledgements, never infer drainage from elapsed time.
// Register every participating service before this can acknowledge a global F0.
module b_control_drain_join #(parameter SERVICES=2)(input clk,rst_n,
 input notice_valid,input [31:0] notice_token,input notice_session,
 input [SERVICES-1:0] service_done_valid,input [SERVICES*32-1:0] service_done_tokens,
 output done_valid,output [31:0] done_token);
 reg complete;
 reg tracked,session;reg [31:0] owner;reg [SERVICES-1:0] seen;
 reg [SERVICES-1:0] matching;integer i;
 wire same=tracked&&owner==notice_token&&session==notice_session;
 always @(*)begin
  matching=0;
  for(i=0;i<SERVICES;i=i+1)
   matching[i]=service_done_valid[i]&&service_done_tokens[i*32+:32]==notice_token;
 end
 // Real matching acknowledgments are captured before fanout to the global
 // cancellation network. A token/session change immediately masks old credit.
 // There is no timer, truncation, speculative idle or release of source data.
 assign done_valid=notice_valid&&same&&complete;
 assign done_token=notice_token;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin tracked<=0;owner<=0;session<=0;seen<=0;complete<=0;end
  else if(!notice_valid)begin tracked<=0;seen<=0;complete<=0;end
  else begin
   tracked<=1;owner<=notice_token;session<=notice_session;
   seen<=(same?seen:{SERVICES{1'b0}})|matching;
   complete<=(&(matching|(same?seen:{SERVICES{1'b0}})));
  end
 end
endmodule
