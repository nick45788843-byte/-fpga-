// 固定图片只读加载器：头校验、整图CRC、完整SDRAM写完成后才开放显示。
module flash_image_reader #(
 parameter CLOCK_HZ=50000000,WIDTH=640,HEIGHT=480,STREAM_HEADER=0,
 parameter [23:0] ASSET_ADDRESS=24'h600000,ASSET_END=24'h700000
)(
 input clk,rst_n,storage_ready,memory_ready,
 output reg bus_start,output reg [23:0] bus_address,output reg [6:0] bus_length,
 input bus_ready,bus_done,bus_error,input [7:0] bus_error_code,
 input byte_valid,input [7:0] data_byte,input [5:0] byte_index,
 output image_req,input image_ack,output reg image_valid,output reg [31:0] image_word,input image_ready,
 output image_abort,input abort_done,write_done_toggle,
 output reg ready,done,error,output reg [7:0] error_code,output reg [31:0] received_words
);
localparam WORDS=WIDTH*HEIGHT,DATA_BYTES=WORDS*2;
localparam WAIT_START=0,HEADER_REQ=1,HEADER_WAIT=2,CHECK_HEADER=3,WRITE_START=4,
 DATA_REQ=5,DATA_WAIT=6,CHECK_DATA=7,WAIT_WRITE=8,ABORT=9,FINISHED=10;
reg [3:0] state;reg [175:0] header;reg header_blank;reg [15:0] header_crc;
reg [31:0] data_crc,expected_crc;
// In the fixed CNPI format all first sixteen bytes are determined by the
// production geometry. Validate them as they arrive instead of retaining a
// 176-bit shift snapshot plus another copy of the expected data CRC.
reg stream_format_bad,stream_geometry_bad;reg [4:0] stream_count;
reg [15:0] stream_check;
function [7:0] expected_prefix;input [4:0] n;begin
 case(n)
  0:expected_prefix=8'h43;1:expected_prefix=8'h4e;2:expected_prefix=8'h50;3:expected_prefix=8'h49;
  4,5:expected_prefix=1;6:expected_prefix=32;7:expected_prefix=0;
  8:expected_prefix=WIDTH[7:0];9:expected_prefix=WIDTH[15:8];
  10:expected_prefix=HEIGHT[7:0];11:expected_prefix=HEIGHT[15:8];
  12:expected_prefix=DATA_BYTES[7:0];13:expected_prefix=DATA_BYTES[15:8];
  14:expected_prefix=DATA_BYTES[23:16];15:expected_prefix=DATA_BYTES[31:24];
  default:expected_prefix=0;
 endcase
end endfunction

localparam BYTE_BITS=$clog2(DATA_BYTES+1),TIMER_BITS=$clog2(CLOCK_HZ*2+1);
reg [BYTE_BITS-1:0] read_bytes;reg [TIMER_BITS-1:0] timer;reg [7:0] low_byte;reg initial_write_toggle;
(* force_ram=1,ram_style="bram" *) reg [15:0] pixels[0:31];
reg [4:0] wp,rp;reg [5:0] queued;reg [1:0] read_state;reg [15:0] ram_word;
wire push=state==DATA_WAIT&&byte_valid&&byte_index[0];
wire pop=image_valid&&image_ready;
wire [15:0] rgb565={data_byte,low_byte};
// 缓冲保存原始16位颜色，同步读出后再展开，减少一块RAM且不改变输出颜色。
wire [31:0] pixel={{ram_word[15:11],ram_word[15:13]},{ram_word[10:5],ram_word[10:9]},{ram_word[4:0],ram_word[4:2]},8'd0};
assign image_req=state==WRITE_START;
assign image_abort=state==ABORT;
function [15:0] crc16;input [15:0] old;input [7:0] v;reg [15:0] c;integer i;
begin c=old^{v,8'd0};for(i=0;i<8;i=i+1)c=c[15]?((c<<1)^16'h1021):(c<<1);crc16=c;end endfunction
function [31:0] crc32;input [31:0] old;input [7:0] v;reg [31:0] c;integer i;
begin c=old^{24'd0,v};for(i=0;i<8;i=i+1)c=c[0]?((c>>1)^32'hedb88320):(c>>1);crc32=c;end endfunction
function [7:0] hb;input [175:0] h;input [4:0] n;begin hb=h[175-{n,3'b000}-:8];end endfunction
wire [15:0] hwidth={hb(header,9),hb(header,8)},hheight={hb(header,11),hb(header,10)};
wire [31:0] hbytes={hb(header,15),hb(header,14),hb(header,13),hb(header,12)};
wire [31:0] hcrc={hb(header,19),hb(header,18),hb(header,17),hb(header,16)};
wire [15:0] hcheck={hb(header,21),hb(header,20)};
task fail;input [7:0] code;begin error<=1;error_code<=code;ready<=0;image_valid<=0;read_state<=0;queued<=0;state<=ABORT;end endtask
always @(posedge clk)begin
 if(push)pixels[wp]<=rgb565;
 if(read_state==1)ram_word<=pixels[rp];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=WAIT_START;bus_start<=0;bus_address<=ASSET_ADDRESS;bus_length<=32;header<=0;header_blank<=1;header_crc<=16'hffff;
  data_crc<=32'hffffffff;expected_crc<=0;read_bytes<=0;timer<=0;low_byte<=0;initial_write_toggle<=0;
  stream_format_bad<=0;stream_geometry_bad<=0;stream_count<=0;stream_check<=0;
  ready<=0;done<=0;error<=0;error_code<=0;received_words<=0;wp<=0;rp<=0;queued<=0;read_state<=0;image_valid<=0;image_word<=0;
 end else begin
  bus_start<=0;done<=0;
  if(byte_valid||pop||bus_done||image_ack)timer<=0;
  else if(state!=WAIT_START&&state!=FINISHED&&state!=ABORT&&timer<CLOCK_HZ*2)timer<=timer+1'b1;
  if(push)begin wp<=wp+1'b1;received_words<=received_words+1'b1;end
  if(pop)begin image_valid<=0;rp<=rp+1'b1;read_state<=0;end
  case({push,pop})2'b10:queued<=queued+1'b1;2'b01:queued<=queued-1'b1;default:queued<=queued;endcase
  if(!image_valid)case(read_state)
   0:if(queued!=0)read_state<=1;
   1:read_state<=2;
   2:begin image_word<=pixel;image_valid<=1;read_state<=3;end
   default:begin end
  endcase
  case(state)
   WAIT_START:if(storage_ready&&memory_ready)begin state<=HEADER_REQ;timer<=0;end
   HEADER_REQ:if(bus_ready)begin bus_address<=ASSET_ADDRESS;bus_length<=32;bus_start<=1;state<=HEADER_WAIT;end
   HEADER_WAIT:begin
    if(byte_valid)begin
     if(!STREAM_HEADER&&byte_index<22)header<={header[167:0],data_byte};
     if(STREAM_HEADER)begin
      if(byte_index<22)begin
       if(byte_index!=stream_count)stream_format_bad<=1;
       stream_count<=stream_count+1'b1;
      end
      if(byte_index<8&&data_byte!=expected_prefix(byte_index))stream_format_bad<=1;
      if(byte_index>=8&&byte_index<16&&data_byte!=expected_prefix(byte_index))stream_geometry_bad<=1;
      if(byte_index>=16&&byte_index<20)expected_crc<={data_byte,expected_crc[31:8]};
      if(byte_index==20)stream_check[7:0]<=data_byte;
      if(byte_index==21)stream_check[15:8]<=data_byte;
     end
     if(data_byte!=8'hff)header_blank<=0;
     if(byte_index<20)header_crc<=crc16(header_crc,data_byte);
    end
    if(bus_done)begin if(bus_error)begin error<=1;error_code<=8'h95;state<=FINISHED;done<=1;end else state<=CHECK_HEADER;end
   end
   CHECK_HEADER:begin
    if(header_blank)begin error<=1;error_code<=8'h90;state<=FINISHED;done<=1;end
    else if((STREAM_HEADER?(stream_format_bad||stream_count!=22):(header[175:144]!=32'h434e5049||hb(header,4)!=1||hb(header,5)!=1||{hb(header,7),hb(header,6)}!=32))||header_crc!=(STREAM_HEADER?stream_check:hcheck))begin error<=1;error_code<=8'h91;state<=FINISHED;done<=1;end
    else if(STREAM_HEADER?(stream_geometry_bad||WIDTH>65535||HEIGHT>65535||{1'b0,ASSET_ADDRESS}+32+DATA_BYTES>{1'b0,ASSET_END}):(hwidth!=WIDTH||hheight!=HEIGHT||hbytes!=DATA_BYTES||{1'b0,ASSET_ADDRESS}+32+hbytes>{1'b0,ASSET_END}))begin error<=1;error_code<=8'h92;state<=FINISHED;done<=1;end
    else begin if(!STREAM_HEADER)expected_crc<=hcrc;initial_write_toggle<=write_done_toggle;state<=WRITE_START;end
   end
   WRITE_START:if(image_ack)state<=DATA_REQ;
   DATA_REQ:if(queued==0&&!image_valid&&read_state==0&&bus_ready)begin
    bus_address<=ASSET_ADDRESS+32+read_bytes;bus_length<=DATA_BYTES-read_bytes>64?64:DATA_BYTES-read_bytes;bus_start<=1;state<=DATA_WAIT;wp<=0;rp<=0;
   end
   DATA_WAIT:begin
    if(byte_valid)begin data_crc<=crc32(data_crc,data_byte);if(!byte_index[0])low_byte<=data_byte;read_bytes<=read_bytes+1'b1;end
    if(bus_done)begin if(bus_error)fail(8'h95);else if(read_bytes+ (byte_valid?1:0)==DATA_BYTES)state<=CHECK_DATA;else state<=DATA_REQ;end
   end
   CHECK_DATA:if(received_words!=WORDS||~data_crc!=expected_crc)fail(8'h93);else state<=WAIT_WRITE;
   WAIT_WRITE:if(queued==0&&!image_valid&&write_done_toggle!=initial_write_toggle)begin ready<=1;done<=1;state<=FINISHED;end
   ABORT:if(abort_done)begin done<=1;state<=FINISHED;end
   default:begin end
  endcase
  if(state!=WAIT_START&&state!=FINISHED&&state!=ABORT&&timer>=CLOCK_HZ*2-1)begin
   if(state<WRITE_START)begin error<=1;error_code<=8'h94;done<=1;state<=FINISHED;end else fail(8'h94);
  end
 end
end
endmodule
