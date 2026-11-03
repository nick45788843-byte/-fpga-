// B端分拍计算256种输入颜色；两个系数共用逐位除法，两级颜色运算共用一乘法器。
// 与原A image_adjust的Q8舍入/饱和语义一致。独立模块，尚未作为板上集成功能交付。
module b_colour_curve(input clk,rst_n,start,input [7:0] brightness,contrast,
 input [31:0] token,output busy,output reg done,error,output reg [31:0] result_token,
 output reg valid,input ready,output reg [7:0] index,data);
localparam IDLE=0,DIVIDE=1,LOAD_X=2,CONTRAST=3,BRIGHT=4,HOLD=5;
reg [2:0] state;reg divide_contrast;reg [7:0] held_contrast;
reg [15:0] numerator,quotient;reg [7:0] remainder;reg [3:0] divide_bit;
reg [9:0] bgain,cgain;reg signed [9:0] multiplicand;reg signed [10:0] multiplier;
wire signed [20:0] product=multiplicand*multiplier;
wire [7:0] trial={remainder[6:0],numerator[15]};
wire [15:0] next_quotient={quotient[14:0],trial>=8'd100};
assign busy=state!=IDLE;
function [7:0] clip;input signed [20:0] value;reg signed [20:0] q;
begin q=(value+21'sd128)>>>8;clip=q<0?0:q>255?255:q[7:0];end endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;divide_contrast<=0;held_contrast<=0;numerator<=0;quotient<=0;remainder<=0;divide_bit<=0;bgain<=256;cgain<=256;multiplicand<=0;multiplier<=0;done<=0;error<=0;result_token<=0;valid<=0;index<=0;data<=0;end
 else begin
  done<=0;
  case(state)
   IDLE:if(start)begin
    result_token<=token;error<=0;index<=0;valid<=0;
    if(brightness>200||contrast>200)begin error<=1;done<=1;end
    else begin held_contrast<=contrast;numerator<={brightness,8'd0}+16'd50;quotient<=0;remainder<=0;divide_bit<=15;divide_contrast<=0;state<=DIVIDE;end
   end
   DIVIDE:begin
    numerator<=numerator<<1;quotient<=next_quotient;remainder<=trial>=100?trial-8'd100:trial;
    if(divide_bit==0)begin
     if(!divide_contrast)begin bgain<=next_quotient[9:0];numerator<={held_contrast,8'd0}+16'd50;quotient<=0;remainder<=0;divide_bit<=15;divide_contrast<=1;end
     else begin cgain<=next_quotient[9:0];state<=LOAD_X;end
    end else divide_bit<=divide_bit-1'b1;
   end
   LOAD_X:begin multiplicand<=$signed({2'b0,index})-10'sd128;multiplier<=$signed({1'b0,cgain});state<=CONTRAST;end
   CONTRAST:begin multiplicand<=((product+21'sd128)>>>8)+10'sd128;multiplier<=$signed({1'b0,bgain});state<=BRIGHT;end
   BRIGHT:begin data<=clip(product);valid<=1;state<=HOLD;end
   HOLD:if(ready)begin valid<=0;if(index==255)begin done<=1;state<=IDLE;end else begin index<=index+1'b1;state<=LOAD_X;end end
   default:state<=IDLE;
  endcase
 end
end
endmodule
