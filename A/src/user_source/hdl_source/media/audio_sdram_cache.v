// 64字分批写入SDRAM并预取输出；缓存范围独立于四幅图像，支持有限区域循环流播。
// 时钟域FIFO放在模块外；此处所有信号均在mem_clk域。输出前必须预留整批空间。
module audio_sdram_cache #(parameter CLOCK_HZ=50000000,ADDRESS_BITS=21,BUFFER_WORDS=524288,AUDIO_BEGIN=1228800)(
 input clk,rst_n,start,cancel,input [31:0] total_frames,
 input input_valid,output input_ready,input [31:0] input_data,input input_last,
 input [9:0] output_space,output output_valid,output [32:0] output_data,
 output reg active,load_complete,queue_complete,output reg [7:0] error_code,
 output memory_request,input memory_ready,memory_grant,memory_done,core_busy,
 output memory_finish,memory_abort,
 output mem_rd_en,output [ADDRESS_BITS-1:0] mem_rd_addr,output mem_wr_en,output [ADDRESS_BITS-1:0] mem_wr_addr,output [31:0] mem_wr_data,
 input mem_rd_valid,input [31:0] mem_rd_data
);
localparam BLOCKS=BUFFER_WORDS/64,POINTER_BITS=$clog2(BLOCKS);
reg [31:0] expected_frames,accepted_frames,write_blocks,read_blocks;reg [6:0] fill;
reg block_ready,padding,eof,closing,job_read,job_start;
reg [31:0] staging[0:63];reg [31:0] staging_data;wire [5:0] staging_address;
wire job_busy,job_done,job_aborted,returned;wire [7:0] job_error;wire [31:0] returned_data;wire [5:0] returned_index;
wire room=write_blocks-read_blocks<BLOCKS;
assign input_ready=active && !closing && !cancel && !error_code && !eof && !padding && !block_ready && fill<64;
wire accept=input_valid && input_ready;
wire [31:0] returning_frame=(read_blocks<<6)+returned_index;
assign output_valid=returned && active && !closing && !cancel && !error_code && returning_frame<expected_frames;
assign output_data={returning_frame==expected_frames-1'b1,returned_data};
wire [ADDRESS_BITS-1:0] target=AUDIO_BEGIN+((job_read?read_blocks[POINTER_BITS-1:0]:write_blocks[POINTER_BITS-1:0])<<6);
audio_memory_transfer #(.CLOCK_HZ(CLOCK_HZ),.ADDRESS_BITS(ADDRESS_BITS),.AUDIO_BEGIN(AUDIO_BEGIN),.AUDIO_END(AUDIO_BEGIN+BUFFER_WORDS)) transfer(
 .clk(clk),.rst_n(rst_n),.start(job_start),.cancel(cancel || closing),.read_operation(job_read),.base_address(target),
 .busy(job_busy),.done(job_done),.aborted(job_aborted),.error_code(job_error),.request_valid(memory_request),.request_ready(memory_ready),.grant(memory_grant),.router_done(memory_done),.core_busy(core_busy),
 .finish_request(memory_finish),.abort_request(memory_abort),.buffer_address(staging_address),.buffer_data(staging_data),
 .mem_rd_en(mem_rd_en),.mem_rd_addr(mem_rd_addr),.mem_wr_en(mem_wr_en),.mem_wr_addr(mem_wr_addr),.mem_wr_data(mem_wr_data),
 .mem_rd_valid(mem_rd_valid),.mem_rd_data(mem_rd_data),.output_valid(returned),.output_data(returned_data),.output_index(returned_index));
always @(posedge clk)begin
 staging_data<=staging[staging_address];
 if(accept)staging[fill[5:0]]<=input_data;
 else if(padding && fill<64)staging[fill[5:0]]<=0;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin active<=0;load_complete<=0;queue_complete<=0;error_code<=0;expected_frames<=0;accepted_frames<=0;write_blocks<=0;read_blocks<=0;fill<=0;block_ready<=0;padding<=0;eof<=0;closing<=0;job_read<=0;job_start<=0;end
 else begin
  job_start<=0;
  if(start && !active && !job_busy)begin
   active<=total_frames!=0;error_code<=total_frames==0?8'hb3:0;load_complete<=0;queue_complete<=0;expected_frames<=total_frames;accepted_frames<=0;
   write_blocks<=0;read_blocks<=0;fill<=0;block_ready<=0;padding<=0;eof<=0;closing<=0;
  end else if(cancel && active && !closing)closing<=1;
  else if(active)begin
   if(accept)begin
    accepted_frames<=accepted_frames+1'b1;fill<=fill+1'b1;
    if(fill==63)block_ready<=1;
    if(input_last)begin
     eof<=1;
     if(accepted_frames+1!=expected_frames)begin error_code<=8'hb3;closing<=1;end
     else if(fill<63)padding<=1;
    end else if(accepted_frames+1>=expected_frames)begin error_code<=8'hb3;closing<=1;end
   end else if(padding && fill<64)begin fill<=fill+1'b1;if(fill==63)begin padding<=0;block_ready<=1;end end
   if(job_done)begin
    if(job_error || job_aborted)begin if(job_error!=0)error_code<=job_error;closing<=1;end
    else if(job_read)begin
     read_blocks<=read_blocks+1'b1;
     if((read_blocks+1'b1)*64>=expected_frames)queue_complete<=1;
    end else begin
     write_blocks<=write_blocks+1'b1;block_ready<=0;fill<=0;
     if(eof)load_complete<=1;
    end
   end else if(!job_busy && !job_start && !closing)begin
    if(output_space>=64 && read_blocks<write_blocks && !queue_complete)begin job_read<=1;job_start<=1;end
    else if(block_ready && room)begin job_read<=0;job_start<=1;end
   end
   if(closing && !job_busy && !job_start)begin active<=0;block_ready<=0;padding<=0;end
  end
 end
end
endmodule
