// CNWA目录：完整扇区、CRC16及所有有效条目通过后，才发布所选文件描述符。
module wav_catalog_read #(parameter EXTERNAL_STREAM=0,CLOCK_HZ=50000000,BASE_LBA=262144)(
 input clk,rst_n,start,cancel,input [7:0] select_id,
 output busy,output reg done,valid,output reg [7:0] error_code,
 output reg [31:0] file_lba,file_bytes,file_crc32,sample_frames,output reg stereo,
 output request_valid,input request_ready,output [31:0] request_lba,
 input sector_valid,input [7:0] sector_byte,input sector_done,sector_error,
 input external_busy,external_done,input [7:0] external_error,input external_valid,input [7:0] external_byte,
 output external_ready,external_start,external_cancel
);
localparam IDLE=0,START_WAIT=1,BYTE=2,CRC=3,ENTRY=4,CHECK=5,FINISH=6;
reg [2:0] state;reg stream_start,stream_cancel;wire stream_busy,stream_done,stream_aborted,bv,br,last;
wire [7:0] stream_error,byte_data;wire [31:0] stream_offset;
reg [8:0] index;reg [3:0] bit_count,entry_index;reg [4:0] entry_offset;
reg [7:0] wanted,entry_id;reg [3:0] count;reg [1:0] channels;reg [15:0] crc_value,stored_crc;
reg [31:0] lba,length,checksum,frames;reg entry_end,bad,found;
reg [32:0] previous_end;
wire [32:0] sector_count=({1'b0,length}+33'd511)>>9;
wire [32:0] entry_limit={1'b0,lba}+sector_count;
wire [33:0] pcm_size=channels==2?{frames,2'b00}:{1'b0,frames,1'b0};
assign busy=state!=IDLE;assign br=state==BYTE && !cancel;
assign external_ready=br;assign external_start=stream_start;assign external_cancel=stream_cancel;
generate if(EXTERNAL_STREAM)begin: shared_stream
 assign stream_busy=external_busy;assign stream_done=external_done;assign stream_error=external_error;
 assign bv=external_valid;assign byte_data=external_byte;assign request_valid=1'b0;assign request_lba=0;
end else begin: private_stream
sector_byte_stream #(.CLOCK_HZ(CLOCK_HZ)) source(.clk(clk),.rst_n(rst_n),.start(stream_start),.cancel(stream_cancel),
 .first_lba(BASE_LBA),.file_bytes(32'd512),.busy(stream_busy),.done(stream_done),.aborted(stream_aborted),.error_code(stream_error),
 .byte_valid(bv),.byte_ready(br),.byte_data(byte_data),.byte_last(last),.byte_offset(stream_offset),
 .request_valid(request_valid),.request_ready(request_ready),.request_lba(request_lba),
 .sector_valid(sector_valid),.sector_byte(sector_byte),.sector_done(sector_done),.sector_error(sector_error));
end endgenerate
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;stream_start<=0;stream_cancel<=0;done<=0;valid<=0;error_code<=0;index<=0;bit_count<=0;entry_index<=0;entry_offset<=0;
  wanted<=0;count<=0;crc_value<=16'hffff;stored_crc<=0;lba<=0;length<=0;checksum<=0;frames<=0;
  entry_id<=0;channels<=0;entry_end<=0;bad<=0;found<=0;previous_end<=0;file_lba<=0;file_bytes<=0;file_crc32<=0;sample_frames<=0;stereo<=0;
 end else begin
  done<=0;stream_start<=0;stream_cancel<=0;
  if(cancel && state!=IDLE && state!=FINISH)begin stream_cancel<=1;valid<=0;error_code<=0;state<=FINISH;end
  else if(state!=IDLE && state!=START_WAIT && state!=FINISH && stream_error!=0)begin valid<=0;error_code<=8'ha7;state<=FINISH;end
  else case(state)
   IDLE:if(start && !cancel && !stream_busy)begin
    valid<=0;error_code<=0;found<=0;bad<=0;index<=0;entry_offset<=0;entry_index<=0;wanted<=select_id;previous_end<=BASE_LBA+8;
    crc_value<=16'hffff;stored_crc<=0;
    if(select_id<1 || select_id>12)begin error_code<=8'hab;state<=FINISH;end
    else begin stream_start<=1;state<=START_WAIT;end
   end
   START_WAIT:state<=BYTE;
   BYTE:if(bv && br)begin
    entry_end<=0;
    case(index)
     0:if(byte_data!="C")bad<=1;1:if(byte_data!="N")bad<=1;2:if(byte_data!="W")bad<=1;3:if(byte_data!="A")bad<=1;
     4:if(byte_data!=1)bad<=1;5:begin count<=byte_data[3:0];if(byte_data<1||byte_data>12)bad<=1;end
     6:if(byte_data!=0)bad<=1;7:if(byte_data!=2)bad<=1;
     510:stored_crc[7:0]<=byte_data;511:stored_crc[15:8]<=byte_data;
    endcase
    if(index>=16 && index<304 && entry_index<count)begin
     case(entry_offset)
      0:entry_id<=byte_data;1:begin channels<=byte_data[1:0];if(byte_data!=1&&byte_data!=2)bad<=1;end
      2:if(byte_data!=16)bad<=1;3:if(byte_data!=0)bad<=1;
      4:if(byte_data!=8'h80)bad<=1;5:if(byte_data!=8'hbb)bad<=1;6,7:if(byte_data!=0)bad<=1;
      8:lba[7:0]<=byte_data;9:lba[15:8]<=byte_data;10:lba[23:16]<=byte_data;11:lba[31:24]<=byte_data;
      12:length[7:0]<=byte_data;13:length[15:8]<=byte_data;14:length[23:16]<=byte_data;15:length[31:24]<=byte_data;
      16:checksum[7:0]<=byte_data;17:checksum[15:8]<=byte_data;18:checksum[23:16]<=byte_data;19:checksum[31:24]<=byte_data;
      20:frames[7:0]<=byte_data;21:frames[15:8]<=byte_data;22:frames[23:16]<=byte_data;23:frames[31:24]<=byte_data;
     endcase
     if(entry_offset==23)begin entry_offset<=0;entry_end<=1;end else entry_offset<=entry_offset+1'b1;
    end
    index<=index+1'b1;
    if(index<510)begin crc_value<=crc_value^{byte_data,8'd0};bit_count<=0;state<=CRC;end
    else if(index==511)state<=CHECK;
   end
   CRC:begin
    crc_value<=crc_value[15]?(crc_value<<1)^16'h1021:crc_value<<1;
    if(bit_count==7)state<=entry_end?ENTRY:BYTE;else bit_count<=bit_count+1'b1;
   end
   ENTRY:begin
    if(entry_id!={4'd0,entry_index}+1'b1 || (channels!=1 && channels!=2) ||
     length<44 || frames==0 || pcm_size+34'd44>{2'd0,length} || lba[2:0]!=0 || {1'b0,lba}<previous_end ||
     entry_limit>33'h100000000)bad<=1;
    if(entry_id==wanted)begin found<=1;file_lba<=lba;file_bytes<=length;file_crc32<=checksum;sample_frames<=frames;stereo<=channels==2;end
    previous_end<=entry_limit;entry_index<=entry_index+1'b1;state<=BYTE;
   end
   CHECK:begin
    if(count<1 || count>12 || crc_value!=stored_crc || bad || entry_index!=count)error_code<=8'ha9;
    else if(!found)error_code<=8'hab;
    else valid<=1;
    state<=FINISH;
   end
   FINISH:if(!stream_busy)begin done<=1;state<=IDLE;end
   default:begin valid<=0;error_code<=8'ha9;state<=FINISH;end
  endcase
 end
end
endmodule
