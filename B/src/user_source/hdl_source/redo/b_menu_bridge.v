// Reuses the existing A board portal and B config backend. This module has no
// local operation UID allocator, Flash driver, result RAM or SPI master.
module b_menu_bridge #(parameter CLOCK_HZ=50000000,IDLE_REFRESH_CYCLES=CLOCK_HZ/50)(input clk,rst_n,emergency,peer_ready,
 input toggle,next_item,plus,minus,
 input global_done,input notice_valid,notice_session,input [31:0] notice_token,
 input transport_idle,normal_control_done,input [31:0] normal_control_token,
 input assembled_valid,input [7:0] assembled_command,input [31:0] assembled_uid,
 input [47:0] assembled_arguments,input backend_ready,
 output assembled_ready,output backend_valid,
 input response_captured,input [31:0] response_uid,input [191:0] response_payload,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,input tx_done,
 output control_done,output [31:0] control_token,
 output display_visible,display_known,display_live,output [2:0] display_item,
 output [15:0] display_value,output [1:0] display_status,output [7:0] display_error,output [31:0] display_cookie,output display_tick_ms);
localparam DIV=CLOCK_HZ/1000,DW=DIV>1?$clog2(DIV):1;
reg [DW-1:0] divider;wire tick_ms=divider==DIV-1;
always @(posedge clk or negedge rst_n)
 if(!rst_n)divider<=0;else if(tick_ms)divider<=0;else divider<=divider+1'b1;
reg [31:0] floor;reg live;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin floor<=0;live<=0;end
 else begin
  if(notice_valid&&notice_session)live<=0;
  if(global_done&&notice_valid&&notice_session)begin floor<=notice_token;live<=1;end
 end
end
wire visible,known,grant_needed,request_valid,result_ready,engine_done;
wire [2:0] item;wire [15:0] value;wire [1:0] status;wire [7:0] error,command;
wire [31:0] uid,engine_cookie;wire [47:0] arguments;
assign display_tick_ms=tick_ms;assign display_visible=visible;assign display_known=known;assign display_live=live;
assign display_item=item;assign display_value=value;assign display_status=status;assign display_error=error;assign display_cookie=floor;
wire internal_command=assembled_command>=24&&assembled_command<=26;
wire matched=assembled_valid&&internal_command&&assembled_command==command+8'd20&&assembled_arguments==arguments;
wire dispatched=request_valid&&matched&&uid==assembled_uid;
assign backend_valid=dispatched&&!notice_valid;
assign assembled_ready=backend_ready&&backend_valid;
// F1 can reach the assembler before the menu has captured its fresh UID.
// Clear only an internal menu owner; PC same-value requests cannot match.
wire menu_notice=notice_valid&&(notice_session||
 internal_command&&assembled_uid==notice_token||uid==notice_token);
b_menu_engine #(.BRIDGE_NOTICE_FACTOR(1)) engine(clk,rst_n,tick_ms,emergency,peer_ready&&live,
 toggle,next_item,plus,minus,visible,item,known,value,status,error,
 grant_needed,matched,assembled_uid,floor,
 request_valid,assembled_ready,uid,command,arguments,
 response_captured,result_ready,response_uid,response_payload,
 menu_notice,notice_session||internal_command&&assembled_uid==notice_token,notice_token,
 normal_control_done&&normal_control_token==notice_token,transport_idle,engine_done,engine_cookie,notice_valid);
// Immutable descriptor fields from offer through physical completion.
reg offered,accepted;reg [15:0] ticket,held_parameter;reg [31:0] held_value;
reg last_visible,last_request;reg [2:0] last_item;reg [3:0] last_command;
localparam RETRY_BITS=IDLE_REFRESH_CYCLES>2048?$clog2(IDLE_REFRESH_CYCLES+1):12;
reg [47:0] last_arguments;reg [RETRY_BITS-1:0] retry;
wire wants_request=grant_needed;
wire changed=visible!=last_visible||item!=last_item||wants_request!=last_request||
 wants_request&&(command[3:0]!=last_command||arguments!=last_arguments);
assign tx_valid=offered;assign tx_kind=8'h53;assign tx_count=0;
assign tx_sequence=held_parameter;assign tx_tag=ticket;assign tx_value=held_value;
assign control_done=notice_valid&&transport_idle&&!offered&&!accepted&&(!menu_notice||engine_done);
assign control_token=notice_token;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  offered<=0;accepted<=0;ticket<=0;held_parameter<=0;held_value<=0;
  last_visible<=0;last_request<=0;last_item<=0;last_command<=0;last_arguments<=0;retry<=0;
 end else begin
  if(offered&&tx_ready)begin offered<=0;accepted<=1;end
  if(accepted&&tx_done)begin accepted<=0;retry<=held_value[27:24]==0?IDLE_REFRESH_CYCLES:2048;end
  else if(retry!=0)retry<=retry-1'b1;
  if(global_done&&notice_valid&&notice_session)begin
   ticket<=0;last_visible<=0;last_request<=0;last_item<=0;last_command<=0;last_arguments<=0;held_value<=0;held_parameter<=0;
  end
  if(!offered&&!accepted&&live&&!notice_valid&&ticket!=16'hffff)begin
   if(changed)begin
    ticket<=ticket+1'b1;held_value<={visible,item,wants_request?command[3:0]:4'd0,8'd0,wants_request?arguments[31:16]:16'd0};
    held_parameter<=wants_request?arguments[15:0]:16'd0;
    last_visible<=visible;last_item<=item;last_request<=wants_request;last_command<=command[3:0];last_arguments<=arguments;
    offered<=1;
   end else if(ticket!=0&&retry==0)offered<=1;
  end
  if(notice_valid&&!accepted&&!(offered&&tx_ready))offered<=0;
 end
end
endmodule
