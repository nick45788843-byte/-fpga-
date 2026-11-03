module b_sd_card_bmp_control #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter [31:0] SCAN_START_SECTOR=0,SCAN_MAX_SECTOR=131071,
    parameter [3:0] SCAN_TARGET_COUNT=8,
    parameter integer LONG_PRESS_MS=1000,AUTO_PLAY_MS=3000,
    parameter integer STALL_TIMEOUT_MS=500,INIT_TIMEOUT_MS=3000,
    parameter DEVELOPMENT_MODE=0,EXTERNAL_SD=0,ADAPTIVE_IMAGES=0,DYNAMIC_SCAN_COUNT=0,COMPACT_HEADERS=0,REFORMAT_ENABLED=0,OUTPUT_PROGRESS_ENABLED=0
)(
    input external_init,external_valid,external_end,external_error,input [7:0] external_byte,
    output client_request,output [31:0] client_lba,output client_cancel,client_reset,
    input pause,output producer_drained,control_idle,output [3:0] cached_mask,
    input ctrl_next,ctrl_prev,ctrl_reload,ctrl_auto_valid,ctrl_auto_value,ctrl_auto_toggle,force_manual,
    output reg reload_accepted,
    input clk,input rst,input key_next,input key_auto,input key_reload,
    input period_cfg_valid,input [31:0] period_cfg_ms,
    output reg [3:0] state_code,
    output reg diagnostic_valid,output reg [127:0] diagnostic_data,
    input [15:0] bmp_width,input [15:0] bmp_height,
    output reg display_valid,input write_finish_toggle,
    output reg [1:0] write_buf_idx,disp_buf_idx,
    output write_req,input write_req_ack,output write_en,output [31:0] write_data,
    output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
    output [15:0] source_width,source_height,output [31:0] source_pixels,output [12:0] orig_width,orig_height,
    input play_mode_valid,input [1:0] requested_play_mode,
    input program_audio_terminal,input [7:0] program_audio_id,input ctrl_reformat,geometry_suspend,
    output reg [1:0] play_mode,output actual_automatic,input [3:0] catalog_count,output [3:0] discovered_count,
    input output_progress
);
localparam MS_CYCLES=CLK_FREQ_HZ/1000;
localparam MS_BITS=MS_CYCLES>1 ? $clog2(MS_CYCLES) : 1;
localparam WAIT_BITS=$clog2(INIT_TIMEOUT_MS+STALL_TIMEOUT_MS+2);
reg [MS_BITS-1:0] ms_divider;
wire ms_tick=ms_divider==MS_CYCLES-1;
reg [WAIT_BITS-1:0] stall_ms;
wire key_next_press,key_reload_press,key_auto_state,key_next_raw,key_reload_raw;
reg auto_play_en;reg [3:0] img_found_count;
assign actual_automatic=auto_play_en;
assign discovered_count=img_found_count;
reg [5:0] media_reset_count;
// Mirrors the counter's NEXT nonzero state exactly, including reload/pause
// priority. No extra reset-release cycle, no asynchronous assertion removed.
// Separate credit breaks the counter decode -> diagnostic mux STA chain.
(* preserve=1 *) reg media_reset_active;
always @(posedge clk or posedge rst)begin
 if(rst)media_reset_active<=0;
 else if(!pause&&key_reload_press)media_reset_active<=1;
 else media_reset_active<=media_reset_count>1;
end
reg media_offline;
wire geometry_hold=REFORMAT_ENABLED&&geometry_suspend;
wire media_rst=rst || pause || media_offline || media_reset_active;

assign client_cancel=media_rst||geometry_hold;assign client_reset=media_reset_active;
assign key_next_press=key_next_raw||ctrl_next;assign key_reload_press=key_reload_raw||ctrl_reload;
wire sd_init_done,bmp_ready,bmp_load_error,scan_done,scan_found_valid;
wire [7:0] bmp_error_code;
wire [31:0] scan_found_sector;
wire [3:0] scan_found_total;
wire sd_sec_read_error;
wire sd_sec_read,sd_sec_read_data_valid,sd_sec_read_end,bmp_data_wr_en;
wire [31:0] sd_sec_read_addr;
wire [7:0] sd_sec_read_data;
assign client_request=sd_sec_read;assign client_lba=sd_sec_read_addr;
wire [23:0] bmp_data;
reg scan_start_pulse,scan_resume_pulse,load_start_pulse,scan_kicked,scan_paused;
reg gallery_replace_pending;
reg first_image_committed,next_req_pending,prev_req_pending;reg geometry_rebuild_pending,scan_found_d1;
reg [15:0] auto_cnt,active_period_ms,auto_threshold;
reg [15:0] long_press_cnt;
reg long_fired;

reg [2:0] img_idx,load_idx;reg [1:0] pending_buf_idx;
reg [31:0] img_sector[0:7];
reg [1:0] cache_bank[0:7];
reg [7:0] cache_valid,cache_bad;
reg load_busy,load_foreground,load_failed;
reg source_done_seen,source_busy_seen,write_done_seen;
reg [31:0] pixel_count;
wire [31:0] expected_pixels=source_pixels;
reg [2:0] wrfin_tgl_sync;
wire write_finish_pulse=wrfin_tgl_sync[2]^wrfin_tgl_sync[1];
// 操作通知排队，不能覆盖同一拍产生的真实故障。
reg notice_start_pending,notice_complete_pending,notice_mode_pending;
reg completion_reported,auto_mode_seen,notice_mode_auto;
reg reload_cycle;
reg [3:0] notice_cached,notice_total;
reg event_written;
wire [7:0] known_mask=8'hff>>(4'd8-img_found_count);
wire [3:0] cached_count={3'd0,cache_valid[0]}+{3'd0,cache_valid[1]}+{3'd0,cache_valid[2]}+{3'd0,cache_valid[3]}+
 {3'd0,cache_valid[4]}+{3'd0,cache_valid[5]}+{3'd0,cache_valid[6]}+{3'd0,cache_valid[7]};
wire [3:0] preload_target=img_found_count>4 ? 4'd4 : img_found_count;
reg fault_pending;
reg [7:0] last_error_code,last_error_source;
reg [2:0] last_error_image;
reg [31:0] last_error_sector;
assign producer_drained=bmp_ready&&!load_busy&&!write_req&&!load_start_pulse&&!scan_start_pulse&&!scan_resume_pulse&&!scan_found_valid&&!scan_found_d1;
assign control_idle=!load_busy&&!next_req_pending&&!prev_req_pending&&!reload_cycle&&!gallery_replace_pending;
reg [3:0] bank_used;
assign cached_mask=bank_used;
reg [2:0] free_bank;reg [3:0] prefetch_image,eviction_image;
integer i,b;
wire [2:0] navigation_base=load_failed && load_foreground ? load_idx : img_idx;
// 下一/上一目标提前计算，避免导航比较、缓存选择和计时清零同拍串联。
reg [2:0] next_from_current,prev_from_current;
always @(posedge clk or posedge rst)begin
 if(rst)begin next_from_current<=0;prev_from_current<=0;scan_found_d1<=0;end
 else begin next_from_current<=next_index_limited(navigation_base,img_found_count);prev_from_current<=prev_index_limited(navigation_base,img_found_count);scan_found_d1<=scan_found_valid;end
end
// 配置变化时预先计算终点；比较结果打一拍，避免串联图片选择和故障编码。
reg auto_due;
always @(posedge clk or posedge rst)begin
 if(rst)auto_due<=0;
 else auto_due<=auto_cnt>=auto_threshold;
end
// 清零计时的当拍屏蔽旧比较结果，防止连续两拍切换两张。
wire manual_prev_press=ctrl_prev || (!key_auto_state && long_press_cnt>=LONG_PRESS_MS && !long_fired);
// 手动导航停止轮播；串口显式切换轮播模式在同拍时优先于物理按键。
wire manual_navigation=img_found_count!=0 && !ctrl_auto_valid && !ctrl_auto_toggle &&
 (key_next_press || manual_prev_press);
wire auto_tick=auto_play_en && play_mode!=0 && auto_due && auto_cnt!=0 && !manual_navigation;
wire request_switch=next_req_pending || prev_req_pending || auto_tick ||
    (!first_image_committed && img_found_count!=0 && !load_failed);
wire [2:0] wanted_image=geometry_rebuild_pending ? img_idx : next_req_pending ? next_from_current :
    prev_req_pending ? prev_from_current : auto_tick ? next_from_current : 3'd0;
wire waiting=!sd_init_done || load_busy || (scan_kicked && !scan_done && !bmp_ready);
wire wait_expired=ms_tick && !media_rst && waiting &&
    stall_ms>=(!sd_init_done ? INIT_TIMEOUT_MS-1 : STALL_TIMEOUT_MS-1);
assign write_en=bmp_data_wr_en && !media_rst && !geometry_hold;
assign write_data={bmp_data,8'd0};

function [2:0] next_index_limited;
 input [2:0] cur;input [3:0] count;
 begin next_index_limited=count==0 || ({1'b0,cur}+4'd1)>=count ? 3'd0 : cur+3'd1;end
endfunction
function [2:0] prev_index_limited;
 input [2:0] cur;input [3:0] count;
 begin prev_index_limited=count==0 ? 3'd0 : cur==0 ? count-4'd1 : cur-3'd1;end
endfunction
always @(*) begin
 bank_used=0;prefetch_image=8;eviction_image=8;free_bank=4;
 for(b=0;b<8;b=b+1) begin
  if(cache_valid[b]) bank_used[cache_bank[b]]=1;
  if(eviction_image==8 && cache_valid[b] && (!display_valid || cache_bank[b]!=disp_buf_idx))eviction_image=b;
  if(prefetch_image==8 && b<img_found_count && !cache_valid[b] && !cache_bad[b]) prefetch_image=b;
 end
 // 重新读卡时旧缓存失效，但当前显示槽仍被保护，直到新首图提交。
 if(display_valid) bank_used[disp_buf_idx]=1;
 for(b=0;b<4;b=b+1) if(free_bank==4 && !bank_used[b]) free_bank=b;
end
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(20)) u_key_next(
 .clk(clk),.rst(rst),.button_in(key_next),.press_pulse(key_next_raw),.button_stable_out());
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(20)) u_key_auto(
 .clk(clk),.rst(rst),.button_in(key_auto),.press_pulse(),.button_stable_out(key_auto_state));
key_press_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(20)) u_key_reload(
 .clk(clk),.rst(rst),.button_in(key_reload),.press_pulse(key_reload_raw),.button_stable_out());

reg [31:0] load_sector;
task start_load;
 input [2:0] index;input foreground;
 begin
  load_idx<=index;load_sector<=img_sector[index];
  pending_buf_idx<=free_bank[1:0];write_buf_idx<=free_bank[1:0];
  load_foreground<=foreground;load_start_pulse<=1;load_busy<=1;
  load_failed<=0;source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
  pixel_count<=0;auto_cnt<=0;stall_ms<=0;
 end
endtask
task report_error;
 input [7:0] source,code;input [2:0] image;input [31:0] sector;
 begin
  event_written=1;diagnostic_valid<=1;
  fault_pending<=1;last_error_source<=source;last_error_code<=code;
  last_error_image<=image;last_error_sector<=sector;
 end
endtask
task report_recovered;
 input [2:0] image;input [31:0] sector;
 begin
  event_written=1;diagnostic_valid<=1;
  fault_pending<=0;
 end
endtask


// The payload register has one writer. Decode real report causes in parallel
// from the SAME old state as the procedural controller. Later regular reports
// mask earlier ones; the outer failure branches remain mutually exclusive.
// No public stage is added, and an invalid payload keeps its previous value.
wire diag_ext_error=EXTERNAL_SD && external_error && !media_rst;
wire diag_replace_empty=gallery_replace_pending && scan_done && scan_found_total==0;
wire diag_regular=!wait_expired && !diag_ext_error && !bmp_load_error && !diag_replace_empty;
wire diag_catalog_empty=sd_init_done && !media_rst && scan_done && !scan_found_valid &&
 img_found_count==scan_found_total && !load_busy && !completion_reported &&
 (cached_count>=preload_target || ((cache_valid|cache_bad)&known_mask)==known_mask) && img_found_count==0;
wire diag_bad_pixels=load_busy && source_done_seen && pixel_count!=expected_pixels;
wire diag_commit=load_busy && source_done_seen && pixel_count==expected_pixels && write_done_seen;
// A committed, non-writing bank can serve manual navigation while an
// unrelated background prefetch continues. Never preempt a foreground
// load, change geometry, reuse its pending bank, or compete with commit.
wire cached_manual_during_prefetch=load_busy && !load_foreground &&
 !diag_bad_pixels && !diag_commit && !geometry_rebuild_pending && !gallery_replace_pending &&
 (next_req_pending || prev_req_pending) && cache_valid[wanted_image] &&
 cache_bank[wanted_image]!=pending_buf_idx;
wire diag_nav=(!load_busy || cached_manual_during_prefetch) && !(sd_init_done && !scan_kicked && !media_rst) &&
 request_switch && img_found_count!=0 && !scan_found_valid && !scan_found_d1;
wire diag_nav_recover=diag_nav && cache_valid[wanted_image] && fault_pending && last_error_source==3;
wire diag_nav_offline=diag_nav && !cache_valid[wanted_image] && media_offline;
wire diag_commit_recover=diag_commit && fault_pending;
wire diag_commit_dev=diag_commit && !fault_pending && DEVELOPMENT_MODE;
wire diag_key_offline=key_next_press && img_found_count==0 && media_offline &&
 !diag_bad_pixels && !diag_commit_recover && !diag_commit_dev && !diag_nav_recover && !diag_nav_offline;
wire diag_regular_body=diag_regular && !diag_catalog_empty;
wire [10:0] diag_report_cause={
 diag_regular && diag_catalog_empty,
 diag_regular_body && diag_nav_offline,
 diag_regular_body && diag_nav_recover,
 diag_regular_body && diag_commit_dev,
 diag_regular_body && diag_commit_recover,
 diag_regular_body && diag_bad_pixels,
 diag_regular_body && diag_key_offline,
 !wait_expired && !diag_ext_error && !bmp_load_error && diag_replace_empty,
 !wait_expired && !diag_ext_error && bmp_load_error,
 !wait_expired && diag_ext_error,
 wait_expired};
wire diag_real_allowed=!(pause||geometry_hold) && !key_reload_press;
wire [10:0] diag_report_select=diag_report_cause & {11{diag_real_allowed}};
wire diag_any_report=|diag_report_select;
// Notices were outside the pause branch in the original controller. A pause
// may still publish an OLD pending notice; reload suppresses all notices.
wire diag_notice_allowed=!key_reload_press && !diag_any_report;
wire [2:0] diag_notice_select={
 diag_notice_allowed && !notice_start_pending && !notice_complete_pending &&
 notice_mode_pending && auto_mode_seen==auto_play_en,
 diag_notice_allowed && !notice_start_pending && notice_complete_pending,
 diag_notice_allowed && notice_start_pending};
wire [31:0] diag_actual_pixels=load_busy ? pixel_count : 32'd0;
wire [31:0] diag_expected_pixels=load_busy ? expected_pixels : 32'd0;
wire [7:0] diag_load_image={5'd0,load_idx}+8'd1;
wire [7:0] diag_wanted_image={5'd0,wanted_image}+8'd1;
wire [7:0] diag_wait_source=!sd_init_done ? 8'd1 :
 load_busy && (write_req || (source_done_seen && !write_done_seen)) ? 8'd2 : 8'd1;
wire [7:0] diag_wait_code=!sd_init_done ? 8'h41 : load_busy && write_req ? 8'h46 :
 load_busy && source_done_seen && !write_done_seen ? 8'h43 : 8'h42;
wire [31:0] diag_wait_sector=sd_init_done && load_busy &&
 (write_req || (source_done_seen && !write_done_seen)) ? load_sector : sd_sec_read_addr;
wire [7:0] diag_bmp_source=bmp_error_code>=8'h90 ? 8'd1 : 8'd3;
wire [31:0] diag_bmp_sector=bmp_error_code>=8'h90 ? sd_sec_read_addr : load_sector;
wire [127:0] diag_report_word=
 ({128{diag_report_select[0]}} & {8'd1,diag_wait_source,diag_wait_code,diag_load_image,diag_wait_sector,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[1]}} & {8'd1,8'd1,8'h97,diag_load_image,sd_sec_read_addr,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[2]}} & {8'd1,diag_bmp_source,bmp_error_code,diag_load_image,diag_bmp_sector,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[3]}} & {8'd1,8'd1,8'h45,8'd1,32'd0,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[4]}} & {8'd1,8'd1,8'h44,({5'd0,img_idx}+8'd1),32'd0,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[5]}} & {8'd1,8'd3,8'h36,diag_load_image,load_sector,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[6]}} & {8'd2,last_error_source,8'd0,diag_load_image,load_sector,diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[7]}} & {8'd2,8'd3,8'd0,diag_load_image,load_sector,32'd0,32'd0}) |
 ({128{diag_report_select[8]}} & {8'd2,last_error_source,8'd0,diag_wanted_image,img_sector[wanted_image],diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[9]}} & {8'd1,8'd1,8'h44,diag_wanted_image,img_sector[wanted_image],diag_actual_pixels,diag_expected_pixels}) |
 ({128{diag_report_select[10]}} & {8'd1,8'd1,8'h45,8'd1,32'd0,diag_actual_pixels,diag_expected_pixels});
wire [127:0] diag_notice_word=
 ({128{diag_notice_select[0]}} & {8'd4,8'd1,8'h10,8'd0,32'd0,32'd0,32'd0}) |
 ({128{diag_notice_select[1]}} & {8'd4,8'd1,(notice_cached==notice_total ? 8'h11 : 8'h12),
   (display_valid ? ({5'd0,img_idx}+8'd1) : 8'd0),32'd0,{28'd0,notice_cached},{28'd0,notice_total}}) |
 ({128{diag_notice_select[2]}} & {8'd4,8'h10,(notice_mode_auto ? 8'h20 : 8'h21),8'd0,32'd0,32'd0,32'd0});
// CE only: A || (!K && !A && N) == A || (!K && N).
// Payload priority and pending-notice consumption retain their original decode.
wire diag_notice_pending_any=notice_start_pending || notice_complete_pending ||
 (notice_mode_pending && auto_mode_seen==auto_play_en);
// A priority tree chooses payload, but its union does not need priority.
// These predicates are the same old-state events as diag_report_cause.
wire diag_any_cause=wait_expired || diag_ext_error || bmp_load_error ||
 diag_replace_empty || diag_catalog_empty || diag_bad_pixels ||
 diag_commit_recover || diag_commit_dev || diag_nav_recover || diag_nav_offline ||
 (key_next_press && img_found_count==0 && media_offline);
wire diag_payload_write=!key_reload_press &&
 (diag_notice_pending_any || (!(pause||geometry_hold) && diag_any_cause));
always @(posedge clk or posedge rst)begin
 if(rst)diagnostic_data<=0;
 else if(diag_payload_write)diagnostic_data<=diag_report_word | diag_notice_word;
end

always @(posedge clk or posedge rst) begin
 if(rst) begin
  ms_divider<=0;stall_ms<=0;media_reset_count<=0;media_offline<=0;
  wrfin_tgl_sync<=0;scan_start_pulse<=0;scan_resume_pulse<=0;load_start_pulse<=0;
  gallery_replace_pending<=0;scan_kicked<=0;scan_paused<=0;first_image_committed<=0;geometry_rebuild_pending<=0;
  play_mode<=1;auto_play_en<=0;auto_cnt<=0;active_period_ms<=AUTO_PLAY_MS;auto_threshold<=AUTO_PLAY_MS-1;long_press_cnt<=0;long_fired<=0;
  next_req_pending<=0;prev_req_pending<=0;img_found_count<=0;
  img_idx<=0;load_idx<=0;pending_buf_idx<=0;write_buf_idx<=0;disp_buf_idx<=0;
  display_valid<=0;load_busy<=0;load_foreground<=0;load_failed<=0;
  source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;pixel_count<=0;
  cache_valid<=0;cache_bad<=0;load_sector<=0;state_code<=0;
  diagnostic_valid<=0;fault_pending<=0;event_written=0;
  notice_start_pending<=1;notice_complete_pending<=0;notice_mode_pending<=0;
  completion_reported<=0;reload_cycle<=0;reload_accepted<=0;auto_mode_seen<=0;notice_mode_auto<=0;notice_cached<=0;notice_total<=0;
  last_error_code<=0;last_error_source<=3;last_error_image<=0;last_error_sector<=0;
  for(i=0;i<8;i=i+1) begin img_sector[i]<=0;cache_bank[i]<=0;end
 end else begin
  event_written=0;
  diagnostic_valid<=0;scan_start_pulse<=0;scan_resume_pulse<=0;load_start_pulse<=0;
  if(reload_cycle&&scan_start_pulse&&!pause&&!media_rst)reload_accepted<=1;
  wrfin_tgl_sync<={wrfin_tgl_sync[1:0],write_finish_toggle};
  if(ms_tick) ms_divider<=0;else ms_divider<=ms_divider+1'b1;
  if(media_reset_count!=0)media_reset_count<=media_reset_count-1'b1;
  // A credited scaler output is real work even while its input FIFO holds
  // off the next SD sector, e.g. during the top/bottom fit-mode borders.
  // The physical SD arbiter retains its independent transaction deadline.
  if(media_rst || !waiting || sd_sec_read_data_valid || sd_sec_read_end || write_finish_pulse ||
     (OUTPUT_PROGRESS_ENABLED && output_progress))
   stall_ms<=0;
  else if(ms_tick && !wait_expired)stall_ms<=stall_ms+1'b1;
  state_code<=display_valid ? ({1'd0,img_idx}+4'd1) : 4'd0;

  if(REFORMAT_ENABLED&&ctrl_reformat)begin
   geometry_rebuild_pending<=display_valid;
   // Old visible bank remains reserved until a complete replacement commits.
   cache_valid<=0;cache_bad<=0;first_image_committed<=0;load_failed<=0;load_busy<=0;
   source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
   next_req_pending<=0;prev_req_pending<=0;completion_reported<=0;notice_complete_pending<=0;
  end else if(geometry_hold&&!pause)begin
   // Stop only private picture work. The catalog and next scan position stay
   // valid; PCM and the physical shared SD engine keep their own owners.
   if(load_busy)cache_valid[load_idx]<=0;
   load_busy<=0;load_failed<=0;source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;stall_ms<=0;auto_cnt<=0;
   scan_paused<=!scan_done;
   // Consume a report already published before the soft cancel edge.
   if(scan_found_valid)begin
    if(gallery_replace_pending)begin
     gallery_replace_pending<=0;img_sector[0]<=scan_found_sector;img_found_count<=1;
     cache_valid<=0;cache_bad<=0;first_image_committed<=0;geometry_rebuild_pending<=0;load_failed<=0;
    end else begin img_sector[img_found_count[2:0]]<=scan_found_sector;if(img_found_count<8)img_found_count<=img_found_count+1'b1;end
   end
  end else if(pause) begin
   // Private BMP parser resets immediately; the shared physical sector owner
   // remains alive until driver_done/error/recovery and reports its own credit.
   if(load_busy)cache_bad[load_idx]<=1;
   load_busy<=0;load_failed<=load_busy;source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
   next_req_pending<=0;prev_req_pending<=0;auto_cnt<=0;scan_kicked<=0;scan_paused<=0;media_offline<=0;stall_ms<=0;
   gallery_replace_pending<=0;reload_cycle<=0;reload_accepted<=0;completion_reported<=0;notice_complete_pending<=0;
  end else if(key_reload_press) begin
   // 只重启TF服务，不复位SDRAM、HDMI、数码管或诊断队列。
   gallery_replace_pending<=0;media_reset_count<=32;media_offline<=0;scan_kicked<=0;scan_paused<=0;
   notice_start_pending<=1;notice_complete_pending<=0;completion_reported<=0;reload_cycle<=1;reload_accepted<=0;
   // 初始化成功以前保留旧列表与有效缓存，无卡失败仍能继续切换。
   load_busy<=0;load_failed<=0;source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
   // 重读TF不是切换播放模式，保留原来的自动/手动选择。
   next_req_pending<=0;prev_req_pending<=0;auto_cnt<=0;stall_ms<=0;
  end else if(wait_expired) begin
   // 令牌、初始化或写完成等待必须有界；已经提交的缓存不失效。
   media_offline<=1;load_busy<=0;load_failed<=load_busy;reload_cycle<=0;
   source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
   if(load_busy)cache_bad[load_idx]<=1;
   if(!sd_init_done)report_error(8'd1,8'h41,load_idx,sd_sec_read_addr);
   else if(load_busy && write_req)report_error(8'd2,8'h46,load_idx,load_sector);
   else if(load_busy && source_done_seen && !write_done_seen)report_error(8'd2,8'h43,load_idx,load_sector);
   else report_error(8'd1,8'h42,load_idx,sd_sec_read_addr);
  end else if(EXTERNAL_SD && external_error && !media_rst)begin
   media_offline<=1;load_busy<=0;load_failed<=load_busy;reload_cycle<=0;
   if(load_busy)cache_bad[load_idx]<=1;
   source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
   report_error(8'd1,8'h97,load_idx,sd_sec_read_addr);
  end else if(bmp_load_error) begin
   load_busy<=0;load_failed<=1;if(load_busy)cache_bad[load_idx]<=1;reload_cycle<=0;
   source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
   if(bmp_error_code>=8'h90)begin media_offline<=1;gallery_replace_pending<=0;report_error(8'd1,bmp_error_code,load_idx,sd_sec_read_addr);end
   else report_error(8'd3,bmp_error_code,load_idx,load_sector);
  end else if(gallery_replace_pending && scan_done && scan_found_total==0)begin
   // 空扫描是明确的失败结果；旧图库继续可用，不保持未完成的重读状态。
   gallery_replace_pending<=0;media_offline<=1;reload_cycle<=0;load_failed<=1;completion_reported<=1;
   notice_start_pending<=0;notice_complete_pending<=0;
   report_error(8'd1,8'h45,2'd0,32'd0);
  end else begin
   if(key_next_press && img_found_count==0 && media_offline)report_error(8'd1,8'h44,img_idx,32'd0);
   if(!key_auto_state) begin
    if(ms_tick && long_press_cnt<LONG_PRESS_MS)long_press_cnt<=long_press_cnt+1'b1;
    if(long_press_cnt>=LONG_PRESS_MS && !long_fired)begin
     long_fired<=1;
    end
   end else begin
    if(long_press_cnt!=0 && !long_fired && img_found_count>1)begin auto_play_en<=!auto_play_en;auto_cnt<=0;end
    long_press_cnt<=0;long_fired<=0;
   end
   if(ms_tick && auto_play_en && display_valid && !load_busy && img_found_count>1)begin
    if(!auto_tick)auto_cnt<=auto_cnt+1'b1;
   end
   if(scan_found_valid)begin
    // 挂载完成并找到首个文件，才接受新列表；失败前旧缓存和轮播继续有效。
    if(gallery_replace_pending)begin
     gallery_replace_pending<=0;img_sector[0]<=scan_found_sector;img_found_count<=1;
     cache_valid<=0;cache_bad<=0;first_image_committed<=0;geometry_rebuild_pending<=0;load_failed<=0;next_req_pending<=0;prev_req_pending<=0;
    end else begin
     img_sector[img_found_count[2:0]]<=scan_found_sector;
     if(img_found_count<8)img_found_count<=img_found_count+1'b1;
    end
    scan_paused<=1;
   end
   if(write_en && load_busy)pixel_count<=pixel_count+1'b1;
   if(load_busy && !bmp_ready)source_busy_seen<=1;
   if(load_busy && source_busy_seen && bmp_ready)source_done_seen<=1;
   if(load_busy && write_finish_pulse)write_done_seen<=1;

   if(load_busy && source_done_seen && pixel_count!=expected_pixels) begin
    load_busy<=0;load_failed<=1;if(load_busy)cache_bad[load_idx]<=1;reload_cycle<=0;
    report_error(8'd3,8'h36,load_idx,load_sector);
   end else if(load_busy && source_done_seen && write_done_seen)begin
    cache_valid[load_idx]<=1;cache_bank[load_idx]<=pending_buf_idx;
    load_busy<=0;load_failed<=0;
    if(load_foreground)begin
     disp_buf_idx<=pending_buf_idx;img_idx<=load_idx;display_valid<=1;first_image_committed<=1;geometry_rebuild_pending<=0;
    end
    if(fault_pending)report_recovered(load_idx,load_sector);
    else if(DEVELOPMENT_MODE)begin
     event_written=1;diagnostic_valid<=1;
    end
   end else if(cached_manual_during_prefetch && request_switch && img_found_count!=0 &&
               !scan_found_valid && !scan_found_d1)begin
    disp_buf_idx<=cache_bank[wanted_image];img_idx<=wanted_image;display_valid<=1;first_image_committed<=1;
    next_req_pending<=0;prev_req_pending<=0;auto_cnt<=0;
    if(fault_pending && last_error_source==3)report_recovered(wanted_image,img_sector[wanted_image]);
   end else if(!load_busy)begin
    if(sd_init_done && !scan_kicked && !media_rst)begin
     // 确认TF初始化成功后，才进入新一轮扫描与缓存重建。
     gallery_replace_pending<=1;
     load_failed<=0;scan_start_pulse<=1;scan_kicked<=1;
    end else if(request_switch && img_found_count!=0 && !scan_found_valid && !scan_found_d1)begin
     if(cache_valid[wanted_image])begin
      disp_buf_idx<=cache_bank[wanted_image];img_idx<=wanted_image;display_valid<=1;first_image_committed<=1;
      next_req_pending<=0;prev_req_pending<=0;auto_cnt<=0;load_failed<=0;
      if(fault_pending && last_error_source==3)report_recovered(wanted_image,img_sector[wanted_image]);
     end else if(!media_rst && !media_offline && sd_init_done && bmp_ready && free_bank<4 &&
                 !gallery_replace_pending && !scan_start_pulse && !scan_resume_pulse)begin
      // F0 保留旧目录；新扫描脉冲尚未被解析器接收时不能并发启动旧文件。
      start_load(wanted_image,1'b1);next_req_pending<=0;prev_req_pending<=0;
     end else if(!media_offline && bmp_ready && free_bank==4 && eviction_image<8 && !gallery_replace_pending)begin
      // Free one real non-visible slot. The pending target remains queued;
      // its next iteration starts the normal complete-frame transaction.
      cache_valid[eviction_image[2:0]]<=0;
     end else if(media_offline)begin
      // 没缓存的图片不能在拔卡后凭空显示，保留当前画面并结束请求。
      next_req_pending<=0;prev_req_pending<=0;auto_play_en<=0;auto_cnt<=0;
      report_error(8'd1,8'h44,wanted_image,img_sector[wanted_image]);
     end
    end else if(!media_rst && !media_offline && sd_init_done && bmp_ready && first_image_committed && prefetch_image<8 && free_bank<4 &&
                !gallery_replace_pending && !scan_start_pulse && !scan_resume_pulse)begin
     start_load(prefetch_image[2:0],1'b0);
    end else if(!media_rst && !media_offline && sd_init_done && bmp_ready && scan_paused && !scan_done && (first_image_committed || load_failed))begin
     scan_resume_pulse<=1;scan_paused<=0;
    end
   end
   if(sd_init_done && !media_rst && scan_done && !scan_found_valid && img_found_count==scan_found_total && !load_busy && !completion_reported &&
      (cached_count>=preload_target || ((cache_valid|cache_bad)&known_mask)==known_mask))begin
    completion_reported<=1;
    // 只有整轮重读成功才归位到第一张并切回手动；失败不改原模式。
    if(reload_cycle && cache_valid[0] && cached_count>=preload_target)begin
     disp_buf_idx<=cache_bank[0];img_idx<=0;display_valid<=1;
     auto_play_en<=0;auto_cnt<=0;next_req_pending<=0;prev_req_pending<=0;
    end
    reload_cycle<=0;
    if(img_found_count==0)report_error(8'd1,8'h45,2'd0,32'd0);
    else begin
     notice_cached<=cached_count;notice_total<=img_found_count;notice_complete_pending<=1;
    end
   end
  end
  if(auto_mode_seen!=auto_play_en)begin
   auto_mode_seen<=auto_play_en;notice_mode_auto<=auto_play_en;notice_mode_pending<=1;
  end
  // 通知不占错误表。按顺序送入既有事件FIFO，普通换图不生成通知。
  if(!key_reload_press && !event_written)begin
   if(notice_start_pending)begin
    notice_start_pending<=0;diagnostic_valid<=1;
    
   end else if(notice_complete_pending)begin
    notice_complete_pending<=0;diagnostic_valid<=1;
    
   end else if(notice_mode_pending && auto_mode_seen==auto_play_en)begin
    notice_mode_pending<=0;diagnostic_valid<=1;
    
   end
  end

  if(!pause && ctrl_auto_valid)begin auto_play_en<=ctrl_auto_value;auto_cnt<=0;end
  if(!pause && ctrl_auto_toggle)begin auto_play_en<=!auto_play_en;auto_cnt<=0;end
  if(!pause && manual_navigation)begin
   auto_play_en<=0;auto_cnt<=0;
   // 将导航请求保留到加载空闲；本次方向取代尚未执行的反向请求。
   if(key_next_press)begin next_req_pending<=1;prev_req_pending<=0;end
   else begin prev_req_pending<=1;next_req_pending<=0;end
  end
  if(!pause&&play_mode_valid&&requested_play_mode<=2)begin play_mode<=requested_play_mode;auto_cnt<=0;end
  // This terminal came from A's real output consumer, with a unique full UID.
  // File decoding/read-ahead completion never advances a narrated program.
  if(!pause&&play_mode==0&&auto_play_en&&program_audio_terminal&&
     program_audio_id==({5'd0,img_idx}+8'd5))begin next_req_pending<=1;prev_req_pending<=0;auto_cnt<=0;end
  if(force_manual)begin auto_play_en<=0;auto_cnt<=0;long_press_cnt<=0;long_fired<=0;end
  if(period_cfg_valid && period_cfg_ms>=1000 && period_cfg_ms<=60000 && active_period_ms!=period_cfg_ms[15:0])begin
   active_period_ms<=period_cfg_ms[15:0];auto_threshold<=period_cfg_ms[15:0]-16'd1;auto_cnt<=0;
  end
 end
end

b_bmp_adaptive_read #(.ADAPTIVE_ENABLED(ADAPTIVE_IMAGES),.COMPACT_HEADERS(COMPACT_HEADERS),.SOFT_CANCEL_ENABLED(REFORMAT_ENABLED)) bmp_read_m0(
 .clk(clk),.rst(media_rst),.soft_cancel(geometry_hold),.ready(bmp_ready),.load_error(bmp_load_error),.load_error_code(bmp_error_code),
 .scan_start(scan_start_pulse),.scan_resume(scan_resume_pulse),.scan_start_sector(SCAN_START_SECTOR),
 .scan_max_sector(SCAN_MAX_SECTOR),.scan_target_count(DYNAMIC_SCAN_COUNT?catalog_count:SCAN_TARGET_COUNT),
 .scan_done(scan_done),.scan_found_valid(scan_found_valid),.scan_found_sector(scan_found_sector),.scan_found_total(scan_found_total),
 .load_start(load_start_pulse),.load_sector(load_sector),.sd_init_done(sd_init_done),.state_code(),
 .bmp_width(bmp_width),.bmp_height(bmp_height),.write_req(write_req),.write_req_ack(write_req_ack),
 .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),.sd_sec_read_data(sd_sec_read_data),
 .sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
 .bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data),.source_width(source_width),.source_height(source_height),.source_pixels(source_pixels),.orig_width(orig_width),.orig_height(orig_height));
generate if(EXTERNAL_SD)begin: g_shared_sd
 assign sd_init_done=external_init;assign sd_sec_read_data=external_byte;
 assign sd_sec_read_data_valid=external_valid;assign sd_sec_read_end=external_end;assign sd_sec_read_error=external_error;
 assign SD_nCS=1'b1;assign SD_DCLK=1'b0;assign SD_MOSI=1'b1;
end else begin: g_private_sd
sd_card_top sd_card_top_m0(
 .clk(clk),.rst(media_rst),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
 .sd_read_error(sd_sec_read_error),.sd_init_done(sd_init_done),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
 .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
 .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
end endgenerate
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output reg button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        button_stable_out <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        
        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                button_stable_out <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
