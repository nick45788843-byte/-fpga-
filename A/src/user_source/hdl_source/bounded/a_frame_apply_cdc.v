// publish_word/token must remain stable until the matching applied_token returns.
// Global rst_n resets both halves; video_rst_n may independently reset the sink.
// Destination capture itself is at the frame boundary, so its ACK is not an
// earlier mailbox receipt followed by a later gallery_active register update.
module a_frame_apply_cdc #(parameter WIDTH=91)(input src_clk,video_clk,rst_n,video_rst_n,
 input publish_valid,input [31:0] publish_token,input [WIDTH-1:0] publish_word,
 input frame_boundary,output [WIDTH-1:0] video_word,output [31:0] video_token,
 output video_valid,output applied_valid,output [31:0] applied_token,
 output [WIDTH-1:0] applied_word);
wire [WIDTH+31:0] destination,acknowledged;
assign video_word=destination[WIDTH-1:0];assign video_token=destination[WIDTH+31:WIDTH];
assign applied_word=acknowledged[WIDTH-1:0];assign applied_token=acknowledged[WIDTH+31:WIDTH];
config_bundle_cdc #(.WIDTH(WIDTH+32),.TRIGGERED_CAPTURE(1)) channel(
 .src_clk(src_clk),.src_rst_n(rst_n),.src_data({publish_token,publish_word}),.src_valid(publish_valid),
 .applied_data(acknowledged),.applied_valid(applied_valid),.dst_clk(video_clk),
 .dst_rst_n(rst_n&&video_rst_n),.dst_capture(frame_boundary),.dst_data(destination),.dst_valid(video_valid));
endmodule

// Same physical clock only. Keep an immutable source snapshot and the actual
// frame register. The acknowledgement aliases that frame register, so a receipt
// can never precede the real display update. No asynchronous return mailbox.
module a_frame_apply_local #(parameter WIDTH=91)(input clk,rst_n,video_rst_n,
 input publish_valid,input [31:0] publish_token,input [WIDTH-1:0] publish_word,
 input frame_boundary,output [WIDTH-1:0] video_word,output [31:0] video_token,
 output video_valid,output applied_valid,output [31:0] applied_token,
 output [WIDTH-1:0] applied_word);
wire sink_reset_n=rst_n&&video_rst_n;
(*async_reg=1,preserve=1*) reg [1:0] source_release,sink_release;
always @(negedge clk or negedge rst_n)
 if(!rst_n)source_release<=0;else source_release<={source_release[0],1'b1};
always @(negedge clk or negedge sink_reset_n)
 if(!sink_reset_n)sink_release<=0;else sink_release<={sink_release[0],1'b1};
wire source_ready=source_release[1],sink_ready=sink_release[1];
reg [WIDTH+31:0] held,live;
reg held_valid,pending,live_valid;
wire capture=frame_boundary&&source_ready&&sink_ready&&held_valid&&(pending||!live_valid);
always @(posedge clk or negedge source_ready)begin
 if(!source_ready)begin held_valid<=0;pending<=0;end
 else begin
  if(capture)pending<=0;
  // An in-flight snapshot is never overwritten. A newer level is accepted
  // after its predecessor's real frame capture, even when the bus has ABA'd.
  if(!pending&&publish_valid&&(!held_valid||{publish_token,publish_word}!=held))begin
   held_valid<=1;pending<=1;
  end
 end
end
always @(posedge clk)begin
 if(source_ready&&!pending&&publish_valid&&(!held_valid||{publish_token,publish_word}!=held))
  held<={publish_token,publish_word};
 if(capture)live<=held;
end
always @(posedge clk or negedge sink_ready)
 if(!sink_ready)live_valid<=0;else if(capture)live_valid<=1;
assign video_word=live[WIDTH-1:0];assign video_token=live[WIDTH+31:WIDTH];
// The status packet also reads ACK data while valid=0. Keep that bus
// deterministic without resetting the wide frame register or replaying it.
assign applied_word=applied_valid?video_word:{WIDTH{1'b0}};
assign applied_token=applied_valid?video_token:32'd0;
assign video_valid=live_valid;assign applied_valid=live_valid&&source_ready&&sink_ready;
endmodule
