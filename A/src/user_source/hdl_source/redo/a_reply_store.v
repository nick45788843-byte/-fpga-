// Sequential mode retains complete current/cache banks and physical UART leases.
// Four complete CN2 frames share one byte RAM. Cache, queue and active UART
// reference banks; no producer/router/cache/transmitter wide-payload copies.
module a_reply_store #(parameter CLKS_PER_BIT=434,SHARED_DESCRIPTOR=0,PIPELINED_BODY=0,EXTERNAL_CRC=0,SEQUENTIAL_REPLY=0)(input clk,rst_n,
 input submit_valid,output submit_ready,input [31:0] submit_wire_id,submit_owner,input submit_cache_enable,invalidate_cache,
 output reg [4:0] source_address,input [7:0] source_byte,
 output reg captured,output [31:0] captured_owner,
 input replay_valid,output replay_ready,input [31:0] replay_wire_id,
 output reg cache_valid,output reg [31:0] cache_wire_id,
 output tx,output reg idle,output [2:0] queued_count,output crc_clear,crc_enable,output [7:0] crc_byte,input [15:0] external_crc);
localparam B_IDLE=0,B_HEADER=1,B_ADDR=2,B_WAIT=3,B_PAYLOAD=4,B_CRC_LO=5,B_CRC_HI=6,B_COMMIT=7;
localparam T_IDLE=0,T_ADDR=1,T_WAIT=2,T_SEND=3,T_DONE=4;
localparam BANK_BITS=SEQUENTIAL_REPLY?1:2,QUEUE_DEPTH=SEQUENTIAL_REPLY?1:4,COUNT_BITS=SEQUENTIAL_REPLY?1:3;
(* force_ram=1,ram_style="bram" *) reg [7:0] memory[0:(SEQUENTIAL_REPLY?127:255)];
reg [2:0] build_state,tx_state;reg [BANK_BITS-1:0] build_bank,tx_bank,cache_bank;
reg [31:0] private_wire_id,private_owner,private_captured_owner;
wire [31:0] wire_id=SHARED_DESCRIPTOR?submit_wire_id:private_wire_id;
wire [31:0] owner=SHARED_DESCRIPTOR?submit_owner:private_owner;
assign captured_owner=SHARED_DESCRIPTOR?submit_owner:private_captured_owner;reg cache_this_frame;reg [5:0] build_index,tx_index;reg [15:0] private_crc;
wire [15:0] crc=EXTERNAL_CRC?external_crc:private_crc;
reg [BANK_BITS-1:0] queue[0:QUEUE_DEPTH-1];reg [1:0] head,tail;reg [COUNT_BITS-1:0] count,refs0,refs1,refs2,refs3;
reg [7:0] byte_out;wire byte_busy,byte_done;
wire building=build_state!=B_IDLE,sending=tx_state!=T_IDLE;
wire [3:0] used={refs3!=0,refs2!=0,refs1!=0,refs0!=0}|
 (building?(4'b0001<<build_bank):4'd0)|(sending?(4'b0001<<tx_bank):4'd0)|(cache_valid?(4'b0001<<cache_bank):4'd0);
wire [BANK_BITS-1:0] free_bank=SEQUENTIAL_REPLY?(!used[0]?0:1):(!used[0]?0:!used[1]?1:!used[2]?2:3);
wire free_found=SEQUENTIAL_REPLY?used[1:0]!=2'b11:used!=4'hf;
wire pop=tx_state==T_IDLE&&count!=0;
wire commit=build_state==B_COMMIT&&(count<QUEUE_DEPTH||pop);
wire replay=replay_valid&&replay_ready;
assign submit_ready=!building&&free_found&&count<QUEUE_DEPTH&&(!SEQUENTIAL_REPLY||(!sending&&!byte_busy));
assign replay_ready=cache_valid&&replay_wire_id==cache_wire_id&&(count<QUEUE_DEPTH||pop)&&!commit&&(!SEQUENTIAL_REPLY||(!sending&&!pop));
assign queued_count=count;
wire enqueue=commit||replay;wire [BANK_BITS-1:0] enqueue_bank=commit?build_bank:cache_bank;
wire [BANK_BITS-1:0] pop_bank=queue[SEQUENTIAL_REPLY?2'd0:head];
function [15:0] crc_step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;crc_step={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
reg [7:0] header_byte;
always @(*)begin
 header_byte=0;
 case(build_index)
  0:header_byte=8'h43;1:header_byte=8'h4e;2:header_byte=2;
  3:header_byte=wire_id[23:16];4:header_byte=wire_id[31:24];
  5:header_byte=wire_id[7:0];6:header_byte=wire_id[15:8];
  7:header_byte=8'h81;8:header_byte=24;default:header_byte=0;
 endcase
end
// Actual sources own a stable response bank and use a synchronous read.
// B_ADDR already gives it an edge; B_WAIT captures that byte before CRC/RAM.
// No state, address, publication, capture or UART cycle is added here.
reg [7:0] held_body_byte;
always @(posedge clk)if(rst_n&&build_state==B_WAIT)held_body_byte<=source_byte;
wire [7:0] body_byte=PIPELINED_BODY?held_body_byte:source_byte;
assign crc_clear=submit_valid&&submit_ready;
assign crc_enable=build_state==B_HEADER||build_state==B_PAYLOAD;
assign crc_byte=build_state==B_HEADER?header_byte:body_byte;
wire write_enable=build_state==B_HEADER||build_state==B_PAYLOAD||build_state==B_CRC_LO||build_state==B_CRC_HI;
wire [7:0] write_byte=build_state==B_HEADER?header_byte:build_state==B_PAYLOAD?body_byte:build_state==B_CRC_LO?crc[7:0]:crc[15:8];
always @(posedge clk)begin
 if(write_enable)memory[{build_bank,build_index}]<=write_byte;
 byte_out<=memory[{tx_bank,tx_index}];
end
uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) transmitter(clk,rst_n,tx_state==T_SEND&&!byte_busy,byte_out,tx,byte_busy,byte_done);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  build_state<=B_IDLE;tx_state<=T_IDLE;build_bank<=0;tx_bank<=0;cache_bank<=0;
  private_wire_id<=0;private_owner<=0;cache_this_frame<=0;build_index<=0;tx_index<=0;private_crc<=16'hffff;source_address<=0;
  captured<=0;private_captured_owner<=0;cache_valid<=0;cache_wire_id<=0;head<=0;tail<=0;count<=0;idle<=1;
  refs0<=0;refs1<=0;refs2<=0;refs3<=0;
 end else begin
  captured<=0;
  if(invalidate_cache)cache_valid<=0;
  // Register the empty/drained observation. Queue pop and transmitter state
  // change together; a combinational reduction can glitch between their NBA
  // updates and incorrectly advertise a completed physical transmission.
  idle<=!building&&!sending&&count==0&&!byte_busy&&!(submit_valid&&submit_ready)&&!replay;
  if(enqueue)begin queue[SEQUENTIAL_REPLY?2'd0:tail]<=enqueue_bank;if(!SEQUENTIAL_REPLY)tail<=tail+1'b1;end
  if(pop&&!SEQUENTIAL_REPLY)head<=head+1'b1;
  case({enqueue,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  case({enqueue&&enqueue_bank==0,pop&&pop_bank==0})2'b10:refs0<=refs0+1'b1;2'b01:refs0<=refs0-1'b1;default:begin end endcase
  case({enqueue&&enqueue_bank==1,pop&&pop_bank==1})2'b10:refs1<=refs1+1'b1;2'b01:refs1<=refs1-1'b1;default:begin end endcase
  case({enqueue&&enqueue_bank==2,pop&&pop_bank==2})2'b10:refs2<=refs2+1'b1;2'b01:refs2<=refs2-1'b1;default:begin end endcase
  case({enqueue&&enqueue_bank==3,pop&&pop_bank==3})2'b10:refs3<=refs3+1'b1;2'b01:refs3<=refs3-1'b1;default:begin end endcase
  case(build_state)
   B_IDLE:if(submit_valid&&submit_ready)begin
    build_bank<=free_bank;if(!SHARED_DESCRIPTOR)begin private_wire_id<=submit_wire_id;private_owner<=submit_owner;end
    cache_this_frame<=submit_cache_enable;
    build_index<=0;private_crc<=16'hffff;build_state<=B_HEADER;
   end
   B_HEADER:begin private_crc<=crc_step(crc,header_byte);build_index<=build_index+1'b1;
    if(build_index==9)begin source_address<=0;build_state<=B_ADDR;end
   end
   B_ADDR:build_state<=B_WAIT;
   B_WAIT:build_state<=B_PAYLOAD;
   B_PAYLOAD:begin private_crc<=crc_step(crc,body_byte);build_index<=build_index+1'b1;
    if(build_index==33)build_state<=B_CRC_LO;else begin source_address<=source_address+1'b1;build_state<=B_ADDR;end
   end
   B_CRC_LO:begin build_index<=35;build_state<=B_CRC_HI;end
   B_CRC_HI:build_state<=B_COMMIT;
   B_COMMIT:if(commit)begin
    if(cache_this_frame&&!invalidate_cache)begin cache_bank<=build_bank;cache_wire_id<=wire_id;cache_valid<=1;end
    captured<=1;if(!SHARED_DESCRIPTOR)private_captured_owner<=owner;build_state<=B_IDLE;
   end
   default:build_state<=B_IDLE;
  endcase
  case(tx_state)
   T_IDLE:if(pop)begin tx_bank<=pop_bank;tx_index<=0;tx_state<=T_ADDR;end
   T_ADDR:tx_state<=T_WAIT;
   T_WAIT:tx_state<=T_SEND;
   T_SEND:if(!byte_busy)tx_state<=T_DONE;
   T_DONE:if(byte_done)begin
    if(tx_index==35)tx_state<=T_IDLE;else begin tx_index<=tx_index+1'b1;tx_state<=T_ADDR;end
   end
   default:tx_state<=T_IDLE;
  endcase
 end
end
endmodule
