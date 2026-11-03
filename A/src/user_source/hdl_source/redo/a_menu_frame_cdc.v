// Latest complete display level, one immutable in-flight bundle, video-frame
// capture, and a real toggle acknowledgment. Reset of either side resets both.
module a_menu_frame_cdc(input ctrl_clk,video_clk,ctrl_rst_n,video_rst_n,enabled,
 input [34:0] desired,input frame_boundary,output reg [34:0] applied);
// Session/key closure resets this display-only handshake on both sides. An
// old queued menu cannot reappear after a cancelled session or local close.
wire reset_n=ctrl_rst_n&&video_rst_n&&enabled;
(* async_reg=1,preserve=1 *) reg [1:0] source_reset_sync,video_reset_sync;
always @(posedge ctrl_clk or negedge reset_n)
 if(!reset_n)source_reset_sync<=0;else source_reset_sync<={source_reset_sync[0],1'b1};
always @(posedge video_clk or negedge reset_n)
 if(!reset_n)video_reset_sync<=0;else video_reset_sync<={video_reset_sync[0],1'b1};
wire source_rst_n=source_reset_sync[1],destination_rst_n=video_reset_sync[1];
reg [34:0] held;
reg request_toggle,ack_toggle,busy;
(* async_reg=1,preserve=1 *) reg [2:0] request_sync;
(* async_reg=1,preserve=1 *) reg [1:0] ack_sync;
always @(posedge ctrl_clk or negedge source_rst_n)begin
 if(!source_rst_n)begin held<=0;request_toggle<=0;busy<=0;ack_sync<=0;end
 else begin
  ack_sync<={ack_sync[0],ack_toggle};
  if(busy&&ack_sync[1]==request_toggle)busy<=0;
  else if(!busy&&desired!=held)begin held<=desired;request_toggle<=!request_toggle;busy<=1;end
 end
end
always @(posedge video_clk or negedge destination_rst_n)begin
 if(!destination_rst_n)begin request_sync<=0;ack_toggle<=0;applied<=0;end
 else begin
  request_sync<={request_sync[1:0],request_toggle};
  if(frame_boundary&&request_sync[2]!=ack_toggle)begin applied<=held;ack_toggle<=request_sync[2];end
 end
end
endmodule

// Display-only latest level on the same physical clock. Closing a menu or
// resetting either owner clears it immediately; reopening waits for a frame.
module a_menu_frame_local #(parameter WIDTH=35)(input clk,ctrl_rst_n,video_rst_n,enabled,
 input [WIDTH-1:0] desired,input frame_boundary,output reg [WIDTH-1:0] applied);
wire reset_n=ctrl_rst_n&&video_rst_n&&enabled;
(*async_reg=1,preserve=1*) reg [1:0] release_phase;
always @(negedge clk or negedge reset_n)
 if(!reset_n)release_phase<=0;else release_phase<={release_phase[0],1'b1};
wire ready=release_phase[1];
always @(posedge clk or negedge ready)
 if(!ready)applied<=0;else if(frame_boundary)applied<=desired;
endmodule
