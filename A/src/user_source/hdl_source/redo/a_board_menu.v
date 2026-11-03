// Thin board UI. Every read/set/save uses the single portal's real B service,
// UID allocator and cancellation. No configuration replica or Flash driver.
// descriptor: visible/item/status/known/error/five decimal digits = 35 bits.
module a_board_menu #(parameter TIMEOUT_MS=20000)(input clk,rst_n,tick_ms,
 input emergency,peer_ready,toggle,next_item,plus,minus,
 output reg visible,output reg [2:0] item,output [34:0] descriptor,
 output request_valid,input request_ready,output reg [7:0] request_command,
 output reg [47:0] request_arguments,
 input result_valid,output result_ready,output reg [4:0] result_address,input [7:0] result_byte,input result_synthetic);
localparam TW=$clog2(TIMEOUT_MS+1);
reg [TW-1:0] age;reg queued,waiting,defaults_running;reg [2:0] defaults_index;
reg [1:0] status;reg known;reg [7:0] error,reply_command,reply_status,reply_error;
reg [15:0] value,reply_value,reply_parameter;reg bad_high;
reg [1:0] read_wait;reg [19:0] digits,bcd_work,bcd_adjust;
reg reading,reading_synthetic;
reg [15:0] digit_binary;reg [4:0] digit_count;integer k;
assign descriptor={visible,item,status,known,error,digits};
assign request_valid=queued&&visible&&!emergency&&peer_ready;
assign result_ready=waiting&&reading&&reading_synthetic==result_synthetic&&result_valid&&result_address==11&&read_wait==2;
wire busy=queued||waiting||digit_count!=0;
function [15:0] parameter_id;input [2:0] index;begin case(index)
 0:parameter_id=16'h0101;1:parameter_id=16'h0201;2:parameter_id=16'h0202;
 3:parameter_id=16'h0203;default:parameter_id=16'h0301;
endcase end endfunction
function [15:0] default_value;input [2:0] index;begin case(index)
 0:default_value=50;1,2:default_value=100;3:default_value=2;default:default_value=3000;
endcase end endfunction
reg [15:0] step,minimum,maximum,changed;
always @(*)begin
 minimum=0;maximum=item==0?100:item==3?7:item==4?60000:200;
 step=item==3?1:item==4?1000:5;if(item==4)minimum=1000;
 if(plus)changed=value>=maximum-step?maximum:value+step;
 else changed=value<=minimum+step?minimum:value-step;
 bcd_adjust=bcd_work;
 for(k=0;k<5;k=k+1)if(bcd_work[k*4+:4]>=5)bcd_adjust[k*4+:4]=bcd_work[k*4+:4]+4'd3;
end
task enqueue;input [7:0] command;input [15:0] id,v;begin
 request_command<=command;request_arguments<={16'd0,v,id};queued<=1;status<=1;error<=0;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  visible<=0;item<=0;age<=0;queued<=0;waiting<=0;defaults_running<=0;defaults_index<=0;
  status<=0;known<=0;error<=0;value<=0;digits<=0;bcd_work<=0;digit_binary<=0;digit_count<=0;
  request_command<=0;request_arguments<=0;result_address<=0;read_wait<=0;
  reading<=0;reading_synthetic<=0;
  reply_command<=0;reply_status<=0;reply_error<=0;reply_value<=0;reply_parameter<=0;bad_high<=0;
 end else begin
  if(digit_count!=0)begin
   bcd_work<={bcd_adjust[18:0],digit_binary[15]};digit_binary<=digit_binary<<1;digit_count<=digit_count-1'b1;
   if(digit_count==1)begin digits<={bcd_adjust[18:0],digit_binary[15]};known<=1;end
  end
  if(visible&&tick_ms&&age<TIMEOUT_MS)age<=age+1'b1;
  if(toggle||next_item||plus||minus)age<=0;
  // Closing the UI cannot abandon a leased response. waiting drains below.
  if(emergency||visible&&age>=TIMEOUT_MS-1)begin visible<=0;queued<=0;defaults_running<=0;end
  else if(toggle)begin
   if(visible)begin visible<=0;queued<=0;defaults_running<=0;end
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
     if(known)enqueue(5,parameter_id(item),changed);
     else enqueue(4,parameter_id(item),0);
    end else if(plus&&item==5)enqueue(6,0,0);
    else if(plus&&item==6)begin defaults_running<=1;defaults_index<=0;enqueue(5,parameter_id(0),default_value(0));end
   end
  end
  if(queued&&!peer_ready)begin queued<=0;defaults_running<=0;status<=3;error<=8'hc0;end
  if(request_valid&&request_ready)begin
   queued<=0;waiting<=1;result_address<=0;read_wait<=0;reading<=0;
   reply_command<=0;reply_status<=0;reply_error<=0;reply_value<=0;reply_parameter<=0;bad_high<=0;
  end
  // The SPI mailbox is a synchronous RAM. Hold each byte address for three
  // control clocks before capture; do not sample a previous address's word.
  if(waiting&&!result_valid)begin reading<=0;result_address<=0;read_wait<=0;end
  if(waiting&&result_valid)begin
   if(!reading||reading_synthetic!=result_synthetic)begin
    reading<=1;reading_synthetic<=result_synthetic;result_address<=0;read_wait<=0;
    reply_command<=0;reply_status<=0;reply_error<=0;reply_value<=0;reply_parameter<=0;bad_high<=0;
   end else if(read_wait!=2)read_wait<=read_wait+1'b1;
   else begin
    read_wait<=0;
    case(result_address)
     0:reply_command<=result_byte;1:reply_status<=result_byte;2:reply_error<=result_byte;
     4:reply_parameter[7:0]<=result_byte;5:reply_parameter[15:8]<=result_byte;
     8:reply_value[7:0]<=result_byte;9:reply_value[15:8]<=result_byte;
     10:bad_high<=result_byte!=0;
    endcase
    if(result_address==11)begin
     waiting<=0;result_address<=0;reading<=0;
     if(reply_status!=0||reply_error!=0||reply_command!=request_command||
       request_command!=6&&(reply_parameter!=request_arguments[15:0]||bad_high||result_byte!=0))begin
      status<=3;error<=reply_error!=0?reply_error:8'h42;defaults_running<=0;
     end else if(defaults_running&&visible&&!emergency&&!toggle&&age<TIMEOUT_MS-1)begin
      if(defaults_index==4)begin defaults_running<=0;status<=2;end
      else begin defaults_index<=defaults_index+1'b1;enqueue(5,parameter_id(defaults_index+1'b1),default_value(defaults_index+1'b1));end
     end else begin
      status<=request_command==4?0:2;error<=0;
      if(item<5&&request_command!=6&&visible)begin
       value<=reply_value;known<=0;digit_binary<=reply_value;digit_count<=16;bcd_work<=0;
      end
     end
    end else result_address<=result_address+1'b1;
   end
  end
 end
end
endmodule
