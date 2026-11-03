// B媒体核心：真实TF/BMP/WAV解析；输出接口等待SPI媒体发送器接入。
module b_media_core_control #(parameter CLOCK_HZ=50000000,FRAME_WIDTH=640,FRAME_HEIGHT=480,ADAPTIVE_IMAGES=0,IMAGE_PROGRESS_ENABLED=0)(
 input clk,rst_n,pause,output drained,image_drained,image_control_idle,reload_accepted,output [3:0] cached_mask,input next_image,previous_image,reload,auto_valid,auto_value,auto_toggle,emergency,
 input [31:0] period_ms,input period_valid,
 output image_req,image_valid,output [31:0] image_word,input image_ack,frame_finish_toggle,
 output [1:0] write_bank,display_bank,output display_valid,output [3:0] image_code,
 input image_sector_room,audio_urgent,input audio_start,audio_cancel,input [7:0] audio_id,input pcm_ready,
 output pcm_valid,pcm_last,output [31:0] pcm_word,audio_frames,output audio_metadata,audio_busy,audio_done,output [7:0] audio_error,
 output event_valid,output [127:0] event_data,
 output tf_cs_n,tf_sclk,tf_mosi,input tf_miso,
 output [15:0] image_source_width,image_source_height,output [31:0] image_source_pixels,output [12:0] image_orig_width,image_orig_height,
 input play_mode_valid,input [1:0] requested_play_mode,input program_audio_terminal,input [7:0] program_audio_id,
 output [1:0] play_mode,output actual_automatic,input peer_online,
 output program_catalog_valid,output program_grant_needed,input program_grant_valid,input [31:0] program_uid,input program_grant_permission,
 output program_tx,input program_ready,output [7:0] program_kind,output [6:0] program_count,output [15:0] program_sequence,program_tag,output [31:0] program_value,
 input program_done,input [5:0] program_address,output [31:0] program_word,
 input program_reply_valid,input [255:0] program_reply,output [3:0] image_catalog_count,output program_prepared,
 input geometry_pause,geometry_invalidate,input image_progress);
reg image_submitted,admitted_image_request;
localparam [15:0] BMP_WIDTH=FRAME_WIDTH,BMP_HEIGHT=FRAME_HEIGHT;
wire reader_drained,reader_image_drained,producer_drained;
wire catalog_ready,meta_req,meta_ready,meta_valid,meta_done,meta_error,meta_cancel,meta_drained,mux_drained;
wire [3:0] catalog_count;wire [31:0] meta_lba;wire [7:0] meta_byte,program_error;
wire shared_image_request,shared_image_cancel,shared_iv,shared_done,shared_error;
wire [31:0] shared_image_lba;wire [7:0] shared_image_byte;
assign drained=reader_drained&&producer_drained&&!audio_busy&&!admitted_image_request&&meta_drained&&mux_drained;
// Picture actions wait for their physical owner and shared SD mux, independent
// of a programme parked at its UID grant. Global F0 still joins that owner.
assign image_drained=reader_image_drained&&producer_drained&&!admitted_image_request&&mux_drained;
wire image_request,image_cancel,image_reset,initialized,iv,idone,ierror;wire [31:0] image_lba;wire [7:0] ibyte;
wire audio_request,audio_ready,av,adone,aerror;wire [31:0] audio_lba;wire [7:0] abyte;wire [15:0] left,right;
assign pcm_word={right,left};
// 按整扇区预留像素FIFO空间；原保持请求只提交一次，不能因空间变化重复读同一扇区。
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin image_submitted<=0;admitted_image_request<=0;end
 else begin admitted_image_request<=0;
  if(pause||geometry_pause||!image_request||image_cancel||image_reset)image_submitted<=0;
  else if(!image_submitted&&image_sector_room)begin image_submitted<=1;admitted_image_request<=1;end
 end
end

b_shared_sd_reader #(.CLOCK_HZ(CLOCK_HZ)) u_shared(
 .clk(clk),.rst_n(rst_n),.reload(image_reset),.drained(reader_drained),.image_drained(reader_image_drained),.image_cancel(shared_image_cancel),.image_request(shared_image_request),.image_lba(shared_image_lba),
 .sd_init_done(initialized),.image_valid(shared_iv),.image_done(shared_done),.image_error(shared_error),.image_byte(shared_image_byte),
 .audio_request(audio_request),.audio_lba(audio_lba),.audio_ready(audio_ready),.audio_cancel(audio_cancel||pause),.audio_urgent(audio_urgent),
 .audio_valid(av),.audio_done(adone),.audio_error(aerror),.audio_byte(abyte),.SD_nCS(tf_cs_n),.SD_DCLK(tf_sclk),.SD_MOSI(tf_mosi),.SD_MISO(tf_miso));
b_sd_card_bmp_control #(.EXTERNAL_SD(1),.CLK_FREQ_HZ(CLOCK_HZ),.SCAN_TARGET_COUNT(8),.ADAPTIVE_IMAGES(ADAPTIVE_IMAGES),.DYNAMIC_SCAN_COUNT(1),.REFORMAT_ENABLED(1),.OUTPUT_PROGRESS_ENABLED(IMAGE_PROGRESS_ENABLED),.COMPACT_HEADERS(FRAME_WIDTH==640&&FRAME_HEIGHT==480)) u_images(
 .external_init(initialized&&catalog_ready),.external_valid(iv),.external_end(idone),.external_error(ierror),.external_byte(ibyte),
 .client_request(image_request),.client_lba(image_lba),.client_cancel(image_cancel),.client_reset(image_reset),
 .pause(pause||emergency),.geometry_suspend(geometry_pause),.ctrl_reformat(geometry_invalidate),.producer_drained(producer_drained),.control_idle(image_control_idle),.reload_accepted(reload_accepted),.cached_mask(cached_mask),.ctrl_next(next_image&&!pause),.ctrl_prev(previous_image),.ctrl_reload(reload),.ctrl_auto_valid(auto_valid),.ctrl_auto_value(auto_value),.ctrl_auto_toggle(auto_toggle),.force_manual(emergency),
 .clk(clk),.rst(!rst_n),.key_next(1'b1),.key_auto(1'b1),.key_reload(1'b1),.period_cfg_valid(period_valid),.period_cfg_ms(period_ms),
 .state_code(image_code),.diagnostic_valid(event_valid),.diagnostic_data(event_data),.bmp_width(BMP_WIDTH),.bmp_height(BMP_HEIGHT),.display_valid(display_valid),
 .write_finish_toggle(frame_finish_toggle),.write_buf_idx(write_bank),.disp_buf_idx(display_bank),.write_req(image_req),.write_req_ack(image_ack),.write_en(image_valid),.write_data(image_word),.SD_nCS(),.SD_DCLK(),.SD_MOSI(),.SD_MISO(tf_miso),
 .source_width(image_source_width),.source_height(image_source_height),.source_pixels(image_source_pixels),.orig_width(image_orig_width),.orig_height(image_orig_height),
 .play_mode_valid(play_mode_valid),.requested_play_mode(requested_play_mode),.program_audio_terminal(program_audio_terminal),.program_audio_id(program_audio_id),
 .play_mode(play_mode),.actual_automatic(actual_automatic),.catalog_count(catalog_count),.discovered_count(image_catalog_count),.output_progress(image_progress));
b_program_sd_mux metadata_sectors(clk,rst_n,pause,reader_image_drained,
 admitted_image_request,image_lba,image_cancel,iv,idone,ierror,ibyte,
 meta_req,meta_ready,meta_lba,meta_cancel,meta_valid,meta_done,meta_error,meta_byte,
 shared_image_request,shared_image_lba,shared_image_cancel,shared_iv,shared_done,shared_error,shared_image_byte,mux_drained);
b_program_player #(.CLOCK_HZ(CLOCK_HZ),.REFRESH_SUPPORT(1)) programs(clk,rst_n,initialized,image_reset,pause,peer_online&&!emergency,display_valid,image_code,
 catalog_ready,program_catalog_valid,catalog_count,meta_req,meta_ready,meta_lba,meta_valid,meta_byte,meta_done,meta_error,meta_cancel,
 program_grant_needed,program_grant_valid,program_uid,program_grant_permission,
 program_tx,program_ready,program_kind,program_count,program_sequence,program_tag,program_value,program_address,program_word,program_done,
 program_reply_valid,program_reply,meta_drained,program_error,play_mode,period_ms,play_mode_valid,program_prepared);
wav_file_reader #(.CLOCK_HZ(CLOCK_HZ)) u_audio(
 .clk(clk),.rst_n(rst_n),.start(audio_start&&!pause),.cancel(audio_cancel||image_reset||pause),.select_id(audio_id),.total_frames(audio_frames),.metadata_valid(audio_metadata),
 .busy(audio_busy),.done(audio_done),.aborted(),.error_code(audio_error),.pcm_valid(pcm_valid),.pcm_ready(pcm_ready),.pcm_left(left),.pcm_right(right),.pcm_last(pcm_last),
 .request_valid(audio_request),.request_ready(audio_ready),.request_lba(audio_lba),.sector_valid(av),.sector_byte(abyte),.sector_done(adone),.sector_error(aerror));
endmodule
