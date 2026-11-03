// Retained bounded media commit algorithm; external identity checks now use full32 UID.
// 只消费CRC已验证的块。图片先写空闲物理槽，完整落存后交换逻辑映射。
module a_media_commit32 #(parameter CLOCK_HZ=50000000,FRAME_WORDS=307200,RETIRE_GUARD=0,SHARED_DESCRIPTOR=0,SCALE_ENABLED=0)(
 input clk,rst_n,valid,output reg consume,input [7:0] kind,arg,input [6:0] count,
 input [15:0] sequence_id,tag,packet_crc,input [31:0] value,
 output reg [5:0] read_address,input [31:0] read_word,
 input memory_ready,write_ack,write_done_toggle,image_ready,write_core_busy,image_abort_done,
 output reg image_req,image_valid,image_abort,output reg [31:0] image_word,
 output [20:0] write_base,read_base0,read_base1,read_base2,read_base3,
 output reg [1:0] display_bank,output reg display_valid,output reg [3:0] image_code,
 output reg frame_toggle,output [3:0] cached_mask,
 input audio_start,audio_cancel,input [7:0] audio_id,input audio_ready,
 output reg audio_busy,audio_done,output reg [7:0] audio_error,output reg [31:0] audio_epoch,
 output reg audio_metadata,output reg [31:0] audio_frames,
 output reg pcm_valid,pcm_last,output reg [31:0] pcm_word,
 output reg peer_restart,output reg peer_valid,output reg [7:0] action_ack,output reg acknowledged_valid,output reg [15:0] acknowledged_tag,output reg [7:0] result_code,
 output reg event_valid,output reg [127:0] event_data,input event_ready,output [31:0] received_pixels,
 input retire_valid,input [31:0] retired_generation,input reader_pipeline_idle,
 output reg retirement_pending,output reg [31:0] map_generation,output retire_exhausted,
 input [31:0] packet_uid,audio_start_uid,output reg [31:0] acknowledged_uid,output image_drained,output reg [7:0] committed_extents,output reg [11:0] committed_scales,
 // A96: original source size per logical bank, {width[12:0],height[12:0]}; 0 = unknown (older B).
 output reg [103:0] committed_dims);
localparam LIMIT=CLOCK_HZ/5,TW=$clog2(LIMIT+1);
localparam IDLE=0,BEGIN_WAIT=1,READ_ADDR=2,READ_WAIT=3,DELIVER=4,END_WAIT=5,ABORT_WAIT=6,FINISH=7,EVENT_WAIT=8;
localparam PIXEL_BITS=FRAME_WORDS>1?$clog2(FRAME_WORDS+1):1;
localparam PIXEL_SUM_BITS=(PIXEL_BITS>7?PIXEL_BITS:7)+1;
reg [3:0] state;reg [95:0] event_payload;reg [TW-1:0] timer;
reg [PIXEL_BITS-1:0] pixels;reg [31:0] audio_received;
wire [31:0] pixels_report=pixels;
wire [PIXEL_SUM_BITS-1:0] pixels_after_block=pixels+count;
reg [2:0] map[0:3],spare,working;reg [3:0] committed;
reg heartbeat_seen;reg [15:0] heartbeat_sequence;localparam [31:0] EXPECTED_PIXELS=FRAME_WORDS;
reg [2:0] frame_scale;reg [1:0] frame_extent;reg frame_active;reg [1:0] logical_bank;reg [31:0] frame_uid,private_active_uid,last_uid;reg [15:0] private_active_tag,last_tag,last_crc;reg last_valid;
reg [7:0] last_kind;reg [7:0] active_result,last_result;reg [7:0] private_active_kind;reg [6:0] private_active_count;reg [5:0] index;
reg [31:0] private_active_value;reg [7:0] private_active_arg;
(* async_reg=1,preserve=1 *) reg done_meta,done_sync,ack_meta,ack_sync;
reg done_seen;reg abort_requested,abort_issued;
function [20:0] base;input [2:0] bank;begin
 case(bank)0:base=0;1:base=FRAME_WORDS;2:base=FRAME_WORDS*2;3:base=FRAME_WORDS*3;default:base=FRAME_WORDS*4;endcase
end endfunction
assign write_base=base(working);assign read_base0=base(map[0]);assign read_base1=base(map[1]);assign read_base2=base(map[2]);assign read_base3=base(map[3]);
assign cached_mask=committed;assign received_pixels=pixels;
assign retire_exhausted=RETIRE_GUARD&&map_generation==32'hffffffff;
assign image_drained=!frame_active&&!image_req&&!abort_requested&&!abort_issued&&state==IDLE;
// Production CRC RAM and UID guard hold the entire current descriptor
// through core consume, including abort/timeout and real backend waits.
// Old frame/audio/replay owners remain independent full32 registers.
wire [31:0] active_uid=SHARED_DESCRIPTOR?packet_uid:private_active_uid;
wire [15:0] active_tag=SHARED_DESCRIPTOR?tag:private_active_tag;
wire [7:0] active_kind=SHARED_DESCRIPTOR?kind:private_active_kind;
wire [6:0] active_count=SHARED_DESCRIPTOR?count:private_active_count;
wire [31:0] active_value=SHARED_DESCRIPTOR?value:private_active_value;
wire [7:0] active_arg=SHARED_DESCRIPTOR?arg:private_active_arg;
task fault;input [7:0] code;begin
 active_result<=code;event_valid<=1;event_data<={8'd1,8'd8,code,active_arg,active_value,pixels_report,EXPECTED_PIXELS};
end endtask
task finish;input [7:0] code;begin active_result<=code;state<=FINISH;end endtask
integer i;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  committed_scales<=0;committed_dims<=0;frame_scale<=0;committed_extents<=0;frame_extent<=0;event_payload<=0;state<=IDLE;timer<=0;consume<=0;read_address<=0;image_req<=0;image_valid<=0;image_word<=0;image_abort<=0;
  heartbeat_seen<=0;heartbeat_sequence<=0;working<=4;spare<=4;committed<=0;frame_active<=0;logical_bank<=0;pixels<=0;display_bank<=0;display_valid<=0;image_code<=0;frame_toggle<=0;
  retirement_pending<=0;map_generation<=0;frame_uid<=0;private_active_uid<=0;last_uid<=0;
  last_kind<=0;acknowledged_valid<=0;active_result<=0;last_result<=0;private_active_tag<=0;last_tag<=0;last_crc<=0;last_valid<=0;private_active_kind<=0;private_active_count<=0;private_active_arg<=0;private_active_value<=0;index<=0;
  done_meta<=0;done_sync<=0;done_seen<=0;ack_meta<=0;ack_sync<=0;abort_requested<=0;abort_issued<=0;
  audio_busy<=0;audio_done<=0;audio_error<=0;audio_epoch<=0;audio_metadata<=0;audio_frames<=0;audio_received<=0;pcm_valid<=0;pcm_last<=0;pcm_word<=0;
  peer_restart<=0;peer_valid<=0;action_ack<=0;acknowledged_uid<=0;acknowledged_tag<=0;result_code<=0;event_valid<=0;event_data<=0;
  for(i=0;i<4;i=i+1)map[i]<=i;
 end else begin
  consume<=0;image_valid<=0;image_abort<=0;pcm_valid<=0;audio_done<=0;peer_restart<=0;peer_valid<=0;if(event_valid&&event_ready)event_valid<=0;
  done_meta<=write_done_toggle;done_sync<=done_meta;ack_meta<=write_ack;ack_sync<=ack_meta;
  if(RETIRE_GUARD&&retirement_pending&&retire_valid&&retired_generation==map_generation&&reader_pipeline_idle)
   retirement_pending<=0;
  if(audio_start)begin audio_epoch<=audio_start_uid;audio_busy<=1;audio_metadata<=0;audio_error<=0;audio_frames<=0;audio_received<=0;end
  if(audio_cancel)begin audio_busy<=0;audio_metadata<=0;audio_error<=0;end
  if(done_sync!=done_seen)begin
   done_seen<=done_sync;
   if(frame_active&&pixels==FRAME_WORDS)begin
    committed_scales[logical_bank*3+:3]<=frame_scale;committed_extents[logical_bank*2+:2]<=frame_extent;map[logical_bank]<=working;spare<=map[logical_bank];committed[logical_bank]<=1;frame_active<=0;frame_toggle<=!frame_toggle;
    if(map_generation!=32'hffffffff)map_generation<=map_generation+1'b1;
    if(RETIRE_GUARD)retirement_pending<=1;
   end
  end
  if(state!=IDLE&&state!=FINISH)begin if(timer<LIMIT)timer<=timer+1'b1;end else timer<=0;
  case(state)
   IDLE:if(valid&&!consume&&(!RETIRE_GUARD||kind!=8'h10||(!retirement_pending&&!retire_exhausted)))begin
    private_active_kind<=kind;private_active_uid<=packet_uid;private_active_count<=count;private_active_arg<=arg;private_active_value<=value;private_active_tag<=tag;index<=0;timer<=0;active_result<=0;
    // 轮询不改变数据回执编号，不能把丢失的数据块误当已执行。
    if(kind==1)begin
     action_ack<=value[15:8];
     if(arg[7])begin display_bank<=arg[1:0];display_valid<=committed[arg[1:0]];image_code<=value[3:0];end
     if(!heartbeat_seen||sequence_id!=heartbeat_sequence)begin peer_valid<=1;heartbeat_seen<=1;heartbeat_sequence<=sequence_id;end
     consume<=1;
    end else if(kind==2)begin
     if(last_valid&&last_kind==2&&tag==last_tag&&packet_crc==last_crc)begin
      acknowledged_uid<=packet_uid;acknowledged_tag<=tag;result_code<=last_result;acknowledged_valid<=1;consume<=1;
     end else if(count!=0||arg!=0)finish(8'h47);
     else begin
      // B重启同步必须结束旧音频会话，禁止从文件首部的数据混入旧缓存。
      if(audio_id!=0||audio_busy)begin audio_epoch<=0;audio_error<=8'hb5;audio_done<=1;audio_busy<=0;audio_metadata<=0;end
      peer_restart<=1;peer_valid<=1;last_valid<=0;abort_requested<=1;abort_issued<=0;state<=ABORT_WAIT;
     end
    end else if(last_valid&&tag==last_tag&&packet_uid==last_uid)begin
     if(packet_crc==last_crc)begin acknowledged_uid<=packet_uid;acknowledged_tag<=tag;result_code<=last_result;acknowledged_valid<=1;consume<=1;end
     else begin fault(8'hd4);result_code<=8'hd4;acknowledged_uid<=packet_uid;acknowledged_tag<=tag;acknowledged_valid<=1;consume<=1;end
    end else case(kind)
     8'h10:begin
      if(count!=0||(SCALE_ENABLED?(arg[7]||arg[6:4]>4):arg[7:4]!=0)||arg[3:2]>2||value!=FRAME_WORDS)begin finish(8'h47);end
      else if(frame_active||!memory_ready)finish(8'h43);
      else begin frame_scale<=SCALE_ENABLED?arg[6:4]:3'd0;frame_extent<=arg[3:2];working<=spare;logical_bank<=arg[1:0];pixels<=0;frame_active<=1;frame_uid<=packet_uid;image_req<=1;state<=BEGIN_WAIT;end
     end
     8'h11:begin
      if(!frame_active||packet_uid!=frame_uid||arg[1:0]!=logical_bank||arg>3||count==0||count>64||value!=pixels||pixels_after_block>FRAME_WORDS)finish(8'hd2);
      else begin read_address<=0;state<=READ_ADDR;end
     end
     // A96: B108 marks bit31 and carries the original size; older B sends FRAME_WORDS.
     8'h12:if(packet_uid!=frame_uid||count!=0||(value!=FRAME_WORDS&&!value[31])||arg>3||arg[1:0]!=logical_bank||pixels!=FRAME_WORDS)finish(8'h47);
      else begin committed_dims[logical_bank*26+:26]<=value[31]?value[25:0]:26'd0;state<=END_WAIT;end
     8'h13:if(count!=0||arg!=0||value!=0)finish(8'h47);
       else if(frame_active&&packet_uid!=frame_uid)finish(8'h49);else begin abort_requested<=1;abort_issued<=0;state<=ABORT_WAIT;end
     8'h20:begin
      if(packet_uid!=audio_epoch||!audio_busy||audio_cancel||count!=0||value==0)finish(8'h49);
      else begin audio_frames<=value;audio_metadata<=1;audio_received<=0;finish(0);end
     end
     8'h21,8'h22:begin
      if(packet_uid!=audio_epoch||!audio_busy||audio_cancel||!audio_metadata||count==0||count>64||value!=audio_received||value+count>audio_frames||((kind==8'h22)!=(value+count==audio_frames)))finish(8'h49);
      else begin read_address<=0;state<=READ_ADDR;end
     end
     8'h23:begin
      if(packet_uid!=audio_epoch)finish(8'h49);
      else begin audio_error<=value[7:0];audio_done<=1;audio_busy<=0;finish(0);end
     end
     8'h30:if(count!=3)finish(8'h47);else if(!event_valid)begin read_address<=0;state<=READ_ADDR;end
     default:finish(8'h40);
    endcase
   end
   BEGIN_WAIT:if(ack_sync)begin image_req<=0;finish(0);end
   READ_ADDR:state<=READ_WAIT;
   READ_WAIT:state<=DELIVER;
   DELIVER:begin
    if(active_kind==8'h30)begin
     event_payload[95-index*32-:32]<=read_word;
     if(index==2)begin event_data<={active_value,event_payload[95:32],read_word};event_valid<=1;state<=EVENT_WAIT;end
     else begin index<=index+1'b1;read_address<=index+1'b1;state<=READ_ADDR;end
    end else if(active_kind==8'h11)begin
     if(image_ready)begin
      image_valid<=1;image_word<=read_word;pixels<=pixels+1'b1;
      if(index+1==active_count)finish(0);else begin index<=index+1'b1;read_address<=index+1'b1;state<=READ_ADDR;end
     end
    end else if(audio_cancel||!audio_busy||active_uid!=audio_epoch)finish(8'h49);
    else if(audio_ready)begin
     pcm_valid<=1;pcm_word<=read_word;pcm_last<=active_kind==8'h22&&index+1==active_count;audio_received<=audio_received+1'b1;
     if(index+1==active_count)begin
      if(active_kind==8'h22)begin audio_busy<=0;audio_done<=1;end
      finish(0);
     end else begin index<=index+1'b1;read_address<=index+1'b1;state<=READ_ADDR;end
    end
   end
   END_WAIT:if(!frame_active&&committed[active_arg[1:0]])finish(0);
   ABORT_WAIT:begin
    if(!frame_active&&!image_req&&!write_core_busy&&!abort_issued)begin pixels<=0;abort_requested<=0;finish(active_result);end
    else if(!abort_issued&&!write_core_busy)begin image_abort<=1;image_req<=0;abort_issued<=1;end
    else if(abort_issued&&image_abort_done)begin frame_active<=0;pixels<=0;abort_requested<=0;abort_issued<=0;finish(active_result);end
   end
   EVENT_WAIT:if(event_valid&&event_ready)finish(0);
   FINISH:begin
    acknowledged_valid<=1;result_code<=active_result;last_result<=active_result;acknowledged_uid<=active_uid;acknowledged_tag<=active_tag;last_tag<=active_tag;last_uid<=active_uid;last_kind<=active_kind;last_crc<=packet_crc;last_valid<=1;consume<=1;if(active_result==0)peer_valid<=1;state<=IDLE;
   end
  endcase
  if(state!=IDLE&&state!=FINISH&&state!=ABORT_WAIT&&timer>=LIMIT-1)begin
   fault(8'hd1);image_req<=0;abort_requested<=1;abort_issued<=0;state<=ABORT_WAIT;timer<=0;
  end
 end
end
endmodule
