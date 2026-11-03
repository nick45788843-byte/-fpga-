// 目录->连续文件流->真实WAV解析，发布PCM帧。done只代表排队完成，未代表扬声器播完。
// 此模块尚未校验整文件CRC32；目录CRC与实际fmt/长度/帧数校验不等于素材完整性校验。
module wav_file_reader #(parameter CLOCK_HZ=50000000)(
 input clk,rst_n,start,cancel,input [7:0] select_id,
 output [31:0] total_frames,output metadata_valid,
 output busy,output reg done,aborted,output reg [7:0] error_code,
 output pcm_valid,input pcm_ready,output signed [15:0] pcm_left,pcm_right,output pcm_last,
 output request_valid,input request_ready,output [31:0] request_lba,
 input sector_valid,input [7:0] sector_byte,input sector_done,sector_error
);
localparam IDLE=0,CATALOG=1,START_FILE=2,READ=3,CLOSING=4;
reg [2:0] state;reg catalog_start,file_start,decoder_start,source_cancel,decoder_reset,checked,decoded,route_catalog;
reg [7:0] selected;
reg [31:0] expected_frames,queued_frames;
wire catalog_busy,catalog_done,catalog_valid,catalog_stereo,catalog_req;wire [7:0] catalog_error;
wire [31:0] catalog_lba,catalog_bytes,catalog_crc,frames,catalog_request_lba;
wire source_busy,source_done,source_aborted,bv,br,byte_last,file_req;wire [7:0] source_error,byte_data;wire [31:0] offset,file_request_lba;
wire parser_busy,parser_done,format_valid,parser_stereo,pv,pr,pl;wire [7:0] parser_error;wire [31:0] data_offset,data_bytes;
assign total_frames=expected_frames;
assign metadata_valid=state==READ && checked;
assign busy=state!=IDLE;
assign request_valid=file_req;
assign request_lba=file_request_lba;
wire catalog_active=route_catalog;wire catalog_byte_ready,catalog_source_start,catalog_source_cancel;
wav_catalog_read #(.EXTERNAL_STREAM(1),.CLOCK_HZ(CLOCK_HZ)) catalog(.clk(clk),.rst_n(rst_n),.start(catalog_start),.cancel(source_cancel),.select_id(selected),
 .busy(catalog_busy),.done(catalog_done),.valid(catalog_valid),.error_code(catalog_error),.file_lba(catalog_lba),.file_bytes(catalog_bytes),.file_crc32(catalog_crc),.sample_frames(frames),.stereo(catalog_stereo),
 .request_valid(catalog_req),.request_ready(request_ready && catalog_active),.request_lba(catalog_request_lba),
 .sector_valid(sector_valid && catalog_active),.sector_byte(sector_byte),.sector_done(sector_done && catalog_active),.sector_error(sector_error && catalog_active),
 .external_busy(source_busy),.external_done(source_done),.external_error(source_error),.external_valid(bv && catalog_active),.external_byte(byte_data),
 .external_ready(catalog_byte_ready),.external_start(catalog_source_start),.external_cancel(catalog_source_cancel));
sector_byte_stream #(.CLOCK_HZ(CLOCK_HZ)) source(.clk(clk),.rst_n(rst_n),.start(file_start||catalog_source_start),.cancel(source_cancel||catalog_source_cancel),.first_lba(catalog_active?32'd262144:catalog_lba),.file_bytes(catalog_active?32'd512:catalog_bytes),
 .busy(source_busy),.done(source_done),.aborted(source_aborted),.error_code(source_error),.byte_valid(bv),.byte_ready(catalog_active?catalog_byte_ready:br),.byte_data(byte_data),.byte_last(byte_last),.byte_offset(offset),
 .request_valid(file_req),.request_ready(request_ready),.request_lba(file_request_lba),
 .sector_valid(sector_valid),.sector_byte(sector_byte),.sector_done(sector_done),.sector_error(sector_error));
wav_pcm_decoder parser(.clk(clk),.rst_n(rst_n && !decoder_reset),.start(decoder_start),.file_bytes(catalog_bytes),.byte_valid(bv && !catalog_active),.byte_ready(br),.byte_data(byte_data),
 .stream_end(source_done),.stream_error(source_error!=0),.busy(parser_busy),.done(parser_done),.error_code(parser_error),.format_valid(format_valid),.stereo(parser_stereo),.data_offset(data_offset),.data_bytes(data_bytes),
 .pcm_valid(pv),.pcm_ready(pr),.pcm_left(pcm_left),.pcm_right(pcm_right),.pcm_last(pl));
assign pcm_valid=pv && state==READ && checked && !cancel;
assign pr=pcm_ready && state==READ && checked && !cancel;
assign pcm_last=pl;
wire [33:0] declared_pcm=catalog_stereo?{expected_frames,2'b00}:{1'b0,expected_frames,1'b0};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;done<=0;aborted<=0;error_code<=0;catalog_start<=0;file_start<=0;decoder_start<=0;source_cancel<=0;decoder_reset<=0;checked<=0;decoded<=0;route_catalog<=1;selected<=0;expected_frames<=0;queued_frames<=0;end
 else begin
  done<=0;catalog_start<=0;file_start<=0;decoder_start<=0;source_cancel<=0;decoder_reset<=0;
  if(cancel && state!=IDLE && state!=CLOSING)begin source_cancel<=1;decoder_reset<=1;aborted<=1;state<=CLOSING;end
  else case(state)
   IDLE:if(start && !cancel)begin aborted<=0;error_code<=0;checked<=0;decoded<=0;queued_frames<=0;catalog_start<=1;route_catalog<=1;selected<=select_id;state<=CATALOG;end
   CATALOG:if(catalog_done)begin
    if(!catalog_valid)begin error_code<=catalog_error;state<=CLOSING;end
    else begin expected_frames<=frames;file_start<=1;decoder_start<=1;route_catalog<=0;state<=START_FILE;end
   end
   START_FILE:state<=READ;
   READ:begin
    if(pcm_valid && pcm_ready)queued_frames<=queued_frames+1'b1;
    if(format_valid && !checked)begin
     if(parser_stereo!=catalog_stereo || {2'd0,data_bytes}!=declared_pcm)begin error_code<=8'ha9;source_cancel<=1;decoder_reset<=1;state<=CLOSING;end
     else checked<=1;
    end
    if(parser_error!=0 || source_error!=0)begin error_code<=parser_error!=0?parser_error:8'ha7;source_cancel<=1;decoder_reset<=1;state<=CLOSING;end
    else if(parser_done)begin
     // data后的尾块不再解析，但读请求必须正确退出，不把旧返回交给下一文件。
     decoded<=1;source_cancel<=1;
     if(queued_frames!=expected_frames)error_code<=8'ha6;
     state<=CLOSING;
    end
   end
   CLOSING:if(!catalog_busy && !source_busy)begin done<=1;state<=IDLE;end
   default:begin error_code<=8'ha9;source_cancel<=1;decoder_reset<=1;state<=CLOSING;end
  endcase
 end
end
endmodule
