// BMP bottom-up rows stay bottom-up. One immutable source row is reused for
// zoom; the existing FIFO reserves an entire unbackpressured TF sector.
module b_image_scale #(parameter WIDTH=640,HEIGHT=480)(input clk,rst_n,
 input start_valid,output start_ready,input [31:0] start_token,input [2:0] selector,
 input [23:0] border,input cancel,input [31:0] cancel_token,
 input input_valid,input [31:0] input_word,output input_ready,sector_room,
 output output_valid,input output_ready,output [31:0] output_word,output output_last,
 output reg done,error,output reg [7:0] error_code,output drained,
 output [31:0] operation_token);
localparam WORDS=WIDTH*HEIGHT,XB=$clog2(WIDTH+1),YB=$clog2(HEIGHT+1),NB=$clog2(WORDS+1);
reg active,output_finished,row_valid;reg [31:0] owner;reg [2:0] mode;
reg [23:0] background;reg [XB-1:0] input_x,output_x;reg [YB-1:0] input_y,output_y,row_y;
reg [NB-1:0] input_count,output_count;
reg [1:0] read_state;reg [31:0] held_word;reg held_valid;
wire affected=cancel&&cancel_token==owner&&active;
wire fifo_ready,fifo_valid;wire [9:0] fifo_space;wire [31:0] fifo_word;
wire fifo_pop=active&&!affected&&!row_valid&&input_count<WORDS;
assign input_ready=active&&!affected&&input_count<WORDS&&fifo_ready;
assign sector_room=fifo_space>=256&&(!active||input_count<WORDS)&&!affected;
media_block_fifo queue(clk,rst_n&&active&&!affected,input_valid&&input_ready,input_word,
 fifo_ready,fifo_space,fifo_pop,fifo_valid,fifo_word);
(* force_ram=1,ram_style="bram" *) reg [23:0] source_row[0:WIDTH-1];
reg [23:0] sampled;
wire fit=mode==1||mode==2;
wire zoom=mode==3||mode==4;
wire [1:0] shift=(mode==2||mode==4)?2:1;
wire [XB-1:0] extent_x=fit?(WIDTH>>shift):WIDTH;
wire [YB-1:0] extent_y=fit?(HEIGHT>>shift):HEIGHT;
wire [XB-1:0] margin_x=fit?(WIDTH-extent_x)>>1:0;
wire [YB-1:0] margin_y=fit?(HEIGHT-extent_y)>>1:0;
wire blank=fit&&(output_x<margin_x||output_x>=margin_x+extent_x||
 output_y<margin_y||output_y>=margin_y+extent_y);
wire [XB-1:0] sample_x=fit?(output_x-margin_x)<<shift:
 zoom?((WIDTH-(WIDTH>>shift))>>1)+(output_x>>shift):output_x;
wire [YB-1:0] sample_y=fit?(output_y-margin_y)<<shift:
 zoom?((HEIGHT-(HEIGHT>>shift))>>1)+(output_y>>shift):output_y;
wire pop=held_valid&&output_ready&&!affected;
assign output_valid=held_valid&&active&&!affected;
assign output_word=held_word;
assign output_last=output_count==WORDS-1;
assign start_ready=!active;
assign drained=!active;
assign operation_token=owner;
always @(posedge clk)begin
 if(fifo_pop&&fifo_valid)source_row[input_x]<=fifo_word[31:8];
 if(read_state==1)sampled<=source_row[sample_x];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  active<=0;output_finished<=0;row_valid<=0;owner<=0;mode<=0;background<=0;
  input_x<=0;input_y<=0;output_x<=0;output_y<=0;row_y<=0;input_count<=0;output_count<=0;
  read_state<=0;held_word<=0;held_valid<=0;done<=0;error<=0;error_code<=0;
 end else begin
  done<=0;error<=0;
  if(start_valid&&start_ready)begin
   error_code<=0;
   if(start_token==0||selector>4)begin error<=1;error_code<=8'h47;end
   else begin
    active<=1;output_finished<=0;row_valid<=0;owner<=start_token;mode<=selector;background<=border;
    input_x<=0;input_y<=0;output_x<=0;output_y<=0;row_y<=0;input_count<=0;output_count<=0;
    read_state<=0;held_valid<=0;
   end
  end
  if(active)begin
   if(fifo_pop&&fifo_valid)begin
    input_count<=input_count+1'b1;
    if(input_x==WIDTH-1)begin input_x<=0;row_y<=input_y;input_y<=input_y+1'b1;row_valid<=1;end
    else input_x<=input_x+1'b1;
   end
   if(row_valid&&(output_finished||!blank&&row_y<sample_y))row_valid<=0;
   if(!held_valid&&!output_finished)case(read_state)
    0:if(blank)begin held_word<={background,8'd0};held_valid<=1;end
      else if(row_valid&&row_y==sample_y)read_state<=1;
    1:read_state<=2;
    2:begin held_word<={sampled,8'd0};held_valid<=1;read_state<=0;end
    default:read_state<=0;
   endcase
   if(pop)begin
    held_valid<=0;output_count<=output_count+1'b1;
    if(output_count==WORDS-1)output_finished<=1;
    else if(output_x==WIDTH-1)begin output_x<=0;output_y<=output_y+1'b1;end
    else output_x<=output_x+1'b1;
   end
   if(output_finished&&input_count==WORDS&&!fifo_valid&&!held_valid)begin active<=0;done<=1;row_valid<=0;end
   if(affected)begin active<=0;row_valid<=0;held_valid<=0;read_state<=0;output_finished<=0;error<=1;error_code<=8'h43;end
  end
 end
end
endmodule
