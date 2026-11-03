// One production control root: actual complete request RAM, normal services,
// B curve calculator, media FIFOs/staging, UID envelope and a single SPI master.
// Physical reader drainage is a separate actual owner credit, not a CS level.
module b_board_services #(parameter CLOCK_HZ=50000000,SPI_DIV=4,HALF_CYCLES=3,
 FRAME_WORDS=307200,MEDIA_UID32=0,ROM_FILE="unicode.mem",IMAGE_SCALE_ENABLED=0,FRAME_WIDTH=640,FRAME_HEIGHT=480,ADAPTIVE_IMAGES=0,FONT_SERVICE_ENABLED=0,CMD22_PERSISTENCE_ENABLED=FONT_SERVICE_ENABLED)(
 input clk,rst_n,miso,output cs_n,sclk,mosi,
 input image_req,image_valid,input [31:0] image_word,input [1:0] write_bank,display_bank,
 input display_valid,input [3:0] image_code,output image_ack,frame_finish_toggle,image_sector_room,
 output next_image,previous_image,reload,auto_valid,auto_value,auto_toggle,emergency,
 output [31:0] period_ms,output period_valid,
 input pcm_valid,pcm_last,input [31:0] pcm_word,output pcm_ready,
 input audio_metadata,input [31:0] audio_frames,input audio_busy,audio_done,input [7:0] audio_error,
 output audio_start,audio_cancel,output [7:0] audio_id,output audio_urgent,
 input event_valid,input [127:0] event_data,input reader_drained,output pause_reader,
 input [31:0] image_uid,audio_uid,input [7:0] audio_request_id,input audio_request_cancel,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso,
 output global_done,output [31:0] global_token,output online,output [15:0] bad_replies,
 output descriptor_error,output [15:0] dropped,
 input [7:0] raw_address,output [7:0] raw_byte,output committed_valid,output [7:0] committed_length,
 output [6:0] committed_glyph_count,
 input image_control_idle,image_reader_drained,input [3:0] image_cached_mask,input image_reload_accepted,
 input [2:0] image_scale_selector,input [15:0] image_source_width,image_source_height,input [31:0] image_source_pixels,input [12:0] image_orig_width,image_orig_height,
 input [1:0] play_mode,input actual_automatic,output play_mode_valid,output [1:0] requested_play_mode,
 output program_audio_terminal,output [7:0] program_audio_id,
 input program_catalog_valid,input program_grant_needed,output program_grant_valid,output [31:0] program_uid,
 input program_tx,output program_ready,input [7:0] program_kind,input [6:0] program_count,input [15:0] program_sequence,program_tag,input [31:0] program_value,
 output program_done,output [5:0] program_address,input [31:0] program_word,
 output program_reply_valid,output [255:0] program_reply,output program_grant_permission,input [3:0] image_catalog_count,input program_prepared,
 output geometry_pause,geometry_invalidate,output image_progress);
wire reply_valid,transport_idle,spi_busy;wire [495:0] reply_body;
reg [31:0] captured_pc_uid;
wire [31:0] fragment_uid={reply_body[199:192],reply_body[207:200],reply_body[215:208],reply_body[223:216]};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)captured_pc_uid<=0;
 else if(reply_valid&&reply_body[255:248]==8'hf6&&reply_body[247:240]==0)captured_pc_uid<=fragment_uid;
end
wire request_valid,request_ready,fragment_ready,ack_valid,ack_ready,ack_captured,notice_valid,notice_session;
wire menu_toggle,menu_next,menu_plus,menu_minus,menu_backend_valid,menu_assembled_ready,menu_control_done;
wire menu_response_captured;wire [31:0] menu_response_uid,menu_control_token;wire [191:0] menu_response_payload;
wire display_tick_ms;wire display_visible,display_known,display_live,display_drained,display_exhausted,display_tx,display_ready,display_done;
wire [2:0] display_item;wire [15:0] display_value;wire [1:0] display_status;wire [7:0] display_error;
wire [31:0] display_cookie,display_tx_value,display_word;wire [7:0] display_kind;wire [6:0] display_count;
wire [15:0] display_sequence,display_tag;wire [5:0] display_address;
wire menu_pair_valid,menu_pair_ready,menu_pair_done;wire [7:0] menu_pair_kind;wire [6:0] menu_pair_count;
wire [15:0] menu_pair_sequence,menu_pair_tag;wire [31:0] menu_pair_value,menu_pair_word;wire [5:0] menu_pair_address;
wire menu_tx,menu_tx_ready,menu_tx_done;wire [7:0] menu_tx_kind;wire [6:0] menu_tx_count;
wire [15:0] menu_tx_sequence,menu_tx_tag;wire [31:0] menu_tx_value;
wire normal_management_idle;
wire font_initialized;wire [7:0] font_boot_error;
wire font_ingress_ready_internal,font_stream_drained;
wire journal_lease,journal_valid,journal_ready,journal_done,journal_error,journal_byte_valid;
wire [2:0] journal_operation;wire [23:0] journal_address;wire [6:0] journal_length;
wire [7:0] journal_write_byte,journal_error_code,journal_byte;wire [5:0] journal_write_index,journal_index;
wire durable_font_complete;wire [7:0] durable_font_error;
wire startup_ready,restore_active,restore_start,restore_raw_valid,restore_raw_last,restore_grant_needed,restore_grant_valid;
wire [31:0] restore_uid;wire [1:0] restore_target,restore_size;wire [6:0] restore_glyphs;
wire [7:0] restore_length,restore_raw_byte,restore_error;
wire live_font_start,live_font_raw_valid,live_font_raw_last;
wire [31:0] live_font_uid;wire [6:0] live_font_glyphs;wire [7:0] live_font_length,live_font_raw_byte;
wire [1:0] live_font_size,live_font_target;
wire font_ingress_request_ready,font_start_valid,font_start_ready,font_raw_valid,font_raw_ready,font_raw_last,font_cancel_valid;
wire [31:0] font_start_uid,font_owner_uid;wire [6:0] font_start_glyph_count;wire [7:0] font_start_utf8_bytes;
wire [1:0] font_start_size,font_start_target;wire [7:0] font_body_address,font_raw_byte;
assign font_start_valid=restore_active?restore_start:live_font_start;
assign font_start_uid=restore_active?restore_uid:live_font_uid;
assign font_start_glyph_count=restore_active?restore_glyphs:live_font_glyphs;
assign font_start_utf8_bytes=restore_active?restore_length:live_font_length;
assign font_start_size=restore_active?restore_size:live_font_size;
assign font_start_target=restore_active?restore_target:live_font_target;
assign font_raw_valid=restore_active?restore_raw_valid:live_font_raw_valid;
assign font_raw_byte=restore_active?restore_raw_byte:live_font_raw_byte;
assign font_raw_last=restore_active?restore_raw_last:live_font_raw_last;

reg font_result_pending;reg [31:0] font_result_owner;reg [7:0] font_result_code;
wire font_result_affected,font_request_gate;

wire font_stream_complete,font_stream_blocked,font_control_done,font_result_valid;wire [7:0] font_stream_error,font_result_error;
wire [31:0] font_control_token,font_result_token,font_body_release_token;wire font_body_release_valid,font_busy;
wire font_request_valid,font_request_ready,font_request_cancel,font_glyph_valid,font_glyph_ready,font_glyph_first,font_glyph_last,font_request_complete;
wire [15:0] font_request_codepoint;wire [1:0] font_request_size;wire [31:0] font_request_token,font_glyph_token;
wire [7:0] font_glyph_byte,font_request_result;wire [8:0] font_glyph_index;
wire font_packet_valid,font_packet_ready,font_packet_done;wire [7:0] font_packet_kind,font_packet_arg;
wire [6:0] font_packet_count;wire [15:0] font_packet_sequence,font_packet_tag;wire [31:0] font_packet_value,font_packet_word;wire [5:0] font_packet_address;
wire font_route_valid,font_route_ready,font_route_done;wire [7:0] font_route_kind;wire [6:0] font_route_count;
wire [15:0] font_route_sequence,font_route_tag;wire [31:0] font_route_value,font_route_word;wire [5:0] font_route_address;
wire glyph_font_valid,glyph_font_ready,glyph_font_done;wire [7:0] glyph_font_kind;wire [6:0] glyph_font_count;
wire [15:0] glyph_font_sequence,glyph_font_tag;wire [31:0] glyph_font_value,glyph_font_word;wire [5:0] glyph_font_address;
wire normal_request_ready,analysis_request_ready,analysis_response,analysis_response_ready,analysis_control_done;
wire [31:0] analysis_response_token,analysis_control_token;wire [191:0] analysis_payload;
wire analysis_tx,analysis_tx_ready,analysis_tx_done;wire [7:0] analysis_tx_kind;wire [6:0] analysis_tx_count;
wire [15:0] analysis_tx_sequence,analysis_tx_tag;wire [31:0] analysis_tx_value;
wire [7:0] normal_source_address;
wire auxiliary_response=font_result_pending||analysis_response;
wire auxiliary_response_ready;
wire [31:0] auxiliary_token=font_result_pending?font_result_owner:analysis_response_token;
wire [191:0] auxiliary_payload=font_result_pending?{160'd0,8'd0,font_result_code,{7'd0,(font_result_code!=0)},8'd22}:analysis_payload;
assign analysis_response_ready=auxiliary_response_ready&&!font_result_pending;
wire analysis_pair_valid,analysis_pair_ready,analysis_pair_done;wire [7:0] analysis_pair_kind;wire [6:0] analysis_pair_count;
wire [15:0] analysis_pair_sequence,analysis_pair_tag;wire [31:0] analysis_pair_value,analysis_pair_word;wire [5:0] analysis_pair_address;
wire pair_valid,pair_ready,pair_done;wire [7:0] pair_kind;wire [6:0] pair_count;
wire [15:0] pair_sequence,pair_tag;wire [31:0] pair_value,pair_word;wire [5:0] pair_address;
wire [31:0] request_token,ack_token,notice_token;wire [7:0] request_command,request_length,ack_index,ack_error,source_address,source_byte;
wire [47:0] request_arguments;
wire normal_done,curve_control_done;wire [31:0] normal_token,curve_control_token;
wire glyph_valid,glyph_ready,glyph_done,rpc_valid,rpc_ready,rpc_done;
wire [7:0] glyph_kind,rpc_kind;wire [6:0] glyph_count,rpc_count;
wire [15:0] glyph_sequence,glyph_tag,rpc_sequence,rpc_tag;wire [31:0] glyph_value,glyph_word,rpc_value,rpc_word;
wire rpc_capture_ready=rpc_kind==8'h41||captured_pc_uid==rpc_value;
wire scheduler_rpc_ready;
assign rpc_ready=scheduler_rpc_ready&&rpc_capture_ready;
wire [5:0] glyph_address,rpc_address;
wire rpc_pair_valid,rpc_pair_ready,rpc_pair_done;wire [7:0] rpc_pair_kind,rpc_pair_arg;wire [6:0] rpc_pair_count;
wire [15:0] rpc_pair_sequence,rpc_pair_tag;wire [31:0] rpc_pair_value,rpc_pair_word;wire [5:0] rpc_pair_address;
wire colour_values_valid,actuation_request,actuation_done,snapshot_valid,snapshot_ready,config_event;
wire [31:0] actuation_token;wire [71:0] colour_values,actuation_values,legacy_values;
wire [191:0] snapshot_payload;wire [23:0] snapshot_jedec;wire [127:0] config_event_data;
wire [7:0] actuation_error,legacy_flags,legacy_text_summary;
wire [7:0] colour_gamma,actuation_gamma,curve_gamma,curve_prepared_gamma,curve_status_gamma;
wire curve_prepared,curve_failed,curve_meta,curve_data,curve_done,curve_status_strobe,curve_status_valid;
wire [31:0] curve_prepared_token,curve_token,curve_meta_word,curve_word,curve_status_token;
wire [15:0] curve_style,curve_status_style;wire [7:0] curve_failure,curve_error;wire [5:0] curve_address;
wire source_start,source_busy,source_done,offer,accept,legacy_busy,legacy_done,media_drained,image_producer_drained,curve_inflight,actuation_inflight;
wire [7:0] source_kind,source_arg,legacy_kind,legacy_arg,link_error;
wire [6:0] source_count,legacy_count;wire [15:0] source_sequence,source_tag,legacy_sequence,legacy_tag;
wire [31:0] source_value,source_uid,source_word,legacy_value,legacy_word;wire [5:0] source_address_word,legacy_address;
wire envelope_error,overflow,echo_seen;wire [15:0] echo_nonce;
wire image_command_granted,command_pause,command_control_done;wire [31:0] command_control_token,authorized_image_uid,authorized_audio_uid;
wire [7:0] authorized_audio_id;wire authorized_audio_cancel;
wire command_next,command_previous,command_reload,command_auto_valid,command_auto_value,command_auto_toggle;
wire legacy_next,legacy_previous,legacy_reload,legacy_auto_valid,legacy_auto_value,legacy_auto_toggle;
wire command_tx,command_ready,command_done;wire [7:0] command_kind;wire [6:0] command_count;
wire text_grant_needed,text_grant_valid,normal_text_grant_needed,text_engine_idle;wire [31:0] text_granted_uid;
wire [15:0] command_sequence,command_tag;wire [31:0] command_value;
wire merged_valid,merged_ready,merged_done;wire [7:0] merged_kind;wire [6:0] merged_count;
wire [15:0] merged_sequence,merged_tag;wire [31:0] merged_value,merged_word;wire [5:0] merged_address;
assign font_result_affected=notice_valid&&(notice_session||notice_token==font_result_owner);
assign font_request_gate=startup_ready&&!notice_valid&&!font_result_pending&&!font_result_valid;
assign font_ingress_request_ready=font_ingress_ready_internal&&font_request_gate&&normal_management_idle;
wire font_cancel_match=notice_valid&&(notice_session||notice_token==(restore_active?restore_uid:font_owner_uid))&&(font_busy||!font_stream_drained||restore_active);
wire font_cancel_applied;
b_font_cancel_boundary font_cancel_stage(.clk(clk),.rst_n(rst_n),.notice_valid(notice_valid),
 .cancel_match(font_cancel_match),.cancel_valid(font_cancel_valid),.applied(font_cancel_applied));
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin font_result_pending<=0;font_result_owner<=0;font_result_code<=0;end
 else begin
  if(font_result_pending&&(auxiliary_response_ready||(font_result_affected&&normal_done&&transport_idle)))font_result_pending<=0;
  if(font_result_valid)begin font_result_pending<=1;font_result_owner<=font_result_token;font_result_code<=font_result_error;end
 end
end
wire actual_cancel_private=notice_valid&&transport_idle&&!actuation_inflight;
wire config_actuation_done=actuation_done||(curve_failed&&actuation_request)||
 (actual_cancel_private&&actuation_request&&(notice_session||notice_token==actuation_token));
wire [7:0] config_actuation_error=actuation_done?actuation_error:curve_failed?curve_failure:8'h43;
// Registered pause decision. The 32-bit notice compare feeds one flop; every
// media/image/scale/transport pause consumer starts from it. A matching notice
// is therefore observed by the media path one cycle later, as if the control
// fragment had completed one cycle later. Request admission at the front is
// still blocked on the same cycle by cancel_notice_valid.
wire pause_request=notice_valid&&(notice_session||notice_token==authorized_image_uid||notice_token==authorized_audio_uid)||command_pause;
reg pause_q;
always @(posedge clk or negedge rst_n)
 if(!rst_n)pause_q<=1'b0;else pause_q<=pause_request;
assign pause_reader=pause_q;
assign next_image=MEDIA_UID32?command_next:legacy_next;assign previous_image=MEDIA_UID32?command_previous:legacy_previous;
assign reload=MEDIA_UID32?command_reload:legacy_reload;assign auto_valid=MEDIA_UID32?command_auto_valid:legacy_auto_valid;
assign auto_value=MEDIA_UID32?command_auto_value:legacy_auto_value;assign auto_toggle=MEDIA_UID32?command_auto_toggle:legacy_auto_toggle;
assign descriptor_error=envelope_error||overflow||display_exhausted;
assign accept=offer&&!legacy_busy;

wire producer_image_ack,producer_sector_room,producer_image_ready,scaled_valid,scale_drained,scale_overflow;
wire [31:0] scaled_word;wire [7:0] live_scale,actuation_scale;wire [2:0] selected_geometry;
// scaled_valid already includes the transport credit; no speculative work.
assign image_progress=scaled_valid;
generate if(IMAGE_SCALE_ENABLED)begin: geometry_control
 b_image_geometry_control change(.clk(clk),.rst_n(rst_n),.request(actuation_request),.request_token(actuation_token),
  .wanted(actuation_scale),.live(live_scale),.apply_done(config_actuation_done),.apply_done_token(actuation_token),.apply_error(config_actuation_error),
  .cancel_valid(notice_valid),.cancel_session(notice_session),.cancel_token(notice_token),.emergency(emergency),
  .owners_drained(image_reader_drained&&image_producer_drained),.selected(selected_geometry),.suspend(geometry_pause),.invalidate(geometry_invalidate));
end else begin: fixed_geometry
 assign selected_geometry=image_scale_selector;assign geometry_pause=0;assign geometry_invalidate=0;
end endgenerate
wire scale_cancel=pause_reader||emergency||geometry_pause||(event_valid&&event_data[127:120]==1&&event_data[119:112]>=1&&event_data[119:112]<=3);
wire producer_media_drained,producer_image_drained;
assign media_drained=producer_media_drained&&scale_drained;
assign image_producer_drained=producer_image_drained&&scale_drained;
wire [127:0] scale_fault={8'd1,8'd3,8'hd5,8'd0,32'd0,32'd0,32'd0};
generate if(ADAPTIVE_IMAGES)begin: adaptive_images
 b_adaptive_image_scale #(.WIDTH(FRAME_WIDTH),.HEIGHT(FRAME_HEIGHT),.RUNTIME_GEOMETRY(IMAGE_SCALE_ENABLED)) path(clk,rst_n,image_req,authorized_image_uid,
  image_source_width,image_source_height,image_source_pixels,producer_image_ack,image_ack,image_valid,image_word,
  scale_cancel,producer_image_ready,scaled_valid,scaled_word,image_sector_room,scale_drained,scale_overflow,selected_geometry);
end else if(IMAGE_SCALE_ENABLED)begin: image_scaling
 b_image_scale_port #(.WIDTH(FRAME_WIDTH),.HEIGHT(FRAME_HEIGHT)) path(clk,rst_n,image_req,authorized_image_uid,image_scale_selector,
  producer_image_ack,image_ack,image_valid,image_word,scale_cancel,producer_image_ready,scaled_valid,scaled_word,image_sector_room,scale_drained,scale_overflow);
end else begin: image_unscaled
 assign image_ack=producer_image_ack;assign image_sector_room=producer_sector_room;
 assign scaled_valid=image_valid;assign scaled_word=image_word;assign scale_drained=1'b1;assign scale_overflow=1'b0;
end endgenerate

assign text_grant_needed=normal_text_grant_needed||restore_grant_needed||program_grant_needed;
assign restore_grant_valid=text_grant_valid&&!normal_text_grant_needed&&restore_grant_needed;
assign program_grant_valid=text_grant_valid&&!normal_text_grant_needed&&!restore_grant_needed;
assign program_uid=text_granted_uid;assign program_grant_permission=startup_ready&&text_engine_idle&&!normal_text_grant_needed&&!restore_grant_needed;
assign program_reply_valid=reply_valid;assign program_reply=reply_body[255:0];
wire [7:0] fragment_command=reply_body[255:248];
wire internal_menu=request_command>=24&&request_command<=26;
wire [7:0] backend_command=internal_menu?request_command-8'd20:request_command;
// CMD11/12/16 legacy text commands are retired: subtitles use CMD22 only.
wire unsupported_command=request_command>=17&&request_command<=19||
 request_command==11||request_command==12||request_command==16;
wire request_fragment=(fragment_command>=3&&fragment_command<=6)||fragment_command==11||fragment_command==12||fragment_command==16||fragment_command==22||(fragment_command>=17&&fragment_command<=19)||(fragment_command>=24&&fragment_command<=26)||fragment_command==8'hf0||fragment_command==8'hf1;
assign request_ready=(!font_request_gate||font_busy)?1'b0:internal_menu?menu_assembled_ready:request_command==8'd22 ? font_ingress_request_ready:unsupported_command?(analysis_request_ready&&normal_management_idle):normal_request_ready;
assign source_address=font_busy?font_body_address:normal_source_address;
b_spi_request_front #(.SHARED_HEADER(1)) assembler(
 .snapshot_borrowed(),.clk(clk),.rst_n(rst_n),.session_clear(1'b0),
 .fragment_valid(reply_valid&&request_fragment),.fragment_ready(fragment_ready),.fragment(reply_body[255:0]),
 .cancel_valid(1'b0),.cancel_token(32'd0),.request_valid(request_valid),.request_ready(request_ready),
 .request_token(request_token),.request_command(request_command),.request_length(request_length),.request_arguments(request_arguments),
 .body_release_valid(font_body_release_valid),.body_release_token(font_body_release_token),.body_locked(),
 .read_address(source_address),.read_byte(source_byte),.ack_valid(ack_valid),.ack_ready(ack_ready),.ack_token(ack_token),
 .ack_index(ack_index),.ack_error(ack_error),.ack_captured(ack_captured),
 .cancel_notice_valid(notice_valid),.cancel_notice_token(notice_token),.cancel_notice_session(notice_session),
 .cancel_done_valid(global_done),.cancel_done_token(global_token));
b_normal_services #(.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(SPI_DIV),.PERSISTENCE_ENABLED(MEDIA_UID32),.ROM_FILE(ROM_FILE),.AUX_ENABLED(1),.GAMMA_ENABLED(MEDIA_UID32),.SCALE_ENABLED(IMAGE_SCALE_ENABLED),.FONT_ENABLED(FONT_SERVICE_ENABLED),.JOURNAL_ENABLED(CMD22_PERSISTENCE_ENABLED)) normal(
 .done_valid(),.done_token(),.done_error(),
 .clk(clk),.rst_n(rst_n),.request_valid(internal_menu?menu_backend_valid:request_valid&&font_request_gate&&!font_busy&&!unsupported_command&&request_command!=8'd22),.request_ready(normal_request_ready),.request_token(request_token),
 .request_command(backend_command),.request_length(request_length),.request_arguments(request_arguments),.source_address(normal_source_address),.source_byte(source_byte),
 .notice_valid(notice_valid),.notice_token(notice_token),.notice_session(notice_session),.control_done(normal_done),.control_done_token(normal_token),
 .glyph_valid(glyph_valid),.glyph_ready(glyph_ready),.glyph_kind(glyph_kind),.glyph_count(glyph_count),.glyph_sequence(glyph_sequence),.glyph_tag(glyph_tag),.glyph_value(glyph_value),.glyph_done(glyph_done),.glyph_address(glyph_address),.glyph_word(glyph_word),
 .rpc_valid(rpc_valid),.rpc_ready(rpc_ready),.rpc_kind(rpc_kind),.rpc_count(rpc_count),.rpc_sequence(rpc_sequence),.rpc_tag(rpc_tag),.rpc_value(rpc_value),.rpc_done(rpc_done),.rpc_address(rpc_address),.rpc_word(rpc_word),
 .reply_valid(reply_valid),.reply_fragment(reply_body[255:0]),.transport_idle(transport_idle),.done_ready(1'b1),
 .raw_address(raw_address),.raw_byte(raw_byte),.committed_valid(committed_valid),.committed_length(committed_length),.committed_glyph_count(committed_glyph_count),
 .colour_values_valid(colour_values_valid),.colour_values(colour_values),.actuation_request(actuation_request),.actuation_token(actuation_token),.actuation_values(actuation_values),
 .actuation_done(config_actuation_done),.actuation_error(config_actuation_error),.legacy_flags(legacy_flags),.legacy_text_summary(legacy_text_summary),.legacy_values(legacy_values),
 .snapshot_valid(snapshot_valid),.snapshot_ready(snapshot_ready),.snapshot_payload(snapshot_payload),.snapshot_jedec(snapshot_jedec),.event_valid(config_event),.event_data(config_event_data),
 .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),.flash_miso(flash_miso),
 .text_grant_needed(normal_text_grant_needed),.text_grant_valid(text_grant_valid&&!program_grant_needed),.text_granted_uid(text_granted_uid),
 .auxiliary_response_valid(auxiliary_response),.auxiliary_response_ready(auxiliary_response_ready),
 .auxiliary_response_token(auxiliary_token),.auxiliary_response_payload(auxiliary_payload),.colour_gamma(colour_gamma),.actuation_gamma(actuation_gamma),.live_scale(live_scale),.actuation_scale(actuation_scale),
 .menu_response_captured(menu_response_captured),.menu_response_uid(menu_response_uid),.menu_response_payload(menu_response_payload),.management_idle(normal_management_idle),.text_engine_idle(text_engine_idle),
 .journal_lease(journal_lease),.journal_valid(journal_valid),.journal_ready(journal_ready),.journal_operation(journal_operation),
 .journal_address(journal_address),.journal_length(journal_length),.journal_write_byte(journal_write_byte),.journal_write_index(journal_write_index),
 .journal_done(journal_done),.journal_error(journal_error),.journal_error_code(journal_error_code),
 .journal_byte_valid(journal_byte_valid),.journal_byte(journal_byte),.journal_index(journal_index),
 .font_request_valid(font_request_valid),.font_request_ready(font_request_ready),.font_request_codepoint(font_request_codepoint),.font_request_size(font_request_size),
 .font_request_token(font_request_token),.font_request_cancel(font_request_cancel),.font_glyph_valid(font_glyph_valid),.font_glyph_ready(font_glyph_ready),
 .font_glyph_byte(font_glyph_byte),.font_glyph_index(font_glyph_index),.font_glyph_first(font_glyph_first),.font_glyph_last(font_glyph_last),.font_glyph_token(font_glyph_token),
 .font_request_complete(font_request_complete),.font_request_result(font_request_result),.font_initialized(font_initialized),.font_boot_error(font_boot_error));
b_cmd22_font_ingress #(.DEGRADED_FONT_REJECT(1)) cmd22_font(.clk(clk),.rst_n(rst_n),.request_valid(request_valid&&font_request_gate&&normal_management_idle),.request_ready(font_ingress_ready_internal),
 .request_token(request_token),.request_command(request_command),.request_length(request_length),.request_arguments(request_arguments),
 .body_byte(source_byte),.body_address(font_body_address),.start_valid(live_font_start),.start_ready(font_start_ready),.start_uid(live_font_uid),
 .start_glyph_count(live_font_glyphs),.start_utf8_bytes(live_font_length),.start_size(live_font_size),.start_target(live_font_target),
 .raw_valid(live_font_raw_valid),.raw_ready(font_raw_ready),.raw_byte(live_font_raw_byte),.raw_last(live_font_raw_last),.cancel_valid(font_cancel_valid),
 .stream_complete(durable_font_complete),.stream_error(durable_font_error),.stream_blocked(font_stream_blocked),
 .notice_valid(notice_valid),.notice_token(notice_token),.notice_session(notice_session),.transport_idle(transport_idle),
 .control_done(font_control_done),.control_done_token(font_control_token),.result_valid(font_result_valid),.result_token(font_result_token),.result_error(font_result_error),
 .body_release_valid(font_body_release_valid),.body_release_token(font_body_release_token),.busy(font_busy),.owner_uid(font_owner_uid),
 .font_unavailable(!font_initialized&&font_boot_error!=0),.font_unavailable_error(font_boot_error==8'h70 ? 8'ha0:8'ha6));
b_cmd22_persistence_bridge #(.DEGRADED_STARTUP_ENABLED(1)) persistence_bridge(.clk(clk),.rst_n(rst_n),.enabled(CMD22_PERSISTENCE_ENABLED!=0),
 .live_start(live_font_start&&font_start_ready&&!restore_active),.live_target(live_font_target),.live_length(live_font_length),.live_size(live_font_size),
 .live_raw_valid(live_font_raw_valid&&font_raw_ready&&!restore_active),.live_raw_byte(live_font_raw_byte),.cancel_valid(font_cancel_valid),
 .stream_complete(font_stream_complete),.stream_error(font_stream_error),.stream_drained(font_stream_drained),
 .durable_complete(durable_font_complete),.durable_error(durable_font_error),.normal_idle(normal_management_idle),.font_initialized(font_initialized),
 .notice_valid(notice_valid),.notice_session(notice_session),.startup_ready(startup_ready),.restore_active(restore_active),
 .restore_start(restore_start),.restore_start_ready(font_start_ready),.restore_uid(restore_uid),.restore_target(restore_target),.restore_size(restore_size),
 .restore_glyphs(restore_glyphs),.restore_length(restore_length),.restore_raw_valid(restore_raw_valid),.restore_raw_ready(font_raw_ready),
 .restore_raw_byte(restore_raw_byte),.restore_raw_last(restore_raw_last),.restore_grant_needed(restore_grant_needed),
 .restore_grant_valid(restore_grant_valid),.restore_granted_uid(text_granted_uid),.restore_error(restore_error),
 .journal_lease(journal_lease),.journal_valid(journal_valid),.journal_ready(journal_ready),.journal_operation(journal_operation),
 .journal_address(journal_address),.journal_length(journal_length),.journal_write_byte(journal_write_byte),.journal_write_index(journal_write_index),
 .journal_done(journal_done),.journal_error(journal_error),.journal_error_code(journal_error_code),
 .journal_byte_valid(journal_byte_valid),.journal_byte(journal_byte),.journal_index(journal_index),.font_boot_error(font_boot_error));
b_font_stream_service #(.REPLY_TIMEOUT_CYCLES(CLOCK_HZ),.MAX_TRANSMISSIONS(4)) font_stream(
 .clk(clk),.rst_n(rst_n),.start_valid(font_start_valid),.start_ready(font_start_ready),.start_uid(font_start_uid),
 .start_glyph_count(font_start_glyph_count),.start_utf8_bytes(font_start_utf8_bytes),.start_size(font_start_size),.start_target(font_start_target),
 .raw_valid(font_raw_valid),.raw_ready(font_raw_ready),.raw_byte(font_raw_byte),.raw_last(font_raw_last),.cancel_valid(font_cancel_valid),
 .font_initialized(font_initialized),.font_request_ready(font_request_ready),.font_request_valid(font_request_valid),.font_request_codepoint(font_request_codepoint),
 .font_request_size(font_request_size),.font_request_token(font_request_token),.font_request_cancel(font_request_cancel),
 .font_glyph_valid(font_glyph_valid),.font_glyph_ready(font_glyph_ready),.font_glyph_byte(font_glyph_byte),.font_glyph_index(font_glyph_index),
 .font_glyph_first(font_glyph_first),.font_glyph_last(font_glyph_last),.font_glyph_token(font_glyph_token),.font_request_complete(font_request_complete),.font_request_result(font_request_result),
 .tx_valid(font_packet_valid),.tx_ready(font_packet_ready),.tx_kind(font_packet_kind),.tx_arg(font_packet_arg),.tx_count(font_packet_count),
 .tx_sequence(font_packet_sequence),.tx_tag(font_packet_tag),.tx_value(font_packet_value),.tx_address(font_packet_address),.tx_word(font_packet_word),.tx_done(font_packet_done),
 .ack_valid(reply_valid),.ack_marker(reply_body[255:248]),.ack_uid(fragment_uid),.ack_kind(reply_body[231:224]),.ack_sequence(reply_body[191:176]),.ack_error(reply_body[239:232]),
 .complete(font_stream_complete),.result_error(font_stream_error),.blocked(font_stream_blocked),.drained(font_stream_drained));
// Removed requests retain a real owner, original command and bounded result.
b_unsupported_analysis_service unsupported(clk,rst_n,request_valid&&font_request_gate&&!font_busy&&unsupported_command&&normal_management_idle,
 analysis_request_ready,request_token,request_command,analysis_response,analysis_response_ready,
 analysis_response_token,analysis_payload,notice_valid,notice_session,notice_token,
 transport_idle,analysis_control_done,analysis_control_token);
assign analysis_tx=1'b0;assign analysis_tx_kind=0;assign analysis_tx_count=0;
assign analysis_tx_sequence=0;assign analysis_tx_tag=0;assign analysis_tx_value=0;
b_curve_service #(.GAMMA_ENABLED(MEDIA_UID32)) curve(.clk(clk),.rst_n(rst_n),.request_valid(colour_values_valid),
 .invalidate(curve_status_strobe&&!curve_status_valid),.request_token(actuation_request?actuation_token:curve_prepared_token),.request_values(colour_values),
 .prepared_valid(curve_prepared),.prepared_token(curve_prepared_token),.prepared_style(curve_style),.failed(curve_failed),.failure_code(curve_failure),
 .meta_request(curve_meta),.data_request(curve_data),.transfer_token(curve_token),.meta_word(curve_meta_word),.transfer_done(curve_done),.transfer_error(curve_error),.read_address(curve_address),.read_word(curve_word),
 .notice_valid(notice_valid),.notice_token(notice_token),.notice_session(notice_session),.transfer_busy(curve_inflight),.transport_idle(transport_idle),.control_done(curve_control_done),.control_done_token(curve_control_token),
 .request_gamma(colour_gamma),.prepared_gamma(curve_prepared_gamma),.transfer_gamma(curve_gamma));
// Exactly the same accepted formats as the production adaptive scaler.
wire [1:0] image_output_extent=
 (image_source_width==640&&image_source_height==480||image_source_width==320&&image_source_height==240||image_source_width==160&&image_source_height==120)?2'd1:
 (image_source_width==640&&image_source_height==360||image_source_width==320&&image_source_height==180)?2'd2:2'd0;
b_media_transport #(.CLOCK_HZ(CLOCK_HZ),.FRAME_WORDS(FRAME_WORDS),.PROTOCOL_VERSION(6),.MANAGEMENT(1),.COLOUR(1),
 .MEDIA_UID32(MEDIA_UID32),.MEDIA_WORDS(MEDIA_UID32?63:64),.CONTROLLED(1),.EXTERNAL_REQUEST(1),.GAMMA_ENABLED(MEDIA_UID32),.DIMENSIONS_ENABLED(ADAPTIVE_IMAGES),.IMAGE_SUSPEND_ENABLED(1),.GEOMETRY_ENABLED(IMAGE_SCALE_ENABLED)) producer(
 .cs_n(),.sclk(),.mosi(),.host_reply_ready(),.host_request_valid(),.host_request_token(),.host_request_cmd(),.host_request_length(),.host_request_args(),
 .clk(clk),.rst_n(rst_n),.miso(1'b1),.image_suspend(emergency||geometry_pause),.image_dims({image_orig_width,image_orig_height}),.image_geometry(selected_geometry),.actuation_scale(actuation_scale),.geometry_previous_scale(live_scale),.image_extent(image_output_extent),
 .curve_meta_request(curve_meta),.curve_data_request(curve_data),.curve_prepared(curve_prepared&&curve_style==actuation_values[55:40]&&curve_prepared_gamma==actuation_gamma),.curve_token(curve_token),.curve_meta_word(curve_meta_word),.curve_read_word(curve_word),.curve_read_address(curve_address),.curve_done(curve_done),.curve_error(curve_error),
 .curve_status_strobe(curve_status_strobe),.curve_status_valid(curve_status_valid),.curve_status_token(curve_status_token),.curve_status_style(curve_status_style),
 .host_request_ready(1'b0),.host_reply_valid(1'b0),.host_reply_token(32'd0),.host_reply_payload(192'd0),
 .actuation_request(actuation_request),.actuation_token(actuation_token),.actuation_values(actuation_values),.actuation_done(actuation_done),.actuation_error(actuation_error),
 .snapshot_valid(snapshot_valid),.snapshot_payload(snapshot_payload),.snapshot_jedec(snapshot_jedec),.snapshot_ready(snapshot_ready),.legacy_flags(legacy_flags),.legacy_text_summary(legacy_text_summary),.legacy_values(legacy_values),
 .image_req(image_req&&(!MEDIA_UID32||image_command_granted)),.image_valid(scaled_valid),.image_word(scaled_word),.write_bank(write_bank),.display_bank(display_bank),.display_valid(display_valid),.image_code(image_code),.image_ack(producer_image_ack),.frame_finish_toggle(frame_finish_toggle),.image_sector_room(producer_sector_room),.image_word_ready(producer_image_ready),
 .next_image(legacy_next),.previous_image(legacy_previous),.reload(legacy_reload),.auto_valid(legacy_auto_valid),.auto_value(legacy_auto_value),.auto_toggle(legacy_auto_toggle),.emergency(emergency),.period_ms(period_ms),.period_valid(period_valid),
 .pcm_valid(pcm_valid),.pcm_last(pcm_last),.pcm_word(pcm_word),.pcm_ready(pcm_ready),.audio_metadata(audio_metadata),.audio_frames(audio_frames),.audio_busy(audio_busy),.audio_done(audio_done),.audio_error(audio_error),.audio_start(audio_start),.audio_cancel(audio_cancel),.audio_id(audio_id),.audio_urgent(audio_urgent),
 .event_valid(event_valid||scale_overflow||config_event),.event_data(event_valid?event_data:scale_overflow?scale_fault:config_event_data),.pause_media(pause_reader),.media_drained(producer_media_drained),.online(online),.dropped(dropped),.link_error(link_error),
 .request_start(source_start),.request_kind(source_kind),.request_arg(source_arg),.request_count(source_count),.request_sequence(source_sequence),.request_tag(source_tag),.request_value(source_value),.request_uid(source_uid),.request_read_address(source_address_word),.request_read_word(source_word),
 .transport_busy(source_busy),.transport_done(source_done),.reply_pulse(reply_valid),.full_reply_body(reply_body),.bad_reply_count(bad_replies),
 .image_operation_uid(authorized_image_uid),.audio_request_uid(authorized_audio_uid),.audio_request_id(authorized_audio_id),.audio_request_cancel(authorized_audio_cancel),
 .playback_info({program_catalog_valid,play_mode,actual_automatic,(play_mode==0&&actual_automatic&&display_valid ? image_code+4'd4 : 4'd0)}),
 .curve_inflight(curve_inflight),.actuation_inflight(actuation_inflight),.image_drained(producer_image_drained),.pause_control(notice_valid),.curve_gamma(curve_gamma),.curve_status_gamma(curve_status_gamma));
generate if(MEDIA_UID32)begin: uid_envelope
 b_media_commands32 #(.RESTORE_ENABLED(1),.RELOAD_START_ACK(1),.PROGRAM_START_GUARD(1),.ACTUAL_MODE_TAG(1)) commands(.clk(clk),.rst_n(rst_n),.reply_valid(reply_valid),.fragment(reply_body[255:0]),
  .notice_valid(notice_valid),.notice_token(notice_token),.notice_session(notice_session),.global_done(global_done),
  .reader_drained(reader_drained),.producer_drained(media_drained),.image_reader_drained(image_reader_drained),.image_producer_drained(image_producer_drained),.transport_idle(transport_idle),.image_req(image_req),.image_control_idle(image_control_idle),
  .cached_mask(image_cached_mask),.display_valid(display_valid),.image_uid(authorized_image_uid),.image_granted(image_command_granted),.audio_uid(authorized_audio_uid),.audio_id(authorized_audio_id),.audio_cancel(authorized_audio_cancel),
  .next_image(command_next),.previous_image(command_previous),.reload(command_reload),.auto_valid(command_auto_valid),.auto_value(command_auto_value),.auto_toggle(command_auto_toggle),
  .pause_action(command_pause),.control_done(command_control_done),.control_token(command_control_token),
  .tx_valid(command_tx),.tx_ready(command_ready),.tx_kind(command_kind),.tx_count(command_count),.tx_sequence(command_sequence),.tx_tag(command_tag),.tx_value(command_value),.tx_done(command_done),
  .text_grant_needed(text_grant_needed),.text_grant_valid(text_grant_valid),.text_uid(text_granted_uid),.reload_accepted(image_reload_accepted),
 .menu_toggle(menu_toggle),.menu_next(menu_next),.menu_plus(menu_plus),.menu_minus(menu_minus),
 .play_mode_valid(play_mode_valid),.play_mode(requested_play_mode),.program_audio_terminal(program_audio_terminal),.program_audio_id(program_audio_id),.program_available(program_catalog_valid),.current_image(image_code),.image_count(image_catalog_count),.program_prepared(program_prepared),.actual_automatic(actual_automatic),.actual_play_mode(play_mode));
 b_media_uid_envelope envelope(clk,rst_n,source_start,source_busy,source_done,source_kind,source_arg,source_count,source_sequence,source_tag,source_value,source_uid,source_address_word,source_word,
  offer,accept,legacy_kind,legacy_arg,legacy_count,legacy_sequence,legacy_tag,legacy_value,legacy_address,legacy_word,legacy_done,envelope_error);
end else begin: legacy_envelope
 assign authorized_image_uid=image_uid;assign authorized_audio_uid=audio_uid;assign authorized_audio_id=audio_request_id;assign authorized_audio_cancel=audio_request_cancel;
 assign image_command_granted=1'b1;assign command_pause=1'b0;assign command_control_done=notice_valid&&transport_idle;assign command_control_token=notice_token;
 assign text_grant_valid=0;assign text_granted_uid=0;
 assign command_tx=1'b0;assign command_kind=8'd0;assign command_count=0;assign command_sequence=0;assign command_tag=0;assign command_value=0;
 assign command_next=0;assign command_previous=0;assign command_reload=0;assign command_auto_valid=0;assign command_auto_value=0;assign command_auto_toggle=0;
 assign offer=source_start;assign source_busy=legacy_busy;assign source_done=legacy_done;
 assign legacy_kind=source_kind;assign legacy_arg=source_arg;assign legacy_count=source_count;assign legacy_sequence=source_sequence;assign legacy_tag=source_tag;assign legacy_value=source_value;
 assign source_address_word=legacy_address;assign legacy_word=source_word;assign envelope_error=1'b0;
end endgenerate
// Human display cannot consume an unbounded fraction of a fast simulation
// or a divided SPI link. Command-bearing kind53 retains its original retry.
localparam DISPLAY_WIRE_GAP=(16*HALF_CYCLES+3)*272*32;
localparam DISPLAY_QUIET=CLOCK_HZ/50>DISPLAY_WIRE_GAP?CLOCK_HZ/50:DISPLAY_WIRE_GAP;
b_menu_bridge #(.CLOCK_HZ(CLOCK_HZ),.IDLE_REFRESH_CYCLES(DISPLAY_QUIET)) menu_bridge(clk,rst_n,emergency,online,
 menu_toggle,menu_next,menu_plus,menu_minus,global_done,notice_valid,notice_session,notice_token,
 transport_idle,normal_done,normal_token,request_valid,request_command,request_token,request_arguments,normal_request_ready,
 menu_assembled_ready,menu_backend_valid,menu_response_captured,menu_response_uid,menu_response_payload,
 menu_tx,menu_tx_ready,menu_tx_kind,menu_tx_count,menu_tx_sequence,menu_tx_tag,menu_tx_value,menu_tx_done,
 menu_control_done,menu_control_token,
 display_visible,display_known,display_live,display_item,display_value,display_status,display_error,display_cookie,display_tick_ms);
reg [11:0] toast_ms;reg [2:0] toast_item;reg [15:0] toast_value;reg [7:0] toast_flags;
wire [15:0] toast_parameter=menu_response_payload[47:32];
wire toast_event=menu_response_captured&&menu_response_payload[7:0]==5&&menu_response_payload[15:8]==0&&menu_response_payload[23:16]==0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin toast_ms<=0;toast_item<=0;toast_value<=0;toast_flags<=0;end
 else begin
  if(display_tick_ms&&toast_ms!=0)toast_ms<=toast_ms-1'b1;
  if(!online||notice_valid||emergency)toast_ms<=0;
  else if(toast_event)begin
   toast_value<=menu_response_payload[79:64];toast_ms<=1900;
   toast_flags<=toast_parameter==16'h0102 ? 8'd1:8'd0;
   case(toast_parameter)
    16'h0101,16'h0102:toast_item<=0;16'h0201:toast_item<=1;16'h0202:toast_item<=2;
    16'h0203:toast_item<=3;16'h0301:toast_item<=4;default:toast_ms<=0;
   endcase
  end
 end
end
b_menu_display_source #(.MIN_REFRESH_CYCLES(DISPLAY_QUIET)) display_source(clk,rst_n,display_tick_ms,display_live&&online,notice_valid,
 display_cookie,display_visible||toast_ms!=0,display_visible?display_item:toast_item,display_visible?display_known:1'b1,display_visible?display_value:toast_value,display_visible?display_status:2'd2,display_visible?display_error:toast_flags,
 display_tx,display_ready,display_kind,display_count,display_sequence,display_tag,display_tx_value,display_done,
 display_address,display_word,display_drained,display_exhausted);
b_spi_pair_router menu_packets(clk,rst_n,
 menu_tx,menu_tx_ready,menu_tx_kind,menu_tx_count,menu_tx_sequence,menu_tx_tag,menu_tx_value,menu_tx_done,,32'd0,
 display_tx,display_ready,display_kind,display_count,display_sequence,display_tag,display_tx_value,display_done,display_address,display_word,
 menu_pair_valid,menu_pair_ready,menu_pair_kind,menu_pair_count,menu_pair_sequence,menu_pair_tag,menu_pair_value,menu_pair_done,menu_pair_address,menu_pair_word);
b_spi_pair_router packet_owners(clk,rst_n,
 glyph_valid,glyph_ready,glyph_kind,glyph_count,glyph_sequence,glyph_tag,glyph_value,glyph_done,glyph_address,glyph_word,
 command_tx,command_ready,command_kind,command_count,command_sequence,command_tag,command_value,command_done,,32'd0,
 pair_valid,pair_ready,pair_kind,pair_count,pair_sequence,pair_tag,pair_value,pair_done,pair_address,pair_word);
b_spi_pair_router analysis_packets(clk,rst_n,
 pair_valid,pair_ready,pair_kind,pair_count,pair_sequence,pair_tag,pair_value,pair_done,pair_address,pair_word,
 menu_pair_valid,menu_pair_ready,menu_pair_kind,menu_pair_count,menu_pair_sequence,menu_pair_tag,menu_pair_value,menu_pair_done,menu_pair_address,menu_pair_word,
 analysis_pair_valid,analysis_pair_ready,analysis_pair_kind,analysis_pair_count,analysis_pair_sequence,analysis_pair_tag,analysis_pair_value,analysis_pair_done,analysis_pair_address,analysis_pair_word);
b_spi_pair_router program_packets(clk,rst_n,
 analysis_pair_valid,analysis_pair_ready,analysis_pair_kind,analysis_pair_count,analysis_pair_sequence,analysis_pair_tag,analysis_pair_value,analysis_pair_done,analysis_pair_address,analysis_pair_word,
 program_tx,program_ready,program_kind,program_count,program_sequence,program_tag,program_value,program_done,program_address,program_word,
 merged_valid,merged_ready,merged_kind,merged_count,merged_sequence,merged_tag,merged_value,merged_done,merged_address,merged_word);
b_spi_arg_pair_router font_rpc_packets(.clk(clk),.rst_n(rst_n),
 .a_valid(rpc_valid&&rpc_capture_ready),.a_ready(scheduler_rpc_ready),.a_kind(rpc_kind),.a_arg(8'd0),.a_count(rpc_count),
 .a_sequence(rpc_sequence),.a_tag(rpc_tag),.a_value(rpc_value),.a_done(rpc_done),.a_address(rpc_address),.a_word(rpc_word),
 .b_valid(font_packet_valid),.b_ready(font_packet_ready),.b_kind(font_packet_kind),.b_arg(font_packet_arg),.b_count(font_packet_count),
 .b_sequence(font_packet_sequence),.b_tag(font_packet_tag),.b_value(font_packet_value),.b_done(font_packet_done),.b_address(font_packet_address),.b_word(font_packet_word),
 .valid(rpc_pair_valid),.ready(rpc_pair_ready),.kind(rpc_pair_kind),.arg(rpc_pair_arg),.count(rpc_pair_count),
 .sequence_id(rpc_pair_sequence),.tag(rpc_pair_tag),.value(rpc_pair_value),.done(rpc_pair_done),.address(rpc_pair_address),.word(rpc_pair_word));
b_spi6_scheduler #(.HALF_CYCLES(HALF_CYCLES)) scheduler(clk,rst_n,miso,cs_n,sclk,mosi,spi_busy,transport_idle,
 accept,legacy_kind,legacy_arg,legacy_count,legacy_sequence,legacy_tag,legacy_value,legacy_busy,legacy_done,legacy_address,legacy_word,
 ack_valid,ack_ready,ack_token,ack_index,ack_error,ack_captured,
 merged_valid,merged_ready,merged_kind,merged_count,merged_sequence,merged_tag,merged_value,merged_done,merged_address,merged_word,
 rpc_pair_valid,rpc_pair_ready,rpc_pair_kind,rpc_pair_arg,rpc_pair_count,rpc_pair_sequence,rpc_pair_tag,rpc_pair_value,rpc_pair_done,rpc_pair_address,rpc_pair_word,
 echo_seen,echo_nonce,reply_valid,reply_body,bad_replies,overflow);
b_link_proof_echo echo(clk,rst_n,reply_valid,reply_body,echo_seen,echo_nonce);
// An affected notice is acknowledged only after the registered pause is
// applied and media/reader are drained under it, so an operation started in
// the single gap cycle is still waited for.
wire media_control_done=notice_valid&&(!pause_request||(pause_q&&media_drained&&reader_drained))&&transport_idle&&!offer&&!source_start;
wire font_owner_drained=font_cancel_applied&&font_control_done&&font_stream_drained&&(!font_result_pending||!font_result_affected);
b_control_drain_join #(.SERVICES(8)) all_owners(clk,rst_n,notice_valid,notice_token,notice_session,
 {font_owner_drained,notice_valid&&display_drained,menu_control_done,analysis_control_done,command_control_done,media_control_done,curve_control_done,normal_done},{font_control_token,notice_token,menu_control_token,analysis_control_token,command_control_token,notice_token,curve_control_token,normal_token},global_done,global_token);
endmodule

// Change only picture ownership. Audio and the physical shared SD engine stay live.
module b_image_geometry_control(
 input clk,rst_n,request,input [31:0] request_token,input [7:0] wanted,live,
 input apply_done,input [31:0] apply_done_token,input [7:0] apply_error,
 input cancel_valid,cancel_session,input [31:0] cancel_token,
 input emergency,owners_drained,
 output reg [2:0] selected,output reg suspend,output reg invalidate);
reg active,failed,success_hold,drain_seen;
reg [31:0] owner;reg [2:0] requested,target;
wire current=request&&active&&request_token==owner;
wire affected=cancel_valid&&(cancel_session||cancel_token==request_token);
wire failed_now=current&&apply_done&&apply_done_token==owner&&apply_error!=0;
wire use_requested=current&&!failed&&!affected&&!failed_now;
wire [2:0] desired=use_requested?requested:success_hold?selected:live[2:0];
wire valid_desired=use_requested?1'b1:success_hold?1'b1:live<5;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin selected<=0;suspend<=0;invalidate<=0;active<=0;failed<=0;success_hold<=0;drain_seen<=0;owner<=0;requested<=0;target<=0;end
 else begin
  invalidate<=0;
  if(success_hold&&live<5&&live[2:0]==selected)success_hold<=0;
  if(!request)begin active<=0;failed<=0;end
  else if(!active||request_token!=owner)begin
   owner<=request_token;requested<=wanted[2:0];active<=1;failed<=wanted>=5||affected;success_hold<=0;
  end
  if(current&&apply_done&&apply_done_token==owner)begin
   if(apply_error!=0)begin failed<=1;success_hold<=0;end else success_hold<=1;
  end
  if(current&&affected)begin failed<=1;success_hold<=0;end
  if(!suspend)begin
   drain_seen<=0;
   if(!emergency&&valid_desired&&desired!=selected)begin target<=desired;suspend<=1;end
  end else begin
   if(!valid_desired)begin target<=selected;drain_seen<=0;end
   else if(target!=desired)begin target<=desired;drain_seen<=0;end
   else if(!owners_drained)drain_seen<=0;
   else if(drain_seen&&(!emergency||target==selected))begin
    if(target!=selected)begin selected<=target;invalidate<=1;end
    suspend<=0;drain_seen<=0;
   end else drain_seen<=1;
  end
 end
end
endmodule

// Retained F0/F1 notice boundary. Raw notice still blocks admission at its
// original edge. A matching cancellation crosses one explicit local register;
// applied becomes true only after the service has consumed that local level.
// The assembler keeps notice/token immutable until the global drain completes.
module b_font_cancel_boundary(input clk,rst_n,notice_valid,cancel_match,
 output cancel_valid,output applied);
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg cancel_q;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [1:0] notice_q;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin cancel_q<=0;notice_q<=0;end
 else begin cancel_q<=notice_valid&&cancel_match;notice_q<={notice_q[0],notice_valid};end
end
assign cancel_valid=notice_valid&&cancel_q;
assign applied=notice_valid&&notice_q[1];
endmodule
