// Production-facing normal command boundary: original Flash/config management,
// actual text/UTF8/display/committed-original/query, one shared RPC packet owner.
// Media and colour transport still join the whole-board global quorum outside.
module b_normal_services #(parameter CLOCK_HZ=50000000,SPI_DIV=4,PERSISTENCE_ENABLED=0,ROM_FILE="unicode.mem",AUX_ENABLED=0,GAMMA_ENABLED=0,SCALE_ENABLED=0,FONT_ENABLED=0,JOURNAL_ENABLED=0)(
 input journal_lease,journal_valid,output journal_ready,input [2:0] journal_operation,
 input [23:0] journal_address,input [6:0] journal_length,input [7:0] journal_write_byte,
 output [5:0] journal_write_index,output journal_done,journal_error,
 output [7:0] journal_error_code,output journal_byte_valid,output [7:0] journal_byte,output [5:0] journal_index,
 input clk,rst_n,input request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_command,request_length,input [47:0] request_arguments,
 output [7:0] source_address,input [7:0] source_byte,
 input notice_valid,input [31:0] notice_token,input notice_session,output control_done,output [31:0] control_done_token,
 output glyph_valid,input glyph_ready,output [7:0] glyph_kind,output [6:0] glyph_count,output [15:0] glyph_sequence,glyph_tag,
 output [31:0] glyph_value,input glyph_done,input [5:0] glyph_address,output [31:0] glyph_word,
 output rpc_valid,input rpc_ready,output [7:0] rpc_kind,output [6:0] rpc_count,output [15:0] rpc_sequence,rpc_tag,
 output [31:0] rpc_value,input rpc_done,input [5:0] rpc_address,output [31:0] rpc_word,
 input reply_valid,input [255:0] reply_fragment,input transport_idle,
 output done_valid,input done_ready,output [31:0] done_token,output [7:0] done_error,
 input [7:0] raw_address,output [7:0] raw_byte,output committed_valid,output [7:0] committed_length,
 output [6:0] committed_glyph_count,
 output colour_values_valid,output [71:0] colour_values,
 output actuation_request,output [31:0] actuation_token,output [71:0] actuation_values,input actuation_done,input [7:0] actuation_error,
 input [7:0] legacy_flags,legacy_text_summary,input [71:0] legacy_values,
 output snapshot_valid,input snapshot_ready,output [191:0] snapshot_payload,output [23:0] snapshot_jedec,
 output event_valid,output [127:0] event_data,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso,
 output text_grant_needed,input text_grant_valid,input [31:0] text_granted_uid,
 input auxiliary_response_valid,output auxiliary_response_ready,input [31:0] auxiliary_response_token,
 input [191:0] auxiliary_response_payload,output [7:0] colour_gamma,actuation_gamma,live_scale,actuation_scale,
 output menu_response_captured,output [31:0] menu_response_uid,output [191:0] menu_response_payload,output management_idle,output text_engine_idle,
 input font_request_valid,output font_request_ready,input [15:0] font_request_codepoint,input [1:0] font_request_size,
 input [31:0] font_request_token,input font_request_cancel,
 output font_glyph_valid,input font_glyph_ready,output [7:0] font_glyph_byte,output [8:0] font_glyph_index,
 output font_glyph_first,font_glyph_last,output [31:0] font_glyph_token,
 output font_request_complete,output [7:0] font_request_result,output font_initialized,output [7:0] font_boot_error);
wire config_ready,text_ready,config_response,config_response_ready,config_control_done,text_control_done;
wire [31:0] config_response_token,config_control_token,text_control_token;wire [191:0] config_payload;
wire is_config=request_command>=3&&request_command<=6;
wire rpc_management_idle,config_result_claimed;
reg flow_busy,body_wait;reg [31:0] flow_owner;
wire flow_gate=(!flow_busy||body_wait)&&(flow_busy||rpc_management_idle);
assign management_idle=!flow_busy&&rpc_management_idle&&!notice_valid;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin flow_busy<=0;body_wait<=0;flow_owner<=0;end
 else begin
  if(request_valid&&flow_gate&&!notice_valid)begin
   if(!flow_busy)begin flow_busy<=1;flow_owner<=request_token;end
   body_wait<=!(is_config?config_ready:text_ready);
  end
  if(done_valid&&done_ready)begin flow_busy<=0;body_wait<=0;end
  if(notice_valid&&(notice_session||notice_token==flow_owner)&&control_done)begin flow_busy<=0;body_wait<=0;end
 end
end
// Observe the real source claim one clock later. The full source is still
// leased through physical F5/idle; this event never releases producer data.
reg menu_claim_observed;
always @(posedge clk or negedge rst_n)
 if(!rst_n)menu_claim_observed<=0;else menu_claim_observed<=config_result_claimed;
assign menu_response_captured=menu_claim_observed;
assign menu_response_uid=config_response_token;assign menu_response_payload=config_payload;
assign request_ready=!notice_valid&&flow_gate&&(is_config?config_ready:text_ready);
wire persist_valid,persist_done,text_storage_ready,text_storage_busy,text_restore_lock,text_restore_ack;
wire [31:0] persist_token;wire [6:0] persist_count;wire [5:0] persist_address,text_restore_address;
wire [7:0] persist_byte,persist_error,text_restore_byte;wire [15:0] text_storage_descriptor,text_restored_descriptor;
// Legacy CMD11 text persistence is retired (subtitles are CMD22-only).
b_config_service #(.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(SPI_DIV),.TEXT_ENABLED(0),.GAMMA_ENABLED(GAMMA_ENABLED),.SCALE_ENABLED(SCALE_ENABLED),.FONT_ENABLED(FONT_ENABLED),.JOURNAL_ENABLED(JOURNAL_ENABLED)) config_service(
 .live_scale(live_scale),.actuation_scale(actuation_scale),
 .clk(clk),.rst_n(rst_n),.request_valid(request_valid&&flow_gate&&is_config),.request_ready(config_ready),
 .request_token(request_token),.request_cmd(request_command),.request_length({8'd0,request_length}),.request_args(request_arguments),
 .reply_valid(config_response),.reply_ready(config_response_ready),.reply_token(config_response_token),.reply_payload(config_payload),
 .colour_values_valid(colour_values_valid),.colour_values(colour_values),.actuation_request(actuation_request),.actuation_token(actuation_token),.actuation_values(actuation_values),
 .actuation_done(actuation_done),.actuation_error(actuation_error),.legacy_flags(legacy_flags),.legacy_text_summary(legacy_text_summary),.legacy_values(legacy_values),
 .snapshot_valid(snapshot_valid),.snapshot_ready(snapshot_ready),.snapshot_payload(snapshot_payload),.snapshot_jedec(snapshot_jedec),.event_valid(event_valid),.event_data(event_data),
 .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),.flash_miso(flash_miso),
 .notice_valid(notice_valid),.notice_token(notice_token),.notice_session(notice_session),.transport_idle(transport_idle),
 .control_done(config_control_done),.control_done_token(config_control_token),
 .persist_valid(persist_valid),.persist_token(persist_token),.persist_count(persist_count),.persist_address(persist_address),.persist_byte(persist_byte),.persist_done(persist_done),.persist_error(persist_error),
 .text_storage_ready(text_storage_ready),.text_storage_busy(text_storage_busy),.text_storage_descriptor(text_storage_descriptor),
 .text_restore_lock(text_restore_lock),.text_restore_address(text_restore_address),.text_restore_byte(text_restore_byte),.text_restore_ack(text_restore_ack),.text_restored_descriptor(text_restored_descriptor),
 .colour_gamma(colour_gamma),.actuation_gamma(actuation_gamma),
 .journal_lease(journal_lease),.journal_valid(journal_valid),.journal_ready(journal_ready),.journal_operation(journal_operation),
 .journal_address(journal_address),.journal_length(journal_length),.journal_write_byte(journal_write_byte),.journal_write_index(journal_write_index),
 .journal_done(journal_done),.journal_error(journal_error),.journal_error_code(journal_error_code),
 .journal_byte_valid(journal_byte_valid),.journal_byte(journal_byte),.journal_index(journal_index),
 .font_request_valid(font_request_valid),.font_request_ready(font_request_ready),.font_request_codepoint(font_request_codepoint),
 .font_request_size(font_request_size),.font_request_token(font_request_token),.font_request_cancel(font_request_cancel),
 .font_glyph_valid(font_glyph_valid),.font_glyph_ready(font_glyph_ready),.font_glyph_byte(font_glyph_byte),.font_glyph_index(font_glyph_index),
 .font_glyph_first(font_glyph_first),.font_glyph_last(font_glyph_last),.font_glyph_token(font_glyph_token),
 .font_request_complete(font_request_complete),.font_request_result(font_request_result),.font_initialized(font_initialized),.font_boot_error(font_boot_error));
b_text_rpc_service #(.ROM_FILE(ROM_FILE),.CONFIG_ENABLED(1),.PERSISTENCE_ENABLED(PERSISTENCE_ENABLED),.AUX_ENABLED(AUX_ENABLED)) text_service(
 .clk(clk),.rst_n(rst_n),.request_valid(request_valid&&flow_gate&&!is_config),.request_ready(text_ready),.request_token(request_token),.request_command(request_command),.request_length(request_length),.request_arguments(request_arguments),
 .source_address(source_address),.source_byte(source_byte),.notice_valid(notice_valid),.notice_token(notice_token),.notice_session(notice_session),
 .control_done(text_control_done),.control_done_token(text_control_token),
 .glyph_valid(glyph_valid),.glyph_ready(glyph_ready),.glyph_kind(glyph_kind),.glyph_count(glyph_count),.glyph_sequence(glyph_sequence),.glyph_tag(glyph_tag),.glyph_value(glyph_value),.glyph_done(glyph_done),.glyph_address(glyph_address),.glyph_word(glyph_word),
 .rpc_valid(rpc_valid),.rpc_ready(rpc_ready),.rpc_kind(rpc_kind),.rpc_count(rpc_count),.rpc_sequence(rpc_sequence),.rpc_tag(rpc_tag),.rpc_value(rpc_value),.rpc_done(rpc_done),.rpc_address(rpc_address),.rpc_word(rpc_word),
 .reply_valid(reply_valid),.reply_fragment(reply_fragment),.transport_idle(transport_idle),.done_valid(done_valid),.done_ready(done_ready),.done_token(done_token),.done_error(done_error),
 .raw_address(raw_address),.raw_byte(raw_byte),.committed_valid(committed_valid),.committed_length(committed_length),.committed_glyph_count(committed_glyph_count),
 .config_response_valid(config_response),.config_response_ready(config_response_ready),.config_response_token(config_response_token),.config_response_payload(config_payload),
 .persist_valid(persist_valid),.persist_token(persist_token),.persist_count(persist_count),.persist_address(persist_address),.persist_byte(persist_byte),.persist_done(persist_done),.persist_error(persist_error),
 .text_storage_ready(text_storage_ready),.text_storage_busy(text_storage_busy),.text_storage_descriptor(text_storage_descriptor),
 .text_restore_lock(text_restore_lock),.text_restore_address(text_restore_address),.text_restore_byte(text_restore_byte),.text_restore_ack(text_restore_ack),.text_restored_descriptor(text_restored_descriptor),
 .text_grant_needed(text_grant_needed),.text_grant_valid(text_grant_valid),.text_granted_uid(text_granted_uid),
 .auxiliary_response_valid(auxiliary_response_valid),.auxiliary_response_ready(auxiliary_response_ready),
 .auxiliary_response_token(auxiliary_response_token),.auxiliary_response_payload(auxiliary_response_payload),.management_idle(rpc_management_idle),.config_result_claimed(config_result_claimed),.text_engine_idle(text_engine_idle));
b_control_drain_join #(.SERVICES(2)) joiner(clk,rst_n,notice_valid,notice_token,notice_session,
 {text_control_done,config_control_done},{text_control_token,config_control_token},control_done,control_done_token);
endmodule
