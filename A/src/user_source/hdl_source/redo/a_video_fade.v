module a_video_fade(input [23:0] rgb,input [2:0] shift,input bypass,output [23:0] out_rgb);
function [7:0] dim;input [7:0] value;input [2:0] amount;
 begin case(amount)
  0:dim=value;1:dim={1'b0,value[7:1]};2:dim={2'b0,value[7:2]};
  3:dim={3'b0,value[7:3]};default:dim=0;
 endcase end
endfunction
assign out_rgb=bypass?rgb:{dim(rgb[23:16],shift),dim(rgb[15:8],shift),dim(rgb[7:0],shift)};
endmodule
