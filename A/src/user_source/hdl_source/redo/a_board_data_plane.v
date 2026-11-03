// Actual A hardware plane. Control transactions remain in the board control top.
// Physical PLL/SDRAM/HDMI IP is reused unchanged; no encrypted implementation is edited.
module a_board_data_plane #(parameter FRAME_WIDTH=640,FRAME_HEIGHT=480)(input clk,rst_n,output ctrl_rst_n,
 output video_clk,video_rst_n,frame_boundary,output mem_clk,
 input [90:0] gallery_word,input [31:0] gallery_generation,
 output [90:0] gallery_actual,output [31:0] gallery_actual_generation,
 output gallery_applied_valid,output [31:0] gallery_applied_generation,
 output retire_valid,output [31:0] retired_generation,
 input image_req,image_valid,image_abort,input [31:0] image_word,input [20:0] image_base,
 output image_ack,image_input_ready,image_abort_done,
 input asset_done,asset_ready,asset_req,asset_valid,asset_abort,input [31:0] asset_word,
 output asset_ack,asset_input_ready,asset_abort_done,
 output memory_ready,writer_busy,memory_core_busy,output write_done_toggle,
 input mode_valid,input [31:0] mode_token,input [2:0] desired_mode,
 output actual_mode_valid,output [31:0] actual_mode_token,output [2:0] actual_mode,
 input settings_valid,input settings_alarm_external,input [31:0] settings_token,settings_word,
 output settings_applied_valid,output settings_applied_alarm_external,output [31:0] settings_applied_token,settings_applied_word,
 input [25:0] fault_word,input [15:0] video_text_descriptor,
 input char_we,char_bank,input [5:0] char_address,input [7:0] char_data,
 input colour_start,colour_cancel,input [31:0] colour_token,input [7:0] colour_brightness,colour_contrast,
 input [15:0] colour_crc,input colour_byte_valid,input [7:0] colour_byte_index,colour_byte_data,
 output colour_ready,colour_byte_ready,colour_done,colour_error,output [7:0] colour_error_code,
 output colour_applied_valid,output [31:0] colour_applied_token,output [15:0] colour_applied_style,
 input peer_online,reload,source_busy,source_done,input [7:0] source_error,
 input source_pcm_valid,input [31:0] source_pcm_word,input source_pcm_last,
 input [31:0] source_frames,input source_metadata,
 output source_pcm_ready,source_start,source_cancel,output [7:0] source_id,
 input pcm_command_valid,input [31:0] pcm_command_token,input [7:0] pcm_command_id,
 input pcm_cancel_valid,input [31:0] pcm_cancel_token,output [31:0] source_uid,
 output pcm_command_ready,output [31:0] pcm_acknowledged_token,pcm_status,
 output playback_applied,pcm_drained,output pcm_event_valid,output [127:0] pcm_event_data,
 output pcm_auto_borrow,input pcm_auto_ready,input [31:0] pcm_auto_uid,
 output HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,HDMI_DDC_SCL,inout HDMI_DDC_SDA,
 output pcm_tap_valid,output [23:0] pcm_tap_left,pcm_tap_right,
 input [7:0] colour_gamma,output [7:0] colour_applied_gamma,input [192:0] video_layout,input [40:0] menu_descriptor,input [36:0] size_text,
 input [39:0] subtitle_style,input [7:0] emergency_style,input [7:0] emergency_descriptor,input emergency_font_we,input [12:0] emergency_font_address,input [31:0] emergency_font_data,input [7:0] normal_audio_id,input normal_program_active,normal_builtin,output [31:0] pcm_completed_token,
 input [7:0] title_descriptor,input title_font_we,input [9:0] title_font_address,input [15:0] title_font_data,
 input program_valid,program_bank,program_released,input [3:0] program_image,input [6:0] program_count,input [71:0] program_rates,input [31:0] program_uid,
 input program_font_we,input [10:0] program_font_address,input [15:0] program_font_data,input normal_program_running,normal_program_narrated,
 input font_stream_job_start,input [1:0] font_stream_job_target,font_stream_job_size,input font_stream_job_bank,
 input [6:0] font_stream_job_glyph_count,input [7:0] font_stream_job_utf8_bytes,
 input font_stream_font_we,input [14:0] font_stream_font_address,input [7:0] font_stream_font_data,input font_stream_font_bank,
 input font_stream_raw_we,input [7:0] font_stream_raw_address,font_stream_raw_data,input font_stream_raw_bank,
 input font_stream_meta_valid,input [5:0] font_stream_meta_index,input [15:0] font_stream_meta_codepoint,input [1:0] font_stream_meta_size,
 input font_stream_commit_valid,font_stream_commit_bank,input [6:0] font_stream_commit_count,input [1:0] font_stream_commit_size,font_stream_commit_target,
 output [7:0] font_stream_render_error);
localparam [20:0] FRAME_PIXELS=FRAME_WIDTH*FRAME_HEIGHT,ASSET_IMAGE_BASE=21'd1667072;
wire sd_card_clk,ext_mem_clk_sft,hdmi_5x_clk,audio_pll_lock,audio_mclk;
wire video_pll_locked;
wire ext_mem_clk;assign mem_clk=ext_mem_clk;
sys_pll sys_pll_m0(.refclk(clk),.clk0_out(sd_card_clk),.clk1_out(ext_mem_clk),.clk2_out(ext_mem_clk_sft),.reset(1'b0));
video_pll video_pll_m0(.refclk(clk),.clk0_out(video_clk),.clk1_out(hdmi_5x_clk),.reset(1'b0),.extlock(video_pll_locked));
PLL_HDMI_AUDIO u_audio_pll(.refclk(clk),.reset(1'b0),.extlock(audio_pll_lock),.clk0_out(),.clk1_out(),.clk2_out(audio_mclk));
reg [1:0] control_reset,video_reset_pipe;
wire control_reset_assert=!rst_n||!video_pll_locked;
always @(negedge video_clk or posedge control_reset_assert)if(control_reset_assert)control_reset<=0;else control_reset<={control_reset[0],1'b1};
assign ctrl_rst_n=control_reset[1];
wire rst_all=!rst_n||!audio_pll_lock||!video_pll_locked;
always @(posedge video_clk or posedge rst_all)if(rst_all)video_reset_pipe<=3;else video_reset_pipe<={video_reset_pipe[0],1'b0};
wire video_reset=video_reset_pipe[1];assign video_rst_n=!video_reset;
wire media_rst_n=!rst_all;
// Memory-owned state uses a local release phase. Assertion remains immediate.
(*async_reg=1,preserve=1*) reg [1:0] memory_release;
always @(negedge ext_mem_clk or posedge rst_all)
 if(rst_all)memory_release<=0;else memory_release<={memory_release[0],1'b1};
wire memory_rst_n=memory_release[1],memory_reset=!memory_rst_n;

wire hs,vs,de,hs_0,vs_0,de_0;reg previous_vs;
always @(posedge video_clk or posedge video_reset)if(video_reset)previous_vs<=1;else previous_vs<=vs;
assign frame_boundary=previous_vs&&!vs;
wire read_req,read_ack,read_en;
// Latch the gallery descriptor at the VGA prefetch request in vertical blank.
// The display VS boundary is later than the SDRAM reader's address capture.
reg gallery_request_previous;
always @(posedge video_clk or posedge video_reset)
 if(video_reset)gallery_request_previous<=0;else gallery_request_previous<=read_req;
wire gallery_read_boundary=read_req&&!gallery_request_previous;
wire [2:0] mode_video;wire mode_video_valid;wire [31:0] mode_video_token;
a_frame_apply_local #(.WIDTH(3)) mode_commit(video_clk,ctrl_rst_n,video_rst_n,mode_valid,mode_token,desired_mode,
 frame_boundary,mode_video,mode_video_token,mode_video_valid,actual_mode_valid,actual_mode_token,actual_mode);
wire [32:0] settings_video;wire [32:0] settings_applied_bundle;
assign settings_applied_word=settings_applied_bundle[31:0];assign settings_applied_alarm_external=settings_applied_bundle[32];wire settings_video_valid;wire [31:0] settings_video_token;
a_frame_apply_local #(.WIDTH(33)) settings_commit(video_clk,ctrl_rst_n,video_rst_n,settings_valid,settings_token,{settings_alarm_external,settings_word},
 frame_boundary,settings_video,settings_video_token,settings_video_valid,settings_applied_valid,settings_applied_token,settings_applied_bundle);
wire [25:0] fault_video;wire fault_valid;wire [31:0] fault_token;
a_frame_apply_local #(.WIDTH(26)) fault_commit(video_clk,ctrl_rst_n,video_rst_n,1'b1,32'd0,fault_word,
 frame_boundary,fault_video,fault_token,fault_valid,,,);
wire reader_retirement_valid,reader_quiescent;wire [31:0] reader_retired_generation,reader_quiescent_generation;wire gallery_video_valid,gallery_busy;
wire [2:0] gallery_fade_shift;
wire picture_commit;wire [1:0] picture_id;
a_gallery_transition #(.LOCAL_CLOCKS(1)) gallery_commit(video_clk,ext_mem_clk,video_clk,ctrl_rst_n,video_rst_n,gallery_generation,gallery_word,gallery_read_boundary,mode_video[0],
 reader_retirement_valid,reader_retired_generation,reader_quiescent,reader_quiescent_generation,
 gallery_actual,gallery_actual_generation,gallery_video_valid,gallery_applied_valid,gallery_applied_generation,retire_valid,retired_generation,gallery_busy,gallery_fade_shift,picture_commit,picture_id);
wire photo_background_video=gallery_actual[90:70]==ASSET_IMAGE_BASE&&gallery_actual[6:5]==0&&gallery_actual[4];
wire frame_access_busy,audio_access_busy,audio_block,refresh_block,Sdr_init_done,Sdr_init_ref_vld,Sdr_busy;
wire frame_rd_en,frame_wr_en,frame_return;wire [20:0] frame_rd_addr,frame_wr_addr;wire [31:0] frame_wr_data,Sdr_rd_dout;wire [3:0] frame_wr_mask;
wire App_rd_en,App_wr_en,Sdr_rd_en;wire [20:0] App_rd_addr,App_wr_addr;wire [31:0] App_wr_din;wire [3:0] App_wr_dm;
wire writer_asset_owner;
wire raw_write_done,write_req,write_valid,write_abort,write_ack,write_ready,write_core_busy,write_abort_done;wire [31:0] write_word;wire [20:0] write_base;
reg memory_write_toggle;reg [2:0] write_done_sync;reg [1:0] init_sync,writer_sync,core_sync;
always @(posedge ext_mem_clk or negedge memory_rst_n)if(!memory_rst_n)memory_write_toggle<=0;else if(raw_write_done)memory_write_toggle<=!memory_write_toggle;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)begin write_done_sync<=0;init_sync<=0;writer_sync<=0;core_sync<=0;end
 else begin write_done_sync<={write_done_sync[1:0],memory_write_toggle};init_sync<={init_sync[0],Sdr_init_done};writer_sync<={writer_sync[0],write_core_busy};core_sync<={core_sync[0],Sdr_busy};end
end
assign write_done_toggle=write_done_sync[2];assign memory_ready=init_sync[1];assign writer_busy=writer_sync[1];assign memory_core_busy=core_sync[1];
frame_source_arbiter writer_owners(video_clk,media_rst_n,asset_done,writer_busy,memory_core_busy,
 asset_req,asset_valid,asset_abort,asset_word,image_req,image_valid,image_abort,image_word,image_base,
 write_ack,write_ready,write_abort_done,writer_asset_owner,write_req,write_valid,write_abort,write_word,write_base,
 asset_ack,asset_input_ready,asset_abort_done,image_ack,image_input_ready,image_abort_done);
wire [31:0] read_data;wire [23:0] vout_data_raw,vout_data;
video_timing_data video_timing_data_m0(video_clk,rst_all,read_req,read_ack,hs_0,vs_0,de_0);
video_delay video_delay_m0(video_clk,rst_all,read_en,read_data[31:8],hs_0,vs_0,de_0,hs,vs,de,vout_data_raw);
assign vout_data=gallery_actual[4]?vout_data_raw:24'd0;
frame_read_write #(.AUDIO_SERVICE(1),.ENABLE_RETIRE_STATUS(1),.WRITE_V_FLIP(1),.DYNAMIC_WRITE_V_FLIP(1),.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),.LOCAL_READY_RELEASE(1)) frame_read_write_m0(
 .write_v_flip(writer_asset_owner),.audio_block(audio_block),.refresh_block(refresh_block),.memory_access_busy(frame_access_busy),.mem_clk(ext_mem_clk),.rst(memory_reset),
 .Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(Sdr_busy),.App_rd_en(frame_rd_en),.App_rd_addr(frame_rd_addr),.Sdr_rd_en(frame_return),.Sdr_rd_dout(Sdr_rd_dout),
 .read_clk(video_clk),.read_req(read_req),.read_req_ack(read_ack),.read_finish(),.read_addr_0(gallery_actual[90:70]),.read_addr_1(gallery_actual[69:49]),
 .read_addr_2(gallery_actual[48:28]),.read_addr_3(gallery_actual[27:7]),.read_addr_index(gallery_actual[6:5]),.read_len(FRAME_PIXELS),.read_en(read_en),.read_data(read_data),
 .App_wr_en(frame_wr_en),.App_wr_addr(frame_wr_addr),.App_wr_din(frame_wr_data),.App_wr_dm(frame_wr_mask),.write_clk(video_clk),.write_abort(write_abort),.write_input_ready(write_ready),
 .write_core_busy(write_core_busy),.write_abort_done(write_abort_done),.write_req(write_req),.write_req_ack(write_ack),.write_finish(raw_write_done),
 .write_addr_0(write_base),.write_addr_1(write_base),.write_addr_2(write_base),.write_addr_3(write_base),.write_addr_index(2'd0),.write_len(FRAME_PIXELS),.write_en(write_valid),.write_data(write_word),
 .read_generation(gallery_actual_generation),.retired_generation(reader_retired_generation),.retirement_valid(reader_retirement_valid),.reader_quiescent(reader_quiescent),.quiescent_generation(reader_quiescent_generation));
sdram U3(.memory_access_busy(frame_access_busy||audio_access_busy),.refresh_block(refresh_block),.Clk(ext_mem_clk),.Clk_sft(ext_mem_clk_sft),.Rst(rst_all),
 .Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(Sdr_busy),.App_wr_en(App_wr_en),.App_wr_addr(App_wr_addr),.App_wr_dm(App_wr_dm),.App_wr_din(App_wr_din),
 .App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),.Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout));
wire am_request,am_ready,am_grant,am_done,am_finish,am_abort,am_rd_en,am_wr_en,am_return;
wire [20:0] am_rd_addr,am_wr_addr;wire [31:0] am_wr_data,am_rd_data;
wire wav_select,wav_available,wav_ready;wire [15:0] wav_left,wav_right;
a_pcm_playback32 #(.CONTROL_TOKEN32(1),.AUTO_UID32(1),.NORMAL_PLAYLIST(1),.CONTROL_HZ(25000000)) pcm_service(
 .sd_clk(video_clk),.mem_clk(ext_mem_clk),.video_clk(video_clk),.rst_n(video_rst_n),.initialized(peer_online&&memory_ready),.reload(reload),
 .source_busy(source_busy),.source_done(source_done),.source_error(source_error),.source_pcm_valid(source_pcm_valid),.source_left(source_pcm_word[15:0]),.source_right(source_pcm_word[31:16]),
 .source_last(source_pcm_last),.source_frames(source_frames),.source_metadata_valid(source_metadata),.source_pcm_ready(source_pcm_ready),.source_start(source_start),.source_cancel(source_cancel),.source_id(source_id),
 .command(16'd0),.command_valid(1'b0),.status(pcm_status),.emergency(actual_mode_valid&&actual_mode[0]),.alarm_external(settings_applied_valid&&settings_applied_alarm_external),.preset(actual_mode[2:1]),
 .sd_request(),.sd_ready(1'b0),.sd_lba(),.sd_valid(1'b0),.sd_byte(8'd0),.sd_done(1'b0),.sd_error(1'b0),.sd_cancel(),.sd_urgent(),
 .external_select(wav_select),.external_available(wav_available),.external_left(wav_left),.external_right(wav_right),.external_ready(wav_ready),
 .memory_request(am_request),.memory_ready(am_ready),.memory_grant(am_grant),.memory_done(am_done),.core_busy(Sdr_busy),.memory_finish(am_finish),.memory_abort(am_abort),
 .mem_rd_en(am_rd_en),.mem_rd_addr(am_rd_addr),.mem_wr_en(am_wr_en),.mem_wr_addr(am_wr_addr),.mem_wr_data(am_wr_data),.mem_rd_valid(am_return),.mem_rd_data(am_rd_data),
 .event_valid(pcm_event_valid),.event_data(pcm_event_data),.playback_applied(playback_applied),.service_drained(pcm_drained),
 .token_command_valid(pcm_command_valid),.token_command(pcm_command_token),.token_source_id(pcm_command_id),.token_command_ready(pcm_command_ready),.acknowledged_token(pcm_acknowledged_token),.token_cancel_valid(pcm_cancel_valid),.token_cancel(pcm_cancel_token),.source_uid(source_uid),
 .auto_borrow_valid(pcm_auto_borrow),.auto_borrow_ready(pcm_auto_ready),.auto_borrow_uid(pcm_auto_uid),.auto_enabled(peer_online&&!reload),.completed_token(pcm_completed_token),
 .normal_program_active(normal_program_active),
 .normal_program_id(peer_online&&normal_program_active&&program_valid&&program_released&&program_image==gallery_actual[3:0]&&gallery_actual[4]&&
   {4'd0,gallery_actual[3:0]}+8'd4==normal_audio_id&&!mode_video[0] ? normal_audio_id : 8'd0));
audio_memory_router pcm_memory(.clk(ext_mem_clk),.rst_n(memory_rst_n),.audio_request(am_request),.audio_ready(am_ready),.audio_grant(am_grant),.audio_finish(am_finish),.audio_abort(am_abort),
 .frame_busy(frame_access_busy),.core_busy(Sdr_busy),.refresh_block(refresh_block),.refresh_valid(Sdr_init_ref_vld),.frame_block(audio_block),.audio_access_busy(audio_access_busy),
 .frame_rd_en(frame_rd_en),.frame_rd_addr(frame_rd_addr),.frame_wr_en(frame_wr_en),.frame_wr_addr(frame_wr_addr),.frame_wr_data(frame_wr_data),.frame_wr_mask(frame_wr_mask),
 .audio_rd_en(am_rd_en),.audio_rd_addr(am_rd_addr),.audio_wr_en(am_wr_en),.audio_wr_addr(am_wr_addr),.audio_wr_data(am_wr_data),.audio_wr_mask(4'd0),
 .mem_rd_en(App_rd_en),.mem_rd_addr(App_rd_addr),.mem_wr_en(App_wr_en),.mem_wr_addr(App_wr_addr),.mem_wr_data(App_wr_din),.mem_wr_mask(App_wr_dm),
 .mem_rd_valid(Sdr_rd_en),.mem_rd_data(Sdr_rd_dout),.frame_rd_valid(frame_return),.audio_rd_valid(am_return),.audio_rd_data(am_rd_data),.done(am_done),.aborted());
wire audio_valid,acr_valid;wire [23:0] audio_left_data,audio_right_data;wire [19:0] acr_cts,acr_n;
emergency_pcm_audio #(.PICTURE_CUE_ENABLED(1),.NORMAL_SOUND_CONTROL(1)) u_pcm_audio(video_clk,video_reset,settings_video[31:24],settings_video[23:16],mode_video[0],wav_select,wav_available,wav_left,wav_right,wav_ready,audio_valid,audio_left_data,audio_right_data,
 picture_commit&&!photo_background_video,picture_id,normal_builtin);
assign pcm_tap_valid=audio_valid;assign pcm_tap_left=audio_left_data;assign pcm_tap_right=audio_right_data;
audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate(video_clk,video_reset,audio_valid,acr_valid,acr_cts,acr_n);
wire adjusted_hs,adjusted_vs,adjusted_de;wire [23:0] adjusted_rgb;
a_colour_lut #(.GAMMA_ENABLED(1)) u_colour_display(.cfg_clk(video_clk),.cfg_rst_n(ctrl_rst_n),.start(colour_start),.cancel(colour_cancel),.token(colour_token),.brightness(colour_brightness),.contrast(colour_contrast),.expected_crc(colour_crc),
 .byte_valid(colour_byte_valid),.byte_index(colour_byte_index),.byte_data(colour_byte_data),.ready(colour_ready),.byte_ready(colour_byte_ready),.done(colour_done),.error(colour_error),.error_code(colour_error_code),
 .applied_valid(colour_applied_valid),.applied_token(colour_applied_token),.applied_style(colour_applied_style),.video_clk(video_clk),.video_rst_n(video_rst_n),.hs(hs),.vs(vs),.de(de),.rgb(vout_data),
 .bypass(mode_video[0]||photo_background_video),.ohs(adjusted_hs),.ovs(adjusted_vs),.ode(adjusted_de),.out_rgb(adjusted_rgb),.gamma(colour_gamma),.applied_gamma(colour_applied_gamma));
wire osd_hs,osd_vs,osd_de;wire [23:0] osd_rgb;
wire [40:0] menu_video;
a_menu_frame_local #(.WIDTH(41)) menu_display_commit(video_clk,ctrl_rst_n,video_rst_n,
 (menu_descriptor[34]||menu_descriptor[37])&&!mode_video[0],menu_descriptor,frame_boundary,menu_video);
wire [23:0] faded_rgb;
a_video_fade picture_fade(adjusted_rgb,gallery_fade_shift,mode_video[0]||photo_background_video,faded_rgb);
emergency_osd #(.PHOTO_BACKDROP(0),.LAYOUT_ENABLED(0),.PCM_WAVEFORM_ENABLED(1),.MENU_ENABLED(1),.SCROLL_ENABLED(1)) u_osd(video_clk,video_reset,video_clk,adjusted_hs,adjusted_vs,adjusted_de,faded_rgb,photo_background_video,mode_video[0],mode_video[2:1],fault_video,
 video_text_descriptor,char_we,char_bank,char_address,char_data,osd_hs,osd_vs,osd_de,osd_rgb,video_layout,audio_valid,audio_left_data,audio_right_data,
 menu_video,emergency_descriptor,emergency_font_we,emergency_font_address,emergency_font_data,subtitle_style,emergency_style,!peer_online,title_descriptor,title_font_we,title_font_address,title_font_data,
 program_valid&&gallery_actual[4]&&program_image==gallery_actual[3:0],program_bank,program_count,program_rates,program_uid,
 normal_program_running&&(normal_program_narrated?(wav_select&&wav_available&&wav_ready):audio_valid),program_font_we,program_font_address,program_font_data,
 font_stream_job_start,font_stream_job_target,font_stream_job_size,font_stream_job_bank,font_stream_job_glyph_count,font_stream_job_utf8_bytes,
 font_stream_font_we,font_stream_font_address,font_stream_font_data,font_stream_font_bank,
 font_stream_raw_we,font_stream_raw_address,font_stream_raw_data,font_stream_raw_bank,font_stream_meta_valid,font_stream_meta_index,font_stream_meta_codepoint,font_stream_meta_size,
 font_stream_commit_valid,font_stream_commit_bank,font_stream_commit_count,font_stream_commit_size,font_stream_commit_target,font_stream_render_error,size_text);
wire axis_s_user,axis_s_valid,axis_s_last,axis_s_ready,edid_trig,edid_valid;wire [23:0] axis_s_data;wire [7:0] edid_data;
wire [9:0] tmds_ch0_data,tmds_ch1_data,tmds_ch2_data,tmds_clk_data;
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (video_reset),
    .I_vs          (osd_vs),
    .I_de          (osd_de),
    .I_rgb         (osd_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (video_reset),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (video_reset),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

