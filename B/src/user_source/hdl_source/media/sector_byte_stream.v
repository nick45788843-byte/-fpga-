// 原始连续扇区文件流：先完整接收512字节，再按ready逐字节输出。
// cancel在读事务中只停止交付，等待该事务结束或超时后才允许新start。
module sector_byte_stream #(parameter CLOCK_HZ=50000000,TIMEOUT_MS=500)(
 input clk,rst_n,start,cancel,input [31:0] first_lba,file_bytes,
 output busy,output reg done,aborted,output reg [7:0] error_code,
 output byte_valid,input byte_ready,output [7:0] byte_data,output byte_last,output reg [31:0] byte_offset,
 output request_valid,input request_ready,output reg [31:0] request_lba,
 input sector_valid,input [7:0] sector_byte,input sector_done,sector_error
);
localparam IDLE=0,REQUEST=1,RECEIVE=2,ADDRESS=3,WAIT_RAM=4,EMIT=5,DRAIN=6,FINISH=7;
localparam DEADLINE=CLOCK_HZ/1000*TIMEOUT_MS;
localparam TIMER_BITS=DEADLINE>1?$clog2(DEADLINE+1):1;
reg [2:0] state;reg [TIMER_BITS-1:0] timer;
reg [7:0] memory[0:511];reg [7:0] ram_byte;reg [8:0] read_index;reg [9:0] receive_count;
reg [31:0] remaining;
wire [32:0] sectors=({1'b0,file_bytes}+33'd511)>>9;
wire [32:0] last_lba={1'b0,first_lba}+sectors-1'b1;
assign busy=state!=IDLE;
assign byte_valid=state==EMIT && !cancel;
assign byte_data=ram_byte;assign byte_last=remaining==1;
assign request_valid=state==REQUEST && !cancel;
always @(posedge clk)begin
 ram_byte<=memory[read_index];
 if(state==RECEIVE && sector_valid && receive_count<512)memory[receive_count[8:0]]<=sector_byte;
end
task fail;begin error_code<=8'ha7;state<=FINISH;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;done<=0;aborted<=0;error_code<=0;timer<=0;remaining<=0;request_lba<=0;read_index<=0;receive_count<=0;byte_offset<=0;
 end else begin
  done<=0;
  if(state==REQUEST || state==RECEIVE || state==DRAIN)begin if(timer<DEADLINE)timer<=timer+1'b1;end else timer<=0;
  if(cancel && state!=IDLE && state!=FINISH && state!=DRAIN)begin
   aborted<=1;
   if(state==RECEIVE && !sector_done && !sector_error && timer<DEADLINE)state<=DRAIN;
   else state<=FINISH;
  end else case(state)
   IDLE:if(start && !cancel)begin
    error_code<=0;aborted<=0;byte_offset<=0;remaining<=file_bytes;request_lba<=first_lba;timer<=0;
    if(file_bytes==0)state<=FINISH;
    else if(last_lba[32])fail();else state<=REQUEST;
   end
   REQUEST:if(timer>=DEADLINE)fail();else if(request_ready)begin receive_count<=0;timer<=0;state<=RECEIVE;end
   RECEIVE:begin
    if(sector_valid && receive_count<513)receive_count<=receive_count+1'b1;
    if(sector_error || timer>=DEADLINE)fail();
    else if(sector_done)begin
     if({1'b0,receive_count}+sector_valid!=11'd512)fail();
     else begin read_index<=0;state<=ADDRESS;end
    end
   end
   ADDRESS:state<=WAIT_RAM;
   WAIT_RAM:state<=EMIT;
   EMIT:if(byte_ready)begin
    remaining<=remaining-1'b1;byte_offset<=byte_offset+1'b1;
    if(remaining==1)state<=FINISH;
    else if(read_index==511)begin request_lba<=request_lba+1'b1;timer<=0;state<=REQUEST;end
    else begin read_index<=read_index+1'b1;state<=ADDRESS;end
   end
   DRAIN:if(sector_done || sector_error || timer>=DEADLINE)state<=FINISH;
   FINISH:begin done<=1;state<=IDLE;end
   default:fail();
  endcase
 end
end
endmodule
