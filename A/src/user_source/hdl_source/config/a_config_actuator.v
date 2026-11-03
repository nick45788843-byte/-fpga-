// A执行器只验证范围、提交实际设置并等待应用确认；确认通道独立，不占媒体接收邮箱。
module a_config_actuator #(parameter CLOCK_HZ=50000000,APPLY_TIMEOUT_CYCLES=CLOCK_HZ)(
 input clk,rst_n,peer_restart,request_valid,output request_ready,input [31:0] request_token,input [71:0] request_values,
 input legacy_ready,input [71:0] legacy_values,
 input media_applied_valid,input [31:0] media_applied,input period_applied_valid,input [31:0] period_applied,
 output reg values_valid,output reg [71:0] values,
 output reg acknowledged_valid,output reg [31:0] acknowledged_token,output reg [7:0] acknowledged_error);
reg pending,initialized;reg [31:0] timer,active_token;reg [71:0] previous_values;
assign request_ready=!pending;
wire applied=media_applied_valid&&media_applied==values[71:40]&&period_applied_valid&&period_applied==values[39:8];
function good_values;input [71:0] v;begin good_values=v[71:64]<=100&&v[63:56]>=20&&v[63:56]<=100&&v[55:48]<=200&&v[47:40]<=200&&v[39:8]>=1000&&v[39:8]<=60000&&v[7:0]<=1;end endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin previous_values<=72'h3232646400000bb800;pending<=0;initialized<=0;timer<=0;active_token<=0;values_valid<=0;values<=72'h3232646400000bb800;acknowledged_valid<=0;acknowledged_token<=0;acknowledged_error<=0;end
 else begin
  if(!initialized&&legacy_ready)begin initialized<=1;values<=legacy_values;values_valid<=1;end
  if(request_valid&&request_ready)begin
   acknowledged_valid<=0;active_token<=request_token;timer<=0;
   if(!good_values(request_values))begin acknowledged_valid<=1;acknowledged_token<=request_token;acknowledged_error<=8'h47;end
   else begin previous_values<=values;values<=request_values;values_valid<=1;pending<=1;initialized<=1;end
  end
  if(pending)begin
   if(applied)begin pending<=0;acknowledged_valid<=1;acknowledged_token<=active_token;acknowledged_error<=0;end
   else if(timer>=APPLY_TIMEOUT_CYCLES-1)begin values<=previous_values;pending<=0;acknowledged_valid<=1;acknowledged_token<=active_token;acknowledged_error<=8'h48;end
   else timer<=timer+1'b1;
  end
  if(peer_restart)begin if(pending)values<=previous_values;pending<=0;acknowledged_valid<=0;timer<=0;end
 end
end
endmodule
