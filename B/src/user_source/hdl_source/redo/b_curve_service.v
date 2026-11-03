// 计算曲线并暂存64字；元数据与完整数据两事务确认后才允许发送参数执行包。
// 包传输端提供done/error，整机接入时done必须来自A的真实应用ACK。
module b_curve_service #(parameter GAMMA_ENABLED=0,ROM_FILE="gamma_curve.mem") (input clk,rst_n,request_valid,invalidate,input [31:0] request_token,
 input [71:0] request_values,output reg prepared_valid,output reg [31:0] prepared_token,
 output reg [15:0] prepared_style,output reg failed,output reg [7:0] failure_code,
 output meta_request,data_request,output [31:0] transfer_token,output [31:0] meta_word,
 input transfer_done,input [7:0] transfer_error,input [5:0] read_address,output reg [31:0] read_word,
 input notice_valid,input [31:0] notice_token,input notice_session,
 input transfer_busy,transport_idle,output control_done,output [31:0] control_done_token,
 input [7:0] request_gamma,output reg [7:0] prepared_gamma,output [7:0] transfer_gamma);
localparam IDLE=0,CALC=1,META=2,DATA=3;
reg [1:0] state;reg start;reg [31:0] token;reg [15:0] style,crc;reg [31:0] partial;
reg [7:0] gamma;
(* force_ram=1,ram_style="bram" *) reg [31:0] words[0:63];
wire curve_busy,curve_done,curve_error,curve_valid;wire [31:0] curve_token;wire [7:0] index,value;
wire [15:0] wanted_style={request_values[55:48],request_values[47:40]};
wire [7:0] wanted_gamma=GAMMA_ENABLED?request_gamma:8'd2;
// Separate the full-UID cancellation comparison from calculator data paths.
// The join gets credit only for the currently sampled notice context. A newer
// token/class cannot reuse an older cancellation result on the pipeline edge.
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg affected_registered;
reg notice_sample_valid,notice_sample_session;reg [31:0] notice_sample_token;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin affected_registered<=0;notice_sample_valid<=0;notice_sample_session<=0;notice_sample_token<=0;end
 else begin
  affected_registered<=notice_session||notice_token==token;
  notice_sample_valid<=notice_valid;notice_sample_session<=notice_session;notice_sample_token<=notice_token;
 end
end
wire notice_context_current=notice_sample_valid&&notice_sample_session==notice_session&&notice_sample_token==notice_token;
wire affected=notice_valid&&notice_sample_valid&&affected_registered;
assign meta_request=state==META&&!affected;assign data_request=state==DATA&&!affected;
assign control_done=notice_valid&&notice_context_current&&transport_idle&&(!affected||(state==IDLE&&!curve_busy&&!transfer_busy));
assign control_done_token=notice_sample_token;assign transfer_token=token;
assign meta_word={crc,style};
assign transfer_gamma=gamma;
generate if(GAMMA_ENABLED)begin: gamma_calculation
 b_colour_curve_gamma #(.ROM_FILE(ROM_FILE)) calculator(clk,rst_n,start,style[15:8],style[7:0],gamma,token,curve_busy,curve_done,curve_error,curve_token,curve_valid,1'b1,index,value);
end else begin: legacy_calculation
 b_colour_curve calculator(clk,rst_n,start,style[15:8],style[7:0],token,curve_busy,curve_done,curve_error,curve_token,curve_valid,1'b1,index,value);
end endgenerate
function [15:0] crc16;input [15:0] old;input [7:0] v;reg [15:0] c;integer k;
begin c=old^{v,8'd0};for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1);crc16=c;end endfunction
always @(posedge clk)begin
 read_word<=words[read_address];
 if(state==CALC&&curve_valid&&index[1:0]==3)words[index[7:2]]<={value,partial[23:0]};
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;start<=0;token<=0;style<=16'h6464;gamma<=2;prepared_gamma<=2;crc<=16'hffff;partial<=0;prepared_valid<=0;prepared_token<=0;prepared_style<=16'h6464;failed<=0;failure_code<=0;end
 else begin
  start<=0;failed<=0;if(invalidate||affected)prepared_valid<=0;
  case(state)
   IDLE:if(request_valid&&!notice_valid&&(!prepared_valid||invalidate||prepared_token!=request_token||prepared_style!=wanted_style||prepared_gamma!=wanted_gamma))begin
    if(prepared_valid&&!invalidate&&prepared_style==wanted_style&&prepared_gamma==wanted_gamma)prepared_token<=request_token;
    else begin token<=request_token;style<=wanted_style;gamma<=wanted_gamma;crc<=16'hffff;partial<=0;prepared_valid<=0;start<=1;state<=CALC;end
   end
   CALC:begin
    if(curve_valid)begin crc<=crc16(crc,value);case(index[1:0])0:partial[7:0]<=value;1:partial[15:8]<=value;2:partial[23:16]<=value;default:begin end endcase end
    if(curve_done)begin if(curve_error)begin state<=IDLE;failed<=1;failure_code<=8'h47;end else state<=META;end
   end
   META:if(transfer_done)begin if(transfer_error!=0)begin failed<=1;failure_code<=transfer_error;state<=IDLE;end else state<=DATA;end
   DATA:if(transfer_done)begin state<=IDLE;if(transfer_error!=0)begin failed<=1;failure_code<=transfer_error;end else begin prepared_valid<=1;prepared_token<=token;prepared_style<=style;prepared_gamma<=gamma;end end
   default:state<=IDLE;
  endcase
  // Stop private calculation only after the actual calculator has returned.
  // Already accepted transport descriptors must finish their actual A ACK.
  if(affected)begin
   prepared_valid<=0;
   if(state==CALC&&curve_done)begin state<=IDLE;failed<=1;failure_code<=8'h43;end
   if((state==META||state==DATA)&&(!transfer_busy||transfer_done))begin state<=IDLE;failed<=1;failure_code<=8'h43;end
  end
 end
end
endmodule
