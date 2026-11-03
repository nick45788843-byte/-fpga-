// New A controls with verified bounded physical/data endpoints.
// Paired SPI6 normal services and forward UID32 media. Full native gates pending.
`default_nettype none
module top #(parameter CLOCK_HZ=25000000,UART_CLKS=217,FLASH_DIV=4,FRAME_WIDTH=640,FRAME_HEIGHT=480,PCM_ANALYSIS_ENABLED=0,STATUS_DIGITS_ENABLED=0)(
 input wire clk,rst_n,key1,key2,key3,board_sclk,board_cs_n,board_mosi,
 output wire board_miso,board_ready,input wire uart_rx,output wire uart_tx,
 output wire user_flash_cs_n,user_flash_sclk,user_flash_mosi,user_flash_wp_n,user_flash_hold_n,
 input wire user_flash_miso,output wire [7:0] seg_sel,seg_data,
 output wire HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,HDMI_DDC_SCL,inout wire HDMI_DDC_SDA,
 output wire sd_ncs,sd_dclk,sd_mosi,input wire sd_miso);
// TF is physically on B. These A pins remain at the documented inactive levels.
assign sd_ncs=1'b1;assign sd_dclk=1'b0;assign sd_mosi=1'b1;
wire ctrl_rst_n,video_clk,video_rst_n,frame_boundary,mem_clk;
wire tick_ms,key_toggle,key_next,key_media;wire [7:0] key_media_code;
wire link_online,link_offline,link_trip,proof_valid;wire [15:0] challenge;
reg [31:0] now_ms;always @(posedge video_clk or negedge ctrl_rst_n)if(!ctrl_rst_n)now_ms<=0;else if(tick_ms)now_ms<=now_ms+1'b1;
wire [2:0] desired_mode,actual_mode;wire mode_ack_valid,mode_current;
wire [31:0] mode_epoch,mode_ack_epoch;
wire automatic_mode;
wire session_ready;
wire packet_valid,packet_consume;wire [7:0] packet_kind,packet_arg;
wire [6:0] packet_count;wire [15:0] packet_seq,packet_tag,packet_crc,link_bad;
wire [31:0] packet_value,packet_word;wire [5:0] packet_address;
wire menu_visible,menu_toggle,menu_next,menu_plus,menu_minus;wire [2:0] menu_item;
wire menu_key_valid,menu_board_cancel,menu_front_idle;wire [7:0] menu_key_code;
wire [40:0] menu_descriptor;wire [103:0] image_dims;wire [36:0] size_text;wire [34:0] normal_menu_descriptor,scale_hint_descriptor;wire [7:0] image_extents;
wire [34:0] received_menu_descriptor;wire display_consume,display_updated;
wire [5:0] display_address;wire [7:0] display_capture_error;wire [31:0] display_generation;
wire [15:0] display_rejected;reg [31:0] display_namespace_cookie;
wire menu_request_valid,menu_request_ready,menu_result_valid,menu_result_ready;
wire menu_result_synthetic;
wire [7:0] menu_command,menu_result_byte;wire [47:0] menu_arguments;wire [4:0] menu_result_address;
a_board_keys #(.CLOCK_HZ(CLOCK_HZ)) keys(video_clk,ctrl_rst_n,{key3,key2,key1},desired_mode[0],link_online,automatic_mode,menu_visible,
 tick_ms,key_toggle,key_next,key_media,key_media_code,menu_toggle,menu_next,menu_plus,menu_minus);
// A96r03: board-key OSD settings menu removed for area (user approved).
// Every setting stays on the serial screen; key media gestures are unchanged.
// 0x53 packets are still consumed/ACKed by the existing credit and status paths.
assign menu_visible=1'b0;assign menu_item=3'd0;assign menu_key_valid=1'b0;assign menu_key_code=8'd0;
assign menu_request_valid=1'b0;assign menu_command=8'd0;assign menu_arguments=48'd0;
assign menu_result_ready=1'b1;assign menu_board_cancel=1'b0;assign menu_front_idle=1'b1;
assign menu_result_address=0;
assign normal_menu_descriptor={link_online&&session_ready&&!desired_mode[0]&&
 received_menu_descriptor[34]&&(!menu_visible||received_menu_descriptor[33:31]==menu_item),received_menu_descriptor[33:0]};
a_menu_display_receive menu_display_receive(video_clk,ctrl_rst_n,link_online&&session_ready,display_namespace_cookie,
 packet_valid&&packet_kind==8'h54,display_consume,packet_arg,packet_count,packet_seq,packet_tag,packet_value,
 display_address,packet_word,received_menu_descriptor,display_generation,display_updated,display_rejected,display_capture_error);



wire glyph_fragment_valid;wire [255:0] glyph_fragment;
wire font_rx_response_valid,font_rx_command_ready,font_rx_busy,font_rx_job_start;
wire [255:0] font_rx_fragment;wire [5:0] font_rx_read_address;
wire [1:0] font_rx_current_target;wire [3:0] font_rx_active_banks;
wire font_rx_font_write_valid,font_rx_font_write_bank,font_rx_raw_write_valid,font_rx_raw_write_bank;
wire [14:0] font_rx_font_write_address;wire [7:0] font_rx_font_write_data;
wire [7:0] font_rx_raw_write_address,font_rx_raw_write_data;
wire font_rx_glyph_meta_valid,font_rx_commit_valid,font_rx_commit_bank;
wire [5:0] font_rx_glyph_meta_index;wire [15:0] font_rx_glyph_meta_codepoint;
wire [1:0] font_rx_glyph_meta_size,font_rx_commit_size,font_rx_commit_target;
wire [6:0] font_rx_commit_glyph_count;wire [7:0] font_rx_commit_utf8_bytes,font_rx_last_error;
wire [1:0] font_rx_current_size;wire [6:0] font_rx_current_glyph_count;
wire [7:0] font_rx_current_utf8_bytes,font_stream_render_error;
// FS2 glyph stream: BEGIN/DATA/ABORT/COMMIT, one retained F2 receipt each;
// the 4A/F3 second receipt phase is retired.
wire font_stream_packet=packet_kind==8'h60||packet_kind==8'h61||packet_kind==8'h64||packet_kind==8'h65;
wire font_stream_receipt=1'b0;
wire font_reply_valid=font_rx_response_valid||glyph_fragment_valid;
wire [63:0] font_reply_header=font_rx_response_valid?
 {font_rx_fragment[255:224],font_rx_fragment[199:192],font_rx_fragment[207:200],font_rx_fragment[215:208],font_rx_fragment[223:216]}:
 glyph_fragment[255:192];
wire [191:0] font_reply_body=font_rx_response_valid?font_rx_fragment[191:0]:glyph_fragment[191:0];
wire font_receipt_captured,glyph_receipt_captured,rpc_receipt_captured;
reg text_owned;reg [31:0] text_owner;reg boot_text_committed;
// No legacy gateway or 24-byte RPC receive copy.
wire local_valid,local_ready,local_response_valid,local_response_ready;
wire [31:0] active_token,active_wire,local_response_token,local_cancel_token,normal_cancel_token;
wire [7:0] active_command,local_response_byte;wire [15:0] active_length,dropped;
wire [47:0] active_arguments;wire [4:0] local_response_address;
wire local_cancel,normal_cancel,local_cancel_done,tx_idle,token_exhausted;
wire urgent_enter,urgent_preset_valid;wire [1:0] urgent_preset;
wire [31:0] allocator_next,seed_token,borrowed_token;wire seed_valid,seed_ready,borrow_valid,borrow_ready;
wire identity_known,reserve_request;wire [15:0] namespace_prefix;wire [7:0] namespace_error;
wire session_control_valid;wire [63:0] session_control_header;
wire namespace_borrow,namespace_borrow_ready,image_borrow,image_borrow_ready,key_borrow,key_borrow_ready,pcm_auto_borrow,pcm_auto_ready;
wire [31:0] source_uid,authorized_image_uid;
wire media_result_valid,media_command_valid,image_command_valid,media_command_consume,image_action_done,image_actions_idle;
wire media_command_captured;
wire [63:0] media_result_header,media_command_header,image_command_header;
wire [3:0] image_action_done_image;
wire [31:0] image_action_done_uid;wire [7:0] image_action_done_error;
wire control_ack;wire [31:0] control_ack_token;wire [7:0] control_ack_index,control_ack_error;wire control_ack_captured;
wire global_b_drained=control_ack&&!control_ack_captured&&control_ack_index==8'hfe&&control_ack_error==0&&
 session_control_valid&&control_ack_token=={session_control_header[7:0],session_control_header[15:8],session_control_header[23:16],session_control_header[31:24]};
always @(posedge video_clk or negedge ctrl_rst_n)
 if(!ctrl_rst_n)display_namespace_cookie<=0;
 else if(global_b_drained&&session_control_header[63:32]==32'hf0000000)display_namespace_cookie<=control_ack_token;
wire [239:0] status_body;wire [191:0] status_payload;
wire capture_command=packet_kind==8'h4d||packet_kind==8'h4e;
wire capture_consume,capture_fragment,capture_locked,capture_drained,pcm_tap_valid;
wire [63:0] capture_header;wire [4:0] capture_address;wire [7:0] capture_byte;
wire [23:0] pcm_tap_left,pcm_tap_right;
wire heartbeat=packet_valid&&packet_kind==1&&packet_consume;
a_link_proof proof(video_clk,ctrl_rst_n,link_offline,heartbeat,packet_arg[2],packet_value[31:16],challenge,proof_valid);
link_watchdog #(.CLOCK_HZ(CLOCK_HZ)) watchdog(video_clk,ctrl_rst_n,proof_valid,link_online,link_offline,link_trip);
wire program_packet=packet_kind==8'h56||packet_kind==8'h57||packet_kind==8'h58||packet_kind==8'h5a;
wire program_consume,program_busy,program_reply_valid,program_font_we,program_valid,program_bank,program_released;
wire [5:0] program_address;wire [63:0] program_reply_header;wire [10:0] program_font_address;wire [15:0] program_font_data;
wire [3:0] program_image;wire [6:0] program_count;wire [7:0] program_length;wire [71:0] program_rates;
wire [31:0] program_expected_uid,program_uid;
wire program_raw_we,program_raw_bank,program_query_hold;wire [7:0] program_raw_address,program_raw_byte;

wire title_font_we;wire [9:0] title_font_address;wire [15:0] title_font_data;wire [7:0] title_descriptor;
wire ux_valid,ux_ready,ux_response,ux_response_ready,ux_busy;
wire base_ready,base_response,base_response_ready;wire [31:0] ux_token,base_token;
wire [7:0] ux_byte,base_byte,ux_payload_address,ux_payload_byte,emergency_descriptor;
wire [39:0] subtitle_style;wire [7:0] emergency_style;
wire style_restore_settled,style_publish,nv_style_source_lock;
wire boot_ready,boot_found;wire [7:0] boot_error;
wire [47:0] boot_styles;
wire emergency_font_we;wire [12:0] emergency_font_address;wire [31:0] emergency_font_data;
wire ux_command=active_command==20||active_command==21;
wire stream_query_command=active_command==16&&active_arguments[7:6]==2'b10;
wire stream_query_ready,stream_query_response,stream_query_response_ready,stream_query_cancelled,stream_query_idle;
wire [31:0] stream_query_token,stream_query_cancelled_token;
wire [7:0] stream_query_byte;
assign local_ready=stream_query_command?stream_query_ready:ux_command?ux_ready:base_ready;
assign local_response_valid=stream_query_response||ux_response||base_response;
assign local_response_token=stream_query_response?stream_query_token:ux_response?ux_token:base_token;
assign local_response_byte=stream_query_response?stream_query_byte:ux_response?ux_byte:base_byte;
assign stream_query_response_ready=local_response_ready&&stream_query_response;
assign ux_response_ready=local_response_ready&&!stream_query_response&&ux_response;
assign base_response_ready=local_response_ready&&!stream_query_response&&!ux_response;
a_font_stream_text_store stream_text_store(
 .clk(video_clk),.rst_n(ctrl_rst_n),
 .raw_we(font_rx_raw_write_valid),.raw_target(font_rx_current_target),.raw_bank(font_rx_raw_write_bank),.job_start(font_rx_job_start),
 .raw_address(font_rx_raw_write_address),.raw_byte(font_rx_raw_write_data),
 .commit_valid(font_rx_commit_valid),.commit_target(font_rx_commit_target),.commit_bank(font_rx_commit_bank),.commit_length(font_rx_commit_utf8_bytes),
 .request_valid(local_valid&&stream_query_command),.request_ready(stream_query_ready),.request_token(active_token),.request_argument(active_arguments[7:0]),
 .cancel_valid(local_cancel),.cancel_token(local_cancel_token),
 .result_valid(stream_query_response),.result_ready(stream_query_response_ready),.result_token(stream_query_token),
 .result_address(local_response_address),.result_byte(stream_query_byte),
 .cancelled(stream_query_cancelled),.cancelled_token(stream_query_cancelled_token),.idle(stream_query_idle));
a_emergency_content #(.STYLE_PERSISTENCE(1)) emergency_content(video_clk,ctrl_rst_n,frame_boundary,
 local_valid&&ux_command,ux_ready,active_token,active_command,active_length,active_arguments,
 ux_payload_address,ux_payload_byte,local_cancel,local_cancel_token,
 ux_response,ux_response_ready,ux_token,local_response_address,ux_byte,
 emergency_font_we,emergency_font_address,emergency_font_data,emergency_descriptor,ux_busy,
 local_valid&&local_ready&&active_command==1,subtitle_style,emergency_style,title_font_we,title_font_address,title_font_data,title_descriptor,
 tick_ms,program_raw_we,program_raw_bank,program_raw_address,program_raw_byte,program_valid,program_bank,program_count,program_length,program_query_hold,
 boot_ready,(boot_found&&boot_error==0)?boot_styles:48'h001105ffff08,style_restore_settled,nv_style_source_lock,style_publish);
a_control_plane #(.CLOCK_HZ(CLOCK_HZ),.UART_CLKS(UART_CLKS),.CAPTURE_ACK(1),.MEDIA32(1),.BORROW_DURING_LOCAL(1),.PCM_CAPTURE(PCM_ANALYSIS_ENABLED),.BOARD_CONTROL_ENABLED(0),.CRC_ROM_ENABLED(1),.PROGRAM_REPLY(1)) control_plane(
 .clk(video_clk),.rst_n(ctrl_rst_n),.tick_ms(tick_ms),.uart_rx(uart_rx),.uart_tx(uart_tx),
 .spi_clk(board_sclk),.spi_cs_n(board_cs_n),.spi_mosi(board_mosi),.spi_miso(board_miso),.spi_ready(board_ready),
 .peer_ready(link_online&&session_ready),.initialize_valid(seed_valid),.first_execution_token(seed_token),.initialize_ready(seed_ready),
 .local_request_valid(local_valid),.local_request_ready(local_ready),.local_request_token(active_token),
 .local_request_wire_id(active_wire),.local_request_command(active_command),.local_request_length(active_length),.local_request_arguments(active_arguments),
 .local_cancel_valid(local_cancel),.local_cancel_token(local_cancel_token),.local_cancel_done(local_cancel_done),.local_cancel_done_token(local_cancel_token),
 .normal_cancel_valid(normal_cancel),.normal_cancel_token(normal_cancel_token),
 .urgent_enter(urgent_enter),.urgent_preset_valid(urgent_preset_valid),.urgent_preset(urgent_preset),
 .local_result_valid(local_response_valid),.local_result_ready(local_response_ready),.local_result_token(local_response_token),
 .local_result_address(local_response_address),.local_result_byte(local_response_byte),
 .packet_valid(packet_valid),.packet_ready(packet_consume),.packet_kind(packet_kind),.packet_arg(packet_arg),.packet_count(packet_count),
 .packet_sequence(packet_seq),.packet_tag(packet_tag),.packet_crc(packet_crc),.packet_value(packet_value),.packet_word(packet_word),.packet_address(packet_address),
 .control_ack(control_ack),.control_ack_token(control_ack_token),.control_ack_index(control_ack_index),.control_ack_error(control_ack_error),
 .control_ack_captured(control_ack_captured),.spi_status(status_body),.control_valid(session_control_valid),.control_header(session_control_header),
 .glyph_valid(font_reply_valid),.glyph_header(font_reply_header),.glyph_body(font_reply_body),
 .exhausted(token_exhausted),.idle(tx_idle),.uart_dropped(dropped),.spi_bad(link_bad),.next_execution_token(allocator_next),
 .borrow_valid(borrow_valid),.borrow_ready(borrow_ready),.borrowed_token(borrowed_token),
 .media_result_valid(media_result_valid),.media_result_header(media_result_header),.media_command_valid(media_command_valid),.media_command_header(media_command_header),
 .pcm_fragment_valid(capture_fragment),.pcm_fragment_header(capture_header),.pcm_fragment_byte(capture_byte),.pcm_fragment_address(capture_address),.pcm_fragment_locked(capture_locked),
 .media_command_captured(media_command_captured),
 .board_request_valid(menu_request_valid),.board_request_ready(menu_request_ready),.board_request_command(menu_command),.board_request_arguments(menu_arguments),
 .board_cancel(menu_board_cancel),.board_result_valid(menu_result_valid),.board_result_ready(menu_result_ready),
 .board_result_address(menu_result_address),.board_result_byte(menu_result_byte),.board_result_synthetic(menu_result_synthetic),
 .local_payload_address(ux_payload_address),.local_payload_byte(ux_payload_byte),
 .program_result_valid(program_reply_valid),.program_result_header(program_reply_header),
 .font_receipt_captured(font_receipt_captured),.glyph_receipt_captured(glyph_receipt_captured),.rpc_receipt_captured(rpc_receipt_captured));
// Necessary local record storage, shared with the immutable emergency photo.
wire boot_unknown,boot_corrupt,boot_custom;
wire [7:0] restore_byte;wire [23:0] jedec_id;
wire [71:0] boot_values;wire [2:0] boot_mode;wire [6:0] boot_count;wire [5:0] restore_address;
wire nv_valid,nv_ready,nv_custom,nv_done,nv_busy,nv_can_save,nv_stored,nv_source_lock;
wire nv_header_we,nv_header_select;wire [5:0] nv_header_address;wire [7:0] nv_header_byte;
wire [31:0] nv_token,nv_saved_token,nv_sequence;wire [71:0] nv_values,nv_saved_values;
wire [2:0] nv_mode,nv_saved_mode;wire [6:0] nv_count,nv_saved_count;
wire [5:0] nv_address;wire [7:0] nv_byte,nv_error;wire nv_saved_custom;
wire asset_start,asset_bus_ready,asset_bus_busy,asset_bus_done,asset_bus_error,asset_byte_valid;
wire [23:0] asset_address;wire [6:0] asset_length;wire [7:0] asset_byte,asset_bus_error_code;wire [5:0] asset_byte_index;
a_flash_store #(.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(FLASH_DIV),.CRC_POOL_ENABLED(1),.ROOT_LEASE(1),.CACHED_HEADER(1),.STYLE_PERSISTENCE(1)) storage(
 video_clk,ctrl_rst_n,boot_ready,boot_found,boot_unknown,boot_corrupt,boot_error,jedec_id,boot_values,boot_mode,boot_custom,boot_count,
 restore_address,restore_byte,nv_valid,nv_ready,nv_token,nv_values,nv_mode,nv_custom,nv_count,nv_address,nv_byte,nv_source_lock,
 nv_done,1'b1,nv_saved_token,nv_error,nv_stored,nv_sequence,nv_saved_values,nv_saved_mode,nv_saved_custom,nv_saved_count,nv_busy,nv_can_save,
 asset_start,asset_address,asset_length,asset_bus_ready,asset_bus_busy,asset_bus_done,asset_bus_error,asset_bus_error_code,
 asset_byte_valid,asset_byte,asset_byte_index,user_flash_cs_n,user_flash_sclk,user_flash_mosi,user_flash_miso,user_flash_wp_n,user_flash_hold_n,nv_header_we,nv_header_address,nv_header_byte,nv_header_select,
 boot_styles,{emergency_style,subtitle_style},nv_style_source_lock);

// Single text writer: boot restore, real shadow bank and frame commit, then F2/F3.
wire glyph_consume,glyph_apply,glyph_apply_ready,glyph_result,glyph_result_ready,glyph_revoke;
wire [5:0] glyph_packet_address,glyph_address;wire [7:0] glyph_byte,glyph_error;
wire [31:0] glyph_token,glyph_result_token;wire [6:0] glyph_count;
wire text_response,text_response_ready;wire [31:0] text_response_token;wire [7:0] text_error;
wire text_publish,text_ack,text_video_valid;wire [31:0] text_publish_token,text_ack_token,text_video_token;
wire [15:0] text_publish_word,text_ack_word,text_video_word;
wire char_we,char_bank;wire [5:0] char_address;wire [7:0] char_data;
wire restore_settled,restore_applied,restore_skipped,text_write_allowed,restore_request_ready;

wire global_flush=identity_known&&!session_ready;
wire removed_layout_packet=packet_kind==8'h50||packet_kind==8'h51;
// A samples the final PCM only in the optional analysis profile. Playback has
// its own data path and remains enabled when this endpoint is compiled away.
generate if(PCM_ANALYSIS_ENABLED)begin: pcm_capture_enabled
a_pcm_capture capture(video_clk,ctrl_rst_n,video_clk,video_rst_n,pcm_tap_valid,pcm_tap_left,pcm_tap_right,
 session_ready,identity_known,namespace_prefix,allocator_next,packet_valid&&capture_command,capture_consume,
 packet_kind,packet_arg,packet_count,packet_seq,packet_tag,packet_value,normal_cancel,normal_cancel_token,
 !session_ready||!link_online,capture_fragment,capture_header,capture_locked,capture_address,capture_byte,capture_drained);
end else begin: pcm_capture_disabled
 assign capture_consume=1'b1;assign capture_fragment=1'b0;assign capture_header=64'd0;
 assign capture_byte=8'd0;assign capture_drained=1'b1;
end endgenerate
wire local_text_cancel=normal_cancel||(global_flush&&text_owned);
wire [31:0] text_abort_token=global_flush&&text_owned?text_owner:normal_cancel_token;
wire glyph_finalize=packet_valid&&packet_kind==8'h4a&&packet_arg==0&&packet_count==0&&packet_tag==0&&
 glyph_fragment_valid&&glyph_fragment[255:248]==8'hf2&&!glyph_revoke&&!(local_text_cancel&&text_abort_token==packet_value);

wire runtime_text_commit=glyph_finalize&&glyph_fragment[239:232]==0&&packet_value==text_owner&&text_owned;
wire text_commit=runtime_text_commit||
 (restore_applied&&!boot_text_committed);
always @(posedge video_clk or negedge ctrl_rst_n)begin
 if(!ctrl_rst_n)begin text_owned<=0;text_owner<=0;boot_text_committed<=0;end
 else begin
  if(glyph_apply&&glyph_apply_ready)begin text_owned<=1;text_owner<=glyph_token;end
  if(text_response&&text_response_ready&&text_error!=0&&text_response_token==text_owner)text_owned<=0;
  if(glyph_finalize&&packet_value==text_owner)text_owned<=0;
  if(restore_applied)boot_text_committed<=1;
 end
end
// Legacy kind49 subtitle glyph path retired: subtitles use the CMD22 font
// stream only. Any stale kind49 packet is consumed without effect.
assign glyph_consume=1'b1;assign glyph_apply=1'b0;assign glyph_token=32'd0;assign glyph_count=7'd0;
assign glyph_byte=8'd0;assign glyph_packet_address=6'd0;assign glyph_result=1'b0;assign glyph_result_token=32'd0;
assign glyph_error=8'd0;
a_font_stream_receive #(.MAX_SHADOW_BYTES(32768),.SHARED_DESCRIPTOR(1)) font_stream_receive(
 video_clk,ctrl_rst_n,packet_valid&&(font_stream_packet||font_stream_receipt),font_rx_command_ready,
 packet_kind,packet_arg,packet_count,packet_seq,packet_tag,packet_crc,packet_value,font_rx_read_address,packet_word,
 font_rx_font_write_valid,font_rx_font_write_address,font_rx_font_write_data,font_rx_font_write_bank,
 font_rx_raw_write_valid,font_rx_raw_write_address,font_rx_raw_write_data,font_rx_raw_write_bank,
 font_rx_glyph_meta_valid,font_rx_glyph_meta_index,font_rx_glyph_meta_codepoint,font_rx_glyph_meta_size,
 font_rx_commit_valid,font_rx_commit_bank,font_rx_commit_glyph_count,font_rx_commit_utf8_bytes,font_rx_commit_size,font_rx_commit_target,
 font_rx_job_start,font_rx_current_target,font_rx_active_banks,frame_boundary,font_rx_response_valid,font_receipt_captured,font_rx_fragment,font_rx_busy,font_rx_last_error,
 font_stream_render_error,font_rx_current_glyph_count,font_rx_current_utf8_bytes,font_rx_current_size);
// Area r01: a_text_restore_router + a_text_apply (851 LUT) replaced by a minimal
// stub.  Boot-time Flash text restore is removed; the OSD char RAM is now
// written exclusively via the runtime glyph_apply serial path (unchanged).
// restore_settled asserts one clock after boot_ready and atomic style restore,
// so namespace reservation cannot save reset styles over a restored v4 record.
// restore_applied=0, restore_skipped=boot_ready are safe constant values:
//   restore_applied=0  means boot_text_committed never sets from restore, fine.
//   restore_skipped=boot_ready matches the "no boot text found" path.
reg restore_settled_r;
always @(posedge video_clk or negedge ctrl_rst_n)
 if(!ctrl_rst_n)restore_settled_r<=0;else if(boot_ready&&style_restore_settled)restore_settled_r<=1;
assign restore_settled=restore_settled_r;
assign restore_applied=1'b0;
assign restore_skipped=boot_ready;
// Legacy text apply/commit CDC/receipts retired with the kind49 path. The
// OSD legacy character layer stays blank; CMD22 targets render subtitles.
assign glyph_apply_ready=1'b0;assign restore_request_ready=1'b0;
assign char_we=1'b0;assign char_bank=1'b0;assign char_address=6'd0;assign char_data=8'd0;
assign text_publish=1'b0;assign text_publish_token=32'd0;assign text_publish_word=16'd0;
assign text_response=1'b0;assign text_response_token=32'd0;assign text_error=8'd0;
assign glyph_revoke=1'b0;
assign text_ack=1'b0;assign text_ack_token=32'd0;assign text_ack_word=16'd0;
assign text_video_word=16'd0;assign text_video_token=32'd0;assign text_video_valid=1'b0;
assign glyph_fragment_valid=1'b0;assign glyph_fragment=256'd0;

// Parameter and colour execution receives bounded complete SPI bodies from B.
wire control_packet=packet_kind==8'h42||packet_kind==8'h43||packet_kind==8'h44||(packet_kind==8'h41&&packet_count==3);
wire management_consume,management_ack,apply_valid,apply_ready;
wire [5:0] management_address;wire [15:0] management_ack_tag;wire [7:0] management_error;
wire [31:0] apply_token,apply_ack_token;wire [71:0] apply_values,settings;wire settings_valid,apply_ack_valid;wire [7:0] apply_ack_error;
wire [23:0] remote_jedec;wire [2:0] apply_scale,apply_previous_scale,desired_image_scale;wire geometry_applied;wire [11:0] image_scales;
wire colour_start,colour_cancel,colour_byte_valid,colour_ready,colour_byte_ready,colour_done,colour_error,colour_applied_valid;
wire [31:0] colour_token,colour_applied_token;wire [7:0] colour_brightness,colour_contrast,colour_byte_index,colour_byte_data,colour_error_code;
wire [15:0] colour_crc,colour_applied_style;
wire [7:0] colour_gamma,colour_applied_gamma;
wire settings_ack_valid,settings_current,settings_ack_alarm;wire [31:0] settings_epoch,settings_ack_epoch,settings_ack_word;
wire peer_restart;
a_settings_colour_port #(.CLOCK_HZ(CLOCK_HZ),.GAMMA_ENABLED(1),.SCALE_ENABLED(1)) execution(video_clk,ctrl_rst_n,peer_restart||global_flush,packet_valid&&control_packet,management_consume,
 packet_kind,packet_arg,packet_count,packet_tag,packet_crc,packet_value,management_address,packet_word,
 management_ack,management_ack_tag,management_error,
 apply_valid,apply_ready,apply_token,apply_values,remote_jedec,
 colour_start,colour_cancel,colour_token,colour_brightness,colour_contrast,colour_crc,colour_byte_valid,colour_byte_index,colour_byte_data,
 colour_ready,colour_byte_ready,colour_done,colour_error,colour_error_code,colour_gamma,apply_scale,apply_previous_scale,!actual_mode[0]&&!desired_mode[0]);
a_config_actuator #(.CLOCK_HZ(CLOCK_HZ),.APPLY_TIMEOUT_CYCLES(CLOCK_HZ*30)) actuator(video_clk,ctrl_rst_n,peer_restart||global_flush,apply_valid,apply_ready,apply_token,apply_values,
 boot_ready&&boot_found&&boot_error==0,boot_values,settings_current&&colour_applied_valid&&geometry_applied,
 {settings_ack_word[31:16],colour_applied_style},settings_valid,settings[39:8],settings_valid,settings,apply_ack_valid,apply_ack_token,apply_ack_error);

// Image/PCM data receive and retirement; no full-slot overwrite before retire.
wire [5:0] media_address;
wire media_consume,image_req,image_valid,image_abort,image_ack,image_input_ready,image_abort_done;
wire [31:0] image_word;wire [20:0] image_base,read_base0,read_base1,read_base2,read_base3;
wire [1:0] display_bank;wire display_valid,frame_toggle;wire [3:0] image_code,cached_mask;
wire memory_ready,writer_busy,memory_core_busy,write_done_toggle;
wire source_busy,source_done,source_metadata,source_pcm_valid,source_pcm_last,source_pcm_ready,source_start,source_cancel;
wire [7:0] source_error,source_id,echoed_action;wire [31:0] audio_epoch,source_frames,source_pcm_word;
wire media_ack;wire [15:0] media_ack_tag;wire [7:0] media_error;
wire retirement_pending,media_retired,retire_exhausted;wire [31:0] media_generation,retired_media_generation;
wire image_receive_drained;
wire asset_ready,asset_done,asset_error,asset_req,asset_valid,asset_abort,asset_ack,asset_input_ready,asset_abort_done;
wire [31:0] asset_word,asset_words;wire [7:0] asset_code;
a_media_receive32 #(.CLOCK_HZ(CLOCK_HZ),.FRAME_WORDS(FRAME_WIDTH*FRAME_HEIGHT),.RETIRE_GUARD(1),.SESSION_GUARD(1),.SHARED_DESCRIPTOR(1),.SCALE_ENABLED(1)) media_receive(
 video_clk,ctrl_rst_n,packet_valid&&!font_stream_packet&&!control_packet&&!capture_command&&!removed_layout_packet&&packet_kind!=8'h40&&packet_kind!=8'h41&&packet_kind!=8'h48&&packet_kind!=8'h49&&packet_kind!=8'h4a&&packet_kind!=8'h4b&&packet_kind!=8'h4c&&packet_kind!=8'h54&&!program_packet,
 media_consume,packet_kind,packet_arg,packet_count,packet_seq,packet_tag,packet_crc,packet_value,media_address,packet_word,
 memory_ready,image_ack,write_done_toggle,image_input_ready,writer_busy,image_abort_done,
 image_req,image_valid,image_abort,image_word,image_base,read_base0,read_base1,read_base2,read_base3,display_bank,display_valid,image_code,frame_toggle,cached_mask,
 source_start,source_cancel||link_offline,source_id,source_pcm_ready,source_busy,source_done,source_error,audio_epoch,source_metadata,source_frames,source_pcm_valid,source_pcm_last,source_pcm_word,
 peer_restart,,echoed_action,media_ack,media_ack_tag,media_error,,,1'b1,,media_retired,retired_media_generation,1'b1,retirement_pending,media_generation,retire_exhausted,
 source_uid,,identity_known,namespace_prefix,authorized_image_uid,media_result_valid,media_result_header,session_ready,image_receive_drained,image_extents,image_scales,image_dims);
assign packet_address=program_packet?program_address:font_stream_packet?font_rx_read_address:packet_kind==8'h54 ? display_address:control_packet?management_address:packet_kind==8'h49 ?glyph_packet_address:media_address;
// Packet kinds are disjoint. Keep the 0x4A receipt match inside its
// own case so unrelated heartbeat/media owners do not traverse that cone.
// Each selected credit and the real mailbox acceptance edge are unchanged.
function select_packet_credit;
 input[7:0] kind;input[6:0] count;input[8:0] credit;
 begin
 case(kind)
  8'h56,8'h57,8'h58,8'h5a:select_packet_credit=credit[0];
  8'h60,8'h61,8'h62,8'h63,8'h64,8'h65,8'h66:select_packet_credit=credit[1];
  8'h54:select_packet_credit=credit[2];
  8'h53,8'h50,8'h51:select_packet_credit=1'b1;
  8'h4d,8'h4e:select_packet_credit=credit[3];
  8'h42,8'h43,8'h44:select_packet_credit=credit[4];
  8'h41:select_packet_credit=count==3 ? credit[4]:1'b1;
  8'h49:select_packet_credit=credit[5];
  8'h48:select_packet_credit=1'b1;
  8'h4a:select_packet_credit=credit[8] ? credit[1]:1'b1;
  8'h4b,8'h4c:select_packet_credit=credit[6];
  default:select_packet_credit=credit[7];
 endcase
 end
endfunction
assign packet_consume=select_packet_credit(packet_kind,packet_count,
 {font_stream_receipt,media_consume,media_command_consume,glyph_consume,
 management_consume,capture_consume,display_consume,font_rx_command_ready,program_consume});
// A95r04: fixed Flash emergency backdrop removed for area. The emergency
// screen keeps its solid preset colour, text, arrow and sound; B-offline
// still shows the built-in poster. The startup writer slot is released at once.
assign asset_start=1'b0;assign asset_address=24'd0;assign asset_length=7'd0;
assign asset_req=1'b0;assign asset_valid=1'b0;assign asset_abort=1'b0;assign asset_word=32'd0;
assign asset_ready=1'b0;assign asset_done=1'b1;assign asset_error=1'b0;assign asset_code=8'd0;assign asset_words=32'd0;
wire select_asset=asset_ready&&(desired_mode[0]||!display_valid);
wire [90:0] desired_gallery={(select_asset?21'd1667072:read_base0),read_base1,read_base2,read_base3,
 (select_asset?2'd0:display_bank),(select_asset||display_valid),image_code};
wire [31:0] gallery_epoch,gallery_actual_epoch,gallery_applied_epoch,gallery_retired_epoch;
wire [90:0] gallery_actual,gallery_snapshot;wire gallery_applied,gallery_retired;
a_geometry_apply_guard geometry_guard(video_clk,ctrl_rst_n,peer_restart||global_flush,apply_valid&&apply_ready,apply_token,apply_scale,apply_previous_scale,
 apply_ack_valid,apply_ack_token,apply_ack_error,actual_mode[0],desired_mode[0],gallery_applied,
 gallery_epoch,gallery_actual_epoch,gallery_applied_epoch,gallery_actual[4]&&!select_asset,gallery_actual[6:5],image_scales,desired_image_scale,geometry_applied);
// Pure display side effect of a matching, actual gallery-frame ACK.
// This has no ready, busy, cancel or media control outputs.
a_scale_hint product_scale_hint(video_clk,ctrl_rst_n,tick_ms,link_online&&session_ready,
 actual_mode[0]||desired_mode[0],gallery_applied&&gallery_applied_epoch==gallery_actual_epoch&&gallery_applied_epoch==gallery_epoch,
 gallery_actual[4]&&!select_asset,image_extents[gallery_actual[6:5]*2+:2],image_scales[gallery_actual[6:5]*3+:3],scale_hint_descriptor);
// A96: decimal text of the shown picture's original size for the size badge.
a_size_text product_size_text(video_clk,ctrl_rst_n,image_dims[gallery_actual[6:5]*26+:26],size_text);
assign menu_descriptor={scale_hint_descriptor[4:2],scale_hint_descriptor[34],scale_hint_descriptor[1:0],normal_menu_descriptor};
wire commit_exhausted,persist_busy,persist_confirm,persist_failed,persist_intent;wire [2:0] persist_mode,persisted_mode;
a_board_commit_state #(.HEADER_CACHE(1),.STYLE_PERSISTENCE(1)) commits(video_clk,ctrl_rst_n,desired_mode,mode_epoch,mode_ack_valid,mode_ack_epoch,actual_mode,mode_current,
 settings,settings_epoch,settings_ack_valid,settings_ack_epoch,{settings_ack_alarm,settings_ack_word},settings_current,
 desired_gallery,media_generation,gallery_epoch,gallery_retired,gallery_retired_epoch,media_retired,retired_media_generation,commit_exhausted,
 char_we,char_bank,char_address,char_data,text_commit,text_ack_word,
 persist_intent||runtime_text_commit||reserve_request||style_publish,persist_intent?persist_mode:desired_mode,restore_settled&&!text_owned,
 nv_valid,nv_ready,nv_token,nv_values,nv_mode,nv_custom,nv_count,nv_address,nv_byte,nv_source_lock,nv_busy,nv_done,nv_saved_token,nv_error,
 persist_busy,persist_confirm,persist_failed,persisted_mode,text_write_allowed,gallery_snapshot,nv_header_we,nv_header_address,nv_header_byte,nv_header_select,style_publish);
wire action_valid,action_ready,action_audio,backend_cancel,backend_applied,backend_cancel_done;
wire [7:0] action_code,backend_error;wire [31:0] action_token,backend_cancel_token,backend_token,backend_done_token;
wire pcm_service_cancel;wire [31:0] pcm_service_cancel_token;
wire pcm_request_ready,pcm_command_valid,pcm_command_ready,playback_applied,pcm_drained;
wire [31:0] pcm_command_token,pcm_ack_token;wire [7:0] pcm_command_id;
wire pcm_applied,pcm_cancel_done,pcm_exhausted;wire [31:0] pcm_applied_token,pcm_cancel_token;wire [7:0] pcm_error;
wire image_request_ready,image_applied,image_cancel_done,image_sequence_exhausted;
wire [31:0] image_applied_token,image_cancel_token;wire [7:0] image_action_error;wire [15:0] action_word;

wire supervisor_busy,media_draining,media_clear_accept;
wire [31:0] pcm_status,pcm_completed_token;reg [7:0] peer_playback_info;reg peer_ux23_seen;
always @(posedge video_clk or negedge ctrl_rst_n)begin
 if(!ctrl_rst_n)begin peer_playback_info<=8'h20;peer_ux23_seen<=0;end
 else if(!session_ready||!link_online)begin peer_playback_info<=8'h20;peer_ux23_seen<=0;end
 // proof_valid is registered from this immutable, CRC-checked heartbeat.
 // Programme short polls also prove liveness, but contain no playback status.
 // Only the real B producer's CRC-protected UX23 marker carries this schema.
 else if(proof_valid&&packet_tag==16'h2311)begin peer_playback_info<=packet_value[15:8];peer_ux23_seen<=1;end
end
wire [15:0] fault_bitmap={8'd0,commit_exhausted,retire_exhausted,token_exhausted,boot_unknown,boot_corrupt,asset_error,(boot_error!=0),link_offline};
wire [31:0] capabilities=(PCM_ANALYSIS_ENABLED?32'h000ee7ff:32'h000ea7ff)|32'h00200000|
 (link_online&&session_ready?32'h800:32'd0)|(link_offline?32'h1000:32'd0)|(peer_ux23_seen?32'h100000:32'd0);
assign status_payload={jedec_id,boot_error,{4'd0,nv_can_save,nv_busy,nv_stored,boot_ready},peer_playback_info,{4'd0,cached_mask},
 {4'd0,(mode_current?actual_mode[2:1]:desired_mode[2:1]),(mode_current?actual_mode[0]:desired_mode[0]),automatic_mode},
 capabilities,dropped,fault_bitmap,now_ms,{4'd0,image_code},24'd0};
a_local_control local_control(
 video_clk,ctrl_rst_n,tick_ms,link_trip,link_online&&session_ready,automatic_mode,1'b0,key_toggle,key_next,
 urgent_enter,urgent_preset_valid,urgent_preset,boot_ready&&boot_found&&boot_error==0,boot_mode,
 boot_ready&&restore_settled,nv_can_save&&!commit_exhausted,persist_busy,persist_confirm,persist_failed,persisted_mode,
 persist_intent,persist_mode,mode_current,actual_mode,desired_mode,
 local_valid&&!ux_command&&!stream_query_command,base_ready,active_token,active_command,active_arguments[7:0],
 local_cancel,local_cancel_token,action_valid,action_ready,action_audio,action_code,action_token,
 backend_applied,backend_token,backend_error,backend_cancel,backend_cancel_token,backend_cancel_done,backend_done_token,
 status_payload,pcm_status,base_response,base_response_ready,base_token,local_response_address,base_byte,
 supervisor_busy,media_draining,media_clear_accept);
// Keep the actual old-completion observation through subsequent NV/PCM drain.
reg local_retired;reg [31:0] local_retired_token;
always @(posedge video_clk or negedge ctrl_rst_n)begin
 if(!ctrl_rst_n)begin local_retired<=0;local_retired_token<=0;end
 else begin
  if(!local_cancel)local_retired<=0;
  if(local_cancel&&local_response_valid&&local_response_ready&&local_response_token==local_cancel_token)begin
   local_retired<=1;local_retired_token<=local_response_token;
  end
  if(local_cancel&&stream_query_cancelled&&stream_query_cancelled_token==local_cancel_token)begin
   local_retired<=1;local_retired_token<=stream_query_cancelled_token;
  end
  if(local_cancel&&backend_cancel_done&&backend_done_token==local_cancel_token)begin
   local_retired<=1;local_retired_token<=backend_done_token;
  end
 end
end
assign local_cancel_done=local_cancel&&local_retired&&local_retired_token==local_cancel_token&&
 stream_query_idle&&!program_busy&&!supervisor_busy&&!ux_busy&&!media_draining&&!persist_busy&&pcm_drained&&!writer_busy;
wire local_drained=tx_idle&&!writer_busy&&pcm_drained&&capture_drained&&!text_owned&&apply_ready&&colour_ready&&
 image_receive_drained&&image_actions_idle&&!retirement_pending;
a_namespace_control namespace_control(
 video_clk,ctrl_rst_n,boot_ready,restore_settled,nv_can_save,persist_busy,local_drained,reserve_request,
 nv_valid&&nv_ready,nv_token,nv_done,nv_saved_token,nv_sequence,nv_error,allocator_next,seed_valid,seed_token,seed_ready,
 namespace_borrow,namespace_borrow_ready,borrowed_token,local_valid&&local_ready&&active_command==1,active_token,
 link_online,peer_restart,link_trip,proof_valid,
 control_ack,control_ack_token,control_ack_index,control_ack_error,control_ack_captured,
 session_control_valid,session_control_header,identity_known,session_ready,namespace_prefix,namespace_error);
assign action_ready=action_audio?pcm_request_ready:image_request_ready;
a_pcm_control32 pcm_bridge(video_clk,ctrl_rst_n,action_valid&&action_audio,pcm_request_ready,action_token,action_code,
 backend_cancel,backend_cancel_token,pcm_command_valid,pcm_command_ready,pcm_command_token,pcm_command_id,
 pcm_service_cancel,pcm_service_cancel_token,pcm_ack_token,pcm_status,playback_applied,pcm_drained,
 pcm_applied,pcm_applied_token,pcm_error,pcm_cancel_done,pcm_cancel_token);
assign pcm_exhausted=token_exhausted;
wire image_action_done_automatic;
a_image_action32 #(.ACTUAL_MODE_ACK(1)) image_actions(video_clk,ctrl_rst_n,action_valid&&!action_audio,image_request_ready,action_token,action_code,
 key_media||menu_key_valid,menu_key_valid?menu_key_code:key_media_code,link_online&&session_ready,key_borrow,key_borrow_ready,borrowed_token,
 image_action_done,image_action_done_uid,image_action_done_error,media_generation,writer_busy,retirement_pending,
 media_retired,retired_media_generation,backend_cancel,backend_cancel_token,global_flush,global_b_drained,
 image_command_valid,image_command_header,automatic_mode,
 image_applied,image_applied_token,image_action_error,image_cancel_done,image_cancel_token,image_actions_idle,image_action_done_image,gallery_actual[4:0],image_action_done_automatic);
assign image_sequence_exhausted=token_exhausted;
assign action_word=16'd0;
a_media_commands32 #(.FAIR_POLL(1)) media_commands(.clk(video_clk),.rst_n(ctrl_rst_n),.session_ready(session_ready),.identity_known(identity_known),
 .packet_valid(packet_valid&&(packet_kind==8'h4b||packet_kind==8'h4c)),.packet_consume(media_command_consume),.packet_kind(packet_kind),.packet_count(packet_count),
 .packet_sequence(packet_seq),.packet_tag(packet_tag),.packet_value(packet_value),.borrow_valid(image_borrow),.borrow_ready(image_borrow_ready),.borrowed_uid(borrowed_token),
 .pcm_uid(source_uid),.pcm_id(source_id),.pcm_cancel(source_cancel||link_offline),.action_valid(image_command_valid),.action_header(image_command_header),
 .command_valid(media_command_valid),.command_header(media_command_header),.image_uid(authorized_image_uid),
 .action_done(image_action_done),.action_done_uid(image_action_done_uid),.action_done_error(image_action_done_error),.poll_finished(media_command_captured),.pcm_completed_token(pcm_completed_token),.pcm_failed_token(pcm_status[23:16]!=0?source_uid:32'd0),.text_uid(program_expected_uid),.action_done_image(image_action_done_image),.action_done_automatic(image_action_done_automatic));
// Recovery takes priority; the three autonomous clients rotate after each
// actual allocation. A PC packet retains priority in the shared allocator.
reg [1:0] borrow_turn;reg [1:0] borrow_choice;
always @(*)begin
 borrow_choice=0;
 case(borrow_turn)
  0:if(image_borrow)borrow_choice=0;else if(pcm_auto_borrow)borrow_choice=1;else borrow_choice=2;
  1:if(pcm_auto_borrow)borrow_choice=1;else if(key_borrow)borrow_choice=2;else borrow_choice=0;
  default:if(key_borrow)borrow_choice=2;else if(image_borrow)borrow_choice=0;else borrow_choice=1;
 endcase
end
assign borrow_valid=namespace_borrow||(session_ready&&(image_borrow||pcm_auto_borrow||key_borrow));
assign namespace_borrow_ready=namespace_borrow&&borrow_ready;
assign image_borrow_ready=!namespace_borrow&&session_ready&&borrow_choice==0&&borrow_ready;
assign pcm_auto_ready=!namespace_borrow&&session_ready&&borrow_choice==1&&borrow_ready;
assign key_borrow_ready=!namespace_borrow&&session_ready&&borrow_choice==2&&borrow_ready;
always @(posedge video_clk or negedge ctrl_rst_n)
 if(!ctrl_rst_n)borrow_turn<=0;
 else if(borrow_valid&&borrow_ready&&!namespace_borrow)borrow_turn<=borrow_choice==2?0:borrow_choice+1'b1;
assign backend_applied=pcm_applied||image_applied;
assign backend_token=pcm_applied?pcm_applied_token:image_applied_token;
assign backend_error=pcm_applied?pcm_error:image_action_error;
assign backend_cancel_done=pcm_cancel_done||image_cancel_done;
assign backend_done_token=pcm_cancel_done?pcm_cancel_token:image_cancel_token;


reg [2:0] reply_page;reg [15:0] common_ack_tag;reg common_ack_valid;reg [7:0] common_error;
reg [239:0] status_body_internal;
integer j;
always @(posedge video_clk or negedge ctrl_rst_n)begin
 if(!ctrl_rst_n)begin reply_page<=0;common_ack_tag<=0;common_ack_valid<=0;common_error<=0;end
 else if(packet_valid&&packet_consume)begin
  reply_page<=reply_page==3?0:reply_page+1'b1;
  if(packet_kind==8'h53)begin common_ack_tag<=packet_tag;common_ack_valid<=1;common_error<=0;end
  else if(packet_kind==8'h54)begin end // display level only; no configuration/media ACK
  else if(control_packet)begin common_ack_tag<=packet_tag;common_ack_valid<=1;common_error<=management_error;end
  else if(!capture_command&&!removed_layout_packet&&packet_kind!=1&&packet_kind!=8'h40&&packet_kind!=8'h41&&packet_kind!=8'h48&&packet_kind!=8'h49&&packet_kind!=8'h4a)begin
   common_ack_tag<=packet_tag;common_ack_valid<=1;common_error<=media_error;
  end
 end
end
always @(*)begin
 status_body_internal=0;status_body_internal[239:208]=32'h434e0681;
 status_body_internal[207:200]=common_ack_tag[7:0];status_body_internal[199:192]=common_ack_tag[15:8];status_body_internal[191:184]=common_error;
 status_body_internal[183:176]={source_busy,display_valid,desired_mode[2:1],frame_toggle,board_ready,memory_ready,desired_mode[0]};
 status_body_internal[175:168]=action_word[7:0];status_body_internal[167:160]=action_word[15:8];status_body_internal[159:152]=source_id;status_body_internal[151:144]=audio_epoch[7:0];
 for(j=0;j<4;j=j+1)status_body_internal[143-j*8-:8]=settings[8+j*8+:8];
 status_body_internal[111:104]={7'd0,source_cancel||link_offline};status_body_internal[103:96]={4'd0,image_code};
 status_body_internal[95:88]={identity_known,session_ready,apply_ack_valid,2'd0,reply_page};status_body_internal[87:80]={text_ack_word[6:0],common_ack_valid};
 case(reply_page)
  0:begin status_body_internal[79:72]={4'd0,nv_can_save,nv_busy,nv_stored,boot_ready};for(j=0;j<9;j=j+1)status_body_internal[71-j*8-:8]=nv_saved_values[j*8+:8];end
  1:begin status_body_internal[79:72]=namespace_prefix[7:0];status_body_internal[71:64]=namespace_prefix[15:8];end
  2:begin for(j=0;j<4;j=j+1)status_body_internal[79-j*8-:8]=apply_ack_token[j*8+:8];status_body_internal[47:40]=apply_ack_error;end
  3:begin
   for(j=0;j<4;j=j+1)status_body_internal[79-j*8-:8]=colour_applied_token[j*8+:8];
   status_body_internal[47:40]=colour_applied_style[7:0];status_body_internal[39:32]=colour_applied_style[15:8];status_body_internal[31:24]={4'd0,colour_applied_gamma[2:0],colour_applied_valid};
   status_body_internal[23:16]=challenge[7:0];status_body_internal[15:8]=challenge[15:8];status_body_internal[7:0]=8'ha6;
  end
 endcase
end

assign status_body=status_body_internal;
a_board_data_plane #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)) data_plane(.clk(clk),.rst_n(rst_n),.ctrl_rst_n(ctrl_rst_n),.video_clk(video_clk),.video_rst_n(video_rst_n),.frame_boundary(frame_boundary),.mem_clk(mem_clk),
 .gallery_word(gallery_snapshot),.gallery_generation(gallery_epoch),.gallery_actual(gallery_actual),.gallery_actual_generation(gallery_actual_epoch),
 .gallery_applied_valid(gallery_applied),.gallery_applied_generation(gallery_applied_epoch),.retire_valid(gallery_retired),.retired_generation(gallery_retired_epoch),
 .image_req(image_req),.image_valid(image_valid),.image_abort(image_abort),.image_word(image_word),.image_base(image_base),.image_ack(image_ack),.image_input_ready(image_input_ready),.image_abort_done(image_abort_done),
 .asset_done(asset_ready||asset_done),.asset_ready(asset_ready),.asset_req(asset_req),.asset_valid(asset_valid),.asset_abort(asset_abort),.asset_word(asset_word),.asset_ack(asset_ack),.asset_input_ready(asset_input_ready),.asset_abort_done(asset_abort_done),
 .memory_ready(memory_ready),.writer_busy(writer_busy),.memory_core_busy(memory_core_busy),.write_done_toggle(write_done_toggle),
 .mode_valid(!commit_exhausted),.mode_token(mode_epoch),.desired_mode(desired_mode),.actual_mode_valid(mode_ack_valid),.actual_mode_token(mode_ack_epoch),.actual_mode(actual_mode),
 .settings_valid(!commit_exhausted),.settings_alarm_external(settings[0]),.settings_token(settings_epoch),.settings_word(settings[71:40]),
 .settings_applied_valid(settings_ack_valid),.settings_applied_alarm_external(settings_ack_alarm),.settings_applied_token(settings_ack_epoch),.settings_applied_word(settings_ack_word),
 .fault_word({2'd0,boot_error,fault_bitmap}),.video_text_descriptor(text_video_word),.video_layout(193'd0),.menu_descriptor(menu_descriptor),.size_text(size_text),
 .subtitle_style(subtitle_style),.emergency_style(emergency_style),.emergency_descriptor(emergency_descriptor),.emergency_font_we(emergency_font_we),
 .emergency_font_address(emergency_font_address),.emergency_font_data(emergency_font_data),.char_we(char_we),.char_bank(char_bank),.char_address(char_address),.char_data(char_data),
 .colour_start(colour_start),.colour_cancel(colour_cancel),.colour_token(colour_token),.colour_brightness(colour_brightness),.colour_contrast(colour_contrast),.colour_crc(colour_crc),.colour_byte_valid(colour_byte_valid),.colour_byte_index(colour_byte_index),.colour_byte_data(colour_byte_data),
 .colour_ready(colour_ready),.colour_byte_ready(colour_byte_ready),.colour_done(colour_done),.colour_error(colour_error),.colour_error_code(colour_error_code),.colour_applied_valid(colour_applied_valid),.colour_applied_token(colour_applied_token),.colour_applied_style(colour_applied_style),
 .colour_gamma(colour_gamma),.colour_applied_gamma(colour_applied_gamma),
 .peer_online(link_online&&session_ready),.reload(peer_restart||global_flush),.source_busy(source_busy),.source_done(source_done),.source_error(source_error),.source_pcm_valid(source_pcm_valid),.source_pcm_word(source_pcm_word),.source_pcm_last(source_pcm_last),.source_frames(source_frames),.source_metadata(source_metadata),
 .source_pcm_ready(source_pcm_ready),.source_start(source_start),.source_cancel(source_cancel),.source_id(source_id),.pcm_command_valid(pcm_command_valid),.pcm_command_token(pcm_command_token),.pcm_command_id(pcm_command_id),
 .pcm_cancel_valid(pcm_service_cancel),.pcm_cancel_token(pcm_service_cancel_token),.source_uid(source_uid),.pcm_command_ready(pcm_command_ready),.pcm_acknowledged_token(pcm_ack_token),.pcm_status(pcm_status),.playback_applied(playback_applied),.pcm_drained(pcm_drained),
 .pcm_auto_borrow(pcm_auto_borrow),.pcm_auto_ready(pcm_auto_ready),.pcm_auto_uid(borrowed_token),
 .pcm_tap_valid(pcm_tap_valid),.pcm_tap_left(pcm_tap_left),.pcm_tap_right(pcm_tap_right),
 .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D2_P(HDMI_D2_P),.HDMI_D1_P(HDMI_D1_P),.HDMI_D0_P(HDMI_D0_P),.HDMI_DDC_SCL(HDMI_DDC_SCL),.HDMI_DDC_SDA(HDMI_DDC_SDA),.normal_audio_id({4'd0,peer_playback_info[3:0]}),.normal_program_active(automatic_mode&&peer_playback_info[4]&&peer_playback_info[6:5]==0),
 .normal_builtin(automatic_mode&&peer_playback_info[4]&&peer_playback_info[6:5]==2),.pcm_completed_token(pcm_completed_token),.title_descriptor(title_descriptor),.title_font_we(title_font_we),.title_font_address(title_font_address),.title_font_data(title_font_data),.program_valid(program_valid),.program_bank(program_bank),.program_image(program_image),.program_count(program_count),
 .program_rates(program_rates),.program_uid(program_uid),.program_released(program_released),.program_font_we(program_font_we),
 .program_font_address(program_font_address),.program_font_data(program_font_data),.normal_program_running(automatic_mode&&peer_playback_info[4]),.normal_program_narrated(peer_playback_info[6:5]==0),
 .font_stream_job_start(font_rx_job_start),.font_stream_job_target(font_rx_current_target),.font_stream_job_size(font_rx_current_size),.font_stream_job_bank(font_rx_font_write_bank),
 .font_stream_job_glyph_count(font_rx_current_glyph_count),.font_stream_job_utf8_bytes(font_rx_current_utf8_bytes),
 .font_stream_font_we(font_rx_font_write_valid),.font_stream_font_address(font_rx_font_write_address),.font_stream_font_data(font_rx_font_write_data),.font_stream_font_bank(font_rx_font_write_bank),
 .font_stream_raw_we(font_rx_raw_write_valid),.font_stream_raw_address(font_rx_raw_write_address),.font_stream_raw_data(font_rx_raw_write_data),.font_stream_raw_bank(font_rx_raw_write_bank),
 .font_stream_meta_valid(font_rx_glyph_meta_valid),.font_stream_meta_index(font_rx_glyph_meta_index),.font_stream_meta_codepoint(font_rx_glyph_meta_codepoint),.font_stream_meta_size(font_rx_glyph_meta_size),
 .font_stream_commit_valid(font_rx_commit_valid),.font_stream_commit_bank(font_rx_commit_bank),.font_stream_commit_count(font_rx_commit_glyph_count),.font_stream_commit_size(font_rx_commit_size),.font_stream_commit_target(font_rx_commit_target),.font_stream_render_error(font_stream_render_error),
 .pcm_event_data(),
 .pcm_event_valid());
a_program_receive program_receive(.clk(video_clk),.rst_n(ctrl_rst_n),.frame_boundary(frame_boundary),
 .cancel(global_flush||peer_restart||media_clear_accept),
 .valid(packet_valid&&program_packet),.consume(program_consume),.kind(packet_kind),.count(packet_count),.tag(packet_tag),.packet_crc(packet_crc),
 .value(packet_value),.expected_uid(program_expected_uid),.session_ready(session_ready),.read_address(program_address),.read_word(packet_word),
 .reply_valid(program_reply_valid),.reply_header(program_reply_header),.busy(program_busy),.font_we(program_font_we),.font_address(program_font_address),.font_data(program_font_data),
 .front_valid(program_valid),.front_bank(program_bank),.front_image(program_image),.front_released(program_released),.front_count(program_count),.front_length(program_length),.samples_per_pixel(program_rates),
 .raw_we(program_raw_we),.raw_bank(program_raw_bank),.raw_address(program_raw_address),.raw_byte(program_raw_byte),.query_hold(program_query_hold),.front_uid(program_uid));
// A compact actual-state scan replaces the broad diagnostic panel/history RAM.
function [7:0] hex_segments;input [3:0] x;begin case(x)
 0:hex_segments=8'hc0;1:hex_segments=8'hf9;2:hex_segments=8'ha4;3:hex_segments=8'hb0;
 4:hex_segments=8'h99;5:hex_segments=8'h92;6:hex_segments=8'h82;7:hex_segments=8'hf8;
 8:hex_segments=8'h80;9:hex_segments=8'h90;10:hex_segments=8'h88;11:hex_segments=8'h83;
 12:hex_segments=8'hc6;13:hex_segments=8'ha1;14:hex_segments=8'h86;default:hex_segments=8'h8e;endcase end endfunction
generate if(STATUS_DIGITS_ENABLED)begin: status_digits
seg_scan #(.CLK_FREQ(CLOCK_HZ)) display_scan(video_clk,ctrl_rst_n,seg_sel,seg_data,
 hex_segments({1'b0,desired_mode}),hex_segments({2'd0,link_offline,link_online}),hex_segments(image_code),hex_segments(cached_mask),
 hex_segments(boot_error[3:0]),hex_segments(boot_error[7:4]),hex_segments(nv_error[3:0]),hex_segments(nv_error[7:4]));
end else begin: status_digits_off
 assign seg_sel=8'hff;assign seg_data=8'hff;
end endgenerate
endmodule
`default_nettype wire

// The timer never feeds back into the image, sound, subtitle or RPC owners.
module a_scale_hint(input clk,rst_n,tick_ms,online,emergency,applied,display_valid,
 input [1:0] extent,input [2:0] geometry,output [34:0] descriptor);
reg [10:0] remaining;reg [1:0] previous;reg [2:0] previous_geometry;reg previous_valid;
// A95r02: re-show on every newly applied picture (rising edge of applied), 2 s.
reg applied_d;
assign descriptor={remaining!=0,3'd7,2'd2,1'b1,8'h80,15'd0,previous_geometry,previous};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin remaining<=0;previous<=0;previous_geometry<=0;previous_valid<=0;applied_d<=0;end
 else if(!online||emergency)begin remaining<=0;previous<=0;previous_geometry<=0;previous_valid<=0;applied_d<=0;end
 else begin
  applied_d<=applied;
  if(tick_ms&&remaining!=0)remaining<=remaining-1'b1;
  if(applied&&display_valid&&geometry<=4&&(!previous_valid||!applied_d||extent!=previous||geometry!=previous_geometry))begin
   previous<=extent;previous_geometry<=geometry;previous_valid<=1;remaining<=2000;
  end
 end
end
endmodule


// Only an actual matching normal gallery may confirm a changed geometry.
// Emergency remains independent: normal-picture rebuilding is deferred there.
module a_geometry_apply_guard(
 input clk,rst_n,clear,apply_accept,input [31:0] apply_token,
 input [2:0] apply_scale,apply_previous_scale,
 input acknowledged_valid,input [31:0] acknowledged_token,input [7:0] acknowledged_error,
 input actual_emergency,desired_emergency,gallery_applied,
 input [31:0] gallery_epoch,gallery_actual_epoch,gallery_applied_epoch,
 input normal_display_valid,input [1:0] actual_bank,input [11:0] committed_scales,
 output reg [2:0] desired_scale,output geometry_applied);
reg pending,last_frame_valid;
reg [2:0] previous_scale;
reg [31:0] owner,last_frame_epoch;
wire direct_frame=gallery_applied&&gallery_applied_epoch==gallery_actual_epoch&&gallery_applied_epoch==gallery_epoch;
wire retained_frame=last_frame_valid&&last_frame_epoch==gallery_actual_epoch&&gallery_actual_epoch==gallery_epoch;
wire actual_scale_matches=normal_display_valid&&(direct_frame||retained_frame)&&
 committed_scales[actual_bank*3+:3]==desired_scale;
// Unchanged geometry need not wait for a normal picture hidden by emergency,
// or for a card that is absent. Changed geometry never receives that shortcut.
wire unchanged_hidden=desired_scale==previous_scale&&
 (actual_emergency||desired_emergency||!normal_display_valid);
assign geometry_applied=!pending||unchanged_hidden||
 (!actual_emergency&&!desired_emergency&&actual_scale_matches);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin desired_scale<=0;previous_scale<=0;pending<=0;owner<=0;last_frame_valid<=0;last_frame_epoch<=0;end
 else begin
  if(direct_frame)begin last_frame_valid<=1;last_frame_epoch<=gallery_applied_epoch;end
  if(pending&&acknowledged_valid&&acknowledged_token==owner)begin
   pending<=0;if(acknowledged_error!=0)desired_scale<=previous_scale;
  end
  if(apply_accept)begin
   previous_scale<=apply_previous_scale;desired_scale<=apply_scale;pending<=1;owner<=apply_token;
  end
  if(clear)begin if(pending)desired_scale<=previous_scale;pending<=0;last_frame_valid<=0;end
 end
end
endmodule

// A96r02: {valid, 9 x 4-bit codes}, code 0-9 digit, 10 'X', 15 blank; text is
// left-aligned "WWWWXHHHH" without leading zeros. Repeated subtraction of
// 1000/100/10/1 and a right-shifting text register (no indexed writes).
// Restarted whenever the shown picture's size changes. Display only.
module a_size_text(input clk,rst_n,input [25:0] dims,output reg [36:0] text);
reg [25:0] current;reg [12:0] value,other;reg [1:0] place;reg [3:0] digit,pushed;reg second,started,busy,pad;
wire [12:0] step=place==0?13'd1000:place==1?13'd100:place==2?13'd10:13'd1;
wire push_digit=busy&&!pad&&value<step&&(digit!=0||started||place==3);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin text<=0;current<=0;value<=0;other<=0;place<=0;digit<=0;pushed<=0;second<=0;started<=0;busy<=0;pad<=0;end
 else if(!busy)begin
  if(dims!=current)begin
   current<=dims;text[36]<=0;
   if(dims[25:13]!=0&&dims[12:0]!=0)begin value<=dims[25:13];other<=dims[12:0];place<=0;digit<=0;pushed<=0;second<=0;started<=0;pad<=0;busy<=1;end
  end
 end else if(pad)begin
  if(pushed==9)begin text[36]<=1;busy<=0;end
  else begin text[35:0]<={4'd15,text[35:4]};pushed<=pushed+1'b1;end
 end else if(value>=step)begin value<=value-step;digit<=digit+1'b1;end
 else begin
  if(push_digit)begin text[35:0]<={digit,text[35:4]};pushed<=pushed+1'b1;started<=1;end
  digit<=0;
  if(place!=3)place<=place+1'b1;
  else if(!second)begin second<=1;place<=0;value<=other;started<=0;text[35:0]<={4'd10,(push_digit?{digit,text[35:8]}:text[35:4])};pushed<=pushed+(push_digit?2'd2:2'd1);end
  else pad<=1;
 end
end
endmodule
