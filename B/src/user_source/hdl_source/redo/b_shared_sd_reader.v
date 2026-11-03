// 实际TF驱动只实例化一次；图像旧脉冲接口先锁存，再接valid/ready仲裁。
module b_shared_sd_reader #(parameter CLOCK_HZ=50000000)(
 input clk,rst_n,reload,image_cancel,image_request,input [31:0] image_lba,
 output sd_init_done,image_valid,image_done,image_error,output [7:0] image_byte,
 input audio_request,input [31:0] audio_lba,output audio_ready,input audio_cancel,audio_urgent,
 output audio_valid,audio_done,audio_error,output [7:0] audio_byte,
 output drained,image_drained,output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO
);
reg image_pending,image_failed,image_request_seen;reg [31:0] pending_lba;
wire arb_image_done,arb_image_error,arb_drained,arb_image_drained;
assign drained=arb_drained&&!image_pending&&!image_request;
assign image_drained=arb_image_drained&&!image_pending&&!image_request;
wire image_ready,driver_request,driver_reset,driver_valid,driver_done,driver_error;
wire [31:0] driver_lba;wire [7:0] driver_byte;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin image_pending<=0;pending_lba<=0;image_failed<=0;image_request_seen<=0;end
 else begin
  image_failed<=0;image_request_seen<=image_request;
  if(image_cancel)image_pending<=0;
  else if(reload || driver_reset)begin if(image_pending)image_failed<=1;image_pending<=0;end
  else begin
   if(image_pending && image_ready)image_pending<=0;
   // 图片模块保持请求直到完成；只接收一次上升沿，不能按每拍重新排队。
   if(image_request && !image_request_seen)begin image_pending<=1;pending_lba<=image_lba;end
  end
 end
end
assign image_done=arb_image_done || image_failed;
assign image_error=arb_image_error || image_failed;
b_sd_read_arbiter #(.CLOCK_HZ(CLOCK_HZ)) arbiter(.clk(clk),.rst_n(rst_n),.reset_bus(reload),.sd_init_done(sd_init_done),
 .image_request(image_pending),.image_lba(pending_lba),.image_ready(image_ready),.image_cancel(image_cancel),
 .image_valid(image_valid),.image_byte(image_byte),.image_done(arb_image_done),.image_error(arb_image_error),
 .audio_request(audio_request),.audio_lba(audio_lba),.audio_ready(audio_ready),.audio_cancel(audio_cancel),.audio_urgent(audio_urgent),
 .audio_valid(audio_valid),.audio_byte(audio_byte),.audio_done(audio_done),.audio_error(audio_error),
 .drained(arb_drained),.image_drained(arb_image_drained),.driver_request(driver_request),.driver_lba(driver_lba),.driver_reset(driver_reset),
 .driver_valid(driver_valid),.driver_byte(driver_byte),.driver_done(driver_done),.driver_error(driver_error));
sd_card_top driver(.clk(clk),.rst(driver_reset),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
 .sd_init_done(sd_init_done),.sd_read_error(driver_error),.sd_sec_read(driver_request),.sd_sec_read_addr(driver_lba),
 .sd_sec_read_data(driver_byte),.sd_sec_read_data_valid(driver_valid),.sd_sec_read_end(driver_done),
 .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
endmodule
