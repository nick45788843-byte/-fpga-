// The same DDS and gain path also produce the frame-committed picture cue.
module emergency_pcm_audio #(parameter CLOCK_HZ=25000000,SAMPLE_RATE=48000,PICTURE_CUE_ENABLED=0,NORMAL_SOUND_CONTROL=0)(
 input clk,rst,input [7:0] normal_volume,alarm_volume,input emergency_mode,
 input external_select,external_available,input signed [15:0] external_left,external_right,
 output external_ready,output reg valid,output reg [23:0] left,right,
 input picture_commit,input [1:0] picture_id,input normal_builtin
);
reg [24:0] sample_acc;
reg prepare;reg [1:0] pipe;
reg [31:0] phase;
reg [2:0] note;
reg [14:0] note_time;
reg [1:0] source;
reg [8:0] gain,normal_target,alarm_target,sample_gain;
reg [7:0] previous_normal,previous_alarm;
reg signed [15:0] wave,sample_l,sample_r,last_l,last_r;
localparam CUE_SAMPLES=SAMPLE_RATE/10,CUE_BITS=$clog2(CUE_SAMPLES+1);
reg [CUE_BITS-1:0] cue_remaining;
reg [1:0] cue_id,pending_cue_id;
reg cue_restart;
wire cue_active=PICTURE_CUE_ENABLED&&cue_remaining!=0;
wire [1:0] wanted=emergency_mode ? ((external_select&&external_available)?2:1) :
 (cue_active&&(!NORMAL_SOUND_CONTROL||normal_builtin)) ? 3 : (external_select&&external_available)?2:0;
wire tick=sample_acc>=CLOCK_HZ-SAMPLE_RATE;
wire [8:0] target=emergency_mode?alarm_target:(NORMAL_SOUND_CONTROL&&source==0&&!normal_builtin)?9'd0:normal_target;
assign external_ready=tick&&source==2&&external_select;
function signed [15:0] wave_lookup;input [7:0] p;reg [5:0] a;reg [12:0] v;begin
 a=p[6]?6'd63-p[5:0]:p[5:0];case(a)
6'd0:v=13'd0;
6'd1:v=13'd192;
6'd2:v=13'd383;
6'd3:v=13'd575;
6'd4:v=13'd766;
6'd5:v=13'd956;
6'd6:v=13'd1146;
6'd7:v=13'd1336;
6'd8:v=13'd1524;
6'd9:v=13'd1712;
6'd10:v=13'd1898;
6'd11:v=13'd2084;
6'd12:v=13'd2268;
6'd13:v=13'd2450;
6'd14:v=13'd2632;
6'd15:v=13'd2812;
6'd16:v=13'd2990;
6'd17:v=13'd3166;
6'd18:v=13'd3340;
6'd19:v=13'd3512;
6'd20:v=13'd3683;
6'd21:v=13'd3851;
6'd22:v=13'd4016;
6'd23:v=13'd4179;
6'd24:v=13'd4340;
6'd25:v=13'd4498;
6'd26:v=13'd4654;
6'd27:v=13'd4806;
6'd28:v=13'd4956;
6'd29:v=13'd5103;
6'd30:v=13'd5246;
6'd31:v=13'd5387;
6'd32:v=13'd5524;
6'd33:v=13'd5658;
6'd34:v=13'd5788;
6'd35:v=13'd5915;
6'd36:v=13'd6039;
6'd37:v=13'd6159;
6'd38:v=13'd6275;
6'd39:v=13'd6387;
6'd40:v=13'd6495;
6'd41:v=13'd6600;
6'd42:v=13'd6701;
6'd43:v=13'd6797;
6'd44:v=13'd6890;
6'd45:v=13'd6978;
6'd46:v=13'd7062;
6'd47:v=13'd7142;
6'd48:v=13'd7217;
6'd49:v=13'd7289;
6'd50:v=13'd7355;
6'd51:v=13'd7418;
6'd52:v=13'd7476;
6'd53:v=13'd7529;
6'd54:v=13'd7578;
6'd55:v=13'd7622;
6'd56:v=13'd7662;
6'd57:v=13'd7697;
6'd58:v=13'd7727;
6'd59:v=13'd7753;
6'd60:v=13'd7774;
6'd61:v=13'd7791;
6'd62:v=13'd7803;
6'd63:v=13'd7810;
endcase wave_lookup=p[7]?-$signed({3'd0,v}):$signed({3'd0,v});end endfunction
function [8:0] percent_gain;
 input [7:0] value;reg [15:0] tmp;
 begin tmp={value,8'd0}+16'd50;percent_gain=tmp/16'd100;end
endfunction
function [31:0] note_increment;
 input [2:0] n;
 begin case(n)
 0:note_increment=23409862;1:note_increment=26276681;2:note_increment=29494578;3:note_increment=31248410;
 4:note_increment=35075155;5:note_increment=39370534;6:note_increment=44191930;7:note_increment=46819716;
 endcase end
endfunction
function [31:0] cue_increment;input [1:0] id;begin case(id)
 0:cue_increment=89478485;1:cue_increment=107374182;
 2:cue_increment=134217728;3:cue_increment=178956971;
endcase end endfunction
wire [31:0] increment=source==1 ? (note_time[14]?32'd78741067:32'd59055800) :
 source==3&&PICTURE_CUE_ENABLED ? cue_increment(cue_id) : note_increment(note);
wire signed [9:0] signed_gain={1'b0,sample_gain};
wire signed [25:0] product_l=sample_l*signed_gain,product_r=sample_r*signed_gain;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  sample_acc<=0;prepare<=0;pipe<=0;valid<=0;phase<=0;note<=0;note_time<=0;
  source<=0;gain<=0;normal_target<=128;alarm_target<=128;sample_gain<=0;
  previous_normal<=50;previous_alarm<=50;wave<=0;sample_l<=0;sample_r<=0;last_l<=0;last_r<=0;left<=0;right<=0;
  cue_remaining<=0;cue_id<=0;pending_cue_id<=0;cue_restart<=0;
 end else begin
  prepare<=tick;
  if(tick)sample_acc<=sample_acc+SAMPLE_RATE-CLOCK_HZ;
  else sample_acc<=sample_acc+SAMPLE_RATE;
  pipe<={pipe[0],prepare};valid<=pipe[1];
  if(normal_volume!=previous_normal)begin normal_target<=percent_gain(normal_volume>100?8'd100:normal_volume);previous_normal<=normal_volume;end
  if(alarm_volume!=previous_alarm)begin alarm_target<=percent_gain(alarm_volume<20?8'd20:alarm_volume>100?8'd100:alarm_volume);previous_alarm<=alarm_volume;end
  if(tick)begin
   sample_gain<=gain;
   if(source!=wanted||(PICTURE_CUE_ENABLED&&cue_restart&&wanted==3))begin
    if(gain!=0)gain<=gain-1'b1;
    else begin
     source<=wanted;phase<=0;
     if(wanted==3&&PICTURE_CUE_ENABLED)begin cue_id<=pending_cue_id;cue_restart<=0;end
    end
   end else if(gain<target)gain<=gain+1'b1;else if(gain>target)gain<=gain-1'b1;
   phase<=phase+increment;
   if((source!=wanted||(PICTURE_CUE_ENABLED&&cue_restart&&wanted==3))&&gain==0)phase<=0;
   if(note_time==23999)begin note_time<=0;note<=note+1'b1;end else note_time<=note_time+1'b1;
   if(external_ready&&external_available)begin last_l<=external_left;last_r<=external_right;end
   if(PICTURE_CUE_ENABLED&&source==3&&wanted==3&&!cue_restart)cue_remaining<=cue_remaining-1'b1;
  end
  // New cues restart through the existing zero-gain switch; WAV credit pauses.
  if(PICTURE_CUE_ENABLED)begin
   if(emergency_mode||(NORMAL_SOUND_CONTROL&&!normal_builtin))begin cue_remaining<=0;cue_restart<=0;end
   else if(picture_commit)begin cue_remaining<=CUE_SAMPLES;pending_cue_id<=picture_id;cue_restart<=1;end
  end
  if(prepare)begin
   wave<=wave_lookup(phase[31:24]);
   sample_l<=source==2?last_l:wave_lookup(phase[31:24]);
   sample_r<=source==2?last_r:wave_lookup(phase[31:24]);
  end
  if(pipe[0])begin left<=product_l[23:0];right<=product_r[23:0];end
 end
end
endmodule
