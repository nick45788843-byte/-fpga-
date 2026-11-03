// Normal menu semantics on B. Config/Flash/actuation stay in the existing
// backend. The integration must provide actual A-issued UID grants and the
// backend's matching complete result and drain credit; none is synthesized here.
module b_menu_engine #(parameter TIMEOUT_MS=20000,BRIDGE_NOTICE_FACTOR=0)(
 input clk,rst_n,tick_ms,emergency,peer_ready,toggle,next_item,plus,minus,
 output reg visible,output reg [2:0] item,output reg known,
 output reg [15:0] value,output reg [1:0] status,output reg [7:0] error,
 output grant_needed,input grant_valid,input [31:0] grant_uid,session_floor,
 output request_valid,input request_ready,output [31:0] request_uid,
 output reg [7:0] request_command,output reg [47:0] request_arguments,
 input result_valid,output result_ready,input [31:0] result_uid,input [191:0] result_payload,
 input notice_valid,notice_session,input [31:0] notice_token,
 input backend_drained,transport_idle,output control_done,output [31:0] control_token,input raw_notice_valid);
localparam TW=$clog2(TIMEOUT_MS+1);
reg [TW-1:0] age;
reg queued,waiting,uid_held,cancelled,defaults_running;reg default_step_pending;
reg [2:0] defaults_index;
reg [31:0] held_uid,owner,last_used_uid;
// The bridge passes N&&(A||H) as notice_valid and A as notice_session.
// Its original predicate is N&&(A||H)&&(A||O||U&&H).
// Factor it to N&&(A||H&&(O||U)), preserving every UID bit and edge.
wire affected=BRIDGE_NOTICE_FACTOR ?
 raw_notice_valid&&(notice_session||(notice_token==held_uid)&&((notice_token==owner)||uid_held)) :
 notice_valid&&(notice_session||notice_token==owner||uid_held&&notice_token==held_uid);
wire fresh_grant=grant_uid>session_floor&&grant_uid>last_used_uid&&grant_uid[31:16]==session_floor[31:16];
assign grant_needed=queued&&!uid_held&&visible&&!emergency&&peer_ready&&!notice_valid;
assign request_valid=queued&&uid_held&&visible&&!emergency&&peer_ready&&!notice_valid;
assign request_uid=held_uid;
assign result_ready=waiting&&result_valid&&result_uid==owner;
assign control_done=notice_valid&&transport_idle&&(!affected||(!waiting&&!queued&&!uid_held&&!default_step_pending));
assign control_token=notice_token;
wire busy=queued||waiting||default_step_pending;
wire [7:0] reply_cmd=result_payload[7:0],reply_status=result_payload[15:8],reply_error=result_payload[23:16];
wire [15:0] reply_parameter=result_payload[47:32],reply_value=result_payload[79:64];
wire bad_reply=reply_status!=0||reply_error!=0||reply_cmd!=request_command||
 request_command!=6&&(reply_parameter!=request_arguments[15:0]||result_payload[95:80]!=0);
function [15:0] parameter_id;input [2:0] i;
begin case(i)0:parameter_id=16'h0101;1:parameter_id=16'h0201;2:parameter_id=16'h0202;3:parameter_id=16'h0203;default:parameter_id=16'h0301;endcase end endfunction
function [15:0] default_value;input [2:0] i;
begin case(i)0:default_value=50;1,2:default_value=100;3:default_value=2;default:default_value=3000;endcase end endfunction
reg [15:0] minimum,maximum,step,changed;
always @(*)begin
 minimum=item==4?1000:0;maximum=item==0?100:item==3?7:item==4?60000:200;
 step=item==3?1:item==4?1000:5;
 if(plus)changed=value>=maximum-step?maximum:value+step;
 else changed=value<=minimum+step?minimum:value-step;
end
task enqueue;input [7:0] c;input [15:0] p,v;
begin request_command<=c;request_arguments<={16'd0,v,p};queued<=1;uid_held<=0;status<=1;error<=0;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  visible<=0;item<=0;known<=0;value<=0;status<=0;error<=0;age<=0;
  default_step_pending<=0;queued<=0;waiting<=0;uid_held<=0;cancelled<=0;defaults_running<=0;defaults_index<=0;
  held_uid<=0;owner<=0;last_used_uid<=0;request_command<=0;request_arguments<=0;
 end else begin
  if(visible&&tick_ms&&age<TIMEOUT_MS)age<=age+1'b1;
  if(toggle||next_item||plus||minus)age<=0;
  if(emergency||visible&&age>=TIMEOUT_MS-1)begin visible<=0;queued<=0;uid_held<=0;defaults_running<=0;default_step_pending<=0;end
  else if(toggle)begin
   if(visible)begin visible<=0;queued<=0;uid_held<=0;defaults_running<=0;default_step_pending<=0;end
   else if(!waiting)begin
    visible<=1;item<=0;known<=0;age<=0;defaults_running<=0;
    if(peer_ready)enqueue(4,16'h0101,0);else begin status<=3;error<=8'hc0;end
   end
  end else if(visible&&!busy&&!defaults_running)begin
   if(next_item)begin
    item<=item+1'b1;known<=0;status<=0;error<=0;
    if(item==7||item<4)begin
     if(peer_ready)enqueue(4,parameter_id(item==7?0:item+1'b1),0);
     else begin status<=3;error<=8'hc0;end
    end
   end else if(plus||minus)begin
    if(item==7)visible<=0;
    else if(!peer_ready)begin status<=3;error<=8'hc0;end
    else if(item<5)begin
     if(known)enqueue(5,parameter_id(item),changed);else enqueue(4,parameter_id(item),0);
    end else if(plus&&item==5)enqueue(6,0,0);
    else if(plus&&item==6)begin defaults_running<=1;defaults_index<=0;enqueue(5,parameter_id(0),default_value(0));end
   end
  end
  if(queued&&!peer_ready)begin queued<=0;uid_held<=0;defaults_running<=0;status<=3;error<=8'hc0;end
  if(grant_needed&&grant_valid&&fresh_grant)begin held_uid<=grant_uid;uid_held<=1;end
  if(request_valid&&request_ready)begin
   owner<=held_uid;last_used_uid<=held_uid;queued<=0;uid_held<=0;waiting<=1;cancelled<=0;
  end
  if(result_ready)begin
   waiting<=0;
   if(cancelled||affected)begin status<=3;error<=8'h43;defaults_running<=0;end
   else if(bad_reply)begin status<=3;error<=reply_error!=0?reply_error:8'h42;defaults_running<=0;end
   else if(defaults_running&&visible&&!emergency&&!toggle&&age<TIMEOUT_MS-1)begin
    if(defaults_index==4)begin defaults_running<=0;status<=2;end
    else default_step_pending<=1;
   end else begin
    status<=request_command==4?0:2;error<=0;
    if(item<5&&request_command!=6&&visible)begin value<=reply_value;known<=1;end
   end
  end
  // A matching validated result only sets this local one-bit credit.
  // Parameter selection and arithmetic occur one clock later, independently
  // of the full cancellation/management return network.
  if(default_step_pending)begin
   default_step_pending<=0;
   if(defaults_running&&visible&&!emergency&&!toggle&&peer_ready&&age<TIMEOUT_MS-1)begin
    defaults_index<=defaults_index+1'b1;
    enqueue(5,parameter_id(defaults_index+1'b1),default_value(defaults_index+1'b1));
   end else begin defaults_running<=0;if(!peer_ready)begin status<=3;error<=8'hc0;end end
  end
  if(affected)begin
   default_step_pending<=0;
   queued<=0;uid_held<=0;defaults_running<=0;
   known<=0;
   if(notice_session)visible<=0;
   if(waiting)cancelled<=1;
  end
  if(cancelled&&backend_drained&&!result_valid)begin waiting<=0;cancelled<=0;status<=3;error<=8'h43;end
 end
end
endmodule
