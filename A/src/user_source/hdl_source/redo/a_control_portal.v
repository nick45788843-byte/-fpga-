// New control architecture's complete physical CN2 ingress/egress. The byte
// backends hold their result until captured, with no extra router/cache/TX copy.
module a_control_portal #(parameter CLOCK_HZ=50000000,CLKS_PER_BIT=434,EXEC_TIMEOUT_MS=20000,BORROW_DURING_LOCAL=0,PCM_ANALYSIS_ENABLED=1,BOARD_CONTROL_ENABLED=0,EXTERNAL_CRC=0)(
 input clk,rst_n,rx,output tx,input tick_ms,peer_ready,
 input initialize_valid,input [31:0] first_execution_token,output initialize_ready,
 output request_valid,input request_ready,output request_remote,
 output [31:0] request_token,request_wire_id,output [7:0] request_command,
 output [15:0] request_length,output [47:0] request_arguments,output request_bank,request_has_bank,
 input payload_bank,input [7:0] payload_address,output [7:0] payload_byte,
 output cancel_valid,cancel_remote,output [31:0] cancel_token,
 input cancel_done,input [31:0] cancel_done_token,
 output urgent_enter,urgent_preset_valid,output [1:0] urgent_preset,
 input result_valid,output result_ready,input [31:0] result_token,
 output [4:0] result_byte_address,input [7:0] result_byte,
 output reply_remote,output exhausted,idle,output [15:0] dropped,output [31:0] next_execution_token,
 input borrow_valid,output borrow_ready,output [31:0] borrowed_token,
 input board_request_valid,output board_request_ready,input [7:0] board_request_command,
 input [47:0] board_request_arguments,input board_cancel,
 output board_result_valid,input board_result_ready,input [4:0] board_result_address,output [7:0] board_result_byte,output board_result_synthetic,output crc_clear,crc_enable,output [7:0] crc_byte,input [15:0] external_crc);
wire pv,pr,bank,has_bank,release_valid,release_bank;
wire [15:0] session,sequence_id,length;wire [7:0] command,rx_byte;wire [47:0] arguments;
a_packet_receiver #(.CLOCK_HZ(CLOCK_HZ),.CLKS_PER_BIT(CLKS_PER_BIT)) receiver(
 clk,rst_n,rx,pv,pr,session,sequence_id,length,command,arguments,bank,has_bank,
 release_valid,release_bank,payload_bank,payload_address,rx_byte,dropped);
// Reader bank belongs to the backend's captured descriptor, not the current
// request. Emergency preemption must not redirect an old owner's byte reads.
assign payload_byte=rx_byte;
wire submit,ready,synthetic,cache_enable,invalidate,captured,cache,replay,replay_ready,store_idle,control_idle;
wire [31:0] submit_wire,submit_owner,captured_owner,cache_wire;wire [7:0] synthetic_command,synthetic_error;
wire [4:0] byte_address;
wire board_synthetic,result_address_board;wire [7:0] board_command,board_error;
assign board_result_synthetic=board_synthetic;
a_command_control #(.EXEC_TIMEOUT_MS(EXEC_TIMEOUT_MS),.BORROW_DURING_LOCAL(BORROW_DURING_LOCAL),.PCM_ANALYSIS_ENABLED(PCM_ANALYSIS_ENABLED),.BOARD_CONTROL_ENABLED(BOARD_CONTROL_ENABLED)) control(
 clk,rst_n,tick_ms,pv,pr,session,sequence_id,length,command,arguments,bank,has_bank,
 peer_ready,first_execution_token,initialize_valid,initialize_ready,
 request_valid,request_ready,request_remote,request_token,request_wire_id,request_command,request_length,request_arguments,request_bank,request_has_bank,
 release_valid,release_bank,cancel_valid,cancel_remote,cancel_token,cancel_done,cancel_done_token,
 urgent_enter,urgent_preset_valid,urgent_preset,result_valid,result_ready,result_token,
 submit,ready,submit_wire,submit_owner,synthetic,cache_enable,invalidate,synthetic_command,synthetic_error,captured,captured_owner,
 cache,cache_wire,replay,replay_ready,reply_remote,exhausted,control_idle,next_execution_token,
 borrow_valid,borrow_ready,borrowed_token,
 board_request_valid,board_request_ready,board_request_command,board_request_arguments,board_cancel,
 board_result_valid,board_result_ready,board_synthetic,board_command,board_error,result_address_board);
// A real board response consumes this source only for the held board owner.
// Before valid its read data is unused. Synthetic UART/board rejects generate
// their own bytes and do not read this response bank. Keep valid/credit unchanged.
assign result_byte_address=result_address_board?board_result_address:byte_address;
assign board_result_byte=board_synthetic?(board_result_address==0?board_command:board_result_address==1?8'd1:board_result_address==2?board_error:8'd0):result_byte;
wire [7:0] source_byte=synthetic?(byte_address==0?synthetic_command:byte_address==1?8'd1:byte_address==2?synthetic_error:8'd0):result_byte;
a_reply_store #(.CLKS_PER_BIT(CLKS_PER_BIT),.SHARED_DESCRIPTOR(1),.PIPELINED_BODY(1),.EXTERNAL_CRC(EXTERNAL_CRC),.SEQUENTIAL_REPLY(1)) replies(clk,rst_n,submit,ready,submit_wire,submit_owner,cache_enable,invalidate,
 byte_address,source_byte,captured,captured_owner,replay,replay_ready,{session,sequence_id},cache,cache_wire,tx,store_idle,,crc_clear,crc_enable,crc_byte,external_crc);
assign idle=store_idle&&control_idle;
endmodule
