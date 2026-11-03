// Menu status only: no command UID allocation, configuration write or save ACK.
// A full namespace cookie and full 32-bit display generation qualify snapshots.
module b_menu_display_source #(parameter MIN_REFRESH_CYCLES=0)(input clk,rst_n,tick_ms,enabled,notice_valid,
 input [31:0] namespace_cookie,input visible,input [2:0] item,input known,
 input [15:0] value,input [1:0] status,input [7:0] error,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 input [5:0] read_address,output reg [31:0] read_word,
 output drained,output reg exhausted);
localparam IDLE=0,FORMAT=1,OFFER=2,FLIGHT=3;
reg [1:0] state;
reg [30:0] held_source,observed_source;
reg [31:0] cookie,generation;
reg [15:0] binary;
reg [19:0] digits;
reg [3:0] step;
reg [4:0] cooldown;
localparam GAP_BITS=MIN_REFRESH_CYCLES>0?$clog2(MIN_REFRESH_CYCLES+1):1;
reg [GAP_BITS-1:0] quiet_cycles;
reg have_last,dirty;
wire [30:0] source={visible,item,known,value,status,error};
// dirty is registered. A change on the exact admission edge must receive a
// new generation too; otherwise the same key would name two different bodies.
wire new_snapshot=dirty||!have_last||source!=held_source;
wire [34:0] descriptor={held_source[30],held_source[29:27],held_source[9:8],
 held_source[26],held_source[7:0],digits};
reg [19:0] adjusted;
integer i;
always @(*)begin
 adjusted=digits;
 for(i=0;i<5;i=i+1)if(digits[i*4+:4]>=5)adjusted[i*4+:4]=digits[i*4+:4]+4'd3;
end
assign tx_valid=state==OFFER;
assign tx_kind=8'h54;assign tx_count=2;
assign tx_sequence=generation[15:0];assign tx_tag=generation[31:16];assign tx_value=cookie;
assign drained=state==IDLE;
always @(posedge clk)begin
 case(read_address)
  0:read_word<=descriptor[31:0];
  1:read_word<={29'd0,descriptor[34:32]};
  default:read_word<=0;
 endcase
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;held_source<=0;observed_source<=0;cookie<=0;generation<=0;
  binary<=0;digits<=0;step<=0;cooldown<=0;have_last<=0;dirty<=1;exhausted<=0;quiet_cycles<=0;
 end else begin
  if(quiet_cycles<MIN_REFRESH_CYCLES)quiet_cycles<=quiet_cycles+1'b1;
  if(source!=observed_source)begin observed_source<=source;dirty<=1;end
  if(tick_ms&&cooldown!=0)cooldown<=cooldown-1'b1;
  case(state)
   IDLE:if(enabled&&!notice_valid&&namespace_cookie!=0&&(!have_last||(cooldown==0&&quiet_cycles>=MIN_REFRESH_CYCLES&&(visible||dirty))))begin
    if(cookie!=namespace_cookie||generation!=32'hffffffff||!new_snapshot)begin
     if(cookie!=namespace_cookie)begin generation<=1;exhausted<=0;end
     else if(new_snapshot)generation<=generation+1'b1;
     cookie<=namespace_cookie;held_source<=source;binary<=value;digits<=0;step<=0;dirty<=0;state<=FORMAT;
    end else exhausted<=1;
   end
   FORMAT:begin
    digits<={adjusted[18:0],binary[15]};binary<=binary<<1;
    if(step==15)state<=OFFER;else step<=step+1'b1;
   end
   OFFER:if(tx_ready)state<=FLIGHT;
   FLIGHT:if(tx_done)begin state<=IDLE;have_last<=enabled&&!notice_valid;cooldown<=20;quiet_cycles<=0;end
  endcase
  // A granted source remains immutable through the actual physical done,
  // even when F0/F1 arrives on the grant edge. Never release by a timer.
  if(!enabled||notice_valid)begin
   have_last<=0;dirty<=1;cooldown<=0;
   if(state==FORMAT||(state==OFFER&&!tx_ready))state<=IDLE;
  end
 end
end
endmodule
