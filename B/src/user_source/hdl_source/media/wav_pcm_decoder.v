// WAV字节流解析：限定48kHz、16位PCM、单/双声道；不依赖FAT32。
// 额外块按WORD边界跳过；输出样本在ready前保持，解析完成不等于播放完成。
module wav_pcm_decoder #(parameter MAX_HEADER_BYTES=4096)(
 input clk,rst_n,start,input [31:0] file_bytes,
 input byte_valid,output byte_ready,input [7:0] byte_data,input stream_end,stream_error,
 output reg busy,done,output reg [7:0] error_code,
 output reg format_valid,stereo,output reg [31:0] data_offset,data_bytes,
 output reg pcm_valid,input pcm_ready,output reg signed [15:0] pcm_left,pcm_right,output reg pcm_last
);
localparam IDLE=0,RIFF=1,RIFF_CHECK=2,CHUNK=3,CHUNK_CHECK=4,
 FORMAT=5,FORMAT_CHECK=6,SKIP=7,DATA=8,DRAIN=9,FAIL=10,CHUNK_BOUND=11;
reg [3:0] state;reg [4:0] index;
// Lifecycle reuse: after RIFF acceptance, limit is the validated RIFF end.
// chunk_size holds RIFF length until the next complete chunk header.
// chunk_bound remains valid through FORMAT/SKIP; position becomes DATA bytes
// remaining only after data_offset has captured the original cursor.
reg [31:0] limit,position,chunk_name,chunk_size;
reg bad_magic;reg [4:0] bad_format;
reg seen_format;reg [15:0] channels;
reg [1:0] sample_index;reg [7:0] low_byte;reg signed [15:0] pending_left;
wire take=byte_valid && byte_ready;
assign byte_ready=busy && !pcm_valid && (state==RIFF || state==CHUNK || state==FORMAT || state==SKIP || state==DATA);
wire [32:0] riff_bound={1'b0,chunk_size}+33'd8;
// The complete 33-bit padded bound is registered before any limit/type
// decision. Byte credit is held for this one extra header-only clock.
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [32:0] chunk_bound;
function [7:0] riff_expected;input [4:0] n;begin case(n)
0:riff_expected="R";1:riff_expected="I";2,3:riff_expected="F";
8:riff_expected="W";9:riff_expected="A";10:riff_expected="V";default:riff_expected="E";
endcase end endfunction
task fail;input [7:0] code;begin error_code<=code;pcm_valid<=0;format_valid<=0;state<=FAIL;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  chunk_bound<=0;state<=IDLE;index<=0;busy<=0;done<=0;error_code<=0;format_valid<=0;stereo<=0;data_offset<=0;data_bytes<=0;
  pcm_valid<=0;pcm_left<=0;pcm_right<=0;pcm_last<=0;position<=0;limit<=0;
  bad_magic<=0;bad_format<=0;chunk_name<=0;chunk_size<=0;seen_format<=0;
  channels<=0;sample_index<=0;low_byte<=0;pending_left<=0;
 end else begin
  done<=0;if(pcm_valid && pcm_ready)pcm_valid<=0;
  if(start && !busy)begin
   busy<=1;error_code<=0;pcm_valid<=0;pcm_last<=0;format_valid<=0;seen_format<=0;position<=0;index<=0;limit<=file_bytes;
   bad_magic<=0;bad_format<=0;sample_index<=0;data_bytes<=0;data_offset<=0;
   if(file_bytes<12)begin error_code<=8'ha6;state<=FAIL;end else state<=RIFF;
  end else if(state==FAIL)begin busy<=0;done<=1;state<=IDLE;end
  else if(busy && stream_error)fail(8'ha7);
  else if(busy && stream_end && state!=DRAIN && state!=FAIL)fail(8'ha6);
  else case(state)
   RIFF:if(take)begin
    position<=position+1'b1;
    if(index<4)begin if(byte_data!=riff_expected(index))bad_magic<=1;end
    else if(index<8)case(index)
     4:chunk_size[7:0]<=byte_data;5:chunk_size[15:8]<=byte_data;6:chunk_size[23:16]<=byte_data;7:chunk_size[31:24]<=byte_data;
    endcase
    else if(byte_data!=riff_expected(index))bad_magic<=1;
    if(index==11)begin index<=0;state<=RIFF_CHECK;end else index<=index+1'b1;
   end
   RIFF_CHECK:begin
    if(bad_magic)fail(8'ha0);
    else if(chunk_size<4 || riff_bound[32] || riff_bound[31:0]!=limit)fail(8'ha6);
    else begin state<=CHUNK;end
   end
   CHUNK:if(position>=MAX_HEADER_BYTES || position>=limit)fail(8'ha6);
    else if(take)begin
     position<=position+1'b1;
     if(index<4)chunk_name<={chunk_name[23:0],byte_data};
     else case(index)
      4:chunk_size[7:0]<=byte_data;5:chunk_size[15:8]<=byte_data;6:chunk_size[23:16]<=byte_data;7:chunk_size[31:24]<=byte_data;
     endcase
     if(index==7)begin index<=0;state<=CHUNK_BOUND;end else index<=index+1'b1;
    end
   CHUNK_BOUND:begin chunk_bound<={1'b0,position}+{1'b0,chunk_size}+chunk_size[0];state<=CHUNK_CHECK;end
   CHUNK_CHECK:begin
    if(chunk_bound[32] || chunk_bound[31:0]>limit)fail(8'ha6);
    else if(chunk_name=="fmt ")begin
     if(seen_format || (chunk_size!=16 && chunk_size!=18))fail(8'ha1);
     else begin index<=0;state<=FORMAT;end
    end else if(chunk_name=="data")begin
     if(!seen_format)fail(8'ha1);
     else if(chunk_size==0 || (stereo?chunk_size[1:0]!=0:chunk_size[0]!=0))fail(8'ha6);
     else begin data_offset<=position;data_bytes<=chunk_size;position<=chunk_size;sample_index<=0;state<=DATA;format_valid<=1;end
    end else begin state<=chunk_size==0?CHUNK:SKIP;end
   end
   FORMAT:if(take)begin
    position<=position+1'b1;
    // 只需核对固定格式，逐字节记录失败，不保存整套常量字段。
    case(index)
     0:if(byte_data!=1)bad_format[0]<=1;1,16,17:if(byte_data!=0)bad_format[0]<=1;
     2:channels[7:0]<=byte_data;3:channels[15:8]<=byte_data;
     4:if(byte_data!=8'h80)bad_format[2]<=1;5:if(byte_data!=8'hbb)bad_format[2]<=1;
     6,7:if(byte_data!=0)bad_format[2]<=1;
     8,11,13:if(byte_data!=0)bad_format[4]<=1;
     9:if(byte_data!=(channels==2?8'hee:8'h77))bad_format[4]<=1;
     10:if(byte_data!=(channels==2?8'd2:8'd1))bad_format[4]<=1;
     12:if(byte_data!=(channels==2?8'd4:8'd2))bad_format[4]<=1;
     14:if(byte_data!=16)bad_format[3]<=1;15:if(byte_data!=0)bad_format[3]<=1;
    endcase
    if(index+1==chunk_size)begin index<=0;state<=FORMAT_CHECK;end else index<=index+1'b1;
   end
   FORMAT_CHECK:begin
    if(bad_format[0])fail(8'ha1);
    else if(channels!=1 && channels!=2)fail(8'ha2);
    else if(bad_format[2])fail(8'ha3);
    else if(bad_format[3])fail(8'ha4);
    else if(bad_format[4])fail(8'ha5);
    else begin seen_format<=1;stereo<=channels==2;state<=position==chunk_bound[31:0]?CHUNK:SKIP;end
   end
   SKIP:if(take)begin position<=position+1'b1;if(position+1==chunk_bound[31:0])begin index<=0;state<=CHUNK;end end
   DATA:if(take)begin
    position<=position-1'b1;
    case(sample_index)
     0:begin low_byte<=byte_data;sample_index<=1;end
     1:if(stereo)begin pending_left<={byte_data,low_byte};sample_index<=2;end
      else begin pcm_left<={byte_data,low_byte};pcm_right<={byte_data,low_byte};pcm_valid<=1;pcm_last<=position==1;sample_index<=0;end
     2:begin low_byte<=byte_data;sample_index<=3;end
     3:begin pcm_left<=pending_left;pcm_right<={byte_data,low_byte};pcm_valid<=1;pcm_last<=position==1;sample_index<=0;end
    endcase
    if(position==1)state<=DRAIN;
   end
   DRAIN:if(pcm_valid && pcm_ready)begin busy<=0;done<=1;state<=IDLE;end
   FAIL:begin busy<=0;done<=1;state<=IDLE;end
   default:begin end
  endcase
 end
end
endmodule
