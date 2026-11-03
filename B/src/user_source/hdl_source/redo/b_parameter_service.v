// B参数服务核心：不含电脑UART；请求由A校验和转发，实际应用确认后才更新配置。
module b_parameter_service #(parameter CLOCK_HZ=50000000,GAMMA_ENABLED=0,SCALE_ENABLED=0,APPLY_TIMEOUT_SECONDS=1)(
 input clk,rst_n,request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_cmd,input [15:0] request_length,input [47:0] request_args,
 output reg reply_valid,input reply_ready,output reg [31:0] reply_token,output reg [191:0] reply_payload,
 input cfg_ready,cfg_stored,cfg_dirty,cfg_can_save,cfg_rejected,input [7:0] cfg_error,
 input [71:0] cfg_values,input [31:0] cfg_generation,cfg_saved_generation,input [7:0] text_summary,
 input applied_valid,input [71:0] applied_values,
 output actuation_request,output reg [71:0] actuation_values,input actuation_done,input [7:0] actuation_error,
 output reg cfg_set_valid,output reg [71:0] cfg_set_values,output reg cfg_save_request,
 input cfg_save_done,cfg_save_failed,cfg_busy,
 input [7:0] cfg_gamma,applied_gamma,output reg [7:0] actuation_gamma,cfg_set_gamma,
 input [7:0] cfg_scale,applied_scale,output reg [7:0] actuation_scale,cfg_set_scale);
localparam IDLE=0,EXECUTE=1,APPLY=2,COMMIT=3,SEND=4,SAVE=5;
reg [2:0] state;reg [7:0] cmd;reg [15:0] len;reg [47:0] args;reg [31:0] token,timer;
wire [15:0] parameter_id=args[15:0];wire [31:0] desired=args[47:16];
wire known=parameter_id==16'h0101||parameter_id==16'h0102||parameter_id==16'h0103||parameter_id==16'h0201||parameter_id==16'h0202||parameter_id==16'h0301||GAMMA_ENABLED&&parameter_id==16'h0203||SCALE_ENABLED&&parameter_id==16'h0204;
reg [31:0] value,minimum,maximum;reg [71:0] proposed;
wire applied=applied_valid&&applied_values==cfg_values&&(!GAMMA_ENABLED||applied_gamma==cfg_gamma)&&(!SCALE_ENABLED||applied_scale==cfg_scale);
localparam [7:0] WRITABLE=8'h3f|(GAMMA_ENABLED?8'h40:8'd0)|(SCALE_ENABLED?8'h80:8'd0);
wire [7:0] flags={3'd0,applied,cfg_can_save,cfg_dirty,cfg_stored,cfg_ready};
assign request_ready=state==IDLE;assign actuation_request=state==APPLY;
always @(*)begin
 value=0;minimum=0;maximum=100;proposed=cfg_values;
 case(parameter_id)
  16'h0101:begin value={24'd0,cfg_values[71:64]};proposed[71:64]=desired[7:0];end
  16'h0102:begin value={24'd0,cfg_values[63:56]};minimum=20;proposed[63:56]=desired[7:0];end
  16'h0201:begin value={24'd0,cfg_values[55:48]};maximum=200;proposed[55:48]=desired[7:0];end
  16'h0202:begin value={24'd0,cfg_values[47:40]};maximum=200;proposed[47:40]=desired[7:0];end
  16'h0203:if(GAMMA_ENABLED)begin value={24'd0,cfg_gamma};maximum=7;end
  16'h0204:if(SCALE_ENABLED)begin value={24'd0,cfg_scale};maximum=4;end
  16'h0103:begin value={24'd0,cfg_values[7:0]};maximum=1;proposed[7:0]=desired[7:0];end
  16'h0301:begin value=cfg_values[39:8];minimum=1000;maximum=60000;proposed[39:8]=desired;end
 endcase
end
function [191:0] parameter_reply;input [7:0] result,error;reg [7:0] pf;begin
 pf={3'd0,cfg_dirty,cfg_stored,applied,known,known};
 parameter_reply={cfg_generation,maximum,minimum,value,flags,8'd0,parameter_id,pf,error,result,cmd};
end endfunction
function [191:0] config_reply;input [7:0] result,error;begin
 config_reply={cfg_saved_generation,cfg_generation,text_summary,cfg_error,WRITABLE,cfg_values[7:0],cfg_values[39:8],cfg_values[47:40],cfg_values[55:48],cfg_values[63:56],cfg_values[71:64],flags,error,result,cmd};
end endfunction
task respond;input [191:0] payload;begin reply_payload<=payload;reply_token<=token;reply_valid<=1;state<=SEND;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;cmd<=0;len<=0;args<=0;token<=0;timer<=0;reply_valid<=0;reply_token<=0;reply_payload<=0;actuation_values<=0;actuation_gamma<=2;cfg_set_gamma<=2;actuation_scale<=0;cfg_set_scale<=0;cfg_set_valid<=0;cfg_set_values<=0;cfg_save_request<=0;end
 else begin
  cfg_set_valid<=0;cfg_save_request<=0;
  case(state)
   IDLE:if(request_valid)begin cmd<=request_cmd;len<=request_length;args<=request_args;token<=request_token;state<=EXECUTE;end
   EXECUTE:begin
    if((cmd==3||cmd==6)&&len!=0||cmd==4&&len!=2||cmd==5&&len!=6)respond({160'd0,8'd0,8'h42,8'd1,cmd});
    else if(!cfg_ready)respond(config_reply(1,8'h43));
    else case(cmd)
     3:respond(config_reply(0,0));
     4:respond(parameter_reply(known?0:1,known?0:8'h45));
     5:if(!known)respond(parameter_reply(1,8'h40));
       else if(desired<minimum||desired>maximum)respond(parameter_reply(1,8'h47));
       else begin actuation_values<=proposed;actuation_gamma<=GAMMA_ENABLED?(parameter_id==16'h0203 ? desired[7:0]:cfg_gamma):8'd2;
        actuation_scale<=SCALE_ENABLED?(parameter_id==16'h0204 ? desired[7:0]:cfg_scale):8'd0;timer<=0;state<=APPLY;end
     6:if(!cfg_can_save)respond(config_reply(1,8'h75));else begin cfg_save_request<=1;timer<=0;state<=SAVE;end
     default:respond({160'd0,8'd0,8'h40,8'd1,cmd});
    endcase
   end
   APPLY:begin
    if(actuation_done)begin
     if(actuation_error!=0)respond(parameter_reply(1,actuation_error));
     else begin cfg_set_values<=actuation_values;cfg_set_gamma<=actuation_gamma;cfg_set_scale<=actuation_scale;cfg_set_valid<=1;timer<=0;state<=COMMIT;end
    end else if(timer>=CLOCK_HZ*APPLY_TIMEOUT_SECONDS-1)respond(parameter_reply(1,8'h48));else timer<=timer+1'b1;
   end
   COMMIT:if(cfg_rejected)respond(parameter_reply(1,8'h43));
    else if(cfg_ready&&cfg_values==actuation_values&&(!GAMMA_ENABLED||cfg_gamma==actuation_gamma)&&(!SCALE_ENABLED||cfg_scale==actuation_scale))respond(parameter_reply(0,0));
    else if(timer>=CLOCK_HZ-1)respond(parameter_reply(1,8'h48));else timer<=timer+1'b1;
   SAVE:if(cfg_save_done)respond(config_reply(0,0));
    else if(cfg_save_failed)respond(config_reply(1,cfg_error==0?8'h75:cfg_error));
    // A timeout is an error only after the real Flash engine is idle. It can
    // never release a still-programming/validating physical transaction.
    else if(timer>=CLOCK_HZ*8-1&&!cfg_busy)respond(config_reply(1,8'h75));
    else if(timer<CLOCK_HZ*8-1)timer<=timer+1'b1;
   SEND:if(reply_valid&&reply_ready)begin reply_valid<=0;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
end
endmodule
