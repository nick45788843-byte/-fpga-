// Full PC/key operation UID. Real B action completion and latest A gallery
// retirement, writer idle and cancellation drainage determine the result.
module a_image_action32 #(parameter ACTUAL_MODE_ACK=0)(input clk,rst_n,
 input request_valid,output request_ready,input [31:0] request_uid,input [7:0] request_code,
 input key_valid,input [7:0] key_code,input peer_ready,
 output key_borrow_valid,input key_borrow_ready,input [31:0] key_uid,
 input b_done,input [31:0] b_uid,input [7:0] b_error,
 input [31:0] media_generation,input writer_busy,retirement_pending,
 input frame_retired,input [31:0] frame_generation,
 input cancel_valid,input [31:0] cancel_uid,input global_cancel,global_drained,
 output command_valid,output [63:0] command_header,output reg automatic_mode,
 output reg applied_valid,output reg [31:0] applied_uid,output reg [7:0] applied_error,
 output reg cancel_done,output reg [31:0] cancel_done_uid,output idle,input [3:0] b_image,input [4:0] actual_image,input b_automatic);
reg [3:0] expected_image;reg expected_automatic;
reg owned,cancelled,finished,key_pending;reg [31:0] uid;reg [7:0] code,error,pending_key_code;
assign request_ready=!owned&&!key_pending&&peer_ready&&request_uid!=0;
assign key_borrow_valid=key_pending&&!owned&&peer_ready;
assign command_valid=owned&&!finished;
assign command_header={8'hf8,code,8'd0,7'd0,cancelled,uid[7:0],uid[15:8],uid[23:16],uid[31:24]};
assign idle=!owned&&!key_pending;
wire selected_frame_complete=ACTUAL_MODE_ACK&&!cancelled&&(code==8'h10||code==8'h11)&&actual_image[4]&&actual_image[3:0]==expected_image;
wire completion_writer_ready=!writer_busy||selected_frame_complete;
wire accepted=request_valid&&request_ready;
wire accept_key=key_borrow_valid&&key_borrow_ready;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin expected_image<=0;expected_automatic<=0;owned<=0;cancelled<=0;finished<=0;key_pending<=0;uid<=0;code<=0;error<=0;pending_key_code<=0;automatic_mode<=0;applied_valid<=0;applied_uid<=0;applied_error<=0;cancel_done<=0;cancel_done_uid<=0;end
 else begin
  applied_valid<=0;cancel_done<=0;
  if(!peer_ready)key_pending<=0;
  if(key_valid&&peer_ready&&!key_pending&&!request_valid)begin key_pending<=1;pending_key_code<=key_code;end
  if(accepted||accept_key)begin
   owned<=1;cancelled<=0;finished<=0;uid<=accepted?request_uid:key_uid;code<=accepted?request_code:pending_key_code;
   if(accept_key)key_pending<=0;
   if(ACTUAL_MODE_ACK&&(accepted?request_code:pending_key_code)>=8'h10&&(accepted?request_code:pending_key_code)<=8'h18)automatic_mode<=0;
  end
  if(owned&&cancel_valid&&cancel_uid==uid&&!cancelled)begin cancelled<=1;finished<=0;end
  if(owned&&global_cancel&&!cancelled)begin cancelled<=1;finished<=0;end
  if(owned&&b_done&&b_uid==uid)begin finished<=1;error<=b_error;expected_image<=b_image;expected_automatic<=b_automatic;end
  if(owned&&global_cancel&&global_drained)begin finished<=1;error<=8'h43;end
  // Reload acknowledges actual TF initialization/scan start. Its new images
  // retire independently; cached-image switching still waits for frame credit.
  if(owned&&finished&&((!cancelled&&error!=0)||
     ((code==8'h20||code>=8'h30&&code<=8'h33||code>=8'h12&&code<=8'h18&&
       (!(ACTUAL_MODE_ACK&&code>=8'h16)||(actual_image[4]&&actual_image[3:0]==expected_image)))&&!cancelled&&error==0)||
     completion_writer_ready&&!retirement_pending&&(error!=0||(frame_retired&&frame_generation==media_generation&&((code!=8'h10&&code!=8'h11&&!(ACTUAL_MODE_ACK&&code>=8'h16&&code<=8'h18))||(actual_image[4]&&actual_image[3:0]==expected_image))))))begin
   owned<=0;
   if(ACTUAL_MODE_ACK&&!cancelled&&code>=8'h10&&code<=8'h20)automatic_mode<=expected_automatic;
   else if(!cancelled&&error==0)case(code)8'h12,8'h16,8'h17,8'h18:automatic_mode<=1;8'h13:automatic_mode<=0;8'h15:automatic_mode<=!automatic_mode;endcase
   if(cancelled)begin cancel_done<=1;cancel_done_uid<=uid;end
   else begin applied_valid<=1;applied_uid<=uid;applied_error<=error;end
  end
  // Keep the existing completion/data cone. Same-edge cancellation wins at
  // the visible control boundary, without putting its 32-bit UID comparator
  // into the enable cone of every applied UID/error data register.
  if(owned&&!cancelled&&(global_cancel||(cancel_valid&&cancel_uid==uid)))begin
   owned<=1;applied_valid<=0;automatic_mode<=automatic_mode;
  end
 end
end
endmodule
