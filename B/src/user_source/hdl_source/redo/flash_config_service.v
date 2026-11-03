// 配置日志：每页一条64字节记录，A/B交替追加，CRC读回通过后最后写提交字节。
// LEGACY_TEXT=0: subtitles are CMD22-only, so the legacy custom-text body is
// neither restored nor stored. Records keep the same format (custom=0,
// length 0, zero body with its CRC); old records with a custom body are still
// fully CRC-validated and their parameters restored, the text is dropped.
module flash_config_service #(
 parameter LEGACY_TEXT=1,CLOCK_HZ=50000000,SPI_DIV=4,SAVE_DELAY_MS=2000,GAMMA_ENABLED=0,SCALE_ENABLED=0,FONT_ENABLED=0,FONT_TIMEOUT_MS=5000,JOURNAL_ENABLED=0,
 parameter [71:0] DEFAULT_VALUES=72'h32_32_64_64_00000bb8_00
)(
 input text_query_lock,input [5:0] query_address,output [7:0] query_byte,output [15:0] live_text_descriptor,
 input glyph_we,glyph_bank,input [5:0] glyph_address,input [7:0] glyph_byte,
 input text_update_valid,input [15:0] text_descriptor,
 output reg restore_we,restore_bank,restore_valid,output reg [5:0] restore_address,
 output reg [7:0] restore_glyph,output reg [15:0] restore_descriptor,
 input mode_update_valid,input [2:0] mode_values,output reg [2:0] live_mode,saved_mode,
 input journal_lease,journal_valid,output journal_ready,input [2:0] journal_operation,
 input [23:0] journal_address,input [6:0] journal_length,input [7:0] journal_write_byte,
 output [5:0] journal_write_index,output journal_done,journal_error,
 output [7:0] journal_error_code,output journal_byte_valid,output [7:0] journal_byte,output [5:0] journal_index,
 input clk,rst_n,cfg_update_valid,input [71:0] cfg_values,input save_request,
 output reg ready,load_done,update_rejected,save_done,save_failed,dirty,stored_valid,
 output busy,output can_save,output reg [7:0] error_code,output reg [23:0] jedec_id,
 output reg [71:0] live_values,output reg [31:0] generation,saved_generation,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso,output flash_wp_n,flash_hold_n,
 input gamma_update_valid,input [7:0] gamma_value,output reg [7:0] live_gamma,saved_gamma,
 input scale_update_valid,input [7:0] scale_value,output reg [7:0] live_scale,saved_scale,
 input font_valid,output font_ready,input [23:0] font_address,input [6:0] font_length,
 output font_done,font_error,output [7:0] font_error_code,
 output font_byte_valid,output [7:0] font_byte,output [5:0] font_index
);
localparam DELAY=0,WAKE=1,WAKE_WAIT=2,ID=3,ID_WAIT=4,SCAN=5,SCAN_WAIT=6,
 CHECK=7,READY=8,TARGET=9,TARGET_WAIT=10,ERASE=11,ERASE_WAIT=12,BUILD=13,
 PROGRAM=14,PROGRAM_WAIT=15,VERIFY=16,VERIFY_WAIT=17,COMMIT=18,COMMIT_WAIT=19,
 FINAL_READ=20,FINAL_WAIT=21,
 SCAN_BODY=22,SCAN_BODY_WAIT=23,SCAN_BODY_CHECK=24,SCAN_NEXT=25,
 BODY_CRC_ADDR=26,BODY_CRC_WAIT=27,BODY_CRC_STEP=28,
 BODY_PROGRAM=29,BODY_PROGRAM_WAIT=30,BODY_VERIFY=31,BODY_VERIFY_WAIT=32,
 BOOT_PREPARE=33,RESTORE_ADDR=34,RESTORE_WAIT=35,RESTORE_WRITE=36,BOOT_FINISH=37,
 TARGET_BODY=38,TARGET_BODY_WAIT=39,FINAL_ACCEPT=40,VERIFY_CHECK=41,FINAL_CHECK=42;
localparam MS_CYCLES=CLOCK_HZ/1000,MS_BITS=MS_CYCLES>1?$clog2(MS_CYCLES):1;
reg [5:0] state;
// 最长上电重试等待为CLOCK_HZ/5，按可达最大值确定计数宽度。
localparam DELAY_BITS=CLOCK_HZ/5>0 ? $clog2(CLOCK_HZ/5+1) : 1;
reg [DELAY_BITS-1:0] delay_counter,delay_limit;
reg [1:0] attempts;
reg [7:0] scan_index;
reg [5:0] crc_index;
reg [15:0] crc,record_crc;
reg chip_accepted,scan_complete,unknown_format,corrupt_seen;
reg best_valid,best_group,free_a_found,free_b_found;
reg [23:0] free_a,free_b,target;
reg target_group;
reg [31:0] best_sequence,save_sequence,save_generation;
reg [2:0] best_mode,save_mode;
reg [71:0] best_values,save_values;
reg [7:0] best_gamma,save_gamma;
reg [7:0] best_scale,save_scale;
reg force_save,save_blocked;
localparam QUIET_BITS=SAVE_DELAY_MS>0 ? $clog2(SAVE_DELAY_MS+1) : 1;
reg [QUIET_BITS-1:0] quiet_ms;
reg [MS_BITS-1:0] ms_counter;
wire ms_tick=ms_counter==MS_CYCLES-1;
reg bus_start;reg [2:0] bus_op;reg [23:0] bus_address;reg [6:0] bus_length;
reg [511:0] encoded_record;
reg write_commit;
wire [7:0] header_byte;
wire bus_rx_valid;wire [7:0] bus_rx_byte;wire [5:0] bus_rx_index;
localparam PREFIX_BYTES=SCALE_ENABLED?29:28;
// Keep complete sequence/values/body CRC, but no raw constant/reserved bytes.
// Invalid header fields are remembered separately from the magic predicate.
reg [103:0] prefix_payload;reg [15:0] prefix_body_crc;
reg [2:0] prefix_version,prefix_mode,prefix_gamma,prefix_scale;
reg prefix_custom,prefix_magic_ok,prefix_semantic_ok;reg [6:0] prefix_length;
reg [7:0] read_crc_low,read_crc_high,read_reserved,read_marker;
reg read_blank,read_matches;
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg checked_error,checked_matches;
reg [7:0] checked_code;
wire [7:0] expected_read_byte=(state==FINAL_WAIT && bus_rx_index==63) ? 8'd0 : header_byte;
wire blank_complete=read_blank && (!bus_rx_valid || bus_rx_byte==8'hff);
wire matches_complete=read_matches && (!bus_rx_valid || bus_rx_byte==expected_read_byte);
// 最后一个字节与完成事件同拍到达，不能用尚未更新的提交标记判定格式。
wire [7:0] marker_complete=bus_rx_valid && bus_rx_index==63 ? bus_rx_byte : read_marker;
wire bus_busy,bus_done,bus_error;wire [7:0] bus_error_code,bus_status;
wire [511:0] bus_read;
reg [7:0] text_memory[0:127];reg [7:0] ram_byte;
reg best_custom,best_text_bank,scan_text_bank,save_custom,save_text_bank;
reg [6:0] best_length,save_length;reg [5:0] restore_index;
reg [15:0] live_descriptor,saved_descriptor,save_descriptor,body_crc,save_body_crc;
reg bad_valid;reg [31:0] bad_sequence;
reg restore_pending;
reg body_semantic_ok,body_matches,body_blank;
wire [5:0] bus_stream_index;
// 保存字段已在READY离开前锁存；构建、写入和校验分时共用头部字节选择器。
wire [5:0] header_byte_index=state==BUILD?crc_index:
 (state==VERIFY_WAIT || state==FINAL_WAIT)?bus_rx_index:bus_stream_index;
assign header_byte=get_byte(encoded_record,header_byte_index);
wire body_program_phase=state==BODY_PROGRAM || state==BODY_PROGRAM_WAIT;
wire body_read=state==SCAN_BODY_WAIT || state==BODY_VERIFY_WAIT || state==TARGET_BODY_WAIT;
wire body_crc_phase=state==BODY_CRC_ADDR || state==BODY_CRC_WAIT || state==BODY_CRC_STEP;
wire restore_phase=state==RESTORE_ADDR || state==RESTORE_WAIT || state==RESTORE_WRITE;
assign query_byte=ram_byte;assign live_text_descriptor=live_descriptor;
wire [5:0] ram_address=state==READY?query_address:restore_phase?restore_index:body_crc_phase?crc_index:bus_stream_index;
wire ram_bank=state==READY?live_descriptor[7]:restore_phase?best_text_bank:save_text_bank;
wire [7:0] normalized_byte=save_custom && {1'b0,ram_address}<save_length ? ram_byte:8'd0;
wire [7:0] program_byte=body_program_phase?normalized_byte:write_commit?8'd0:header_byte;
// 收到read_valid时传输器已预取下一地址，尾部补零要按刚返回的read_index判定。
wire [7:0] verify_expected_byte=save_custom && {1'b0,bus_rx_index}<save_length?ram_byte:8'd0;
wire body_matches_complete=body_matches && (!bus_rx_valid || bus_rx_byte==verify_expected_byte);
wire body_blank_complete=body_blank && (!bus_rx_valid || bus_rx_byte==8'hff);
wire [7:0] read_version={5'd0,prefix_version},read_custom={7'd0,prefix_custom},read_length={1'b0,prefix_length};
wire [15:0] read_body_crc=prefix_body_crc;
wire [7:0] read_gamma=(GAMMA_ENABLED||SCALE_ENABLED)&&read_version>=4?{5'd0,prefix_gamma}:8'd2;
wire [7:0] read_scale=SCALE_ENABLED&&read_version==5?{5'd0,prefix_scale}:8'd0;
wire accepted_text=LEGACY_TEXT && !restore_pending && text_update_valid && ready && state==READY && text_descriptor!=live_descriptor &&
 (text_descriptor==0 || (text_descriptor[15:8]!=0 && text_descriptor[6:0]<=64));
// 字符存储无复位；扫描临时银行只有正文CRC与范围均有效才成为最佳记录。
generate if(LEGACY_TEXT)begin:legacy_text_memory
always @(posedge clk)begin
 ram_byte<=text_memory[{ram_bank,ram_address}];
 if(glyph_we)text_memory[{glyph_bank,glyph_address}]<=glyph_byte;
 else if(bus_rx_valid && state==SCAN_BODY_WAIT)text_memory[{scan_text_bank,bus_rx_index}]<=bus_rx_byte;
end
end else begin:no_text_memory
always @(posedge clk)ram_byte<=8'd0;
end endgenerate
assign busy=state!=READY;
function [7:0] get_byte;
 input [511:0] data;input [5:0] index;
 begin get_byte=data[{~index,3'b000} +:8];end
endfunction
function [15:0] crc_byte;
 input [15:0] old;input [7:0] value;reg [15:0] c;integer i;
 begin c=old^{value,8'd0};for(i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
endfunction
// Header/build, body/build and physical read CRC steps are mutually
// exclusive. Use one byte network, preserving both CRC registers and cycles.
wire crc_body_selected=state==BODY_CRC_STEP || body_read;
wire [15:0] crc_step_seed=crc_body_selected?body_crc:crc;
wire [7:0] crc_step_byte=state==BODY_CRC_STEP?normalized_byte:
 state==BUILD?header_byte:bus_rx_byte;
wire [15:0] crc_step_value=crc_byte(crc_step_seed,crc_step_byte);
function values_valid;
 input [71:0] value;
 begin values_valid=value[71:64]<=100 && value[63:56]>=20 && value[63:56]<=100 &&
  value[55:48]<=200 && value[47:40]<=200 && value[39:8]>=1000 && value[39:8]<=60000 && value[7:0]<=1;end
endfunction
// These bits are zero for every value that passes values_valid. Keep the
// complete raw input/header and its rejection/CRC logic; normalize only at
// the original validated write edges. DEFAULT_VALUES paths stay unmodified.
function [71:0] validated_value_bits;
 input [71:0] value;
 begin validated_value_bits={1'b0,value[70:64],1'b0,value[62:40],16'd0,value[23:8],7'd0,value[0]};end
endfunction
function newer;
 input [31:0] candidate,reference;
 begin newer=candidate>reference;end
endfunction
wire [31:0] read_sequence={prefix_payload[79:72],prefix_payload[87:80],prefix_payload[95:88],prefix_payload[103:96]};
wire [71:0] read_values={prefix_payload[71:40],prefix_payload[15:8],prefix_payload[23:16],prefix_payload[31:24],prefix_payload[39:32],prefix_payload[7:0]};
wire [2:0] read_mode=read_version==1?3'd0:prefix_mode;
localparam MAX_VERSION=SCALE_ENABLED?5:GAMMA_ENABLED?4:3;
wire header_ok=prefix_magic_ok && read_version>=1 && read_version<=MAX_VERSION && prefix_semantic_ok &&
 read_marker==0 && crc=={read_crc_high,read_crc_low} && values_valid(read_values);
wire accepted_mode=mode_update_valid && ready && mode_values!=live_mode;
wire accepted_gamma=GAMMA_ENABLED&&gamma_update_valid&&ready&&gamma_value<8&&gamma_value!=live_gamma;
wire accepted_scale=SCALE_ENABLED&&scale_update_valid&&ready&&scale_value<5&&scale_value!=live_scale;
wire accepted_change=accepted_text || accepted_mode || accepted_gamma || accepted_scale || cfg_update_valid && ready && values_valid(cfg_values) && cfg_values!=live_values;
wire save_allowed=chip_accepted && scan_complete && !unknown_format && best_sequence!=32'hffffffff;
assign can_save=save_allowed;
always @(*)begin
 encoded_record={512{1'b1}};
 encoded_record[511:480]=32'h434e4647;
 encoded_record[479:472]=SCALE_ENABLED?8'd5:GAMMA_ENABLED?8'd4:8'd3;encoded_record[471:464]=8'd64;
 encoded_record[447:440]=save_sequence[7:0];encoded_record[439:432]=save_sequence[15:8];
 encoded_record[431:424]=save_sequence[23:16];encoded_record[423:416]=save_sequence[31:24];
 encoded_record[415:384]=save_values[71:40];
 encoded_record[383:376]=save_values[15:8];encoded_record[375:368]=save_values[23:16];
 encoded_record[367:360]=save_values[31:24];encoded_record[359:352]=save_values[39:32];
 encoded_record[351:344]=save_values[7:0];
 encoded_record[343:336]={5'd0,save_mode};
 encoded_record[335:328]={7'd0,save_custom};encoded_record[327:320]={1'b0,save_length};
 encoded_record[319:312]=8'd1;encoded_record[311:304]=save_body_crc[7:0];encoded_record[303:296]=save_body_crc[15:8];
 if(GAMMA_ENABLED||SCALE_ENABLED)encoded_record[295:288]=save_gamma;
 if(SCALE_ENABLED)encoded_record[287:280]=save_scale;
 encoded_record[31:24]=record_crc[7:0];encoded_record[23:16]=record_crc[15:8];
end
wire cfg_lease=!ready || state!=READY;
wire mux_font_ready,mux_font_done,mux_font_error,mux_font_byte_valid;
wire [7:0] mux_font_error_code,mux_font_byte;
wire [5:0] mux_font_index;
assign font_ready=FONT_ENABLED&&mux_font_ready;
assign font_done=mux_font_done;assign font_error=mux_font_error;assign font_error_code=mux_font_error_code;
assign font_byte_valid=mux_font_byte_valid;assign font_byte=mux_font_byte;assign font_index=mux_font_index;
b_flash_font_mux #(.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(SPI_DIV),.TIMEOUT_MS(FONT_TIMEOUT_MS),.JOURNAL_ENABLED(JOURNAL_ENABLED)) u_flash_mux(
 .clk(clk),.rst_n(rst_n),.cfg_lease(cfg_lease),.cfg_start(bus_start),.cfg_operation(bus_op),
 .cfg_address(bus_address),.cfg_length(bus_length),.cfg_write_byte(program_byte),.cfg_write_index(bus_stream_index),
 .cfg_busy(bus_busy),.cfg_done(bus_done),.cfg_error(bus_error),.cfg_error_code(bus_error_code),.cfg_status(bus_status),.cfg_read_data(bus_read),
 .cfg_byte_valid(bus_rx_valid),.cfg_byte(bus_rx_byte),.cfg_index(bus_rx_index),
 .journal_lease(journal_lease),.journal_valid(journal_valid),.journal_ready(journal_ready),.journal_operation(journal_operation),
 .journal_address(journal_address),.journal_length(journal_length),.journal_write_byte(journal_write_byte),.journal_write_index(journal_write_index),
 .journal_done(journal_done),.journal_error(journal_error),.journal_error_code(journal_error_code),
 .journal_byte_valid(journal_byte_valid),.journal_byte(journal_byte),.journal_index(journal_index),
 .font_valid(FONT_ENABLED&&font_valid),.font_ready(mux_font_ready),.font_address(font_address),.font_length(font_length),
 .font_done(mux_font_done),.font_error(mux_font_error),.font_error_code(mux_font_error_code),
 .font_byte_valid(mux_font_byte_valid),.font_byte(mux_font_byte),.font_index(mux_font_index),
 .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),.flash_miso(flash_miso),.flash_wp_n(flash_wp_n),.flash_hold_n(flash_hold_n));
// A successful header read replaces every consumed field. Body reads retain
// them through SCAN_BODY_CHECK. Raw bytes still feed the original CRC, blank
// and exact readback-match paths below, including every reserved byte.
always @(posedge clk)begin
 if(bus_start && bus_op==0 && !body_read)begin prefix_magic_ok<=1;prefix_semantic_ok<=1;end
 if(bus_rx_valid && bus_op==0 && !body_read && bus_rx_index<PREFIX_BYTES)begin
  // Sequence and values occupy one contiguous 13-byte interval. A common
  // shift enable retains all 104 bits without thirteen byte-write decoders.
  if(bus_rx_index>=8 && bus_rx_index<=20)prefix_payload<={prefix_payload[95:0],bus_rx_byte};
  case(bus_rx_index)
   0:begin prefix_magic_ok<=bus_rx_byte==8'h43;prefix_semantic_ok<=1;end
   1:prefix_magic_ok<=prefix_magic_ok && bus_rx_byte==8'h4e;
   2:prefix_magic_ok<=prefix_magic_ok && bus_rx_byte==8'h46;
   3:prefix_magic_ok<=prefix_magic_ok && bus_rx_byte==8'h47;
   // All unsupported versions share the same original invalid/unknown path.
   4:prefix_version<=bus_rx_byte>=1 && bus_rx_byte<=MAX_VERSION?bus_rx_byte[2:0]:3'd0;
   5:prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte==8'd64;
   21:begin
    prefix_mode<=bus_rx_byte[2:0];
    if(read_version!=1)prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte<=7;
   end
   22:begin
    prefix_custom<=bus_rx_byte[0];
    if(read_version>=3)prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte<=1;
   end
   23:begin
    prefix_length<=bus_rx_byte[6:0];
    if(read_version>=3)prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte<=64 && (prefix_custom || bus_rx_byte==0);
   end
   24:if(read_version>=3)prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte==1;
   25:prefix_body_crc[7:0]<=bus_rx_byte;
   26:prefix_body_crc[15:8]<=bus_rx_byte;
   27:begin
    prefix_gamma<=bus_rx_byte[2:0];
    if(read_version>=4)prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte<8;
   end
   28:begin
    prefix_scale<=bus_rx_byte[2:0];
    if(read_version==5)prefix_semantic_ok<=prefix_semantic_ok && bus_rx_byte<5;
   end
  endcase
 end
end
task mark_bad;
 begin if(!bad_valid || newer(read_sequence,bad_sequence))begin bad_valid<=1;bad_sequence<=read_sequence;end end
endtask
 task boot_fail;
 input [7:0] code;
 begin error_code<=code;scan_complete<=0;state<=BOOT_PREPARE;end
endtask
task accept_header;
 begin
  best_valid<=1;best_mode<=read_mode;best_values<=validated_value_bits(read_values);best_gamma<=read_gamma;best_scale<=read_scale;best_sequence<=read_sequence;best_group<=scan_index[7];
 end
endtask
task save_fail;
 input [7:0] code;
 begin save_failed<=1;error_code<=code;save_blocked<=1;quiet_ms<=0;state<=READY;end
endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  bad_valid<=0;bad_sequence<=0;restore_pending<=1;best_custom<=0;best_length<=0;best_text_bank<=0;scan_text_bank<=0;save_custom<=0;save_text_bank<=0;save_length<=0;
  live_descriptor<=0;saved_descriptor<=0;save_descriptor<=0;body_crc<=16'hffff;save_body_crc<=0;
  body_semantic_ok<=1;body_matches<=1;body_blank<=1;restore_index<=0;
  restore_we<=0;restore_bank<=0;restore_valid<=0;restore_address<=0;restore_glyph<=0;restore_descriptor<=0;
  state<=DELAY;delay_counter<=0;delay_limit<=CLOCK_HZ/100;attempts<=0;
  scan_index<=0;crc_index<=0;crc<=16'hffff;record_crc<=0;
  chip_accepted<=0;scan_complete<=0;unknown_format<=0;corrupt_seen<=0;
  live_mode<=0;saved_mode<=0;best_mode<=0;save_mode<=0;best_valid<=0;best_group<=0;free_a_found<=0;free_b_found<=0;
  free_a<=24'h7f0000;free_b<=24'h7f8000;target<=0;target_group<=0;
  best_sequence<=0;save_sequence<=0;save_generation<=0;
  best_values<=DEFAULT_VALUES;save_values<=DEFAULT_VALUES;
  live_gamma<=2;saved_gamma<=2;best_gamma<=2;save_gamma<=2;
  live_scale<=0;saved_scale<=0;best_scale<=0;save_scale<=0;
  force_save<=0;save_blocked<=0;quiet_ms<=0;ms_counter<=0;
  bus_start<=0;bus_op<=0;bus_address<=0;bus_length<=0;write_commit<=0;
  read_crc_low<=0;read_crc_high<=0;read_reserved<=0;read_marker<=0;read_blank<=1;read_matches<=1;checked_error<=0;checked_matches<=0;checked_code<=0;
  ready<=0;load_done<=0;update_rejected<=0;save_done<=0;save_failed<=0;
  dirty<=0;stored_valid<=0;error_code<=0;jedec_id<=0;live_values<=DEFAULT_VALUES;generation<=0;saved_generation<=0;
 end else begin
  restore_we<=0;restore_valid<=0;bus_start<=0;load_done<=0;update_rejected<=0;save_done<=0;save_failed<=0;
  // 每个收到的字节参与校验，不保留整条移位记录；包括保留区的字节也不能漏检。
  if(bus_start && bus_op==0 && body_read)begin body_crc<=16'hffff;body_semantic_ok<=1;body_matches<=1;body_blank<=1;end
  else if(bus_rx_valid && bus_op==0 && body_read)begin
   body_crc<=crc_step_value;
   body_blank<=body_blank && bus_rx_byte==8'hff;
   body_matches<=body_matches && bus_rx_byte==verify_expected_byte;
   if(state==SCAN_BODY_WAIT)body_semantic_ok<=body_semantic_ok &&
    (read_custom!=0 && {2'd0,bus_rx_index}<read_length ? bus_rx_byte<=251 && bus_rx_byte!=95 : bus_rx_byte==0);
  end
  if(bus_start && bus_op==0 && !body_read)begin
   read_crc_low<=0;read_crc_high<=0;read_reserved<=0;read_marker<=0;
   read_blank<=1;read_matches<=1;crc<=16'hffff;
  end else if(bus_rx_valid && bus_op==0 && !body_read)begin
   read_blank<=read_blank && bus_rx_byte==8'hff;
   read_matches<=read_matches && bus_rx_byte==expected_read_byte;
   if(bus_rx_index<60)crc<=crc_step_value;
   case(bus_rx_index)
    60:read_crc_low<=bus_rx_byte;61:read_crc_high<=bus_rx_byte;
    62:read_reserved<=bus_rx_byte;63:read_marker<=bus_rx_byte;
   endcase
  end

  if(ready && text_update_valid && text_descriptor==restore_descriptor)restore_pending<=0;
  if(ms_tick)ms_counter<=0;else ms_counter<=ms_counter+1'b1;
  if(accepted_change)begin if(cfg_update_valid && values_valid(cfg_values))live_values<=validated_value_bits(cfg_values);
   if(accepted_gamma)live_gamma<=gamma_value;
   if(accepted_scale)live_scale<=scale_value;
   if(accepted_text)live_descriptor<=text_descriptor;
   if(accepted_mode)begin live_mode<=mode_values;force_save<=1;end if(generation!=32'hffffffff)generation<=generation+1'b1;dirty<=1;quiet_ms<=0;save_blocked<=0;end
  else if(cfg_update_valid && (!ready || !values_valid(cfg_values)) || GAMMA_ENABLED&&gamma_update_valid&&(!ready||gamma_value>=8)||SCALE_ENABLED&&scale_update_valid&&(!ready||scale_value>=5))update_rejected<=1;
  else if(ms_tick && dirty && quiet_ms<SAVE_DELAY_MS)quiet_ms<=quiet_ms+1'b1;
  if((save_request || mode_update_valid) && ready)begin force_save<=1;save_blocked<=0;end
  case(state)
   DELAY:if(delay_counter>=delay_limit)state<=WAKE;else delay_counter<=delay_counter+1'b1;
   WAKE:begin bus_op<=4;bus_length<=0;bus_start<=1;state<=WAKE_WAIT;end
   WAKE_WAIT:if(bus_done)begin
    if(bus_error)boot_fail(bus_error_code);
    else begin delay_counter<=0;state<=ID;end
   end
   ID:if(delay_counter<CLOCK_HZ/100000)delay_counter<=delay_counter+1'b1;
      else begin bus_op<=3;bus_length<=3;bus_start<=1;state<=ID_WAIT;end
   ID_WAIT:if(bus_done)begin
    jedec_id<=bus_read[23:0];
    if(bus_error)boot_fail(bus_error_code);
    else if(bus_read[23:0]==24'hef4017 || bus_read[23:0]==24'hef3017 || bus_read[23:0]==24'hef4018)begin chip_accepted<=1;scan_index<=0;state<=SCAN;end
    else if(attempts<2)begin attempts<=attempts+1'b1;delay_limit<=CLOCK_HZ/5;delay_counter<=0;state<=DELAY;end
    else boot_fail(8'h61);
   end
   SCAN:begin bus_op<=0;bus_address<={8'h7f,scan_index,8'd0};bus_length<=64;bus_start<=1;state<=SCAN_WAIT;end
   SCAN_WAIT:if(bus_done)begin
    if(bus_error)boot_fail(bus_error_code);
    else begin
     if(blank_complete)begin
      if(!scan_index[7] && !free_a_found)begin free_a<={8'h7f,scan_index,8'd0};free_a_found<=1;end
      if(scan_index[7] && !free_b_found)begin free_b<={8'h7f,scan_index,8'd0};free_b_found<=1;end
     end else corrupt_seen<=1;
     if(prefix_magic_ok && marker_complete==0 && (read_version<1 || read_version>MAX_VERSION))unknown_format<=1;
     state<=CHECK;
    end
   end
   CHECK:begin
    if(header_ok && (!best_valid || newer(read_sequence,best_sequence)))begin
     if(read_version>=3)begin scan_text_bank<=!best_text_bank;state<=SCAN_BODY;end
     else begin accept_header;best_custom<=0;best_length<=0;state<=SCAN_NEXT;end
    end else begin
     if(!header_ok && prefix_magic_ok && read_marker==0 && read_version>=1 && read_version<=MAX_VERSION)mark_bad;
     state<=SCAN_NEXT;
    end
   end
   SCAN_BODY:begin bus_op<=0;bus_address<={8'h7f,scan_index,8'd64};bus_length<=64;bus_start<=1;state<=SCAN_BODY_WAIT;end
   SCAN_BODY_WAIT:if(bus_done)begin if(bus_error)boot_fail(bus_error_code);else state<=SCAN_BODY_CHECK;end
   SCAN_BODY_CHECK:begin
    if(body_crc==read_body_crc && body_semantic_ok)begin
     accept_header;best_custom<=LEGACY_TEXT&&read_custom[0];best_length<=LEGACY_TEXT?read_length[6:0]:7'd0;best_text_bank<=LEGACY_TEXT&&scan_text_bank;
    end else mark_bad;
    state<=SCAN_NEXT;
   end
   SCAN_NEXT:begin
    if(scan_index==255)begin state<=BOOT_PREPARE;scan_complete<=1;end
    else begin scan_index<=scan_index+1'b1;state<=SCAN;end
   end
   BOOT_PREPARE:begin
    live_mode<=best_valid?best_mode:3'd0;saved_mode<=best_valid?best_mode:3'd0;stored_valid<=best_valid;
    live_values<=best_valid?best_values:DEFAULT_VALUES;
    live_gamma<=best_valid?best_gamma:8'd2;saved_gamma<=best_valid?best_gamma:8'd2;
    live_scale<=best_valid?best_scale:8'd0;saved_scale<=best_valid?best_scale:8'd0;
    generation<=best_valid?best_sequence:0;saved_generation<=best_valid?best_sequence:0;
    if(scan_complete && ((!best_valid && corrupt_seen) || (bad_valid && newer(bad_sequence,best_sequence))))error_code<=8'h72;
    if(unknown_format)error_code<=8'h73;
    restore_descriptor<=best_valid && best_custom?{8'd1,best_text_bank,best_length}:16'd0;
    live_descriptor<=best_valid && best_custom?{8'd1,best_text_bank,best_length}:16'd0;
    saved_descriptor<=best_valid && best_custom?{8'd1,best_text_bank,best_length}:16'd0;
    restore_bank<=best_text_bank;restore_index<=0;
    state<=best_valid && best_custom?RESTORE_ADDR:BOOT_FINISH;
   end
   RESTORE_ADDR:state<=RESTORE_WAIT;
   RESTORE_WAIT:state<=RESTORE_WRITE;
   RESTORE_WRITE:begin
    restore_we<=1;restore_address<=restore_index;restore_glyph<=ram_byte;
    if(restore_index==63)state<=BOOT_FINISH;
    else begin restore_index<=restore_index+1'b1;state<=RESTORE_ADDR;end
   end
   BOOT_FINISH:begin ready<=1;load_done<=1;restore_valid<=1;state<=READY;end
   READY:begin
    if(!text_query_lock && !accepted_change && (force_save || (dirty && !save_blocked && quiet_ms>=SAVE_DELAY_MS)))begin
     force_save<=0;
     if(!save_allowed)save_fail(8'h75);
     else if(stored_valid && live_values==best_values && (!GAMMA_ENABLED||live_gamma==saved_gamma) && (!SCALE_ENABLED||live_scale==saved_scale) && live_mode==saved_mode && live_descriptor==saved_descriptor && error_code==0)begin dirty<=0;saved_generation<=generation;save_done<=1;end
     else begin
      save_descriptor<=live_descriptor;save_custom<=live_descriptor[15:8]!=0;
      save_text_bank<=live_descriptor[7];save_length<=live_descriptor[15:8]!=0?live_descriptor[6:0]:7'd0;
      save_mode<=live_mode;save_values<=live_values;save_generation<=generation;save_sequence<=best_sequence+1'b1;
      save_gamma<=live_gamma;
      save_scale<=live_scale;
      target_group<=best_valid?!best_group:1'b0;
      target<=best_valid && !best_group ? free_b : free_a;
      state<=TARGET;
     end
    end
   end
   TARGET:begin bus_op<=0;bus_address<=target;bus_length<=64;bus_start<=1;state<=TARGET_WAIT;end
   TARGET_WAIT:if(bus_done)begin
    if(bus_error)save_fail(bus_error_code);
    else if(!blank_complete)state<=ERASE;
    else state<=TARGET_BODY;
   end
   ERASE:begin
    // 目标始终在另一组，只擦目标所在4KiB扇区，最新有效记录仍保留。
    bus_op<=2;bus_address<={target[23:12],12'd0};bus_length<=0;bus_start<=1;state<=ERASE_WAIT;
   end
   ERASE_WAIT:if(bus_done)begin
    if(bus_error)save_fail(bus_error_code);
    else begin body_crc<=16'hffff;crc_index<=0;state<=BODY_CRC_ADDR;end
   end
   TARGET_BODY:begin bus_op<=0;bus_address<=target+64;bus_length<=64;bus_start<=1;state<=TARGET_BODY_WAIT;end
   TARGET_BODY_WAIT:if(bus_done)begin
    if(bus_error)save_fail(bus_error_code);else if(!body_blank_complete)state<=ERASE;
    else begin body_crc<=16'hffff;crc_index<=0;state<=BODY_CRC_ADDR;end
   end
   BODY_CRC_ADDR:state<=BODY_CRC_WAIT;
   BODY_CRC_WAIT:state<=BODY_CRC_STEP;
   BODY_CRC_STEP:begin
    body_crc<=crc_step_value;
    if(crc_index==63)begin save_body_crc<=crc_step_value;crc<=16'hffff;crc_index<=0;state<=BUILD;end
    else begin crc_index<=crc_index+1'b1;state<=BODY_CRC_ADDR;end
   end
   BODY_PROGRAM:begin bus_op<=1;bus_address<=target+64;bus_length<=64;bus_start<=1;state<=BODY_PROGRAM_WAIT;end
   BODY_PROGRAM_WAIT:if(bus_done)begin if(bus_error)save_fail(bus_error_code);else state<=BODY_VERIFY;end
   BODY_VERIFY:begin bus_op<=0;bus_address<=target+64;bus_length<=64;bus_start<=1;state<=BODY_VERIFY_WAIT;end
   BODY_VERIFY_WAIT:if(bus_done)begin
    if(bus_error)save_fail(bus_error_code);else if(!body_matches_complete)save_fail(8'h74);else state<=PROGRAM;
   end
   BUILD:begin
    crc<=crc_step_value;
    if(crc_index==59)begin record_crc<=crc_step_value;state<=BODY_PROGRAM;end
    else crc_index<=crc_index+1'b1;
   end
   PROGRAM:begin bus_op<=1;bus_address<=target;bus_length<=64;write_commit<=0;bus_start<=1;state<=PROGRAM_WAIT;end
   PROGRAM_WAIT:if(bus_done)begin if(bus_error)save_fail(bus_error_code);else state<=VERIFY;end
   VERIFY:begin bus_op<=0;bus_address<=target;bus_length<=64;bus_start<=1;state<=VERIFY_WAIT;end
   VERIFY_WAIT:if(bus_done)begin
    // 末字节也参与本拍比较；下一拍才决定提交，切断长组合路径。
    checked_error<=bus_error;checked_code<=bus_error_code;checked_matches<=matches_complete;state<=VERIFY_CHECK;
   end
   VERIFY_CHECK:begin
    if(checked_error)save_fail(checked_code);else if(!checked_matches)save_fail(8'h74);else state<=COMMIT;
   end
   COMMIT:begin bus_op<=1;bus_address<=target+24'd63;bus_length<=1;write_commit<=1;bus_start<=1;state<=COMMIT_WAIT;end
   COMMIT_WAIT:if(bus_done)begin if(bus_error)save_fail(bus_error_code);else state<=FINAL_READ;end
   FINAL_READ:begin bus_op<=0;bus_address<=target;bus_length<=64;bus_start<=1;state<=FINAL_WAIT;end
   FINAL_WAIT:if(bus_done)begin
    checked_error<=bus_error;checked_code<=bus_error_code;checked_matches<=matches_complete;state<=FINAL_CHECK;
   end
   FINAL_CHECK:begin
    if(checked_error)save_fail(checked_code);
    else if(!checked_matches)save_fail(8'h74);
    else state<=FINAL_ACCEPT;
   end
   // 校验完成后下一拍确认保存，切断字节选择、比较到dirty使能的长路径。
   FINAL_ACCEPT:begin
     stored_valid<=1;best_valid<=1;best_group<=target_group;best_sequence<=save_sequence;
     saved_descriptor<=save_descriptor;best_custom<=save_custom;best_length<=save_length;best_text_bank<=save_text_bank;
     saved_mode<=save_mode;best_values<=save_values;saved_generation<=save_generation;save_done<=1;error_code<=0;
     saved_gamma<=save_gamma;best_gamma<=save_gamma;
     saved_scale<=save_scale;best_scale<=save_scale;
     if(generation==save_generation && !accepted_change)dirty<=0;
     if(target_group)free_b<=target==24'h7fff00 ? 24'h7f8000 : target+24'd256;
     else free_a<=target==24'h7f7f00 ? 24'h7f0000 : target+24'd256;
     state<=READY;
   end
   default:boot_fail(8'h76);
  endcase
 end
end
endmodule
