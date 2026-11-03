// Owns the complete decoded glyph frame through transport retries/application ACK.
module b_glyph_snapshot(input clk,rst_n,input request_valid,output request_ready,
 input [31:0] request_token,input [6:0] request_count,
 output reg [5:0] glyph_address,input [7:0] glyph_byte,
 output reg frame_valid,input frame_release,output reg [31:0] frame_token,output reg [6:0] frame_count,
 input [5:0] read_address,output reg [31:0] read_word);
 localparam IDLE=0,ADDR=1,WAIT_BYTE=2,COPY=3;
 reg [1:0] state;reg [5:0] cursor;reg [31:0] words[0:15];
 assign request_ready=state==IDLE&&!frame_valid&&request_count<=64;
 always @(posedge clk)read_word<=read_address<16?words[read_address[3:0]]:32'd0;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;cursor<=0;glyph_address<=0;frame_valid<=0;frame_token<=0;frame_count<=0;end
  else begin
   if(frame_valid&&frame_release)frame_valid<=0;
   case(state)
    IDLE:if(request_valid&&request_ready)begin frame_token<=request_token;frame_count<=request_count;cursor<=0;
     if(request_count==0)frame_valid<=1;else state<=ADDR;
    end
    ADDR:begin glyph_address<=cursor;state<=WAIT_BYTE;end
    WAIT_BYTE:state<=COPY;
    COPY:begin
     if(cursor[1:0]==0)words[cursor[5:2]]<={24'd0,glyph_byte};
     else words[cursor[5:2]][cursor[1:0]*8+:8]<=glyph_byte;
     if({1'b0,cursor}+1==frame_count)begin frame_valid<=1;state<=IDLE;end
     else begin cursor<=cursor+1'b1;state<=ADDR;end
    end
   endcase
  end
 end
endmodule
