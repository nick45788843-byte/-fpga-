module b_text_rpc_service #(parameter ROM_FILE="unicode.mem",CONFIG_ENABLED=0,PERSISTENCE_ENABLED=0,AUX_ENABLED=0)(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_token,input [7:0] request_command,request_length,input [47:0] request_arguments,
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
 input config_response_valid,output config_response_ready,input [31:0] config_response_token,input [191:0] config_response_payload,
 output persist_valid,output [31:0] persist_token,output [6:0] persist_count,
 input [5:0] persist_address,output [7:0] persist_byte,input persist_done,input [7:0] persist_error,
 input text_storage_ready,text_storage_busy,input [15:0] text_storage_descriptor,
 output text_restore_lock,output [5:0] text_restore_address,input [7:0] text_restore_byte,
 output text_restore_ack,output [15:0] text_restored_descriptor,
 output text_grant_needed,input text_grant_valid,input [31:0] text_granted_uid,
 input auxiliary_response_valid,output auxiliary_response_ready,input [31:0] auxiliary_response_token,
 input [191:0] auxiliary_response_payload,output management_idle,output config_result_claimed,output text_engine_idle);

// Subtitles are unified on CMD22 (b_cmd22_font_ingress/b_font_stream_service).
// The legacy CMD11 text, CMD12/CMD16 readback and boot text restore leaves
// are removed; CMD11/12/16 are answered by the bounded unsupported service.
// This module keeps only the shared RPC result owner for config and
// auxiliary responses. Removed outputs hold their idle values.
wire rpc_claim,rpc_busy,rpc_control_done;wire [31:0] rpc_control_token;
reg [1:0] result_source;
wire selected_aux=rpc_busy?(result_source==3):(AUX_ENABLED&&auxiliary_response_valid);
wire selected_config=rpc_busy?(result_source==2):(!selected_aux&&CONFIG_ENABLED&&config_response_valid);
wire selected_response=selected_aux?auxiliary_response_valid:selected_config&&config_response_valid;
wire [31:0] selected_token=selected_aux?auxiliary_response_token:config_response_token;
wire [191:0] selected_payload=selected_aux?auxiliary_response_payload:config_response_payload;
wire response_ready;
assign request_ready=1'b0;
assign source_address=8'd0;
assign text_engine_idle=!rpc_busy&&!request_valid;
assign management_idle=!rpc_busy&&!selected_response;
assign config_result_claimed=rpc_claim&&selected_config;
assign config_response_ready=CONFIG_ENABLED&&response_ready&&selected_config;
assign auxiliary_response_ready=AUX_ENABLED&&response_ready&&selected_aux;
always @(posedge clk or negedge rst_n)
 if(!rst_n)result_source<=0;
 else if(rpc_claim)result_source<=selected_aux?2'd3:2'd2;
assign glyph_valid=1'b0;assign glyph_kind=8'd0;assign glyph_count=7'd0;assign glyph_sequence=16'd0;
assign glyph_tag=16'd0;assign glyph_value=32'd0;assign glyph_word=32'd0;
assign raw_byte=8'd0;assign committed_valid=1'b0;assign committed_length=8'd0;assign committed_glyph_count=7'd0;
assign persist_valid=1'b0;assign persist_token=32'd0;assign persist_count=7'd0;assign persist_byte=8'd0;
assign text_restore_lock=1'b0;assign text_restore_address=6'd0;assign text_restore_ack=1'b0;
assign text_restored_descriptor=16'd0;assign text_grant_needed=1'b0;
b_rpc_response_delivery #(.CONTROL_ENABLED(1),.RESPONSE_LEASE(1)) rpc(
 .clk(clk),.rst_n(rst_n),.response_valid(selected_response),.response_ready(response_ready),
 .response_token(selected_token),.response_payload(selected_payload),
 .tx_valid(rpc_valid),.tx_ready(rpc_ready),.tx_kind(rpc_kind),.tx_count(rpc_count),
 .tx_sequence(rpc_sequence),.tx_tag(rpc_tag),.tx_value(rpc_value),.tx_done(rpc_done),
 .read_address(rpc_address),.read_word(rpc_word),.reply_valid(reply_valid),.reply_fragment(reply_fragment),
 .done_valid(done_valid),.done_ready(done_ready),.done_token(done_token),.done_error(done_error),
 .cancel_notice_valid(notice_valid),.cancel_notice_token(notice_token),.cancel_notice_session(notice_session),
 .transport_idle(transport_idle),.cancel_done_valid(rpc_control_done),.cancel_done_token(rpc_control_token),
 .lease_accept(rpc_claim),.lease_busy(rpc_busy));
assign control_done=rpc_control_done;assign control_done_token=rpc_control_token;
endmodule
