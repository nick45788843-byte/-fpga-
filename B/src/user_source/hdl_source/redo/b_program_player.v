// TF program metadata/font cache. Complete header/entry CRC before SPI publish.
// One whole entry stays immutable through every ACK/retry and actual wire done.
module b_program_player #(parameter CLOCK_HZ=50000000,BASE_LBA=131072,REFRESH_SUPPORT=0)(
 input clk,rst_n,initialized,reload,pause,enabled,display_valid,input [3:0] image_code,
 output reg catalog_ready,catalog_valid,output reg [3:0] catalog_count,
 output sd_request,input sd_ready,output [31:0] sd_lba,
 input sd_valid,input [7:0] sd_byte,input sd_done,sd_error,output sd_cancel,
 output grant_needed,input grant_valid,input [31:0] granted_uid,input grant_permission,
 output tx_valid,input tx_ready,output [7:0] tx_kind,output [6:0] tx_count,
 output [15:0] tx_sequence,tx_tag,output [31:0] tx_value,
 input [5:0] tx_address,output [31:0] tx_word,input tx_done,
 input reply_valid,input [255:0] reply_fragment,output drained,output reg [7:0] error_code,
 input [1:0] play_mode,input [31:0] period_ms,input refresh,output prepared);
localparam CAT_REQ=0,CAT_READ=1,CAT_CHECK=2,IDLE=3,ENTRY_REQ=4,ENTRY_READ=5,ENTRY_CHECK=6,
 GRANT_LOW=7,GRANT=8,SEND=9,WAIT_TX=10,GAP=11,WAIT_ACK=12,CANCEL=13,DIV_INIT=14,DIVIDE=15;
reg [3:0] state;reg [11:0] byte_index;reg [2:0] sector;
reg [31:0] magic,entry_magic;reg [7:0] version,number;reg [15:0] size_field,crc,stored_crc;
reg [23:0] assembled;wire [31:0] read_data;
reg [3:0] target,completed_image,failed_image;reg [31:0] uid;
reg refresh_pending;
reg [1:0] phase;reg polling,inflight,got_ack;reg [7:0] ack_error;
reg [11:0] sent_bytes;reg [6:0] payload_words;reg [15:0] packet_number;
localparam TIMER_BITS=$clog2(CLOCK_HZ/2+1);
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [TIMER_BITS-1:0] packet_timer;reg [7:0] gap;reg [3:0] poll_count;
reg [7:0] glyph_count;reg [31:0] entry_frames,duration_samples,captured_period,completed_period;
reg [1:0] captured_mode,completed_mode,divide_style;reg [5:0] divide_bit;
assign prepared=catalog_valid&&display_valid&&completed_image!=0&&state==IDLE&&completed_image==image_code&&completed_mode==play_mode&&
 (play_mode==0||completed_period==period_ms)&&(!REFRESH_SUPPORT||(!refresh_pending&&!refresh));
reg [31:0] dividend,quotient,rate16,rate32,rate64;reg [12:0] remainder,denominator;
reg [7:0] entry_id,entry_audio,raw_length,utf_min,utf_max;reg [1:0] utf_remaining;reg [6:0] utf_count;reg utf_bad;
wire [13:0] remainder_next={remainder,dividend[31]};
wire subtract_divisor=remainder_next>={1'b0,denominator};
wire [31:0] quotient_next={quotient[30:0],subtract_divisor};
wire [31:0] reply_uid={reply_fragment[199:192],reply_fragment[207:200],reply_fragment[215:208],reply_fragment[223:216]};
wire [15:0] reply_tag={reply_fragment[231:224],reply_fragment[239:232]};
function [15:0] crcbyte;input [15:0] old;input [7:0] data;reg [7:0] x;
begin x=old[15:8]^data;crcbyte={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
assign sd_request=(state==CAT_REQ||state==ENTRY_REQ)&&initialized&&!pause&&!reload;
assign sd_lba=state==CAT_REQ?BASE_LBA:BASE_LBA+8+({28'd0,target}-1)*8+sector;
assign sd_cancel=pause||reload;
assign grant_needed=((state==GRANT&&grant_permission)||state==SEND||state==WAIT_TX||state==GAP||state==WAIT_ACK)&&!pause&&!reload;
assign tx_valid=state==SEND&&!pause&&!reload;
assign tx_kind=polling?8'd1:phase==0?8'h56:phase==1?8'h57:phase==2?8'h58:8'h5a;
assign tx_count=polling?7'd0:phase==1?payload_words+7'd1:7'd1;
assign tx_sequence=16'hffff;assign tx_tag=packet_number;
assign tx_value=polling?32'd0:phase==1?{20'd0,sent_bytes}:32'd2264;
wire [9:0] source_index=(sent_bytes>>2)+(tx_address==0?6'd0:tx_address-6'd1);
assign tx_word=tx_address==0?uid:read_data;
assign drained=(state==IDLE||state==CAT_REQ||state==CANCEL)&&!inflight&&!sd_request;
// Explicit native RAM prevents the entry buffer becoming 32768 flip-flops
// when SD writes and the rate-override read mux are optimized together.
wire entry_we=state==ENTRY_READ&&sd_valid&&byte_index[1:0]==3&&!pause&&!reload;
wire [15:0] entry_low,entry_high;reg [1:0] rate_select;
always @(posedge clk)rate_select<=source_index==3?2'd1:source_index==4?2'd2:source_index==5?2'd3:2'd0;
assign read_data=rate_select==1?rate16:rate_select==2?rate32:rate_select==3?rate64:{entry_high,entry_low};
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) entry_lower(
 .doa(),.dia(assembled[15:0]),.addra({1'b0,byte_index[11:2]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(entry_we),.clka(clk),.rsta(1'b0),.ocea(1'b1),
 .dob(entry_low),.dib(16'd0),.addrb({1'b0,source_index}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) entry_upper(
 .doa(),.dia({sd_byte,assembled[23:16]}),.addra({1'b0,byte_index[11:2]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(entry_we),.clka(clk),.rsta(1'b0),.ocea(1'b1),
 .dob(entry_high),.dib(16'd0),.addrb({1'b0,source_index}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
task send_packet;input [1:0] next_phase;input [11:0] offset;input [15:0] number_value;begin
 phase<=next_phase;sent_bytes<=offset;packet_number<=number_value;payload_words<=2264-offset>=252?63:(2264-offset)>>2;
 polling<=0;poll_count<=0;got_ack<=0;state<=SEND;
end endtask
// Only local registered state and ACK feed the private deadline counter.
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)packet_timer<=0;
 else if(state==GRANT||state==WAIT_ACK&&got_ack)packet_timer<=0;
 else if((state==SEND||state==WAIT_TX||state==GAP||state==WAIT_ACK)&&packet_timer<CLOCK_HZ/2)packet_timer<=packet_timer+1'b1;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  refresh_pending<=0;state<=CAT_REQ;byte_index<=0;sector<=0;magic<=0;entry_magic<=0;version<=0;number<=0;size_field<=0;crc<=16'hffff;stored_crc<=0;assembled<=0;
  catalog_ready<=0;catalog_valid<=0;catalog_count<=4;target<=0;completed_image<=0;failed_image<=0;uid<=0;phase<=0;polling<=0;inflight<=0;got_ack<=0;ack_error<=0;
  sent_bytes<=0;payload_words<=0;packet_number<=0;gap<=0;poll_count<=0;error_code<=0;
  glyph_count<=0;entry_frames<=0;duration_samples<=0;captured_period<=0;completed_period<=0;captured_mode<=0;completed_mode<=0;
  divide_style<=0;divide_bit<=0;dividend<=0;quotient<=0;rate16<=1;rate32<=1;rate64<=1;remainder<=0;denominator<=640;
  entry_id<=0;entry_audio<=0;raw_length<=0;utf_min<=8'h80;utf_max<=8'hbf;utf_remaining<=0;utf_count<=0;utf_bad<=0;
 end else begin
  if(tx_valid&&tx_ready)inflight<=1;
  if(inflight&&tx_done)inflight<=0;

  if(reply_valid&&reply_fragment[255:248]==8'hf7&&reply_uid==uid&&reply_tag==packet_number)begin got_ack<=1;ack_error<=reply_fragment[247:240];end
  if((state==CAT_READ||state==ENTRY_READ)&&sd_valid)begin
   byte_index<=byte_index+1'b1;
   if(byte_index<(state==CAT_READ?510:4094))crc<=crcbyte(crc,sd_byte);
   else if(byte_index==(state==CAT_READ?510:4094))stored_crc[7:0]<=sd_byte;
   else stored_crc[15:8]<=sd_byte;
   case(byte_index[1:0])0:assembled[7:0]<=sd_byte;1:assembled[15:8]<=sd_byte;2:assembled[23:16]<=sd_byte;endcase
   if(state==CAT_READ)case(byte_index)
    0,1,2,3:magic<={magic[23:0],sd_byte};4:version<=sd_byte;5:number<=sd_byte;6:size_field[7:0]<=sd_byte;7:size_field[15:8]<=sd_byte;
   endcase
   if(state==ENTRY_READ&&byte_index<4)entry_magic<={entry_magic[23:0],sd_byte};
   if(state==ENTRY_READ&&byte_index==6)glyph_count<=sd_byte;
   if(state==ENTRY_READ&&byte_index==4)entry_id<=sd_byte;
   if(state==ENTRY_READ&&byte_index==5)entry_audio<=sd_byte;
   if(state==ENTRY_READ&&byte_index==7)raw_length<=sd_byte;
   if(state==ENTRY_READ&&byte_index>=8&&byte_index<12)entry_frames[(byte_index-8)*8+:8]<=sd_byte;
   if(state==ENTRY_READ&&byte_index>=24&&byte_index<24+raw_length)begin
    if(utf_remaining!=0)begin
     if(sd_byte<utf_min||sd_byte>utf_max)utf_bad<=1;
     utf_min<=8'h80;utf_max<=8'hbf;utf_remaining<=utf_remaining-1'b1;
     if(utf_remaining==1)utf_count<=utf_count+1'b1;
    end else if(sd_byte>=8'h20&&sd_byte<8'h7f)utf_count<=utf_count+1'b1;
    else if(sd_byte>=8'hc2&&sd_byte<=8'hdf)begin utf_remaining<=1;utf_min<=8'h80;utf_max<=8'hbf;end
    else if(sd_byte>=8'he0&&sd_byte<=8'hef)begin utf_remaining<=2;utf_min<=sd_byte==8'he0 ? 8'ha0:8'h80;utf_max<=sd_byte==8'hed ? 8'h9f:8'hbf;end
    else if(sd_byte>=8'hf0&&sd_byte<=8'hf4)begin utf_remaining<=3;utf_min<=sd_byte==8'hf0 ? 8'h90:8'h80;utf_max<=sd_byte==8'hf4 ? 8'h8f:8'hbf;end
    else utf_bad<=1;
   end
  end
  case(state)
   CAT_REQ:if(sd_request&&sd_ready)begin byte_index<=0;magic<=0;crc<=16'hffff;stored_crc<=0;state<=CAT_READ;end
   CAT_READ:if(sd_error)begin catalog_ready<=1;catalog_valid<=0;catalog_count<=4;error_code<=8'h5a;state<=IDLE;end
    else if(sd_done)state<=CAT_CHECK;
   CAT_CHECK:begin
    catalog_ready<=1;catalog_valid<=byte_index==512&&magic=="CNPL"&&version==2&&number>=1&&number<=8&&size_field==4096&&crc==stored_crc;
    catalog_count<=byte_index==512&&magic=="CNPL"&&version==2&&number>=1&&number<=8&&size_field==4096&&crc==stored_crc?number[3:0]:4'd4;
    error_code<=magic=="CNPL"&&crc!=stored_crc?8'h5a:0;state<=IDLE;
   end
   IDLE:if(REFRESH_SUPPORT&&refresh_pending)begin completed_image<=0;failed_image<=0;refresh_pending<=0;end
    else if(!catalog_ready)state<=CAT_REQ;
    else if(enabled&&catalog_valid&&display_valid&&image_code!=0&&image_code<=catalog_count&&
      (image_code!=completed_image||play_mode!=completed_mode||(play_mode!=0&&period_ms!=completed_period))&&image_code!=failed_image)begin
     target<=image_code;sector<=0;byte_index<=0;crc<=16'hffff;stored_crc<=0;entry_magic<=0;state<=ENTRY_REQ;
     utf_bad<=0;utf_count<=0;utf_remaining<=0;utf_min<=8'h80;utf_max<=8'hbf;
    end
   ENTRY_REQ:if(sd_request&&sd_ready)state<=ENTRY_READ;
   ENTRY_READ:if(sd_error)begin error_code<=8'h5a;failed_image<=target;state<=IDLE;end
    else if(sd_done)begin
     if(sector==7)state<=ENTRY_CHECK;
     else begin sector<=sector+1'b1;state<=ENTRY_REQ;end
    end
   ENTRY_CHECK:if(byte_index!=0||entry_magic!="CNP2"||crc!=stored_crc||glyph_count>64||raw_length>192||entry_frames==0||
     entry_id!=target||entry_audio!=target+8'd4||utf_bad||utf_remaining!=0||utf_count!=glyph_count)begin
     error_code<=8'h5a;failed_image<=target;state<=IDLE;
    end else begin
     captured_mode<=play_mode;captured_period<=period_ms;divide_style<=0;
     duration_samples<=play_mode==0?entry_frames:(period_ms<<5)+(period_ms<<4);state<=DIV_INIT;
    end
   DIV_INIT:begin
    dividend<=duration_samples;quotient<=0;remainder<=0;divide_bit<=0;
    denominator<=13'd640+({5'd0,glyph_count}<<(4+divide_style));state<=DIVIDE;
   end
   DIVIDE:begin
    dividend<=dividend<<1;quotient<=quotient_next;
    remainder<=subtract_divisor?remainder_next-denominator:remainder_next;
    if(divide_bit==31)begin
     case(divide_style)0:rate16<=quotient_next==0?1:quotient_next;1:rate32<=quotient_next==0?1:quotient_next;default:rate64<=quotient_next==0?1:quotient_next;endcase
     if(divide_style==2)state<=GRANT_LOW;else begin divide_style<=divide_style+1'b1;state<=DIV_INIT;end
    end else divide_bit<=divide_bit+1'b1;
   end
   GRANT_LOW:if(!grant_valid)state<=GRANT;
   GRANT:if(grant_permission&&grant_valid&&granted_uid!=0)begin uid<=granted_uid;error_code<=0;send_packet(0,0,0);end
   SEND:if(tx_valid&&tx_ready)state<=WAIT_TX;
   WAIT_TX:if(tx_done)begin gap<=0;state<=WAIT_ACK;end
   WAIT_ACK:if(got_ack)begin
     if(ack_error!=0)begin error_code<=ack_error;failed_image<=target;state<=IDLE;end
     else if(phase==3)begin completed_image<=target;completed_mode<=captured_mode;completed_period<=captured_period;failed_image<=0;state<=IDLE;end
     else if(phase==0)send_packet(1,0,packet_number+1'b1);
     else if(phase==1)begin
      if(sent_bytes+payload_words*4==2264)send_packet(2,2264,packet_number+1'b1);
      else send_packet(1,sent_bytes+payload_words*4,packet_number+1'b1);
     end else send_packet(3,2264,packet_number+1'b1);
    end else if(packet_timer>=CLOCK_HZ/2-1)begin error_code<=8'h5b;failed_image<=target;state<=IDLE;end
    else begin
     if(gap==127)begin
      gap<=0;
      // Eight short polls, then retry the same retained data/tag.
      if(poll_count==7)begin poll_count<=0;polling<=0;end
      else begin poll_count<=poll_count+1'b1;polling<=1;end
      state<=SEND;
     end else gap<=gap+1'b1;
    end
   CANCEL:if(!inflight&&!pause&&!reload)state<=catalog_ready?IDLE:CAT_REQ;
  endcase
  if(REFRESH_SUPPORT&&refresh)refresh_pending<=1;
  if(pause||reload)begin
   refresh_pending<=0;
   state<=CANCEL;completed_image<=0;failed_image<=0;got_ack<=0;
   if(reload)begin catalog_ready<=0;catalog_valid<=0;catalog_count<=4;end
  end
 end
end
endmodule

// Metadata shares only the image sector channel. Audio retains its existing
// urgent/fair physical arbiter. A pending image request cannot be overwritten.
module b_program_sd_mux(input clk,rst_n,pause,physical_drained,
 input image_request,input [31:0] image_lba,input image_cancel,
 output image_valid,image_done,image_error,output [7:0] image_byte,
 input meta_request,output meta_ready,input [31:0] meta_lba,input meta_cancel,
 output meta_valid,meta_done,meta_error,output [7:0] meta_byte,
 output reg request,output reg [31:0] lba,output cancel,
 input valid,input done,error,input [7:0] data,output drained);
reg [1:0] state;reg pending;reg [31:0] pending_lba;
assign meta_ready=state==0&&!pending&&!image_request&&!pause;
assign cancel=pause||(state==1?image_cancel:state==2?meta_cancel:1'b0);
assign image_valid=state==1&&valid&&!image_cancel;assign image_done=state==1&&done;assign image_error=state==1&&error;assign image_byte=data;
assign meta_valid=state==2&&valid&&!meta_cancel;assign meta_done=state==2&&done;assign meta_error=state==2&&error;assign meta_byte=data;
assign drained=state==0&&!pending&&!request;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=0;pending<=0;pending_lba<=0;request<=0;lba<=0;end
 else begin
  request<=0;
  if(image_request&&!image_cancel&&!pause)begin pending<=1;pending_lba<=image_lba;end
  if(image_cancel||pause)pending<=0;
  if(state==0&&!pause)begin
   if((pending||image_request)&&!image_cancel)begin
    lba<=image_request?image_lba:pending_lba;request<=1;state<=1;pending<=0;
   end else if(meta_request&&meta_ready&&!meta_cancel)begin lba<=meta_lba;request<=1;state<=2;end
  end else if(done||error||(cancel&&physical_drained))state<=0;
 end
end
endmodule

