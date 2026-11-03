// A executes B's table. The gamma identity is committed with the real frame ACK.
module a_colour_lut #(parameter CLOCK_HZ=50000000,GAMMA_ENABLED=0)(
 input cfg_clk,cfg_rst_n,start,cancel,input [31:0] token,input [7:0] brightness,contrast,input [15:0] expected_crc,
 input byte_valid,input [7:0] byte_index,byte_data,output ready,output reg done,error,output reg [7:0] error_code,
 output byte_ready,output reg applied_valid,output reg [31:0] applied_token,output reg [15:0] applied_style,
 input video_clk,video_rst_n,hs,vs,de,input [23:0] rgb,input bypass,
 output reg ohs,ovs,ode,output reg [23:0] out_rgb,input [7:0] gamma,output reg [7:0] applied_gamma);
(* force_ram=1,ram_style="bram" *) reg [7:0] red_table[0:511],green_table[0:511],blue_table[0:511];
reg receiving,in_flight,known_bank,write_bank;reg [8:0] received;reg [15:0] crc,required_crc;
reg [31:0] held_token;reg [15:0] held_style;reg [7:0] held_gamma;
localparam TIMER_BITS=$clog2(CLOCK_HZ/2+1);reg [TIMER_BITS-1:0] timer;
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg [51:0] held_descriptor;
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg request_toggle,ever_sent,ack_toggle;
(* async_reg=1,preserve=1 *) reg [1:0] ack_sync,valid_sync;
(* async_reg=1,preserve=1 *) reg [2:0] request_sync;reg [1:0] sent_sync;
reg active_bank,mapped_valid,last_vs;
wire local_video_rst_n=video_rst_n&&cfg_rst_n;
wire write_enable=receiving&&!cancel&&byte_valid&&byte_index==received[7:0];
assign ready=!receiving&&!in_flight;
assign byte_ready=receiving;
function [15:0] crc16;input [15:0] old;input [7:0] value;reg [15:0] c;integer i;
begin c=old^{value,8'd0};for(i=0;i<8;i=i+1)c=c[15]?((c<<1)^16'h1021):(c<<1);crc16=c;end endfunction
wire [15:0] next_crc=crc16(crc,byte_data);
always @(posedge cfg_clk)if(write_enable)begin
 red_table[{write_bank,byte_index}]<=byte_data;green_table[{write_bank,byte_index}]<=byte_data;blue_table[{write_bank,byte_index}]<=byte_data;
end
always @(posedge cfg_clk or negedge cfg_rst_n)begin
 if(!cfg_rst_n)begin receiving<=0;in_flight<=0;known_bank<=0;write_bank<=1;received<=0;crc<=16'hffff;required_crc<=0;timer<=0;held_token<=0;held_style<=16'h6464;held_gamma<=2;held_descriptor<=0;request_toggle<=0;ever_sent<=0;ack_sync<=0;valid_sync<=0;done<=0;error<=0;error_code<=0;applied_valid<=0;applied_token<=0;applied_style<=16'h6464;applied_gamma<=2;end
 else begin
  done<=0;ack_sync<={ack_sync[0],ack_toggle};valid_sync<={valid_sync[0],mapped_valid};
  if(!valid_sync[1])applied_valid<=0;
  if(start&&ready)begin
   error<=0;error_code<=0;
   if(brightness>200||contrast>200||GAMMA_ENABLED&&gamma>=8)begin error<=1;error_code<=8'he1;done<=1;end
   else begin receiving<=1;write_bank<=!known_bank;received<=0;crc<=16'hffff;required_crc<=expected_crc;held_token<=token;held_style<={brightness,contrast};held_gamma<=GAMMA_ENABLED?gamma:8'd2;timer<=0;end
  end
  if(receiving&&!cancel)begin
   if(byte_valid)begin
    timer<=0;
    if(byte_index!=received[7:0])begin receiving<=0;error<=1;error_code<=8'he2;done<=1;end
    else begin
     crc<=next_crc;received<=received+1'b1;
     if(received==255)begin
      receiving<=0;
      if(next_crc!=required_crc)begin error<=1;error_code<=8'he3;done<=1;end
      else begin held_descriptor<={write_bank,held_gamma[2:0],held_token,held_style};request_toggle<=!request_toggle;ever_sent<=1;in_flight<=1;end
     end
    end
   end else if(timer>=CLOCK_HZ/2-1)begin receiving<=0;error<=1;error_code<=8'he4;done<=1;end
   else timer<=timer+1'b1;
  end
  if(in_flight&&valid_sync[1]&&ack_sync[1]==request_toggle)begin
   known_bank<=held_descriptor[51];applied_token<=held_descriptor[47:16];applied_style<=held_descriptor[15:0];applied_gamma<={5'd0,held_descriptor[50:48]};applied_valid<=1;in_flight<=0;done<=1;
  end
  else if(!in_flight&&ever_sent&&valid_sync[1]&&ack_sync[1]==request_toggle)begin
   known_bank<=held_descriptor[51];applied_token<=held_descriptor[47:16];applied_style<=held_descriptor[15:0];applied_gamma<={5'd0,held_descriptor[50:48]};applied_valid<=1;
  end
  if(cancel&&receiving)begin receiving<=0;error<=1;error_code<=8'he5;done<=1;end
 end
end
always @(posedge video_clk or negedge local_video_rst_n)begin
 if(!local_video_rst_n)begin request_sync<=0;sent_sync<=0;ack_toggle<=0;active_bank<=0;mapped_valid<=0;last_vs<=0;end
 else begin
  request_sync<={request_sync[1:0],request_toggle};sent_sync<={sent_sync[0],ever_sent};last_vs<=vs;
  if(!sent_sync[1])begin mapped_valid<=0;ack_toggle<=0;active_bank<=0;end
  else if(vs&&!last_vs&&(request_sync[2]!=ack_toggle||!mapped_valid))begin active_bank<=held_descriptor[51];mapped_valid<=1;ack_toggle<=request_sync[2];end
 end
end
reg [7:0] red,green,blue;reg [23:0] looked,raw0,raw1;reg [1:0] ph,pv,pd,pb;
always @(posedge video_clk)begin
 red<=red_table[{active_bank,rgb[23:16]}];green<=green_table[{active_bank,rgb[15:8]}];blue<=blue_table[{active_bank,rgb[7:0]}];
end
always @(posedge video_clk or negedge local_video_rst_n)begin
 if(!local_video_rst_n)begin looked<=0;raw0<=0;raw1<=0;ph<=0;pv<=0;pd<=0;pb<=3;ohs<=0;ovs<=0;ode<=0;out_rgb<=0;end
 else begin
  looked<={red,green,blue};raw0<=rgb;raw1<=raw0;ph<={ph[0],hs};pv<={pv[0],vs};pd<={pd[0],de};pb<={pb[0],bypass||!mapped_valid};
  ohs<=ph[1];ovs<=pv[1];ode<=pd[1];out_rgb<=pb[1]?raw1:looked;
 end
end
endmodule
