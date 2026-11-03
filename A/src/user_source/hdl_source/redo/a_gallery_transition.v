module a_gallery_transition #(parameter LOCAL_CLOCKS=0)(input ctrl_clk,mem_clk,video_clk,rst_n,video_rst_n,
 input [31:0] map_generation,input [90:0] desired_word,input frame_boundary,emergency,
 input reader_retirement_valid,input [31:0] reader_retired_generation,
 input reader_quiescent,input [31:0] reader_quiescent_generation,
 output [90:0] video_word,output [31:0] video_generation,output video_valid,
 output frame_applied_valid,output [31:0] frame_applied_generation,
 output retire_valid,output [31:0] retired_generation,output publish_busy,
 output [2:0] fade_shift,output picture_commit,output [1:0] picture_id);
generate if(LOCAL_CLOCKS)begin:local_pipeline
a_gallery_same_clock implementation(.ctrl_clk(ctrl_clk),.mem_clk(mem_clk),.video_clk(video_clk),.rst_n(rst_n),.video_rst_n(video_rst_n),.map_generation(map_generation),.desired_word(desired_word),.frame_boundary(frame_boundary),.emergency(emergency),.reader_retirement_valid(reader_retirement_valid),.reader_retired_generation(reader_retired_generation),.reader_quiescent(reader_quiescent),.reader_quiescent_generation(reader_quiescent_generation),.video_word(video_word),.video_generation(video_generation),.video_valid(video_valid),.frame_applied_valid(frame_applied_valid),.frame_applied_generation(frame_applied_generation),.retire_valid(retire_valid),.retired_generation(retired_generation),.publish_busy(publish_busy),.fade_shift(fade_shift),.picture_commit(picture_commit),.picture_id(picture_id));
end else begin:legacy_pipeline
a_gallery_legacy implementation(.ctrl_clk(ctrl_clk),.mem_clk(mem_clk),.video_clk(video_clk),.rst_n(rst_n),.video_rst_n(video_rst_n),.map_generation(map_generation),.desired_word(desired_word),.frame_boundary(frame_boundary),.emergency(emergency),.reader_retirement_valid(reader_retirement_valid),.reader_retired_generation(reader_retired_generation),.reader_quiescent(reader_quiescent),.reader_quiescent_generation(reader_quiescent_generation),.video_word(video_word),.video_generation(video_generation),.video_valid(video_valid),.frame_applied_valid(frame_applied_valid),.frame_applied_generation(frame_applied_generation),.retire_valid(retire_valid),.retired_generation(retired_generation),.publish_busy(publish_busy),.fade_shift(fade_shift),.picture_commit(picture_commit),.picture_id(picture_id));
end endgenerate
endmodule

// One held descriptor, one actual frame ACK; the old reader still retires itself.
module a_gallery_legacy(input ctrl_clk,mem_clk,video_clk,rst_n,video_rst_n,
 input [31:0] map_generation,input [90:0] desired_word,input frame_boundary,emergency,
 input reader_retirement_valid,input [31:0] reader_retired_generation,
 input reader_quiescent,input [31:0] reader_quiescent_generation,
 output [90:0] video_word,output [31:0] video_generation,output video_valid,
 output reg frame_applied_valid,output [31:0] frame_applied_generation,
 output retire_valid,output [31:0] retired_generation,output publish_busy,
 output reg [2:0] fade_shift,output picture_commit,output [1:0] picture_id);
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg [122:0] held_data,capture_word;
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg request_toggle,ack_toggle,in_flight,ever_sent,capture_valid;
(* async_reg=1,preserve=1 *) reg [2:0] request_sync;
(* async_reg=1,preserve=1 *) reg [1:0] sent_sync,ack_sync,valid_sync;
reg [31:0] applied_generation;
reg [1:0] phase;
wire local_video_rst_n=rst_n&&video_rst_n;
wire pending=request_sync[2]!=ack_toggle||(!capture_valid&&sent_sync[1]);
wire [20:0] old_base=video_word[6:5]==0?video_word[90:70]:
 video_word[6:5]==1?video_word[69:49]:video_word[6:5]==2?video_word[48:28]:video_word[27:7];
wire [20:0] new_base=held_data[6:5]==0?held_data[90:70]:
 held_data[6:5]==1?held_data[69:49]:held_data[6:5]==2?held_data[48:28]:held_data[27:7];
wire picture_change=capture_valid&&video_word[4]&&held_data[4]&&old_base!=new_base;
wire capture_now=frame_boundary&&sent_sync[1]&&pending&&
 (emergency||!picture_change||(phase==1&&fade_shift==4));
assign picture_commit=capture_now&&picture_change&&!emergency;
assign picture_id=held_data[6:5];
assign video_word=capture_word[90:0];assign video_generation=capture_word[122:91];
assign video_valid=capture_valid;assign frame_applied_generation=applied_generation;
assign publish_busy=in_flight;
always @(posedge ctrl_clk)begin
 if(rst_n&&!in_flight&&(!ever_sent||{map_generation,desired_word}!=held_data))
  held_data<={map_generation,desired_word};
end
always @(posedge ctrl_clk or negedge rst_n)begin
 if(!rst_n)begin request_toggle<=0;in_flight<=0;ever_sent<=0;ack_sync<=0;valid_sync<=0;frame_applied_valid<=0;applied_generation<=0;end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};valid_sync<={valid_sync[0],capture_valid};
  if(!valid_sync[1])frame_applied_valid<=0;
  if(in_flight&&ack_sync[1]==request_toggle&&valid_sync[1])begin
   applied_generation<=held_data[122:91];frame_applied_valid<=1;in_flight<=0;
  end else if(!in_flight&&(!ever_sent||{map_generation,desired_word}!=held_data))begin
   request_toggle<=!request_toggle;in_flight<=1;ever_sent<=1;
  end else if(!in_flight&&ever_sent&&valid_sync[1]&&ack_sync[1]==request_toggle)begin
   applied_generation<=held_data[122:91];frame_applied_valid<=1;
  end
 end
end
always @(posedge video_clk)if(local_video_rst_n&&capture_now)capture_word<=held_data;
always @(posedge video_clk or negedge local_video_rst_n)begin
 if(!local_video_rst_n)begin request_sync<=0;sent_sync<=0;ack_toggle<=0;capture_valid<=0;phase<=0;fade_shift<=0;end
 else begin
  request_sync<={request_sync[1:0],request_toggle};sent_sync<={sent_sync[0],ever_sent};
  if(emergency)begin phase<=0;fade_shift<=0;end
  if(capture_now)begin
   capture_valid<=1;ack_toggle<=request_sync[2];
   if(emergency||!capture_valid||!held_data[4])begin phase<=0;fade_shift<=0;end
   else if(picture_change)begin phase<=2;fade_shift<=4;end
  end else if(frame_boundary&&!emergency)begin
   if(sent_sync[1]&&pending&&picture_change)begin
    phase<=1;if(fade_shift<4)fade_shift<=fade_shift+1'b1;
   end else if(phase==2)begin
    if(fade_shift>0)fade_shift<=fade_shift-1'b1;
    if(fade_shift<=1)phase<=0;
   end
  end
 end
end
wire [65:0] reader_word;wire reader_valid;
config_bundle_cdc #(.WIDTH(66)) reader_return(
 .src_clk(mem_clk),.src_rst_n(rst_n),
 .src_data({reader_quiescent_generation,reader_retired_generation,reader_quiescent,reader_retirement_valid}),.src_valid(1'b1),
 .applied_data(),.applied_valid(),.dst_clk(ctrl_clk),.dst_rst_n(rst_n),.dst_capture(1'b0),.dst_data(reader_word),.dst_valid(reader_valid));
assign retired_generation=map_generation;
assign retire_valid=frame_applied_valid&&applied_generation==map_generation&&reader_valid&&
 ((reader_word[0]&&reader_word[33:2]==map_generation)||(reader_word[1]&&reader_word[65:34]==map_generation));
endmodule

module a_gallery_same_clock(input ctrl_clk,mem_clk,video_clk,rst_n,video_rst_n,
 input [31:0] map_generation,input [90:0] desired_word,input frame_boundary,emergency,
 input reader_retirement_valid,input [31:0] reader_retired_generation,
 input reader_quiescent,input [31:0] reader_quiescent_generation,
 output [90:0] video_word,output [31:0] video_generation,output video_valid,
 output frame_applied_valid,output [31:0] frame_applied_generation,
 output retire_valid,output [31:0] retired_generation,output publish_busy,
 output [2:0] fade_shift,output picture_commit,output [1:0] picture_id);
// Production ctrl_clk and video_clk are the identical 25 MHz net. The root
// already supplies a coherent registered {epoch, descriptor}; keep one actual
// front word, rather than another 123-bit same-clock request mailbox.
wire local_reset_n=rst_n&&video_rst_n;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [122:0] front;
reg front_valid,request_toggle;
(*async_reg=1,preserve=1*) reg [1:0] ack_sync;
(*async_reg=1,preserve=1*) reg [2:0] request_sync;
(*async_reg=1,preserve=1*) reg [1:0] memory_release;
reg ack_toggle;reg [1:0] phase;reg [2:0] fade;
// A95r02: one fade level every 8 frames (~0.53 s out, ~0.53 s in); table unchanged.
reg [2:0] pace;wire fade_step=frame_boundary&&pace==3'd7;
// A single outstanding request leases the full 32-bit generation through the
// real memory proof. The returning toggle acknowledges that immutable lease;
// it never stands in for a free-running or truncated generation counter.
// Async assertion reaches memory_release; its final registered stage alone
// releases the memory domain. Do not bypass it with raw session/reset logic.
wire memory_reset_n=memory_release[1];
(*async_reg=1,preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg request_half;
// Real 25MHz video and 50MHz memory clocks have coincident rising edges.
// Sample the immutable request on memory's opposite edge before its existing
// three-stage rising-edge synchronizer. Full generation ownership is unchanged.
always @(negedge mem_clk or negedge memory_reset_n)
 if(!memory_reset_n)request_half<=0;else request_half<=request_toggle;
always @(negedge mem_clk or negedge local_reset_n)
 if(!local_reset_n)memory_release<=0;else memory_release<={memory_release[0],1'b1};
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [31:0] memory_generation;
always @(negedge mem_clk or negedge memory_reset_n)
 if(!memory_reset_n)memory_generation<=0;else memory_generation<=front[122:91];
always @(posedge mem_clk or negedge memory_reset_n)begin
 if(!memory_reset_n)begin request_sync<=0;ack_toggle<=0;end
 else begin
  request_sync<={request_sync[1:0],request_half};
  if(request_sync[2]!=ack_toggle&&
    ((reader_retirement_valid&&reader_retired_generation==memory_generation)||
     (reader_quiescent&&reader_quiescent_generation==memory_generation)))ack_toggle<=request_sync[2];
 end
end
assign video_word=front[90:0];assign video_generation=front[122:91];assign video_valid=front_valid;
assign frame_applied_valid=front_valid;assign frame_applied_generation=front[122:91];
wire proven=front_valid&&ack_sync[1]==request_toggle;
wire pending=!front_valid||front!={map_generation,desired_word};
wire [20:0] old_base=front[6:5]==0?front[90:70]:front[6:5]==1?front[69:49]:front[6:5]==2?front[48:28]:front[27:7];
wire [20:0] new_base=desired_word[6:5]==0?desired_word[90:70]:desired_word[6:5]==1?desired_word[69:49]:desired_word[6:5]==2?desired_word[48:28]:desired_word[27:7];
wire picture_change=front_valid&&front[4]&&desired_word[4]&&old_base!=new_base;
wire capture_now=frame_boundary&&(!front_valid||proven)&&pending&&
 (emergency||!picture_change||(phase==1&&fade==4));
assign picture_commit=capture_now&&picture_change&&!emergency;assign picture_id=desired_word[6:5];
assign publish_busy=!front_valid||!proven||pending;assign fade_shift=fade;
assign retire_valid=proven&&front[122:91]==map_generation;assign retired_generation=front[122:91];
always @(posedge ctrl_clk)if(local_reset_n&&capture_now)front<={map_generation,desired_word};
always @(posedge ctrl_clk or negedge local_reset_n)begin
 if(!local_reset_n)begin front_valid<=0;request_toggle<=0;ack_sync<=0;phase<=0;fade<=0;pace<=0;end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};
  if(frame_boundary)pace<=pace+1'b1;
  if(emergency)begin phase<=0;fade<=0;end
  if(capture_now)begin
   front_valid<=1;request_toggle<=!request_toggle;
   if(!emergency&&picture_change)begin phase<=2;fade<=4;end
   else begin phase<=0;fade<=0;end
  end else if(fade_step&&!emergency)begin
   if((!front_valid||proven)&&pending&&picture_change)begin phase<=1;if(fade<4)fade<=fade+1'b1;end
   else if(phase==2)begin if(fade>0)fade<=fade-1'b1;if(fade<=1)phase<=0;end
  end
 end
end
endmodule
