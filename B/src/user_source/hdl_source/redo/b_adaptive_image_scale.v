// Power-of-two fit uses one source row and existing whole-sector FIFO credit.
module b_adaptive_image_scale #(parameter WIDTH=640,HEIGHT=480,RUNTIME_GEOMETRY=0)(input clk,rst_n,
 input image_request,input [31:0] image_uid,input [15:0] source_width,source_height,
 input [31:0] source_pixels,input transport_ack,output image_ack,
 input source_valid,input [31:0] source_word,input cancel,input transport_ready,
 output transport_valid,output [31:0] transport_word,output sector_room,drained,output reg overflow,input [2:0] selector);
localparam XB=$clog2(WIDTH+1),YB=$clog2(HEIGHT+1),NB=$clog2(WIDTH*HEIGHT+1);
reg acknowledged,active,row_valid,output_finished;
reg [31:0] owner;reg [NB-1:0] total_input,input_count,output_count;
reg [XB-1:0] input_width,input_x,output_x,extent_x,margin_x;
reg [YB-1:0] input_y,row_y,output_y,extent_y,margin_y;
reg [2:0] geometry;
reg [1:0] shift,read_state;reg held_valid;reg [31:0] held_word;
wire start=image_request&&transport_ack&&!acknowledged&&!active&&!cancel;
wire [1:0] requested_shift=source_width==WIDTH/4&&source_height<=HEIGHT/4?2:
 source_width==WIDTH/2&&source_height<=HEIGHT/2?1:0;
wire [XB-1:0] requested_extent_x=source_width<<requested_shift;
wire [YB-1:0] requested_extent_y=source_height<<requested_shift;
wire fifo_ready,fifo_valid;wire [9:0] fifo_space;wire [31:0] fifo_word;
wire input_ready=active&&input_count<total_input&&!cancel&&fifo_ready;
wire fifo_pop=active&&!row_valid&&input_count<total_input&&!cancel;
media_block_fifo queue(clk,rst_n&&active&&!cancel,source_valid&&input_ready,source_word,
 fifo_ready,fifo_space,fifo_pop,fifo_valid,fifo_word);
(* force_ram=1,ram_style="bram" *) reg [23:0] source_row[0:WIDTH-1];
reg [23:0] sampled;

wire fit=RUNTIME_GEOMETRY&&(geometry==1||geometry==2);
wire zoom=RUNTIME_GEOMETRY&&(geometry==3||geometry==4);
wire [1:0] geometry_shift=(geometry==2||geometry==4)?2:1;
wire [XB-1:0] geometry_extent_x=WIDTH>>geometry_shift;
wire [YB-1:0] geometry_extent_y=HEIGHT>>geometry_shift;
wire [XB-1:0] geometry_margin_x=(WIDTH-geometry_extent_x)>>1;
wire [YB-1:0] geometry_margin_y=(HEIGHT-geometry_extent_y)>>1;
wire outer_blank=fit&&(output_x<geometry_margin_x||output_x>=geometry_margin_x+geometry_extent_x||
 output_y<geometry_margin_y||output_y>=geometry_margin_y+geometry_extent_y);
wire [XB-1:0] canonical_x=fit?(output_x-geometry_margin_x)<<geometry_shift:
 zoom?geometry_margin_x+(output_x>>geometry_shift):output_x;
wire [YB-1:0] canonical_y=fit?(output_y-geometry_margin_y)<<geometry_shift:
 zoom?geometry_margin_y+(output_y>>geometry_shift):output_y;
wire blank=outer_blank||canonical_x<margin_x||canonical_x>=margin_x+extent_x||canonical_y<margin_y||canonical_y>=margin_y+extent_y;
wire [XB-1:0] sample_x=(canonical_x-margin_x)>>shift;
wire [YB-1:0] sample_y=(canonical_y-margin_y)>>shift;
assign image_ack=acknowledged&&transport_ack&&!cancel;
assign transport_valid=held_valid&&active&&transport_ready&&!cancel;
assign transport_word=held_word;
assign sector_room=fifo_space>=256&&!cancel;
assign drained=!active;
always @(posedge clk)begin
 if(fifo_pop&&fifo_valid)source_row[input_x]<=fifo_word[31:8];
 if(read_state==1)sampled<=source_row[sample_x];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  acknowledged<=0;active<=0;row_valid<=0;output_finished<=0;owner<=0;total_input<=0;input_count<=0;output_count<=0;
  input_width<=0;input_x<=0;input_y<=0;output_x<=0;output_y<=0;row_y<=0;
  extent_x<=0;extent_y<=0;margin_x<=0;margin_y<=0;shift<=0;read_state<=0;held_valid<=0;held_word<=0;overflow<=0;geometry<=0;
 end else begin
  overflow<=source_valid&&!input_ready&&!cancel;
  if(!image_request)acknowledged<=0;
  if(start)begin
   geometry<=RUNTIME_GEOMETRY?selector:3'd0;
   acknowledged<=1;active<=1;owner<=image_uid;total_input<=source_pixels;input_width<=source_width;
   extent_x<=requested_extent_x;extent_y<=requested_extent_y;shift<=requested_shift;
   margin_x<=(WIDTH-requested_extent_x)>>1;margin_y<=(HEIGHT-requested_extent_y)>>1;
   input_x<=0;input_y<=0;output_x<=0;output_y<=0;row_y<=0;input_count<=0;output_count<=0;
   row_valid<=0;output_finished<=0;read_state<=0;held_valid<=0;
  end
  if(active)begin
   if(fifo_pop&&fifo_valid)begin
    input_count<=input_count+1'b1;
    if(input_x==input_width-1)begin input_x<=0;row_y<=input_y;input_y<=input_y+1'b1;row_valid<=1;end
    else input_x<=input_x+1'b1;
   end
   if(row_valid&&(output_finished||!blank&&row_y<sample_y))row_valid<=0;
   if(!held_valid&&!output_finished)case(read_state)
    0:if(blank)begin held_word<=0;held_valid<=1;end
      else if(row_valid&&row_y==sample_y)read_state<=1;
    1:read_state<=2;
    2:begin held_word<={sampled,8'd0};held_valid<=1;read_state<=0;end
    default:read_state<=0;
   endcase
   if(transport_valid)begin
    held_valid<=0;output_count<=output_count+1'b1;
    if(output_count==WIDTH*HEIGHT-1)output_finished<=1;
    else if(output_x==WIDTH-1)begin output_x<=0;output_y<=output_y+1'b1;end
    else output_x<=output_x+1'b1;
   end
   if(output_finished&&input_count==total_input&&!fifo_valid&&!held_valid)begin active<=0;row_valid<=0;end
  end
  if(cancel||overflow)begin active<=0;acknowledged<=0;row_valid<=0;held_valid<=0;read_state<=0;end
 end
end
endmodule
