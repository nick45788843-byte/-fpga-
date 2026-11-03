// New physical UART/SPI control root. Normal configuration/text ownership is B;
// local emergency/media backends complete only on actual apply/save/drain.
// Result sources are leased until full UART-frame capture, with no body copies.
module a_control_plane #(parameter CLOCK_HZ=50000000,UART_CLKS=434,MEDIA32=0,CAPTURE_ACK=0,BORROW_DURING_LOCAL=0,PCM_CAPTURE=0,BOARD_CONTROL_ENABLED=0,CRC_ROM_ENABLED=0,PROGRAM_REPLY=0)(
 input clk,rst_n,tick_ms,uart_rx,output uart_tx,
 input spi_clk,spi_cs_n,spi_mosi,output spi_miso,spi_ready,
 input peer_ready,initialize_valid,input [31:0] first_execution_token,output initialize_ready,
 output local_request_valid,input local_request_ready,
 output [31:0] local_request_token,local_request_wire_id,
 output [7:0] local_request_command,output [15:0] local_request_length,output [47:0] local_request_arguments,
 output local_cancel_valid,output [31:0] local_cancel_token,
 input local_cancel_done,input [31:0] local_cancel_done_token,
 output urgent_enter,urgent_preset_valid,output [1:0] urgent_preset,
 input local_result_valid,output local_result_ready,input [31:0] local_result_token,
 output [4:0] local_result_address,input [7:0] local_result_byte,
 output packet_valid,input packet_ready,output [7:0] packet_kind,packet_arg,
 output [6:0] packet_count,output [15:0] packet_sequence,packet_tag,packet_crc,
 output [31:0] packet_value,output [31:0] packet_word,input [5:0] packet_address,
 output control_ack,output [31:0] control_ack_token,output [7:0] control_ack_index,control_ack_error,
 output control_ack_captured,
 input [239:0] spi_status,input control_valid,input [63:0] control_header,
 input glyph_valid,input [63:0] glyph_header,input [191:0] glyph_body,
 output exhausted,idle,output [15:0] uart_dropped,spi_bad,
 output normal_cancel_valid,output [31:0] normal_cancel_token,next_execution_token,
 input borrow_valid,output borrow_ready,output [31:0] borrowed_token,
 input media_result_valid,input [63:0] media_result_header,
 input media_command_valid,input [63:0] media_command_header,
 input pcm_fragment_valid,input [63:0] pcm_fragment_header,input [7:0] pcm_fragment_byte,
 output [4:0] pcm_fragment_address,output pcm_fragment_locked,output media_command_captured,
 input board_request_valid,output board_request_ready,input [7:0] board_request_command,
 input [47:0] board_request_arguments,input board_cancel,
 output board_result_valid,input board_result_ready,input [4:0] board_result_address,output [7:0] board_result_byte,output board_result_synthetic,
 input [7:0] local_payload_address,output [7:0] local_payload_byte,input program_result_valid,input [63:0] program_result_header,
 output font_receipt_captured,output glyph_receipt_captured,output rpc_receipt_captured);
wire uart_crc_clear,uart_crc_enable,spi_crc_clear,spi_crc_enable;
wire [7:0] uart_crc_byte,spi_crc_byte;wire [15:0] uart_crc,spi_crc;
generate if(CRC_ROM_ENABLED)begin:shared_crc_table
 crc_byte_bram_pair table_pair(clk,rst_n,uart_crc_clear,uart_crc_enable,uart_crc_byte,uart_crc,
  spi_crc_clear,spi_crc_enable,spi_crc_byte,spi_crc);
end else begin:no_shared_crc_table
 assign uart_crc=16'hffff;assign spi_crc=16'hffff;
end endgenerate
wire request_valid,request_ready,remote,bank,has_bank,read_bank,sender_bank;
wire [7:0] sender_address;
wire [31:0] token,wire_id,cancel_token;wire [7:0] command,payload_address,payload_byte;
wire [15:0] length;wire [47:0] arguments;
assign read_bank=!remote&&command==20?bank:sender_bank;
assign payload_address=!remote&&command==20?local_payload_address:sender_address;
assign local_payload_byte=payload_byte;
wire cancel,cancel_remote,cancel_done;wire [31:0] cancel_done_token;
wire result_valid,result_ready;wire [31:0] result_token;wire [7:0] result_byte;wire [4:0] result_address;
assign local_request_valid=request_valid&&!remote;
assign local_request_token=token;assign local_request_wire_id=wire_id;
assign local_request_command=command;assign local_request_length=length;assign local_request_arguments=arguments;
assign local_cancel_valid=cancel&&!cancel_remote;assign local_cancel_token=cancel_token;
assign normal_cancel_valid=cancel&&cancel_remote;assign normal_cancel_token=cancel_token;
wire remote_captured,remote_cancel_done;wire [31:0] remote_cancel_token;
assign request_ready=remote?remote_captured:local_request_ready;
assign cancel_done=cancel_remote?remote_cancel_done:local_cancel_done;
assign cancel_done_token=cancel_remote?remote_cancel_token:local_cancel_done_token;
wire board_gateway_idle,board_portal_ready;
assign board_request_ready=board_gateway_idle&&board_portal_ready;
a_control_portal #(.CLOCK_HZ(CLOCK_HZ),.CLKS_PER_BIT(UART_CLKS),.BORROW_DURING_LOCAL(BORROW_DURING_LOCAL),.PCM_ANALYSIS_ENABLED(PCM_CAPTURE),.BOARD_CONTROL_ENABLED(BOARD_CONTROL_ENABLED),.EXTERNAL_CRC(CRC_ROM_ENABLED)) portal(
 .clk(clk),.rst_n(rst_n),.rx(uart_rx),.tx(uart_tx),.tick_ms(tick_ms),.peer_ready(peer_ready),
 .initialize_valid(initialize_valid),.first_execution_token(first_execution_token),.initialize_ready(initialize_ready),
 .request_valid(request_valid),.request_ready(request_ready),.request_remote(remote),.request_token(token),.request_wire_id(wire_id),
 .request_command(command),.request_length(length),.request_arguments(arguments),.request_bank(bank),.request_has_bank(has_bank),
 .payload_bank(read_bank),.payload_address(payload_address),.payload_byte(payload_byte),
 .cancel_valid(cancel),.cancel_remote(cancel_remote),.cancel_token(cancel_token),.cancel_done(cancel_done),.cancel_done_token(cancel_done_token),
 .urgent_enter(urgent_enter),.urgent_preset_valid(urgent_preset_valid),.urgent_preset(urgent_preset),
 .result_valid(result_valid),.result_ready(result_ready),.result_token(result_token),.result_byte_address(result_address),.result_byte(result_byte),
 .exhausted(exhausted),.idle(idle),.dropped(uart_dropped),.next_execution_token(next_execution_token),
 .borrow_valid(borrow_valid),.borrow_ready(borrow_ready),.borrowed_token(borrowed_token),
 .board_request_valid(board_request_valid&&board_gateway_idle),.board_request_ready(board_portal_ready),
 .board_request_command(board_request_command),.board_request_arguments(board_request_arguments),.board_cancel(board_cancel),
 .board_result_valid(board_result_valid),.board_result_ready(board_result_ready),.board_result_address(board_result_address),.board_result_byte(board_result_byte),.board_result_synthetic(board_result_synthetic),.crc_clear(uart_crc_clear),.crc_enable(uart_crc_enable),.crc_byte(uart_crc_byte),.external_crc(uart_crc),
 .reply_remote());
wire qv,qr,ack_ready,request_lock;wire [5:0] rpc_address;
wire reply_valid,reply_store_ready,reply_write,reply_publish,reply_snapshot_valid;
wire [5:0] reply_address;wire [7:0] reply_byte;
wire own_rpc=packet_kind==8'h40;
wire own_receipt=packet_kind==8'h41&&packet_count==0&&packet_arg==0&&packet_tag==0;
wire own_ack=packet_kind==8'h48;
// 只在匹配的实际 F0/FE 全局排空之后，释放重启 B 已失去的旧 RPC 确认。
wire rpc_clear=CAPTURE_ACK&&control_ack&&!control_ack_captured&&control_ack_index==8'hfe&&control_ack_error==0&&
 control_valid&&control_header[63:32]==32'hf0000000&&
 control_ack_token=={control_header[7:0],control_header[15:8],control_header[23:16],control_header[31:24]};
assign packet_valid=qv&&!own_rpc&&!own_receipt&&!own_ack;
wire consume=own_rpc?qr:own_receipt?1'b1:own_ack?ack_ready:packet_ready;
wire media_command_frame;
a_spi_reply_store6 #(.TRACK_MEDIA(MEDIA32)) reply_store(clk,rst_n,reply_write,reply_address,reply_byte,reply_publish,
 reply_store_ready,spi_clk,spi_cs_n,spi_miso,reply_snapshot_valid,media_command_frame,media_command_captured);
a_spi_mailbox6 #(.SERIAL_CRC(1),.REGISTER_HEADER(1)) board_link(
 .clk(clk),.rst_n(rst_n),.spi_clk(spi_clk),.cs_n(spi_cs_n),.mosi(spi_mosi),.ready(spi_ready),
 .command_valid(qv),.command_ready(consume),.command_kind(packet_kind),.command_arg(packet_arg),.command_count(packet_count),
 .command_sequence(packet_sequence),.command_tag(packet_tag),.command_crc(packet_crc),.command_value(packet_value),
 .read_address(own_rpc?rpc_address:packet_address),.read_word(packet_word),.bad_frames(spi_bad));
assign ack_ready=!request_lock;
assign control_ack=qv&&own_ack&&ack_ready&&packet_count==0&&packet_arg<=1&&packet_value!=0;
assign control_ack_token=packet_value;assign control_ack_index=packet_tag[7:0];assign control_ack_error=packet_tag[15:8];
assign control_ack_captured=packet_arg[0];
wire fragment_valid,request_abort,notice,failure,failure_ready,sender_idle;
wire [63:0] fragment_header;wire [4:0] fragment_address;wire [7:0] fragment_byte,failure_byte;
wire [31:0] notice_token,failure_token;
reg capture_visible;reg [31:0] captured_token;reg [7:0] captured_command;
wire [63:0] capture_header={8'hf6,8'd0,captured_command,8'd0,captured_token[7:0],captured_token[15:8],captured_token[23:16],captured_token[31:24]};
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin capture_visible<=0;captured_token<=0;captured_command<=0;end
 else if(rpc_clear)capture_visible<=0;
 else if(request_valid&&remote&&remote_captured)begin capture_visible<=1;captured_token<=token;captured_command<=command;end
end
a_request_sender requests(clk,rst_n,request_valid&&remote,remote_captured,token,command,length,arguments,bank,has_bank,
 sender_bank,sender_address,payload_byte,fragment_valid,request_lock,fragment_address,fragment_byte,
 control_ack,packet_value,packet_tag[7:0],packet_tag[15:8],packet_arg[0],cancel&&cancel_remote,cancel_token,
 notice,notice_token,1'b0,32'd0,remote_cancel_done,remote_cancel_token,
 failure,failure_ready,failure_token,result_address,failure_byte,sender_idle,fragment_header,request_abort);
// During an emergency the old frame must be invalidated before the sender's
// descriptor switches to F1. A captured CDC snapshot remains immutable.
wire rpc_result,rpc_ready,receipt,receipt_ready;wire [31:0] rpc_token,receipt_token;
wire [7:0] rpc_byte,receipt_error;
a_remote_reply_port #(.CLEAR_ENABLED(CAPTURE_ACK)) rpc(clk,rst_n,qv,qr,packet_kind,packet_arg,packet_count,packet_tag,packet_crc,packet_value,
 rpc_address,packet_word,rpc_result,rpc_ready,rpc_token,result_address,rpc_byte,receipt,receipt_ready,receipt_token,receipt_error,rpc_clear);
wire receipt_fragment_valid;wire [255:0] receipt_fragment;
// F5 intentionally remains visible for receipt retries. It can coexist with
// the next request; only an unacknowledged F4 still owns the response lease.
assign board_gateway_idle=sender_idle&&(!receipt_fragment_valid||receipt_fragment[255:248]==8'hf5)&&!rpc_result;
a_glyph_result_fragment #(.REVOKE_ENABLED(CAPTURE_ACK),.RESULT_MARKER(8'hf4),.RECEIPT_MARKER(8'hf5),.PAYLOAD_KIND(8'h40),.SOURCE_CLEAR_ATOMIC(1)) rpc_receipts(
 clk,rst_n,receipt,receipt_ready,receipt_token,receipt_error,qv&&own_receipt,packet_value,
 receipt_fragment_valid,receipt_fragment,rpc_clear,{receipt_fragment[199:192],receipt_fragment[207:200],receipt_fragment[215:208],receipt_fragment[223:216]},rpc_receipt_captured);
reg result_leased;reg [1:0] result_source;
wire [1:0] chosen=result_leased?result_source:local_result_valid?0:failure?1:2;
assign result_valid=chosen==0?local_result_valid:chosen==1?failure:rpc_result;
assign result_token=chosen==0?local_result_token:chosen==1?failure_token:rpc_token;
assign result_byte=chosen==0?local_result_byte:chosen==1?failure_byte:rpc_byte;
assign local_result_ready=result_ready&&chosen==0;
assign failure_ready=result_ready&&chosen==1;
assign rpc_ready=result_ready&&chosen==2;
assign local_result_address=result_address;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin result_leased<=0;result_source<=0;end
 else if(result_valid)begin
  if(result_ready)result_leased<=0;
  else if(!result_leased)begin result_leased<=1;result_source<=chosen;end
 end
end
wire poll_finished;
a_spi_poll_event polls(clk,rst_n,spi_cs_n,poll_finished);
a_spi_reply_mux_ram #(.MEDIA32(MEDIA32),.PCM_CAPTURE(PCM_CAPTURE),.EXTERNAL_CRC(CRC_ROM_ENABLED),.PROGRAM_REPLY(PROGRAM_REPLY)) replies(
 .clk(clk),.rst_n(rst_n),.poll_consumed(poll_finished),.status_body(spi_status),
 .request_valid(fragment_valid),.request_header(fragment_header),.request_byte(fragment_byte),.request_address(fragment_address),.request_locked(request_lock),.request_abort(request_abort),
 .control_valid(control_valid||(CAPTURE_ACK&&capture_visible)),.control_header(control_valid?control_header:capture_header),
 .glyph_valid(glyph_valid),.glyph_header(glyph_header),.glyph_body(glyph_body),
 .receipt_valid(receipt_fragment_valid),.receipt_header(receipt_fragment[255:192]),
 .store_ready(reply_store_ready),.write_valid(reply_write),.write_address(reply_address),.write_byte(reply_byte),.publish(reply_publish),.frame_valid(reply_valid),
 .font_receipt_captured(font_receipt_captured),.glyph_receipt_captured(glyph_receipt_captured),.rpc_receipt_captured(rpc_receipt_captured),
 .media_result_valid(media_result_valid),.media_result_header(media_result_header),.media_command_valid(media_command_valid),.media_command_header(media_command_header),
 .pcm_valid(pcm_fragment_valid),.pcm_header(pcm_fragment_header),.pcm_byte(pcm_fragment_byte),.pcm_address(pcm_fragment_address),.pcm_locked(pcm_fragment_locked),
 .media_command_frame(media_command_frame),.crc_clear(spi_crc_clear),.crc_enable(spi_crc_enable),.crc_byte(spi_crc_byte),.external_crc(spi_crc),
 .program_result_valid(program_result_valid),.program_result_header(program_result_header));
endmodule
