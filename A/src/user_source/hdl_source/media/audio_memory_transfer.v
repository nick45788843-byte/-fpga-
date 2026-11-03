// 固定64字读写批次。写入缓存采用同步RAM预取；读启动前下游必须预留64字空间。
// 超时/取消停止发新命令，通过路由层排空后完成，禁止提前把归属交回图像。
module audio_memory_transfer #(parameter CLOCK_HZ=50000000,ADDRESS_BITS=21,TIMEOUT_MS=2,
 parameter AUDIO_BEGIN=1228800,AUDIO_END=1753088)(
 input clk,rst_n,start,cancel,read_operation,input [ADDRESS_BITS-1:0] base_address,
 output busy,output reg done,aborted,output reg [7:0] error_code,
 output request_valid,input request_ready,grant,router_done,core_busy,
 output finish_request,abort_request,
 output reg [5:0] buffer_address,input [31:0] buffer_data,
 output reg mem_rd_en,output reg [ADDRESS_BITS-1:0] mem_rd_addr,
 output reg mem_wr_en,output reg [ADDRESS_BITS-1:0] mem_wr_addr,output reg [31:0] mem_wr_data,
 input mem_rd_valid,input [31:0] mem_rd_data,output output_valid,output [31:0] output_data,output [5:0] output_index
);
localparam IDLE=0,REQUEST=1,WAIT_GRANT=2,PRIME0=3,PRIME1=4,WRITE=5,READ=6,DRAIN=7,FINISH=8,WAIT_RETURN=9,ABORT=10;
localparam DEADLINE=CLOCK_HZ/1000*TIMEOUT_MS;
localparam TIMER_BITS=DEADLINE>1?$clog2(DEADLINE+1):1;
reg [3:0] state,quiet;reg reading;reg [ADDRESS_BITS-1:0] base;reg [6:0] sent,received;reg [TIMER_BITS-1:0] timer;
reg return_seen;
wire [ADDRESS_BITS:0] address_end={1'b0,base_address}+64;
assign busy=state!=IDLE;assign request_valid=state==REQUEST && !cancel;
assign finish_request=state==FINISH;
assign abort_request=state==ABORT || (cancel && state!=IDLE && state!=REQUEST);
assign output_valid=reading && !aborted && !cancel && (state==READ || state==DRAIN) && mem_rd_valid && received<64;
assign output_data=mem_rd_data;assign output_index=received[5:0];
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;return_seen<=0;done<=0;aborted<=0;error_code<=0;reading<=0;base<=0;sent<=0;received<=0;timer<=0;quiet<=0;buffer_address<=0;mem_rd_en<=0;mem_rd_addr<=0;mem_wr_en<=0;mem_wr_addr<=0;mem_wr_data<=0;end
 else begin
  done<=0;mem_rd_en<=0;mem_wr_en<=0;
  // Reservation abort may return before ABORT reaches WAIT_RETURN.
  if(state!=IDLE&&router_done)return_seen<=1;
  if(state!=IDLE && timer<DEADLINE)timer<=timer+1'b1;
  if(output_valid)received<=received+1'b1;
  if(state!=IDLE && state!=ABORT && state!=WAIT_RETURN && (cancel || timer>=DEADLINE))begin
   aborted<=cancel;error_code<=cancel?0:8'hb1;
   if(state==REQUEST)begin done<=1;state<=IDLE;end else state<=ABORT;
  end else case(state)
   IDLE:if(start && !cancel)begin
    return_seen<=0;
    reading<=read_operation;base<=base_address;sent<=0;received<=0;buffer_address<=0;quiet<=0;timer<=0;error_code<=0;aborted<=0;state<=REQUEST;
    if(base_address<AUDIO_BEGIN || address_end>AUDIO_END || base_address[5:0]!=0)begin error_code<=8'hb2;done<=1;state<=IDLE;end
   end
   REQUEST:if(request_ready)state<=WAIT_GRANT;
   WAIT_GRANT:if(grant)state<=reading?READ:PRIME0;
   PRIME0:state<=PRIME1;
   PRIME1:begin buffer_address<=1;state<=WRITE;end
   WRITE:begin
    mem_wr_en<=1;mem_wr_addr<=base+sent;mem_wr_data<=buffer_data;
    if(sent==63)begin quiet<=0;state<=DRAIN;end
    else begin sent<=sent+1'b1;buffer_address<=sent[5:0]+6'd2;end
   end
   READ:begin
    mem_rd_en<=1;mem_rd_addr<=base+sent;
    if(sent==63)begin quiet<=0;state<=DRAIN;end else sent<=sent+1'b1;
   end
   DRAIN:begin
    if(core_busy || mem_rd_valid || mem_rd_en || mem_wr_en)quiet<=0;
    else if(quiet==10 && (!reading || received==64))state<=FINISH;
    else if(quiet<10)quiet<=quiet+1'b1;
   end
   FINISH:state<=WAIT_RETURN;
   ABORT:state<=WAIT_RETURN;
   WAIT_RETURN:if(router_done||return_seen)begin done<=1;state<=IDLE;end
   default:begin error_code<=8'hb1;state<=ABORT;end
  endcase
 end
end
endmodule
