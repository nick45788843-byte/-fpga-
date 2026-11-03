// 一段音频从TF读入独立SDRAM环形缓存，再按48kHz送往视频域。
// 请求编号保持到真正预取成功；失败锁存并回退内部音源，不自动无限重试。
module a_pcm_playback32 #(parameter CLOCK_HZ=50000000,CONTROL_HZ=CLOCK_HZ,AUDIO_BEGIN=1536000,BUFFER_WORDS=131072,CONTROL_TOKEN32=0,AUTO_UID32=0,NORMAL_PLAYLIST=0)(
 input sd_clk,mem_clk,video_clk,rst_n,input initialized,reload,
 input source_busy,source_done,input [7:0] source_error,
 input source_pcm_valid,input [15:0] source_left,source_right,input source_last,
 input [31:0] source_frames,input source_metadata_valid,
 output source_pcm_ready,source_start,source_cancel,output [7:0] source_id,
 input [15:0] command,input command_valid,output [31:0] status,
 input emergency,alarm_external,input [1:0] preset,
 output sd_request,input sd_ready,output [31:0] sd_lba,
 input sd_valid,input [7:0] sd_byte,input sd_done,sd_error,output sd_cancel,sd_urgent,
 output external_select,external_available,output [15:0] external_left,external_right,input external_ready,
 output memory_request,input memory_ready,memory_grant,memory_done,core_busy,
 output memory_finish,memory_abort,output mem_rd_en,output [20:0] mem_rd_addr,
 output mem_wr_en,output [20:0] mem_wr_addr,output [31:0] mem_wr_data,input mem_rd_valid,input [31:0] mem_rd_data,
 output reg event_valid,output reg [127:0] event_data,
 output playback_applied,service_drained,
 input token_command_valid,input [31:0] token_command,input [7:0] token_source_id,
 output token_command_ready,output reg [31:0] acknowledged_token,
 input token_cancel_valid,input [31:0] token_cancel,
 output [31:0] source_uid,
 output auto_borrow_valid,input auto_borrow_ready,input [31:0] auto_borrow_uid,input auto_enabled,
 input [7:0] normal_program_id,input normal_program_active,output reg [31:0] completed_token
);
localparam IDLE=0,CLEAR=1,INIT=2,START=3,BUFFER=4,PLAY=5,STOP=6;
reg [2:0] state;reg [7:0] seen,ack,id,wanted,error;reg pending,was_emergency,was_external;reg [1:0] was_preset;
reg [7:0] was_normal_id;reg was_normal_active;
reg [31:0] seen_token;reg cancel_seen,pending_auto;
assign source_uid=seen_token;
wire matched_cancel=CONTROL_TOKEN32&&token_cancel_valid&&token_cancel!=0&&token_cancel==seen_token;

assign token_command_ready=CONTROL_TOKEN32&&token_command!=0&&token_command!=seen_token;
reg [11:0] failed_files;reg [26:0] timer;reg reader_start;wire reader_busy,reader_done,reader_aborted;wire [7:0] reader_error;
wire pv,pr,pl,metadata_valid;wire [15:0] left,right;wire [31:0] total_frames;
wire session_reset=state==IDLE || state==CLEAR;
wire fifo_reset_n=rst_n && !session_reset;
(*async_reg=1,preserve=1*) reg cancelling_phase,session_reset_phase;
// Release FIFO session reset on the existing memory falling phase.
// Keep vendor async assertion/synchronous release and all settling guards.
wire phased_fifo_reset_n;
// PCM cache and metadata endpoints release reset on their own memory phase.
// Assertion is asynchronous; two falling edges precede positive-edge work.
(*async_reg=1,preserve=1*) reg [1:0] memory_reset_release;
always @(negedge mem_clk or negedge rst_n)
 if(!rst_n)memory_reset_release<=0;else memory_reset_release<={memory_reset_release[0],1'b1};
wire memory_rst_n=memory_reset_release[1];
wire memory_session_rst_n=memory_rst_n && !session_reset_phase;
// The vendor FIFOs release their shared async reset from the same memory falling phase.
assign phased_fifo_reset_n=memory_session_rst_n;
wire cancelling=state==STOP || reload;
assign sd_cancel=cancelling;
assign sd_urgent=state==BUFFER;
assign status={ack,error,{5'd0,state},id};
// 输入来自B已解析的PCM；此处不再实例化TF、WAV目录或WAV解码器。
assign reader_busy=source_busy;assign reader_done=source_done;assign reader_aborted=1'b0;
assign reader_error=source_error;assign pv=source_pcm_valid;
assign left=source_left;assign right=source_right;assign pl=source_last;
assign total_frames=source_frames;assign metadata_valid=source_metadata_valid;
assign source_pcm_ready=pr;assign source_start=reader_start;assign source_cancel=cancelling;assign source_id=(state==START||state==BUFFER||state==PLAY)?id:8'd0;
assign sd_request=0;assign sd_lba=0;
wire in_valid,in_ready;wire [32:0] in_data;wire [9:0] in_space;
// B's PCM tuple is launched by the source positive-edge registers.
// Capture the complete tuple on the falling phase; the original positive
// FIFO write-valid/ready edge and all sample ownership remain unchanged.
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [32:0] source_tuple_phase;
always @(negedge sd_clk or negedge rst_n)begin
 if(!rst_n)source_tuple_phase<=0;else source_tuple_phase<={pl,right,left};
end
pcm_frame_fifo input_fifo(.arst_n(phased_fifo_reset_n),.write_clk(sd_clk),.write_valid(pv),.write_data(source_tuple_phase),.write_ready(pr),.write_space(in_space),
 .read_clk(mem_clk),.read_ready(in_ready),.read_valid(in_valid),.read_data(in_data));
wire [31:0] frames_mem;wire frames_valid;
config_bundle_cdc #(.DST_DATA_PHASE(1)) descriptor(.src_clk(sd_clk),.src_rst_n(fifo_reset_n),.src_data(total_frames),.src_valid(metadata_valid),.applied_data(),.applied_valid(),
 .dst_clk(mem_clk),.dst_rst_n(memory_session_rst_n),.dst_data(frames_mem),.dst_valid(frames_valid),
 .dst_capture(1'b0));

always @(negedge mem_clk or negedge rst_n)begin
 if(!rst_n)begin cancelling_phase<=0;session_reset_phase<=1;end
 else begin cancelling_phase<=cancelling;session_reset_phase<=session_reset;end
end
reg [1:0] cancel_mem;reg meta_seen,cache_start;wire cache_active,loaded,queued;wire [7:0] cache_error;
wire out_valid,out_ready;wire [32:0] out_data;wire [9:0] out_space;
reg [8:0] produced;reg prefilled;
always @(posedge mem_clk or negedge memory_rst_n)begin
 if(!memory_rst_n)begin cancel_mem<=0;meta_seen<=0;cache_start<=0;produced<=0;prefilled<=0;end
 else begin
  cancel_mem<={cancel_mem[0],cancelling_phase};cache_start<=0;
  if(session_reset_phase)begin meta_seen<=0;produced<=0;prefilled<=0;end
  else begin
   if(frames_valid && !meta_seen && !cache_active)begin meta_seen<=1;cache_start<=1;end
   if(out_valid && out_ready)begin
    if(produced<256)produced<=produced+1'b1;
    if(produced>=255 || out_data[32])prefilled<=1;
   end
  end
 end
end
audio_sdram_cache #(.CLOCK_HZ(CLOCK_HZ),.AUDIO_BEGIN(AUDIO_BEGIN),.BUFFER_WORDS(BUFFER_WORDS)) cache(.clk(mem_clk),.rst_n(memory_rst_n),.start(cache_start),.cancel(cancel_mem[1]),.total_frames(frames_mem),
 .input_valid(in_valid),.input_ready(in_ready),.input_data(in_data[31:0]),.input_last(in_data[32]),
 .output_space(out_space),.output_valid(out_valid),.output_data(out_data),.active(cache_active),.load_complete(loaded),.queue_complete(queued),.error_code(cache_error),
 .memory_request(memory_request),.memory_ready(memory_ready),.memory_grant(memory_grant),.memory_done(memory_done),.core_busy(core_busy),
 .memory_finish(memory_finish),.memory_abort(memory_abort),.mem_rd_en(mem_rd_en),.mem_rd_addr(mem_rd_addr),.mem_wr_en(mem_wr_en),.mem_wr_addr(mem_wr_addr),.mem_wr_data(mem_wr_data),
 .mem_rd_valid(mem_rd_valid),.mem_rd_data(mem_rd_data));
wire play_valid;wire [32:0] play_data;reg [1:0] play_sync;reg finished,underrun;
pcm_frame_fifo output_fifo(.arst_n(phased_fifo_reset_n),.write_clk(mem_clk),.write_valid(out_valid),.write_data(out_data),.write_ready(out_ready),.write_space(out_space),
 .read_clk(video_clk),.read_ready(external_ready && external_select),.read_valid(play_valid),.read_data(play_data));
always @(posedge video_clk or negedge fifo_reset_n)begin
 if(!fifo_reset_n)begin play_sync<=0;finished<=0;underrun<=0;end
 else begin
  play_sync<={play_sync[0],state==PLAY};
  if(external_select && external_ready)begin
   if(!play_valid)underrun<=1;
   else if(play_data[32])finished<=1;
  end
 end
end
assign external_select=play_sync[1] && !finished && !underrun;
assign external_available=external_select && play_valid;
assign external_left=play_data[15:0];assign external_right=play_data[31:16];
reg [1:0] ready_sync,active_sync,finish_sync,under_sync;reg [7:0] cache_error_sd;
// New control plane observes actual output selection and memory drain in sd_clk.
// These status synchronizers do not replace the existing data/FIFO CDC.
(* async_reg=1,preserve=1 *) reg [1:0] memory_request_sync,core_busy_sync,select_sync;
reg [2:0] status_settle;
always @(posedge sd_clk or negedge rst_n)begin
 if(!rst_n)begin memory_request_sync<=0;core_busy_sync<=0;select_sync<=0;status_settle<=0;end
 else begin
  memory_request_sync<={memory_request_sync[0],memory_request};
  core_busy_sync<={core_busy_sync[0],core_busy};
  select_sync<={select_sync[0],external_select};
  status_settle<={status_settle[1:0],1'b1};
 end
end
assign playback_applied=status_settle[2]&&state==PLAY&&select_sync[1]&&!error;
assign service_drained=status_settle[2]&&state==IDLE&&!pending&&!reader_busy&&!active_sync[1]&&
                       !memory_request_sync[1]&&!core_busy_sync[1]&&!select_sync[1];
// Automatic starts/repeats wait for the old real cache, source and output to
// drain, then borrow from the same forward allocator as PC and images.
assign auto_borrow_valid=AUTO_UID32&&auto_enabled&&state==CLEAR&&timer>=15&&pending_auto&&
 !reader_busy&&!active_sync[1]&&!memory_request_sync[1]&&!core_busy_sync[1]&&!select_sync[1]&&!reload;
wire [7:0] cache_error_held;wire cache_error_valid;
config_bundle_cdc #(.WIDTH(8)) error_return(.src_clk(mem_clk),.src_rst_n(memory_session_rst_n),.src_data(cache_error),.src_valid(cache_active),.applied_data(),.applied_valid(),
 .dst_clk(sd_clk),.dst_rst_n(fifo_reset_n),.dst_data(cache_error_held),.dst_valid(cache_error_valid),
 .dst_capture(1'b0));
always @(posedge sd_clk or negedge rst_n)begin
 if(!rst_n)begin ready_sync<=0;active_sync<=0;finish_sync<=0;under_sync<=0;end
 else begin ready_sync<={ready_sync[0],prefilled};active_sync<={active_sync[0],cache_active};finish_sync<={finish_sync[0],finished};under_sync<={under_sync[0],underrun};end
end
task fail;
 input [7:0] code;
 begin if(id>=1&&id<=12)failed_files[id-1'b1]<=1;error<=code;ack<=seen;acknowledged_token<=seen_token;pending<=0;state<=STOP;event_valid<=1;event_data<={8'd1,8'd7,code,id,32'd0,32'd0,32'd0};end
endtask
always @(posedge sd_clk or negedge rst_n)begin
 if(!rst_n)begin was_normal_active<=0;was_normal_id<=0;completed_token<=0;state<=IDLE;seen<=0;seen_token<=0;cancel_seen<=0;pending_auto<=0;acknowledged_token<=0;ack<=0;id<=0;wanted<=0;error<=0;pending<=0;timer<=0;reader_start<=0;event_valid<=0;event_data<=0;was_emergency<=0;was_external<=0;was_preset<=0;cache_error_sd<=0;failed_files<=0;end
 else begin
  reader_start<=0;event_valid<=0;
  if(NORMAL_PLAYLIST&&auto_enabled)begin was_normal_id<=emergency?8'd0:normal_program_id;was_normal_active<=!emergency&&normal_program_active;end
  if(session_reset)cache_error_sd<=0;else if(cache_error_valid)cache_error_sd<=cache_error_held;
  if(!matched_cancel&&(!AUTO_UID32||auto_enabled))begin was_emergency<=emergency;was_external<=alarm_external;was_preset<=preset;end
  if(AUTO_UID32&&reload)begin was_emergency<=0;was_external<=0;pending_auto<=0;end
  if(!token_cancel_valid)cancel_seen<=0;
  if(matched_cancel&&!cancel_seen)begin
   cancel_seen<=1;wanted<=0;pending<=1;pending_auto<=0;error<=0;state<=STOP;timer<=0;
  end else if(CONTROL_TOKEN32&&!matched_cancel&&token_command_valid&&token_command_ready)begin
   seen_token<=token_command;cancel_seen<=0;seen<=token_command[7:0];wanted<=token_source_id;
   pending<=1;pending_auto<=0;error<=0;state<=STOP;timer<=0;
  end else if(!CONTROL_TOKEN32&&command_valid && command[15:8]!=seen)begin
   seen<=command[15:8];wanted<=command[7:0];pending<=1;error<=0;state<=STOP;timer<=0;
  end else if(!matched_cancel&&(!AUTO_UID32||auto_enabled)&&(emergency!=was_emergency || (emergency && alarm_external!=was_external) || (emergency && preset!=was_preset)))begin
   wanted<=emergency && alarm_external?{6'd0,preset}+1'b1:0;pending<=1;
   pending_auto<=AUTO_UID32&&emergency&&alarm_external;error<=0;state<=STOP;timer<=0;
  end else if(NORMAL_PLAYLIST&&AUTO_UID32&&auto_enabled&&!matched_cancel&&!emergency&&(normal_program_id!=was_normal_id||normal_program_active!=was_normal_active))begin
   wanted<=normal_program_id;pending<=1;pending_auto<=normal_program_id!=0;error<=0;state<=STOP;timer<=0;
  end else if(!matched_cancel&&reload && state!=IDLE && state!=STOP)fail(8'ha7);
  else case(state)
   IDLE:if(pending)begin state<=CLEAR;timer<=0;end
   CLEAR:if(timer>=15)begin
    if(!AUTO_UID32||!pending_auto||(auto_borrow_valid&&auto_borrow_ready))begin
     id<=wanted;error<=0;
     if(AUTO_UID32&&pending_auto)begin seen_token<=auto_borrow_uid;seen<=auto_borrow_uid[7:0];pending_auto<=0;end
     if(wanted==0)begin pending<=0;ack<=seen;acknowledged_token<=seen_token;state<=IDLE;end
     else begin state<=INIT;timer<=0;end
    end
   end else timer<=timer+1'b1;
   INIT:if(initialized && !reload)begin state<=START;timer<=0;end
    else if(timer>=CONTROL_HZ*2)fail(8'ha7);else timer<=timer+1'b1;
   START:begin reader_start<=1;state<=BUFFER;timer<=0;end
   BUFFER:begin
    if(reader_done && reader_error!=0)fail(reader_error);
    else if(cache_error_sd!=0 && active_sync[1])fail(cache_error_sd);
    else if(ready_sync[1])begin state<=PLAY;ack<=seen;acknowledged_token<=seen_token;pending<=0;timer<=0;
     if(id>=1&&id<=12 && failed_files[id-1'b1])begin failed_files[id-1'b1]<=0;event_valid<=1;event_data<={8'd2,8'd7,8'd0,id,32'd0,32'd0,32'd0};end
    end
    else if(timer>=CONTROL_HZ*2)fail(8'hb4);else timer<=timer+1'b1;
   end
   PLAY:begin
    if(reader_done && reader_error!=0)fail(reader_error);
    else if(cache_error_sd!=0)fail(cache_error_sd);
    else if(under_sync[1])fail(8'hb4);
    else if(finish_sync[1])begin
     completed_token<=seen_token;state<=STOP;
     // One short spoken alert, then the independent local alarm DDS.
    end
   end
   STOP:if(!reader_busy && !active_sync[1] && !memory_request)begin state<=pending?CLEAR:IDLE;timer<=0;end
   default:state<=STOP;
  endcase
 end
end
endmodule
