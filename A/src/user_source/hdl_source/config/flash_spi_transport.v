// 标准SPI模式，只允许操作用户配置区，不提供整片擦除或状态寄存器写入。
module flash_spi_transport #(
 parameter STREAM_SUPPORT=0,SNAPSHOT_SUPPORT=1,ASSET_READ_SUPPORT=0,ASSET_TIMEOUT_MS=10,
 parameter [23:0] ASSET_BEGIN=24'h600000,ASSET_END=24'h700000,
 parameter CLOCK_HZ=50000000,CLK_DIV=4,TIMEOUT_MS=5000,
 parameter [23:0] AREA_BEGIN=24'h7f0000,AREA_END=24'h800000
)(
 input clk,rst_n,start,input [2:0] operation,input [23:0] address,
 input write_stream_mode,input [7:0] write_stream_byte,output [5:0] write_stream_index,
 input [6:0] length,input [511:0] write_data,
 output reg busy,done,error,output reg [7:0] error_code,
 output reg [511:0] read_data,output reg [7:0] status,
 output reg read_byte_valid,output reg [7:0] read_byte,output reg [5:0] read_index,
 output reg cs_n,output sclk,mosi,input miso,output wp_n,hold_n
);
localparam IDLE=0,SEND=1,WAIT=2,GAP=3,POLL_DELAY=4,PREFETCH=5;
localparam STATUS_CMD=0,STATUS_DATA=1,WREN_CMD=2,MAIN_CMD=3,ADDRESS=4,DATA=5;
localparam MS_CYCLES=CLOCK_HZ/1000,MS_BITS=MS_CYCLES>1?$clog2(MS_CYCLES):1;
reg [2:0] state,phase,after_gap;
reg [2:0] op;
reg [1:0] status_phase;
reg [23:0] addr;
reg [6:0] bytes,position;
reg [1:0] addr_position;
// 记录在事务开始时锁存，之后按字节编号读取，不做512位移位。
// 内容未初始化也不会使用：只有页编程事务才访问，并且先锁存再发送。
reg [511:0] tx_record;reg stream_latched,asset_read_latched;
// 默认保留通用事务快照；专用配置服务可禁用快照，全程使用稳定字节流。
wire tx_stream=STREAM_SUPPORT && (!SNAPSHOT_SUPPORT || stream_latched);
// 同步RAM的地址在字节启动前稳定；换到下一个字节时额外等待一拍。
assign write_stream_index=position[5:0];
reg byte_start;reg [7:0] tx;
wire byte_busy,byte_done;wire [7:0] rx;
reg [MS_BITS-1:0] ms_counter;
reg [$clog2(TIMEOUT_MS+1)-1:0] elapsed_ms;
reg [3:0] gap_counter;
reg [15:0] poll_counter;
wire config_range_ok=address>=AREA_BEGIN && {1'b0,address}+length<={1'b0,AREA_END};
wire asset_range_ok=address>=ASSET_BEGIN&&{1'b0,address}+length<={1'b0,ASSET_END};
wire range_ok=config_range_ok||(ASSET_READ_SUPPORT&&operation==0&&asset_range_ok);
assign wp_n=1'b1;assign hold_n=1'b1;
spi_byte_engine #(.CLK_DIV(CLK_DIV)) u_byte(.clk(clk),.rst_n(rst_n),.start(byte_start),
 .tx_byte(tx),.miso(miso),.busy(byte_busy),.done(byte_done),.rx_byte(rx),.sclk(sclk),.mosi(mosi));
task finish;
 input [7:0] code;
 begin busy<=0;done<=1;error<=code!=0;error_code<=code;cs_n<=1;state<=IDLE;end
endtask
task gap_to;
 input [2:0] next_phase;
 begin cs_n<=1;gap_counter<=0;after_gap<=next_phase;state<=GAP;end
endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  asset_read_latched<=0;stream_latched<=0;state<=IDLE;phase<=0;after_gap<=0;op<=0;status_phase<=0;
  addr<=0;bytes<=0;position<=0;addr_position<=0;
  byte_start<=0;tx<=8'hff;busy<=0;done<=0;error<=0;error_code<=0;
  read_data<=0;read_byte_valid<=0;read_byte<=0;read_index<=0;status<=0;cs_n<=1;ms_counter<=0;elapsed_ms<=0;gap_counter<=0;poll_counter<=0;
 end else begin
  byte_start<=0;done<=0;read_byte_valid<=0;
  if(!busy)begin ms_counter<=0;elapsed_ms<=0;end
  else if(ms_counter==MS_CYCLES-1)begin ms_counter<=0;if(elapsed_ms<TIMEOUT_MS)elapsed_ms<=elapsed_ms+1'b1;end
  else ms_counter<=ms_counter+1'b1;
  if(busy && (elapsed_ms>=TIMEOUT_MS||(asset_read_latched&&elapsed_ms>=ASSET_TIMEOUT_MS)))finish(8'h62);
  else case(state)
   IDLE:if(start)begin
    error<=0;error_code<=0;read_data<=0;
    if(operation>4 || (operation<3 && (!range_ok || (operation!=2 && (length==0 || length>64)) ||
       (operation==1 && {1'b0,address[7:0]}+length>256) ||
       (operation==2 && (address[11:0]!=0 || {1'b0,address}+25'd4096>{1'b0,AREA_END})))))finish(8'h63);
    else begin
     asset_read_latched<=ASSET_READ_SUPPORT&&operation==0&&asset_range_ok;op<=operation;addr<=address;bytes<=operation==3?7'd3:length;
     stream_latched<=STREAM_SUPPORT && write_stream_mode;
     if(SNAPSHOT_SUPPORT && !(STREAM_SUPPORT && write_stream_mode))tx_record<=write_data;position<=0;addr_position<=0;busy<=1;cs_n<=0;
     status_phase<=0;phase<=operation>=3?MAIN_CMD:STATUS_CMD;state<=SEND;
    end
   end
   SEND:if(!byte_busy)begin
    case(phase)
     STATUS_CMD:tx<=8'h05;
     STATUS_DATA:tx<=8'hff;
     WREN_CMD:tx<=8'h06;
     MAIN_CMD:tx<=op==4?8'hab:op==3?8'h9f:op==0?8'h03:op==1?8'h02:8'h20;
     ADDRESS:tx<=addr_position==0?addr[23:16]:addr_position==1?addr[15:8]:addr[7:0];
     DATA:tx<=op==1?(tx_stream?write_stream_byte:tx_record[511-{position[5:0],3'b000} -:8]):8'hff;
    endcase
    byte_start<=1;state<=WAIT;
   end
   WAIT:if(byte_done)case(phase)
    STATUS_CMD:begin phase<=STATUS_DATA;state<=SEND;end
    STATUS_DATA:begin
     status<=rx;
     if(rx[0])begin poll_counter<=0;gap_to(STATUS_CMD);end
     else if(status_phase==2)begin
      if(rx[1])begin poll_counter<=0;gap_to(STATUS_CMD);end
      else finish(0);
     end else if(op==0)gap_to(MAIN_CMD);
     else if(rx[4:2]!=0)finish(8'h64);
     else if(status_phase==1)begin
      if(!rx[1])finish(8'h65);else gap_to(MAIN_CMD);
     end else gap_to(WREN_CMD);
    end
    WREN_CMD:begin status_phase<=1;gap_to(STATUS_CMD);end
    MAIN_CMD:begin
     position<=0;addr_position<=0;
     if(op==4)finish(0);else begin phase<=op==3?DATA:ADDRESS;state<=SEND;end
    end
    ADDRESS:begin
     if(addr_position==2)begin
      if(op==2)begin status_phase<=2;gap_to(STATUS_CMD);end
      else begin phase<=DATA;state<=tx_stream && op==1?PREFETCH:SEND;end
     end else begin addr_position<=addr_position+1'b1;state<=SEND;end
    end
    DATA:begin
     // 普通读取按字节输出；只有三字节器件ID需要装入并行结果。
     if(op==3)read_data<={488'd0,read_data[15:0],rx};
     if(op==0)begin read_byte_valid<=1;read_byte<=rx;read_index<=position[5:0];end
     if(position+1>=bytes)begin
      if(op==1)begin status_phase<=2;gap_to(STATUS_CMD);end
      else finish(0);
     end else begin position<=position+1'b1;state<=tx_stream && op==1?PREFETCH:SEND;end
    end
    default:finish(8'h66);
   endcase
   PREFETCH:state<=SEND;
   GAP:begin
    if(gap_counter>=3)begin
     if(after_gap==STATUS_CMD && status_phase==2)begin state<=POLL_DELAY;poll_counter<=0;end
     else begin cs_n<=0;phase<=after_gap;state<=SEND;end
    end else gap_counter<=gap_counter+1'b1;
   end
   POLL_DELAY:begin
    if(poll_counter>=CLOCK_HZ/100000)begin cs_n<=0;phase<=STATUS_CMD;state<=SEND;end
    else poll_counter<=poll_counter+1'b1;
   end
   default:finish(8'h66);
  endcase
 end
end
endmodule
