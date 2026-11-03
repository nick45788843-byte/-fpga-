// 新A的唯一应急权威：请求与实际应用/保存分离，B业务不拥有解除应急的权限。
module a_emergency_authority #(
 parameter STORE_TIMEOUT_MS=8000,APPLY_TIMEOUT_MS=1000,BOOT_EMERGENCY=0
)(input clk,rst_n,tick_ms,link_trip,
 input local_enter,local_toggle,local_next,
 input immediate_enter,immediate_preset_valid,input [1:0] immediate_preset,
 input restore_valid,input [2:0] restored_mode,
 input persist_ready,persist_can_save,persist_busy,persist_confirm,persist_failed,input [2:0] persisted_mode,
 output reg persist_request,output reg [2:0] persist_values,
 input actual_valid,input [2:0] actual_mode,
 input request_valid,output request_ready,input [7:0] request_cmd,request_arg,input [31:0] request_token,
 output reg response_valid,input response_ready,output reg [31:0] response_token,output reg [7:0] response_error,
 output reg [2:0] desired_mode,output busy,
 input cancel_valid,input [31:0] cancel_token);
localparam IDLE=0,STORE=1,APPLY=2;
localparam MAX_MS=STORE_TIMEOUT_MS>APPLY_TIMEOUT_MS?STORE_TIMEOUT_MS:APPLY_TIMEOUT_MS;
localparam TIMER_W=MAX_MS>0?$clog2(MAX_MS+1):1;
reg [1:0] state;reg [TIMER_W-1:0] age;
reg [2:0] target,previous_mode;reg pc_active,store_sent,background_dirty,mode_touched;
reg [31:0] active_token;
// Link/key safety has priority. A CRC-qualified PC enter preserves its preset;
// a direct preset takes effect immediately even while an old NV save is busy.
wire [2:0] forced_mode=(local_enter||(local_toggle&&!desired_mode[0]))?3'd1:
 immediate_preset_valid?{immediate_preset,1'b1}:{desired_mode[2:1],1'b1};
assign busy=state!=IDLE;
assign request_ready=state==IDLE&&!response_valid&&!local_enter&&!local_toggle&&!local_next&&!immediate_enter&&!immediate_preset_valid;
task reply;input [7:0] code;begin
 if(pc_active)begin response_valid<=1;response_token<=active_token;response_error<=code;end
 state<=IDLE;pc_active<=0;age<=0;store_sent<=0;
end endtask
task begin_mode;input [2:0] mode;input pc;input [31:0] tok;begin
 target<=mode;previous_mode<=desired_mode;active_token<=tok;pc_active<=pc;store_sent<=0;age<=0;mode_touched<=1;state<=STORE;
 // 进入不等待Flash；退出仍保持旧应急画面，直到保存确认。
 if(mode[0])desired_mode<=mode;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;age<=0;target<=3'b001;previous_mode<=3'b001;desired_mode<=3'b001;active_token<=0;
  pc_active<=0;store_sent<=0;background_dirty<=0;mode_touched<=0;
  persist_request<=0;persist_values<=3'b001;response_valid<=0;response_token<=0;response_error<=0;
 end else begin
  persist_request<=0;
  if(response_valid&&response_ready)response_valid<=0;
  if(restore_valid&&!mode_touched&&state==IDLE&&!background_dirty)begin
   // Safe boot keeps the saved preset but never treats an old normal-exit record
   // as authority to clear a new boot emergency. Explicit exits still persist/apply.
   desired_mode<=BOOT_EMERGENCY?{restored_mode[2:1],1'b1}:restored_mode;
   target<=BOOT_EMERGENCY?{restored_mode[2:1],1'b1}:restored_mode;
   persist_values<=BOOT_EMERGENCY?{restored_mode[2:1],1'b1}:restored_mode;
  end
  case(state)
   IDLE:if(background_dirty&&persist_ready&&persist_can_save&&!persist_busy)begin
    persist_values<=desired_mode;persist_request<=1;background_dirty<=0;
   end
   STORE:begin
    if(tick_ms&&!persist_busy&&age<STORE_TIMEOUT_MS)age<=age+1'b1;
    if(persist_busy)age<=0;
    if(!store_sent&&persist_ready&&!persist_busy)begin
     if(!persist_can_save)begin background_dirty<=target[0];reply(8'h75);end
     else begin persist_values<=target;persist_request<=1;store_sent<=1;end
    end
    if(store_sent&&persist_failed)begin
     // 撤销未成功退出，避免迟到保存/其它参数保存把应急状态带成普通。
     persist_values<=desired_mode;persist_request<=1;background_dirty<=1;reply(8'h75);
    end else if(store_sent&&persist_confirm&&persisted_mode==target)begin
     desired_mode<=target;state<=APPLY;age<=0;
    end else if(age>=STORE_TIMEOUT_MS-1&&!persist_busy)begin
     persist_values<=desired_mode;persist_request<=1;background_dirty<=1;reply(8'h48);
    end
   end
   APPLY:begin
    if(tick_ms&&age<APPLY_TIMEOUT_MS)age<=age+1'b1;
    if(actual_valid&&actual_mode==target)reply(0);
    else if(age>=APPLY_TIMEOUT_MS-1)begin
     if(!target[0])begin desired_mode<=previous_mode;persist_values<=previous_mode;persist_request<=1;background_dirty<=1;end
     reply(8'h48);
    end
   end
  endcase
  if(request_valid&&request_ready)begin
   if((request_cmd==7&&request_arg<=1)||(request_cmd==8&&request_arg<=3))begin
    begin_mode(request_cmd==7?{desired_mode[2:1],request_arg[0]}:{request_arg[1:0],1'b1},1'b1,request_token);
   end else begin response_valid<=1;response_token<=request_token;response_error<=request_cmd==7||request_cmd==8?8'h47:8'h40;end
  end
  if(state==IDLE&&!response_valid)begin
   if(local_next&&desired_mode[0])begin_mode({desired_mode[2:1]+2'd1,1'b1},0,0);
   else if(local_toggle)begin_mode({desired_mode[2:1],!desired_mode[0]},0,0);
  end
  if(cancel_valid&&pc_active&&cancel_token==active_token&&state!=IDLE)begin
   if(!target[0])begin desired_mode<=previous_mode;persist_values<=previous_mode;end else persist_values<=desired_mode;
   persist_request<=1;background_dirty<=1;reply(8'h43);
  end
  // 专用安全进入优先于一切长事务；旧PC操作得到取消结果，迟到完成不解除应急。
  if(local_enter||(local_toggle&&!desired_mode[0])||immediate_enter||immediate_preset_valid)begin
   if(pc_active&&state!=IDLE)begin response_valid<=1;response_token<=active_token;response_error<=8'h43;end
   desired_mode<=forced_mode;target<=forced_mode;persist_values<=forced_mode;
   state<=IDLE;pc_active<=0;store_sent<=0;age<=0;background_dirty<=1;mode_touched<=1;persist_request<=0;
  end
 end
end
endmodule
