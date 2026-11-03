// One committed-bank lease for both legacy glyph IDs (CMD12) and exact UTF8
// bytes (CMD16). The bank remains immutable across the complete paged query.
module b_text_readback(input clk,rst_n,input request_valid,output request_ready,
 input [31:0] request_token,input [7:0] request_offset,input request_raw,
 output query_begin,input query_ready,output [31:0] query_token,
 input query_active,input committed_valid,input [6:0] committed_count,input [7:0] committed_length,
 output query_end,output [31:0] query_end_token,
 output [5:0] glyph_address,input [7:0] glyph_byte,output [7:0] raw_address,input [7:0] raw_byte,
 output reg response_valid,input response_ready,output reg [31:0] response_token,output reg [191:0] response_payload,
 input notice_valid,input [31:0] notice_token,input notice_session,
 output reg control_done,output reg [31:0] control_token);
localparam IDLE=0,LOCK=1,ADDR=2,WAIT_BYTE=3,COPY=4,RELEASE=5,RESTART=6,ABORT=7;
reg [2:0] state;reg [31:0] owner,lease_owner;reg [7:0] offset,total,address,expected_offset;
reg [4:0] count,index;reg custom,raw_mode,lease_held,lease_raw;
wire affected=notice_valid&&(notice_session||notice_token==owner||(lease_held&&notice_token==lease_owner));
assign request_ready=state==IDLE&&!response_valid&&!notice_valid;
assign query_begin=state==LOCK&&!notice_valid;assign query_token=owner;
assign query_end=state==RELEASE||state==RESTART||(state==ABORT&&lease_held);assign query_end_token=lease_owner;
assign glyph_address=address[5:0];assign raw_address=address;
wire [7:0] read_byte=raw_mode?raw_byte:glyph_byte;
wire [7:0] command=raw_mode?8'd16:8'd12;
wire [7:0] live_total=raw_mode?committed_length:{1'b0,committed_count};
task error_reply;input [7:0] code;
begin response_valid<=1;response_token<=request_token;response_payload<=0;
 response_payload[31:0]<={8'd0,code,8'd1,request_raw?8'd16:8'd12};end endtask
task reply;
begin response_payload[63:0]<={total,7'd0,custom,3'd0,count,offset,8'd0,8'd0,8'd0,command};
 response_token<=owner;response_valid<=1;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;owner<=0;lease_owner<=0;offset<=0;total<=0;address<=0;expected_offset<=0;
  count<=0;index<=0;custom<=0;raw_mode<=0;lease_held<=0;lease_raw<=0;response_valid<=0;response_token<=0;response_payload<=0;control_done<=0;control_token<=0;end
 else begin
  if(!notice_valid)control_done<=0;
  if(response_valid&&response_ready)response_valid<=0;
  if(notice_valid&&!control_done&&state!=ABORT)begin
   control_token<=notice_token;
   if(affected)begin response_valid<=0;state<=ABORT;end else control_done<=1;
  end else case(state)
   IDLE:if(request_valid&&request_ready)begin
    owner<=request_token;offset<=request_offset;raw_mode<=request_raw;response_payload<=0;
    if(request_token==0||request_offset>=(request_raw?192:64))error_reply(request_token==0?8'h41:8'h47);
    else if(lease_held&&request_offset!=0)begin
     if(request_offset!=expected_offset||request_raw!=lease_raw)error_reply(8'h46);
     else begin count<=request_offset>=total?0:total-request_offset>=16?16:total-request_offset;
      index<=0;address<=request_offset;state<=ADDR;end
    end else state<=lease_held?RESTART:LOCK;
   end
   LOCK:if(query_ready)begin total<=live_total;custom<=committed_valid;lease_held<=1;lease_raw<=raw_mode;lease_owner<=owner;
    count<=offset>=live_total?0:live_total-offset>=16?16:live_total-offset;index<=0;address<=offset;state<=ADDR;end
   ADDR:state<=WAIT_BYTE;
   WAIT_BYTE:state<=COPY;
   COPY:begin response_payload[191:64]<={index<count?read_byte:8'd0,response_payload[191:72]};
    if(index==15)begin
     if(offset+count>=total)state<=RELEASE;
     else begin reply();expected_offset<=offset+count;state<=IDLE;end
    end else begin index<=index+1'b1;address<=address+1'b1;state<=ADDR;end
   end
   RELEASE:begin reply();lease_held<=0;state<=IDLE;end
   RESTART:begin lease_held<=0;state<=LOCK;end
   ABORT:if(!query_active)begin lease_held<=0;expected_offset<=0;response_valid<=0;control_done<=1;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
end
endmodule
