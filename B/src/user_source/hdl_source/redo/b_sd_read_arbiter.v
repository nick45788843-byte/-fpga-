// 两个读客户端共享一套TF驱动；一个物理事务期间固定归属，不交叉返回。
// 每方保留一个待发请求；正常交替，音频低水位最多连发三块后让图片一块。
module b_sd_read_arbiter #(parameter CLOCK_HZ=50000000,TIMEOUT_MS=500,RESET_CYCLES=32)(
 input clk,rst_n,reset_bus,sd_init_done,
 input image_request,input [31:0] image_lba,output image_ready,input image_cancel,
 output image_valid,output [7:0] image_byte,output reg image_done,image_error,
 input audio_request,input [31:0] audio_lba,output audio_ready,input audio_cancel,audio_urgent,
 output audio_valid,output [7:0] audio_byte,output reg audio_done,audio_error,
 output reg driver_request,output reg [31:0] driver_lba,output driver_reset,
 output drained,image_drained,
 input driver_valid,input [7:0] driver_byte,input driver_done,driver_error
);
localparam IDLE=0,ACTIVE=1,RECOVER=2;
localparam DEADLINE=CLOCK_HZ/1000*TIMEOUT_MS;
localparam TIMER_BITS=DEADLINE>1?$clog2(DEADLINE+1):1;
localparam RESET_BITS=RESET_CYCLES>1?$clog2(RESET_CYCLES+1):1;
reg [1:0] state,urgent_streak;reg pending_image,pending_audio,owner_audio,drop_owner,turn_audio;
reg [31:0] saved_image_lba,saved_audio_lba;
reg [TIMER_BITS-1:0] timer;reg [RESET_BITS-1:0] reset_count;reg [9:0] receive_count;
wire accepting=sd_init_done && state!=RECOVER && !reset_bus &&
 !(state==ACTIVE && (driver_error || timer>=DEADLINE));
assign image_ready=accepting && !pending_image && !image_cancel;
assign audio_ready=accepting && !pending_audio && !audio_cancel;
wire choose_audio=pending_audio && (!pending_image || (audio_urgent && urgent_streak<3) || (!audio_urgent && turn_audio));
assign image_byte=driver_byte;assign audio_byte=driver_byte;
assign image_valid=state==ACTIVE && !owner_audio && !drop_owner && !image_cancel && !reset_bus && driver_valid;
assign audio_valid=state==ACTIVE && owner_audio && !drop_owner && !audio_cancel && !reset_bus && driver_valid;
assign drained=state==IDLE&&!pending_image&&!pending_audio&&!driver_request&&!reset_bus;
// An unrelated audio sector may remain active when an image action finishes.
assign image_drained=state!=RECOVER&&!pending_image&&
 !(state==ACTIVE&&!owner_audio)&&!(driver_request&&!owner_audio)&&!reset_bus;
assign driver_reset=!rst_n || reset_bus || state==RECOVER;
task recover;
 begin
  if((state==ACTIVE && !owner_audio) || pending_image)begin image_done<=1;image_error<=1;end
  if((state==ACTIVE && owner_audio) || pending_audio)begin audio_done<=1;audio_error<=1;end
  pending_image<=0;pending_audio<=0;drop_owner<=0;state<=RECOVER;reset_count<=RESET_CYCLES;timer<=0;
 end
endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;urgent_streak<=0;pending_image<=0;pending_audio<=0;owner_audio<=0;drop_owner<=0;turn_audio<=0;
  saved_image_lba<=0;saved_audio_lba<=0;timer<=0;reset_count<=0;receive_count<=0;
  driver_request<=0;driver_lba<=0;image_done<=0;audio_done<=0;image_error<=0;audio_error<=0;
 end else begin
  driver_request<=0;image_done<=0;audio_done<=0;image_error<=0;audio_error<=0;
  if(image_request && image_ready)begin pending_image<=1;saved_image_lba<=image_lba;end
  if(audio_request && audio_ready)begin pending_audio<=1;saved_audio_lba<=audio_lba;end
  if(image_cancel)begin
   if(pending_image)begin pending_image<=0;image_done<=1;end
   if(state==ACTIVE && !owner_audio)drop_owner<=1;
  end
  if(audio_cancel)begin
   if(pending_audio)begin pending_audio<=0;audio_done<=1;end
   if(state==ACTIVE && owner_audio)drop_owner<=1;
  end
  if(reset_bus)recover();
  else case(state)
   IDLE:if(sd_init_done)begin
    if((pending_audio && !audio_cancel) || (pending_image && !image_cancel))begin
     if((choose_audio && !audio_cancel) || image_cancel)begin
      owner_audio<=1;driver_lba<=saved_audio_lba;pending_audio<=0;turn_audio<=0;
      if(urgent_streak<3)urgent_streak<=urgent_streak+1'b1;
     end else begin
      owner_audio<=0;driver_lba<=saved_image_lba;pending_image<=0;turn_audio<=1;urgent_streak<=0;
     end
     driver_request<=1;drop_owner<=0;receive_count<=0;timer<=0;state<=ACTIVE;
    end
   end
   ACTIVE:begin
    if(timer<DEADLINE)timer<=timer+1'b1;
    if(driver_valid && receive_count<513)receive_count<=receive_count+1'b1;
    if(driver_error || timer>=DEADLINE || !sd_init_done)recover();
    else if(driver_done)begin
     if(owner_audio)begin audio_done<=1;audio_error<=({1'b0,receive_count}+driver_valid!=512);end
     else begin image_done<=1;image_error<=({1'b0,receive_count}+driver_valid!=512);end
     state<=IDLE;drop_owner<=0;
    end
   end
   RECOVER:if(reset_count==0)state<=IDLE;else reset_count<=reset_count-1'b1;
   default:recover();
  endcase
 end
end
endmodule
