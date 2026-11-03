// One 256-point vendor core serves both channels of an immutable PCM block.
// A query lease prevents a new capture from replacing any paged result.
module b_pcm_analysis(input clk,rst_n,input start,output start_ready,input [31:0] token,
 input sample_valid,input [31:0] sample_word,output sample_ready,
 output busy,output reg done,failed,output reg [31:0] result_token,
 output reg result_valid,output reg [15:0] generation,
 input query_begin,output query_ready,input [31:0] query_token,
 input query_end,input [31:0] query_end_token,output reg query_active,
 input [1:0] read_kind,input [7:0] read_index,output [15:0] read_value,
 input notice_valid,notice_session,input [31:0] notice_token,output control_done);
localparam IDLE=0,CAPTURE=1,START_FFT=2,FEED=3,WAIT_FFT=4,FINISH=5;
reg [2:0] state;
reg [7:0] capture_index,feed_index;
reg [8:0] output_count;
reg channel,aborting,done_seen;
reg [31:0] lease_token;
(* force_ram=1,ram_style="bram" *) reg [31:0] samples[0:255];
(* force_ram=1,ram_style="bram" *) reg [15:0] spectrum[0:255];
reg [31:0] sample_read;
reg [15:0] spectrum_read;
reg [1:0] selected_kind;
reg feed_valid;
wire core_start=state==START_FFT;
wire core_done,core_busy,core_valid;
wire [23:0] core_real,core_imag;
wire [15:0] core_input=channel?sample_read[31:16]:sample_read[15:0];
wire [23:0] abs_real=core_real[23]?(~core_real+24'd1):core_real;
wire [23:0] abs_imag=core_imag[23]?(~core_imag+24'd1):core_imag;
wire [24:0] magnitude={1'b0,abs_real}+{1'b0,abs_imag}+25'd128;
wire [16:0] normalized=magnitude[24:8];
wire affected=notice_valid&&(notice_session||notice_token==result_token);
assign start_ready=state==IDLE&&!query_active&&!notice_valid&&generation!=16'hffff;
assign sample_ready=state==CAPTURE&&!aborting&&!affected;
assign busy=state!=IDLE||core_busy;
assign query_ready=state==IDLE&&result_valid&&!query_active&&!notice_valid;
assign read_value=selected_kind[1]?spectrum_read:selected_kind[0]?sample_read[31:16]:sample_read[15:0];
assign control_done=notice_valid&&(!affected||!busy)&&
 (!query_active||(!notice_session&&notice_token!=lease_token));
b_fft256_vendor fft(clk,!rst_n,1'b0,core_start,feed_valid,core_input,16'd0,
 core_done,core_busy,core_valid,core_real,core_imag);
wire capture_write=sample_valid&&sample_ready;
always @(posedge clk)begin
 if(capture_write)samples[capture_index]<=sample_word;
 sample_read<=samples[state==IDLE?read_index:feed_index];
 spectrum_read<=spectrum[{read_kind[0],read_index[6:0]}];
 selected_kind<=read_kind;
 if(core_valid&&output_count<128&&!aborting&&!affected)
  spectrum[{channel,output_count[6:0]}]<=normalized[16]?16'hffff:normalized[15:0];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;capture_index<=0;feed_index<=0;output_count<=0;
  channel<=0;aborting<=0;done_seen<=0;feed_valid<=0;done<=0;failed<=0;result_token<=0;
  result_valid<=0;generation<=0;query_active<=0;lease_token<=0;end
 else begin
  done<=0;failed<=0;
  if(query_begin&&query_ready&&query_token!=0)begin query_active<=1;lease_token<=query_token;end
  if(query_end&&query_active&&query_end_token==lease_token)query_active<=0;
  if(notice_valid&&(notice_session||notice_token==lease_token))query_active<=0;
  if(notice_valid&&notice_session)result_valid<=0;
  if(affected&&state!=IDLE)aborting<=1;
  feed_valid<=state==FEED;
  if(core_done)done_seen<=1;
  case(state)
   IDLE:if(start&&start_ready&&!query_begin&&token!=0)begin
    result_token<=token;result_valid<=0;capture_index<=0;channel<=0;aborting<=0;state<=CAPTURE;
   end
   CAPTURE:begin
    if(affected)begin failed<=1;done<=1;state<=IDLE;end
    else if(capture_write)begin
     if(capture_index==255)begin feed_index<=0;output_count<=0;done_seen<=0;state<=START_FFT;end
     else capture_index<=capture_index+1'b1;
    end
   end
   START_FFT:state<=FEED;
   FEED:begin
    if(feed_index==255)state<=WAIT_FFT;else feed_index<=feed_index+1'b1;
   end
   WAIT_FFT:if(done_seen&&!core_busy&&!core_valid&&output_count==256)begin
    if(aborting||affected)begin failed<=1;done<=1;state<=IDLE;end
    else if(!channel)begin channel<=1;feed_index<=0;output_count<=0;done_seen<=0;state<=START_FFT;end
    else state<=FINISH;
   end
   FINISH:begin
    done<=1;state<=IDLE;
    if(aborting||affected)failed<=1;
    else begin result_valid<=1;generation<=generation+1'b1;end
   end
   default:state<=IDLE;
  endcase
  if(core_valid&&output_count<256)output_count<=output_count+1'b1;
 end
end
endmodule
