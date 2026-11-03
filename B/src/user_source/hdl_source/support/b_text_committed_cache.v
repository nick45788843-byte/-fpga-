// Only feed commit_valid after the real display result succeeded. RAM is not Flash.
// Query leases block a subsequent bank reuse until their matching end token.
module b_text_committed_cache #(parameter GLYPH_ENABLED=0)(input clk,rst_n,
 input commit_valid,output commit_ready,input [31:0] commit_token,input [7:0] commit_length,
 output reg [7:0] source_address,input [7:0] source_byte,
 output reg done_valid,input done_ready,output reg [31:0] done_token,
 input query_begin,output query_ready,input [31:0] query_token,input query_end,input [31:0] query_end_token,
 output reg query_active,output reg [31:0] query_owner,output reg [7:0] query_length,
 output reg [31:0] query_generation,input [7:0] query_address,output [7:0] query_byte,
 output reg committed_valid,output reg [7:0] committed_length,output reg [31:0] committed_generation,
 input [6:0] commit_glyph_count,output reg [5:0] source_glyph_address,input [7:0] source_glyph_byte,
 input [5:0] query_glyph_address,output [7:0] query_glyph_byte,output reg [6:0] committed_glyph_count);
 localparam IDLE=0,ADDR=1,WAIT_BYTE=2,COPY=3,G_ADDR=4,G_WAIT=5,G_COPY=6;
 reg [2:0] state;reg bank;reg [7:0] cursor,length;reg [6:0] glyph_count;reg [31:0] owner;
 (* force_ram=1,ram_style="bram" *) reg [7:0] raw[0:511];
 (* force_ram=1,ram_style="bram" *) reg [7:0] glyph[0:127];
 reg [7:0] raw_read,glyph_read;reg raw_read_valid,glyph_read_valid;
 assign query_byte=raw_read_valid?raw_read:8'd0;
 assign query_glyph_byte=glyph_read_valid?glyph_read:8'd0;
 assign commit_ready=state==IDLE&&!done_valid&&!query_active&&!query_begin&&commit_length<=192&&
  (!GLYPH_ENABLED||(commit_glyph_count<=64&&commit_glyph_count<=commit_length))&&committed_generation!=32'hffffffff;
 assign query_ready=state==IDLE&&!done_valid&&!query_active&&query_token!=0;
 // 存储端口独立于异步复位控制，保留原同步读延迟和银行租约。
 always @(posedge clk)begin
  raw_read<=raw[{bank,query_address}];glyph_read<=glyph[{bank,query_glyph_address}];
  raw_read_valid<=query_active&&query_address<query_length;
  glyph_read_valid<=query_active&&query_glyph_address<committed_glyph_count;
  if(rst_n&&state==COPY)raw[{!bank,cursor}]<=source_byte;
  if(rst_n&&state==G_COPY)glyph[{!bank,cursor[5:0]}]<=source_glyph_byte;
 end
 task finish;begin
  bank<=!bank;committed_valid<=1;committed_length<=length;committed_generation<=committed_generation+1'b1;
  committed_glyph_count<=glyph_count;done_valid<=1;done_token<=owner;state<=IDLE;
 end endtask
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;bank<=0;cursor<=0;length<=0;owner<=0;source_address<=0;glyph_count<=0;source_glyph_address<=0;committed_glyph_count<=0;
   done_valid<=0;done_token<=0;query_active<=0;query_owner<=0;query_length<=0;query_generation<=0;
   committed_valid<=0;committed_length<=0;committed_generation<=0;end
  else begin
   if(done_valid&&done_ready)done_valid<=0;
   if(query_begin&&query_ready)begin query_active<=1;query_owner<=query_token;
    query_length<=committed_length;query_generation<=committed_generation;end
   if(query_active&&query_end&&query_end_token==query_owner)query_active<=0;
   case(state)
    IDLE:if(commit_valid&&commit_ready)begin
     owner<=commit_token;length<=commit_length;cursor<=0;glyph_count<=GLYPH_ENABLED?commit_glyph_count:7'd0;
     if(commit_length==0)begin bank<=!bank;committed_valid<=1;committed_length<=0;
      committed_generation<=committed_generation+1'b1;committed_glyph_count<=0;done_valid<=1;done_token<=commit_token;end
     else state<=ADDR;
    end
    ADDR:begin source_address<=cursor;state<=WAIT_BYTE;end
    WAIT_BYTE:state<=COPY;
    COPY:begin
     if(cursor+1==length)begin
      if(GLYPH_ENABLED&&glyph_count!=0)begin cursor<=0;state<=G_ADDR;end else finish();
     end else begin cursor<=cursor+1'b1;state<=ADDR;end
    end
    G_ADDR:begin source_glyph_address<=cursor[5:0];state<=G_WAIT;end
    G_WAIT:state<=G_COPY;
    G_COPY:begin
     if(cursor+1==glyph_count)finish();else begin cursor<=cursor+1'b1;state<=G_ADDR;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
