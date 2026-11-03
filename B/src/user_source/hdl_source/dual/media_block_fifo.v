// B板专用同钟媒体队列：32位存入块RAM，结束位置由音频总长度判断。
// 已预读的队头也计入占用，只有消费者确认后才能释放，禁止覆盖未发送数据。
module media_block_fifo(input clk,rst_n,input write_valid,input [31:0] write_data,
 output write_ready,output [9:0] write_space,input read_ready,output reg read_valid,output reg [31:0] read_data);
(* force_ram=1,ram_style="bram" *) reg [31:0] words[0:511];
reg [8:0] wp,rp;reg [9:0] used;reg pending;reg [31:0] ram_word;
wire push=write_valid&&write_ready,pop=read_valid&&read_ready;
wire fetch=!pending&&(!read_valid||pop)&&(used>(pop?10'd1:10'd0));
wire [8:0] fetch_address=rp+pop;
assign write_ready=used<511;assign write_space=10'd511-used;
always @(posedge clk)begin
 if(push)words[wp]<=write_data;
 if(fetch)ram_word<=words[fetch_address];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin wp<=0;rp<=0;used<=0;pending<=0;read_valid<=0;read_data<=0;end
 else begin
  if(push)wp<=wp+1'b1;
  if(pop)begin rp<=rp+1'b1;read_valid<=0;end
  case({push,pop})2'b10:used<=used+1'b1;2'b01:used<=used-1'b1;default:used<=used;endcase
  pending<=fetch;
  if(pending)begin read_data<=ram_word;read_valid<=1;end
 end
end
endmodule
