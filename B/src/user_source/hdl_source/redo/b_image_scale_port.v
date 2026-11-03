// 原始 BMP 的启动确认必须等私有缩放所有者建立，输出只按发送 FIFO 信用推进。
module b_image_scale_port #(parameter WIDTH=640,HEIGHT=480)(input clk,rst_n,
 input image_request,input [31:0] image_uid,input [2:0] selector,
 input transport_ack,output image_ack,input source_valid,input [31:0] source_word,
 input cancel,input transport_ready,output transport_valid,output [31:0] transport_word,
 output sector_room,drained,output reg overflow);
reg acknowledged;
wire ready,input_ready,output_valid,last,done,error;
wire [7:0] error_code;wire [31:0] private_uid;
wire start=image_request&&transport_ack&&!acknowledged&&ready&&!cancel;
assign image_ack=acknowledged&&transport_ack&&!cancel;
assign transport_valid=output_valid&&transport_ready&&!cancel;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin acknowledged<=0;overflow<=0;end
 else begin
  overflow<=source_valid&&!input_ready&&!cancel;
  if(!image_request||cancel)acknowledged<=0;
  else if(start)acknowledged<=1;
 end
end
b_image_scale #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) scale(clk,rst_n,start,ready,image_uid,selector,
 24'd0,cancel||overflow,private_uid,source_valid,source_word,input_ready,sector_room,
 output_valid,transport_ready&&!cancel,transport_word,last,done,error,error_code,drained,private_uid);
endmodule
