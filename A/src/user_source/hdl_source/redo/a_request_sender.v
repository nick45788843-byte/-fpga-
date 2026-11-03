// A owns one complete RX bank until B's final capture or actual cancellation.
// The SPI frame builder reads header/body bytes directly; no 256-bit fragment
// snapshot and no second complete request-body cache exist here.
module a_request_sender(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_command,input [15:0] request_length,
 input [47:0] request_arguments,input request_bank,request_has_bank,
 output read_bank,output [7:0] read_address,input [7:0] read_byte,
 output fragment_valid,input fragment_locked,input [4:0] fragment_address,output [7:0] fragment_byte,
 input ack_valid,input [31:0] ack_token,input [7:0] ack_index,ack_error,input ack_captured,
 input cancel_valid,input [31:0] cancel_token,
 output cancel_notice_valid,output [31:0] cancel_notice_token,
 input cancel_confirm_valid,input [31:0] cancel_confirm_token,
 output cancel_done,output [31:0] cancel_done_token,
 output failure_valid,input failure_ready,output [31:0] failure_token,
 input [4:0] failure_address,output [7:0] failure_byte,output idle,output [63:0] fragment_header,output abort_fragment);
localparam IDLE=0,SEND=1,CANCEL=2,CAPTURED=3,FAIL=4;
reg [2:0] state;
reg [31:0] owner;reg [7:0] command,length,index,base,count,error;
reg bank,has_bank,external_cancel;reg [47:0] arguments;
wire affected=cancel_valid&&cancel_token==owner&&state!=IDLE;
assign abort_fragment=affected&&state!=CANCEL;
wire drained=cancel_confirm_valid&&cancel_confirm_token==owner||
 ack_valid&&ack_token==owner&&ack_index==8'hff&&ack_error==0&&!ack_captured;
assign request_ready=state==CAPTURED&&request_token==owner&&!affected;
assign read_bank=bank;
assign read_address=base+{3'd0,fragment_address}-8'd8;
assign fragment_valid=(state==SEND&&!affected)||state==CANCEL;
assign cancel_notice_valid=state==CANCEL;
assign cancel_notice_token=owner;
assign cancel_done=state==IDLE&&external_cancel&&cancel_valid&&cancel_token==owner;
assign cancel_done_token=owner;
assign failure_valid=state==FAIL&&!affected;
assign failure_token=owner;
assign failure_byte=failure_address==0?command:failure_address==1?8'd1:failure_address==2?error:8'd0;
assign idle=state==IDLE;
wire [7:0] offset=base+{3'd0,fragment_address}-8'd8;
assign fragment_header={state==CANCEL?8'hf1:command,state==CANCEL?8'd0:length,
 state==CANCEL?8'd0:index,state==CANCEL?8'd0:count,owner[7:0],owner[15:8],owner[23:16],owner[31:24]};
  // Legacy CN2 requests are capped at 192 bytes. CMD22 adds a six-byte
  // descriptor before up to 192 UTF-8 bytes, so its legal body is 198 bytes.
  // Keep the exception command-specific so malformed long legacy requests
  // cannot enter the fragment sender.
  wire request_length_allowed=(request_length<=16'd192)||
    (request_command==8'd22&&request_length<=16'd198);
reg [7:0] header_byte;
always @(*)begin
 case(fragment_address)
  0:header_byte=state==CANCEL?8'hf1:command;
  1:header_byte=state==CANCEL?8'd0:length;
  2:header_byte=state==CANCEL?8'd0:index;
  3:header_byte=state==CANCEL?8'd0:count;
  4:header_byte=owner[7:0];5:header_byte=owner[15:8];
  6:header_byte=owner[23:16];7:header_byte=owner[31:24];
  default:header_byte=0;
 endcase
end
reg [7:0] inline_byte;
always @(*)case(offset)
 0:inline_byte=arguments[7:0];1:inline_byte=arguments[15:8];2:inline_byte=arguments[23:16];
 3:inline_byte=arguments[31:24];4:inline_byte=arguments[39:32];5:inline_byte=arguments[47:40];
 default:inline_byte=0;
endcase
assign fragment_byte=fragment_address<8?header_byte:
 state!=SEND||fragment_address-8>=count?8'd0:
 has_bank?read_byte:inline_byte;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;owner<=0;command<=0;length<=0;index<=0;base<=0;count<=0;error<=0;
  bank<=0;has_bank<=0;arguments<=0;external_cancel<=0;
 end else begin
  if(!cancel_valid)external_cancel<=0;
  case(state)
   IDLE:if(cancel_valid&&cancel_token!=0&&!(external_cancel&&cancel_token==owner))begin
    // Body capture releases the A bank, but B may still be validating/applying
    // or delivering a result. F1 must reach that owner even after SEND ended.
    owner<=cancel_token;state<=CANCEL;external_cancel<=1;
    end else if(request_valid&&request_length_allowed&&!(cancel_valid&&cancel_token==request_token))begin
    owner<=request_token;command<=request_command;length<=request_length[7:0];
    arguments<=request_arguments;bank<=request_bank;has_bank<=request_has_bank;
    index<=0;base<=0;count<=request_length>24?8'd24:request_length[7:0];error<=0;state<=SEND;
   end
   SEND:if(!fragment_locked&&ack_valid&&ack_token==owner&&ack_index==index)begin
    if(ack_error!=0||ack_captured!=(base+count==length))begin
     error<=ack_error!=0?ack_error:8'hd6;state<=CANCEL;external_cancel<=0;
    end else if(base+count==length)state<=CAPTURED;
    else begin
     base<=base+count;index<=index+1'b1;
     count<=length-base-count>24?8'd24:length-base-count;
    end
   end
   CANCEL:if(!fragment_locked&&drained)begin
    if(external_cancel||affected)begin state<=IDLE;external_cancel<=1;end
    else state<=CAPTURED;
   end
   CAPTURED:if(request_valid&&request_ready)state<=error==0?IDLE:FAIL;
   FAIL:if(failure_valid&&failure_ready)state<=IDLE;
  endcase
  // Even an inconsistent capture ACK requires B's real drain before a bank
  // can be reused. Timers and malformed ACKs never declare cancellation done.
  if(affected&&state!=CANCEL)begin state<=CANCEL;external_cancel<=1;end
  else if(affected&&state==CANCEL)external_cancel<=1;
 end
end
endmodule
