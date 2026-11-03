// 一个失联边沿只触发一次；人工退出后不会因持续离线反复进入应急。
module link_watchdog #(parameter CLOCK_HZ=50000000,BOOT_MS=2000,TIMEOUT_MS=500)(
 input clk,rst_n,valid_peer,output reg online,offline,trip);
localparam DIV=CLOCK_HZ/1000,W=DIV>1?$clog2(DIV):1;
localparam MAX=BOOT_MS>TIMEOUT_MS?BOOT_MS:TIMEOUT_MS,AW=$clog2(MAX+1);
reg [W-1:0] divider;reg [AW-1:0] age;wire tick=divider==DIV-1;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin divider<=0;age<=0;online<=0;offline<=0;trip<=0;end
 else begin trip<=0;if(tick)divider<=0;else divider<=divider+1'b1;
  if(valid_peer)begin age<=0;online<=1;offline<=0;end
  else if(tick&&!offline)begin
   if(age>=(online?TIMEOUT_MS:BOOT_MS)-1)begin online<=0;offline<=1;trip<=1;end
   else age<=age+1'b1;
  end
 end
end
endmodule
