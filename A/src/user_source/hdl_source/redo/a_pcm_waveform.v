// Fixed 256 PCM periods / 48 kHz = 5.333 ms, left output channel.
// A only samples/displays actual post-gain PCM. Hysteretic rising trigger avoids
// free-running phase drift; DC/silence uses a bounded 1024-sample trigger timeout.
module a_pcm_waveform(input clk,rst,frame_boundary,input pcm_valid,
 input [23:0] pcm_left,pcm_right,input enabled,pixel_valid,
 input [9:0] x,input [8:0] y,output ink,output [23:0] colour,
 output reg published_valid);
(* force_ram=1,ram_style="bram" *) reg [7:0] samples[0:255];
reg capture_bank,display_bank,complete,capturing,armed,divider;
reg [6:0] capture_index;reg [9:0] trigger_age;
reg [7:0] current_sample,previous_sample;
reg visible,grid;reg [8:0] pixel_y;
wire signed [7:0] amplitude_in=pcm_left[23:16];
wire trigger_now=(armed&&amplitude_in>=0)||trigger_age==255;
wire take_sample=pcm_valid&&!complete&&((!capturing&&trigger_now)||(capturing&&divider));
wire [6:0] address=(x-10'd368)>>1;
always @(posedge clk)begin
 if(!rst&&take_sample)samples[{capture_bank,capture_index}]<=pcm_left[23:16];
 current_sample<=samples[{display_bank,address}];
 previous_sample<=samples[{display_bank,address==0?7'd0:address-1'b1}];
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  capture_bank<=1;display_bank<=0;complete<=0;capturing<=0;armed<=0;divider<=0;
  capture_index<=0;trigger_age<=0;published_valid<=0;visible<=0;pixel_y<=0;grid<=0;
 end else begin
  visible<=enabled&&pixel_valid&&x>=368&&x<624&&y>=360&&y<400;
  pixel_y<=y;grid<=y==336||x[5:0]==0||(y==272||y==304||y==368||y==400);
  if(pcm_valid&&!complete)begin
   if(!capturing)begin
    if(amplitude_in<=-3)armed<=1;
    if(trigger_now)begin capturing<=1;capture_index<=1;divider<=0;end
    else trigger_age<=trigger_age+1'b1;
   end else begin
    divider<=!divider;
    if(divider)begin
     if(capture_index==127)complete<=1;
     else capture_index<=capture_index+1'b1;
    end
   end
  end
  if(frame_boundary&&complete)begin
   display_bank<=capture_bank;capture_bank<=!capture_bank;published_valid<=1;
   capture_index<=0;trigger_age<=0;armed<=0;capturing<=0;divider<=0;complete<=0;
  end
 end
end
wire signed [8:0] a={current_sample[7],current_sample};
wire signed [8:0] b={previous_sample[7],previous_sample};
wire signed [8:0] scaled_a=a>>>3,scaled_b=b>>>3;
wire [8:0] ya=9'd380-scaled_a,yb=9'd380-scaled_b;
wire [8:0] lo=ya<yb?ya:yb,hi=ya>yb?ya:yb;
wire trace=published_valid&&pixel_y>=lo&&pixel_y<=hi;
assign ink=visible&&trace;
assign colour=24'h36e6bb;
endmodule
