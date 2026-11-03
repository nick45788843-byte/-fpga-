// One debounced key front end. The default media gestures remain single short
// presses; long KEY1 opens/closes the small settings menu. KEY3 is independent.
module a_board_keys #(parameter CLOCK_HZ=50000000,DEBOUNCE_MS=20,LONG_MS=1000)(
 input clk,rst_n,input [2:0] keys,input emergency,peer_online,auto_active,menu_visible,
 output tick_ms,output reg toggle_emergency,next_preset,media_valid,
 output reg [7:0] media_code,output reg menu_toggle,menu_next,menu_plus,menu_minus);
localparam DIV=CLOCK_HZ/1000,DIW=DIV>1?$clog2(DIV):1;
localparam DBW=DEBOUNCE_MS>1?$clog2(DEBOUNCE_MS+1):1;
localparam HW=LONG_MS>1?$clog2(LONG_MS+1):1;
reg [DIW-1:0] divider;reg [2:0] sync0,sync1,stable,long_seen;
reg [DBW-1:0] debounce[0:2];reg [HW-1:0] held[0:2];integer i;
assign tick_ms=divider==DIV-1;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  divider<=0;sync0<=7;sync1<=7;stable<=7;long_seen<=0;
  toggle_emergency<=0;next_preset<=0;media_valid<=0;media_code<=0;
  menu_toggle<=0;menu_next<=0;menu_plus<=0;menu_minus<=0;
  for(i=0;i<3;i=i+1)begin debounce[i]<=0;held[i]<=0;end
 end else begin
  sync0<=keys;sync1<=sync0;toggle_emergency<=0;next_preset<=0;media_valid<=0;
  menu_toggle<=0;menu_next<=0;menu_plus<=0;menu_minus<=0;
  if(tick_ms)begin
   divider<=0;
   for(i=0;i<3;i=i+1)begin
    if(sync1[i]==stable[i])debounce[i]<=0;
    else if(debounce[i]>=DEBOUNCE_MS-1)begin
     debounce[i]<=0;stable[i]<=sync1[i];
     if(i==0&&!sync1[i]&&emergency)next_preset<=1;
     if(sync1[i]&&!long_seen[i])case(i)
      0:if(!emergency)begin
       if(menu_visible)menu_next<=1;
       else if(peer_online&&!auto_active)begin media_valid<=1;media_code<=8'h10;end
      end
      1:if(!emergency)begin
       if(menu_visible)menu_plus<=1;
       else if(peer_online)begin media_valid<=1;media_code<=8'h15;end
      end
      2:toggle_emergency<=1;
     endcase
    end else debounce[i]<=debounce[i]+1'b1;
    if(stable[i])begin held[i]<=0;long_seen[i]<=0;end
    else if(!sync1[i]&&held[i]>=LONG_MS-1&&!long_seen[i])begin
     long_seen[i]<=1;
     case(i)
      0:if(!emergency)menu_toggle<=1;
      1:if(!emergency)begin
       if(menu_visible)menu_minus<=1;
       else if(peer_online&&!auto_active)begin media_valid<=1;media_code<=8'h11;end
      end
      2:if(menu_visible||emergency||!peer_online)toggle_emergency<=1;
        else begin media_valid<=1;media_code<=8'h20;end
     endcase
    end else if(!sync1[i]&&held[i]<LONG_MS)held[i]<=held[i]+1'b1;
   end
  end else divider<=divider+1'b1;
 end
end
endmodule
