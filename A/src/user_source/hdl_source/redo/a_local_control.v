// Local safety and bounded media effects only. B retains normal management.
module a_local_control(input clk,rst_n,tick_ms,link_trip,peer_online,automatic_mode,
 input key_enter,key_toggle,key_next,urgent_enter,urgent_preset_valid,input [1:0] urgent_preset,
 input restore_valid,input [2:0] restored_mode,
 input persist_ready,persist_can_save,persist_busy,persist_confirm,persist_failed,input [2:0] persisted_mode,
 output persist_request,output [2:0] persist_mode,
 input actual_valid,input [2:0] actual_mode,output [2:0] desired_mode,
 input request_valid,output request_ready,input [31:0] request_token,input [7:0] request_command,request_argument,
 input cancel_valid,input [31:0] cancel_token,
 output action_valid,input action_ready,output action_audio,output [7:0] action_code,output [31:0] action_token,
 input applied_valid,input [31:0] applied_token,input [7:0] applied_error,
 output backend_cancel,output [31:0] backend_cancel_token,
 input backend_cancel_done,input [31:0] backend_done_token,
 input [191:0] actual_status,input [31:0] audio_status,
 output result_valid,input result_ready,output [31:0] result_token,
 input [4:0] result_address,output [7:0] result_byte,
 output supervisor_busy,media_draining,output media_clear_accept);
wire query=request_command==1||request_command==2||request_command==15;
wire emergency=request_command==7||request_command==8;
wire media=request_command==9||request_command==10||request_command==13||request_command==14;
wire query_ready,emergency_ready,media_ready;
// CMD9 acceptance at its actual media source; retains its complete readiness guard.
assign media_clear_accept=request_valid&&request_command==9&&media_ready;
assign request_ready=query?query_ready:emergency?emergency_ready:media?media_ready:1'b0;
wire er,er_ready,mr,mr_ready;wire [31:0] et,mt;wire [7:0] ee;wire [191:0] minimal_media;
a_emergency_authority #(.BOOT_EMERGENCY(1)) authority(
 clk,rst_n,tick_ms,link_trip,key_enter,key_toggle,key_next,urgent_enter,urgent_preset_valid,urgent_preset,
 restore_valid,restored_mode,persist_ready,persist_can_save,persist_busy,persist_confirm,persist_failed,persisted_mode,
 persist_request,persist_mode,actual_valid,actual_mode,request_valid&&emergency,emergency_ready,
 request_command,request_argument,request_token,er,er_ready,et,ee,desired_mode,supervisor_busy,cancel_valid,cancel_token);
a_media_actions #(.MINIMAL_REPLY(1)) media_effects(
 clk,rst_n,tick_ms,peer_online,desired_mode[0],automatic_mode,request_valid&&media,media_ready,
 request_token,request_command,request_argument,action_valid,action_ready,action_audio,action_code,action_token,
 applied_valid,applied_token,applied_error,cancel_valid,cancel_token,backend_cancel,backend_cancel_token,
 backend_cancel_done,backend_done_token,192'd0,mr,mr_ready,mt,minimal_media,media_draining);
a_local_reply results(clk,rst_n,request_valid&&query,query_ready,request_token,request_command,
 request_valid&&emergency&&emergency_ready,request_token,request_command,
 er,er_ready,et,ee,mr,mr_ready,mt,minimal_media[7:0],minimal_media[23:16],actual_status,audio_status,
 result_valid,result_ready,result_token,result_address,result_byte);
endmodule
