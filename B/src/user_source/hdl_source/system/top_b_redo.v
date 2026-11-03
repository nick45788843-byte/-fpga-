// Independent SPI6 DEV physical B top. UART belongs to A only.
// This candidate closes normal/text/curve/TF onto the single production master;
// A authorizes all external media operations with its forward UID32 allocator.
module top #(parameter CLOCK_HZ=50000000,FLASH_DIV=4,HALF_CYCLES=3,
 FRAME_WIDTH=640,FRAME_HEIGHT=480,ROM_FILE="unicode.mem",IMAGE_SCALE_SELECTOR=0,ADAPTIVE_IMAGES=1)(
 input clk,rst_n,uart_rx,board_miso,board_ready,
 output uart_tx,board_cs_n,board_sclk,board_mosi,
 output tf_cs_n,tf_sclk,tf_mosi,input tf_miso,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso);
reg [1:0] reset_pipe;
always @(posedge clk or negedge rst_n)if(!rst_n)reset_pipe<=0;else reset_pipe<={reset_pipe[0],1'b1};
wire reset_n=reset_pipe[1];
localparam [2:0] INITIAL_SCALE_SELECTOR=IMAGE_SCALE_SELECTOR;
assign uart_tx=1'b1;
wire image_req,image_valid,image_ack,frame_finish,display_valid,image_sector_room,image_progress;wire geometry_pause,geometry_invalidate;
wire [3:0] image_catalog_count;
wire [31:0] image_word;wire [1:0] write_bank,display_bank;wire [3:0] image_code;
wire next_image,previous_image,reload,auto_valid,auto_value,auto_toggle,emergency,period_valid;
wire program_prepared;wire peer_online,program_catalog_valid,program_grant_needed,program_grant_valid,program_grant_permission,program_tx,program_ready,program_done,program_reply_valid;
wire [31:0] program_uid,program_value,program_word;wire [7:0] program_kind;wire [6:0] program_count;
wire [15:0] program_sequence,program_tag;wire [5:0] program_address;wire [255:0] program_reply;
wire [31:0] period_ms;wire [1:0] play_mode,requested_play_mode;wire play_mode_valid,actual_automatic,program_audio_terminal;wire [7:0] program_audio_id;
wire pcm_valid,pcm_last,pcm_ready,audio_metadata,audio_busy,audio_done,audio_start,audio_cancel,audio_urgent;
wire [31:0] pcm_word,audio_frames;wire [7:0] audio_error,audio_id;
wire event_valid;wire [127:0] event_data;wire reader_drained,image_drained,image_control_idle,reload_accepted,pause_reader;wire [3:0] cached_mask;
wire [15:0] image_source_width,image_source_height;wire [31:0] image_source_pixels;wire [12:0] image_orig_width,image_orig_height;
b_media_core_control #(.CLOCK_HZ(CLOCK_HZ),.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),.ADAPTIVE_IMAGES(ADAPTIVE_IMAGES),.IMAGE_PROGRESS_ENABLED(1)) media(
 .clk(clk),.rst_n(reset_n),.pause(pause_reader),.geometry_pause(geometry_pause),.geometry_invalidate(geometry_invalidate),.image_progress(image_progress),.drained(reader_drained),.image_drained(image_drained),.image_control_idle(image_control_idle),.reload_accepted(reload_accepted),.cached_mask(cached_mask),
 .next_image(next_image),.previous_image(previous_image),.reload(reload),.auto_valid(auto_valid),.auto_value(auto_value),.auto_toggle(auto_toggle),.emergency(emergency),.period_ms(period_ms),.period_valid(period_valid),
 .image_req(image_req),.image_valid(image_valid),.image_word(image_word),.image_ack(image_ack),.frame_finish_toggle(frame_finish),.write_bank(write_bank),.display_bank(display_bank),.display_valid(display_valid),.image_code(image_code),.image_sector_room(image_sector_room),
 .audio_urgent(audio_urgent),.audio_start(audio_start),.audio_cancel(audio_cancel),.audio_id(audio_id),.pcm_ready(pcm_ready),.pcm_valid(pcm_valid),.pcm_last(pcm_last),.pcm_word(pcm_word),.audio_frames(audio_frames),.audio_metadata(audio_metadata),.audio_busy(audio_busy),.audio_done(audio_done),.audio_error(audio_error),
 .event_valid(event_valid),.event_data(event_data),.tf_cs_n(tf_cs_n),.tf_sclk(tf_sclk),.tf_mosi(tf_mosi),.tf_miso(tf_miso),
 .image_source_width(image_source_width),.image_source_height(image_source_height),.image_source_pixels(image_source_pixels),.image_orig_width(image_orig_width),.image_orig_height(image_orig_height),
 .play_mode_valid(play_mode_valid),.requested_play_mode(requested_play_mode),.program_audio_terminal(program_audio_terminal),.program_audio_id(program_audio_id),
 .play_mode(play_mode),.actual_automatic(actual_automatic),.peer_online(peer_online),.program_catalog_valid(program_catalog_valid),.program_grant_needed(program_grant_needed),.program_grant_valid(program_grant_valid),.program_uid(program_uid),.program_grant_permission(program_grant_permission),
 .program_tx(program_tx),.program_ready(program_ready),.program_kind(program_kind),.program_count(program_count),.program_sequence(program_sequence),.program_tag(program_tag),.program_value(program_value),
 .program_done(program_done),.program_address(program_address),.program_word(program_word),.program_reply_valid(program_reply_valid),.program_reply(program_reply),.image_catalog_count(image_catalog_count),.program_prepared(program_prepared));
// The production selector is fixed at elaboration. Identity images use the
// existing credited direct path; nonidentity candidates retain the real scaler.
b_board_services #(.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(FLASH_DIV),.HALF_CYCLES(HALF_CYCLES),.FRAME_WORDS(FRAME_WIDTH*FRAME_HEIGHT),.MEDIA_UID32(1),.ROM_FILE(ROM_FILE),.IMAGE_SCALE_ENABLED(1),.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),.ADAPTIVE_IMAGES(ADAPTIVE_IMAGES),.FONT_SERVICE_ENABLED(1)) services(
 .clk(clk),.rst_n(reset_n),.geometry_pause(geometry_pause),.geometry_invalidate(geometry_invalidate),.image_progress(image_progress),.miso(board_miso),.cs_n(board_cs_n),.sclk(board_sclk),.mosi(board_mosi),
 .image_req(image_req),.image_valid(image_valid),.image_word(image_word),.write_bank(write_bank),.display_bank(display_bank),.display_valid(display_valid),.image_code(image_code),.image_ack(image_ack),.frame_finish_toggle(frame_finish),.image_sector_room(image_sector_room),
 .next_image(next_image),.previous_image(previous_image),.reload(reload),.auto_valid(auto_valid),.auto_value(auto_value),.auto_toggle(auto_toggle),.emergency(emergency),.period_ms(period_ms),.period_valid(period_valid),
 .pcm_valid(pcm_valid),.pcm_last(pcm_last),.pcm_word(pcm_word),.pcm_ready(pcm_ready),.audio_metadata(audio_metadata),.audio_frames(audio_frames),.audio_busy(audio_busy),.audio_done(audio_done),.audio_error(audio_error),.audio_start(audio_start),.audio_cancel(audio_cancel),.audio_id(audio_id),.audio_urgent(audio_urgent),
 .event_valid(event_valid),.event_data(event_data),.reader_drained(reader_drained),.image_reader_drained(image_drained),.image_control_idle(image_control_idle),.image_cached_mask(cached_mask),.image_reload_accepted(reload_accepted),.pause_reader(pause_reader),
 .image_uid(32'd0),.audio_uid(32'd0),.audio_request_id(8'd0),.audio_request_cancel(1'b0),
 .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),.flash_miso(flash_miso),.raw_address(8'd0),.image_scale_selector(INITIAL_SCALE_SELECTOR),
 .image_source_width(image_source_width),.image_source_height(image_source_height),.image_source_pixels(image_source_pixels),.image_orig_width(image_orig_width),.image_orig_height(image_orig_height),
 .play_mode_valid(play_mode_valid),.requested_play_mode(requested_play_mode),.program_audio_terminal(program_audio_terminal),.program_audio_id(program_audio_id),
 .play_mode(play_mode),.actual_automatic(actual_automatic),.online(peer_online),.program_catalog_valid(program_catalog_valid),.program_grant_needed(program_grant_needed),.program_grant_valid(program_grant_valid),.program_uid(program_uid),.program_grant_permission(program_grant_permission),
 .program_tx(program_tx),.program_ready(program_ready),.program_kind(program_kind),.program_count(program_count),.program_sequence(program_sequence),.program_tag(program_tag),.program_value(program_value),
 .program_done(program_done),.program_address(program_address),.program_word(program_word),.program_reply_valid(program_reply_valid),.program_reply(program_reply),.image_catalog_count(image_catalog_count),.program_prepared(program_prepared),
 .committed_glyph_count(),
 .committed_length(),
 .committed_valid(),
 .raw_byte(),
 .dropped(),
 .descriptor_error(),
 .bad_replies(),
 .global_token(),
 .global_done());
endmodule
