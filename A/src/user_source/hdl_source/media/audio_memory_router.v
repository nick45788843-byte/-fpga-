// 音频预约存储总线：先阻止图像新突发，旧事务排空后才授予，完成后再排空释放。
// 预约阶段不宣称实际访问忙，避免与刷新等待相互锁死。数据返回归属全程固定。
module audio_memory_router #(parameter ADDRESS_BITS=21,DRAIN_CYCLES=10)(
 input clk,rst_n,audio_request,output audio_ready,output audio_grant,
 input audio_finish,audio_abort,frame_busy,core_busy,refresh_block,refresh_valid,
 output frame_block,output audio_access_busy,
 input frame_rd_en,input [ADDRESS_BITS-1:0] frame_rd_addr,
 input frame_wr_en,input [ADDRESS_BITS-1:0] frame_wr_addr,input [31:0] frame_wr_data,input [3:0] frame_wr_mask,
 input audio_rd_en,input [ADDRESS_BITS-1:0] audio_rd_addr,
 input audio_wr_en,input [ADDRESS_BITS-1:0] audio_wr_addr,input [31:0] audio_wr_data,input [3:0] audio_wr_mask,
 output mem_rd_en,output [ADDRESS_BITS-1:0] mem_rd_addr,
 output mem_wr_en,output [ADDRESS_BITS-1:0] mem_wr_addr,output [31:0] mem_wr_data,output [3:0] mem_wr_mask,
 input mem_rd_valid,input [31:0] mem_rd_data,
 output frame_rd_valid,output audio_rd_valid,output [31:0] audio_rd_data,output reg done,aborted
);
localparam IDLE=0,RESERVE=1,ACTIVE=2,TAIL=3;
localparam QUIET_BITS=DRAIN_CYCLES>1?$clog2(DRAIN_CYCLES+1):1;
reg [1:0] state;reg [QUIET_BITS-1:0] quiet;
wire owns_audio=state==ACTIVE || state==TAIL;
assign audio_ready=state==IDLE;
assign audio_grant=state==ACTIVE && !audio_abort;
assign frame_block=state!=IDLE;
assign audio_access_busy=owns_audio;
assign mem_rd_en=owns_audio?(audio_grant && audio_rd_en):frame_rd_en;
assign mem_rd_addr=owns_audio?audio_rd_addr:frame_rd_addr;
assign mem_wr_en=owns_audio?(audio_grant && audio_wr_en):frame_wr_en;
assign mem_wr_addr=owns_audio?audio_wr_addr:frame_wr_addr;
assign mem_wr_data=owns_audio?audio_wr_data:frame_wr_data;
assign mem_wr_mask=owns_audio?audio_wr_mask:frame_wr_mask;
assign frame_rd_valid=mem_rd_valid && !owns_audio;
assign audio_rd_valid=mem_rd_valid && owns_audio && !aborted && !audio_abort;
assign audio_rd_data=mem_rd_data;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;quiet<=0;done<=0;aborted<=0;end
 else begin
  done<=0;
  case(state)
   IDLE:begin quiet<=0;if(audio_request)begin state<=RESERVE;aborted<=0;end end
   RESERVE:begin
    if(audio_abort)begin state<=IDLE;done<=1;aborted<=1;end
    else if(frame_busy || core_busy || frame_rd_en || frame_wr_en || mem_rd_valid || refresh_block || refresh_valid)quiet<=0;
    else if(quiet>=DRAIN_CYCLES)begin quiet<=0;state<=ACTIVE;end
    else quiet<=quiet+1'b1;
   end
   ACTIVE:if(audio_finish || audio_abort)begin state<=TAIL;quiet<=0;if(audio_abort)aborted<=1;end
   TAIL:begin
    if(core_busy || mem_rd_valid || mem_rd_en || mem_wr_en)quiet<=0;
    else if(quiet>=DRAIN_CYCLES)begin state<=IDLE;quiet<=0;done<=1;end
    else quiet<=quiet+1'b1;
   end
   default:begin state<=TAIL;quiet<=0;aborted<=1;end
  endcase
 end
end
endmodule
