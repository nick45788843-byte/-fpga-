// Bounded RGB888 BMP reader. A still receives one complete fixed-size frame.
module b_bmp_adaptive_read #(parameter ADAPTIVE_ENABLED=0,COMPACT_HEADERS=0,SOFT_CANCEL_ENABLED=0)(input clk,rst,output ready, input soft_cancel,
 output reg load_error,output reg [7:0] load_error_code,
 input scan_start,scan_resume,input [31:0] scan_start_sector,scan_max_sector,
 input [3:0] scan_target_count,output reg scan_done,scan_found_valid,
 output reg [31:0] scan_found_sector,output reg [3:0] scan_found_total,
 input load_start,input [31:0] load_sector,input sd_init_done,output [3:0] state_code,
 input [15:0] bmp_width,bmp_height,output reg write_req,input write_req_ack,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,input [7:0] sd_sec_read_data,
 input sd_sec_read_data_valid,sd_sec_read_end,output reg bmp_data_wr_en,
 output reg [23:0] bmp_data,output reg [15:0] source_width,source_height,
 output reg [31:0] source_pixels,
 // B108: original BMP header width/height, kept separately (source_* are fitted).
 output reg [12:0] orig_width,orig_height);
localparam IDLE=0,SCAN=1,HEADER=2,WAIT_WRITE=3,PIXELS=4,SCALE_DIVIDE=5;
reg [2:0] state;reg [9:0] rd_cnt;
reg signature0_ok,signature1_ok;
reg [1:0] planes_zero,planes_one,bpp_zero,bpp_twentyfour;
reg [3:0] compression_zero;
reg [31:0] scan_sector,load_sector_latched;
reg [31:0] file_len_full;reg [24:0] file_len_low;reg file_len_high;
wire [31:0] file_len=COMPACT_HEADERS?{file_len_high,6'd0,file_len_low}:file_len_full;
reg [31:0] pixel_offset_full;reg [12:0] pixel_offset_low;reg pixel_offset_high;
wire [31:0] pixel_offset=COMPACT_HEADERS?{pixel_offset_high,18'd0,pixel_offset_low}:pixel_offset_full;
reg [31:0] dib_size_full;reg [12:0] dib_size_low;reg dib_size_high;
wire [31:0] dib_size=COMPACT_HEADERS?{dib_size_high,18'd0,dib_size_low}:dib_size_full;
reg [31:0] width_full;reg [12:0] width_low;reg width_high;
wire [31:0] width=COMPACT_HEADERS?{width_high,18'd0,width_low}:width_full;
reg [31:0] height_full;reg [12:0] height_low;reg height_high;
wire [31:0] height=COMPACT_HEADERS?{height_high,18'd0,height_low}:height_full;
reg [31:0] byte_position,payload_count;
localparam ROW_BYTE_BITS=COMPACT_HEADERS?14:15;
reg [ROW_BYTE_BITS-1:0] row_byte_bounded;wire [14:0] row_byte=row_byte_bounded;
reg [1:0] channel;
localparam ROW_INDEX_BITS=COMPACT_HEADERS?12:13;
reg [ROW_INDEX_BITS-1:0] row_index_bounded;wire [12:0] row_index=row_index_bounded;
localparam ROW_START_OFFSET_BITS=COMPACT_HEADERS?24:32;
reg [ROW_START_OFFSET_BITS-1:0] row_start_offset_bounded;wire [31:0] row_start_offset=row_start_offset_bounded;
reg [31:0] row_end_offset;
// Capture header-derived geometry before the pixel stream starts. This keeps
// the SD address CE path independent of width*3 and stride*height arithmetic.
localparam ROW_BYTES_LATCHED_BITS=COMPACT_HEADERS?14:15;
reg [ROW_BYTES_LATCHED_BITS-1:0] row_bytes_latched_bounded;wire [14:0] row_bytes_latched=row_bytes_latched_bounded;
localparam ROW_STRIDE_LATCHED_BITS=COMPACT_HEADERS?14:15;
reg [ROW_STRIDE_LATCHED_BITS-1:0] row_stride_latched_bounded;wire [14:0] row_stride_latched=row_stride_latched_bounded;
reg [31:0] payload_bytes_latched;
localparam FIT_WIDTH_BITS=COMPACT_HEADERS?10:16;
reg [FIT_WIDTH_BITS-1:0] fit_width_bounded;wire [15:0] fit_width=fit_width_bounded;
localparam FIT_HEIGHT_BITS=COMPACT_HEADERS?9:16;
reg [FIT_HEIGHT_BITS-1:0] fit_height_bounded;wire [15:0] fit_height=fit_height_bounded;
localparam X_PHASE_BITS=COMPACT_HEADERS?12:16;
reg [X_PHASE_BITS-1:0] x_phase_bounded;wire [15:0] x_phase=x_phase_bounded;
localparam Y_PHASE_BITS=COMPACT_HEADERS?12:16;
reg [Y_PHASE_BITS-1:0] y_phase_bounded;wire [15:0] y_phase=y_phase_bounded;
reg [22:0] div_numerator;
localparam DIV_QUOTIENT_BITS=COMPACT_HEADERS?10:23;
reg [DIV_QUOTIENT_BITS-1:0] div_quotient_bounded;wire [22:0] div_quotient=div_quotient_bounded;
localparam DIV_REMAINDER_BITS=COMPACT_HEADERS?12:24;
reg [DIV_REMAINDER_BITS-1:0] div_remainder_bounded;wire [23:0] div_remainder=div_remainder_bounded;
localparam DIV_DIVISOR_BITS=COMPACT_HEADERS?13:16;
reg [DIV_DIVISOR_BITS-1:0] div_divisor_bounded;wire [15:0] div_divisor=div_divisor_bounded;
reg [4:0] div_count;
reg div_wide_source;
reg scanning_pause,request_pending,row_started,row_finished;
(* async_reg=1,preserve=1 *) reg [1:0] write_ack_sync;
wire native_size=width=={16'd0,bmp_width}&&height=={16'd0,bmp_height};
wire half_size=width==({16'd0,bmp_width}>>1)&&height==({16'd0,bmp_height}>>1);
wire quarter_size=width==({16'd0,bmp_width}>>2)&&height==({16'd0,bmp_height}>>2);
wire wide_size=width=={16'd0,bmp_width}&&height==(({16'd0,bmp_height}*3)>>2);
wire half_wide_size=width==({16'd0,bmp_width}>>1)&&height==(({16'd0,bmp_height}*3)>>3);
wire large_size=ADAPTIVE_ENABLED&&bmp_width<=16'd1024&&bmp_height<=16'd1024&&
 width>={16'd0,bmp_width}&&height>={16'd0,bmp_height}&&
 (width!={16'd0,bmp_width}||height!={16'd0,bmp_height})&&width<=32'd4096&&height<=32'd4096;
wire dimensions_ok=width!=0&&height!=0&&(native_size||ADAPTIVE_ENABLED&&(half_size||quarter_size||wide_size||half_wide_size||large_size));
// Fixed-size modes retain nominal target geometry; large sources use bounded
// dimensions plus line/column phase sampling before entering the frame cache.
// Header comparisons and rejection precedence below remain unchanged.
wire [9:0] half_width=bmp_width[9:0]>>1,quarter_width=bmp_width[9:0]>>2;
wire [8:0] half_height=bmp_height[8:0]>>1,quarter_height=bmp_height[8:0]>>2;
wire [8:0] wide_height=({2'd0,bmp_height[8:0]}*11'd3)>>2;
wire [8:0] half_wide_height=({2'd0,bmp_height[8:0]}*11'd3)>>3;
wire [31:0] source_aspect_wide=width[12:0]*bmp_height;
wire [31:0] source_aspect_tall=height[12:0]*bmp_width;
wire contain_width_limited=source_aspect_wide>source_aspect_tall;
wire select_half=ADAPTIVE_ENABLED&&half_size,select_quarter=ADAPTIVE_ENABLED&&quarter_size;
wire select_wide=ADAPTIVE_ENABLED&&wide_size,select_half_wide=ADAPTIVE_ENABLED&&half_wide_size;
wire [21:0] full_pixels=bmp_width[9:0]*bmp_height[8:0],half_pixels=half_width*half_height,
 quarter_pixels=quarter_width*quarter_height,wide_pixels=bmp_width[9:0]*wide_height,half_wide_pixels=half_width*half_wide_height;
wire [21:0] accepted_pixels=native_size?full_pixels:select_half?half_pixels:select_quarter?quarter_pixels:
 select_wide?wide_pixels:select_half_wide?half_wide_pixels:full_pixels;
wire [14:0] full_row=(bmp_width[9:0]<<1)+bmp_width[9:0],half_row=(half_width<<1)+half_width,
 quarter_row=(quarter_width<<1)+quarter_width;
wire [14:0] full_stride=(full_row+3)&15'h7ffc,half_stride=(half_row+3)&15'h7ffc,quarter_stride=(quarter_row+3)&15'h7ffc;
// Constant multiply is expressed as a zero-extended shift-add so the BMP
// header path does not infer a MULT18 for width*3.
wire [16:0] large_row_bytes={1'b0,width[15:0]}+{width[15:0],1'b0};
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [14:0] large_row_bytes_limited,large_row_stride;
wire [14:0] fixed_row_bytes=(select_half||select_half_wide)&&!native_size?half_row:select_quarter&&!native_size?quarter_row:full_row;
wire [14:0] fixed_row_stride=(select_half||select_half_wide)&&!native_size?half_stride:select_quarter&&!native_size?quarter_stride:full_stride;
wire [14:0] row_bytes=large_size?large_row_bytes_limited:fixed_row_bytes;
wire [14:0] row_stride=large_size?large_row_stride:fixed_row_stride;
wire [21:0] full_payload=full_stride*bmp_height[8:0],half_payload=half_stride*half_height,
 quarter_payload=quarter_stride*quarter_height,wide_payload=full_stride*wide_height,half_wide_payload=half_stride*half_wide_height;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [31:0] large_payload_bytes;
wire [21:0] fixed_payload_bytes=native_size?full_payload:select_half?half_payload:select_quarter?quarter_payload:
 select_wide?wide_payload:select_half_wide?half_wide_payload:full_payload;
wire [31:0] payload_bytes=large_size?large_payload_bytes:{10'd0,fixed_payload_bytes};
// The large branch is entered only after dimensions_ok proves both
// dimensions <=4096. Fixed modes equal their selected configured height.
// Reuse the already computed large payload and derive the fixed last row from
// configured geometry; do not multiply unvalidated 32-bit header height again.
wire [31:0] fixed_height=native_size?{16'd0,bmp_height}:select_half?({16'd0,bmp_height}>>1):
 select_quarter?({16'd0,bmp_height}>>2):select_wide?(({16'd0,bmp_height}*3)>>2):
 select_half_wide?(({16'd0,bmp_height}*3)>>3):{16'd0,bmp_height};
wire [31:0] last_row_offset=large_size?large_payload_bytes-{17'd0,large_row_stride}:
 (bmp_width<=16'd1023&&bmp_height<=16'd511)?
 {10'd0,fixed_payload_bytes}-{17'd0,fixed_row_stride}:
 (fixed_height-32'd1)*{17'd0,fixed_row_stride};
// Full-width bounds below retain pixel_offset <=4096 and file_len <=16MiB.
// For every header that can pass those bounds, these operations are exact:
// offset uses at most 13 bits, payload is at most 27 bits by construction,
// and ceil(file_len/512) is at most 32768. Invalid upper-bit headers still
// fail the same original full-width comparisons; no range is accepted anew.
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [27:0] file_end;
wire [25:0] rounded_file_len={1'b0,file_len[24:0]}+26'd511;
wire [32:0] sector_count={17'd0,rounded_file_len[24:9]};
wire [13:0] dib_end=14'd14+{1'b0,dib_size[12:0]};
wire bounds_ok=dib_size>=40&&dib_size<=4096&&(planes_one[0]&&planes_zero[1])&&pixel_offset>=54&&pixel_offset<=4096&&
 {1'b0,pixel_offset[12:0]}>=dib_end&&file_end<=file_len&&file_len!=0&&file_len<=32'd16777216&&
 {1'b0,(state==SCAN?scan_sector:load_sector_latched)}+sector_count-1<={1'b0,scan_max_sector};
wire [7:0] header_error_next=!signature0_ok||!signature1_ok?8'h31:!dimensions_ok?8'h32:
 !(bpp_twentyfour[0]&&bpp_zero[1])?8'h34:!(&compression_zero)?8'h35:!bounds_ok?8'h36:8'd0;
(*preserve=1,allow_backward_retiming=0,allow_forward_retiming=0*) reg [7:0] header_error;
assign ready=state==IDLE;assign state_code={1'b0,state};
// For the bounded fixed target geometry, all accepted fixed and large
// sources have payload == stride*height. The row_index already counts every
// row, and exact 512-byte transfers are enforced independently. Keep the old
// whole-payload counter for target inputs outside that proven identity.
wire use_row_completion=bmp_width<=16'd1023&&bmp_height<=16'd511;
// A full sector advances from its first aligned byte through exactly 512
// positions. Skip only the prefix before this row; after the first accepted
// byte, row_byte and row_finished bound the entire remaining row.
wire pixel_byte=use_row_completion?
 (!row_finished&&(row_started||{1'b0,rd_cnt[8:0]}>={1'b0,row_start_offset[8:0]})):
 (byte_position>=row_start_offset&&byte_position<row_end_offset&&payload_count<payload_bytes_latched);
// Include a valid final byte when end is asserted on the same edge.
wire pixel_valid_now=sd_sec_read_data_valid&&rd_cnt<10'd512;
wire row_finished_at_end=row_finished||
 (pixel_valid_now&&pixel_byte&&row_byte==row_stride_latched-1);
wire [31:0] byte_position_at_end=byte_position+{31'd0,pixel_valid_now};
wire [31:0] payload_count_at_end=payload_count+{31'd0,(pixel_valid_now&&pixel_byte)};
wire [23:0] previous_row_low=row_start_offset[23:0]-{10'd0,row_stride_latched[13:0]};
wire [31:0] previous_row_start=COMPACT_HEADERS?{8'd0,previous_row_low}:row_start_offset-{17'd0,row_stride_latched};
wire [31:0] previous_row_sector={previous_row_start[31:9],9'd0};
wire [16:0] x_phase_sum={1'b0,x_phase}+{1'b0,fit_width};
wire [16:0] y_phase_sum={1'b0,y_phase}+{1'b0,fit_height};
wire large_x_pick=x_phase_sum>={1'b0,width[15:0]};
wire large_y_pick=y_phase_sum>={1'b0,height[15:0]};
// A CMD17 transfer always supplies 512 bus bytes, including file-tail padding.
// Count all active sector bytes, saturating above the only accepted length.
// Include a final valid byte on the same edge as end in the length decision.
wire sector_active=state==SCAN||state==HEADER||state==PIXELS;
wire [10:0] sector_bytes_at_end={1'b0,rd_cnt}+{10'd0,sd_sec_read_data_valid};
wire sector_length_ok=sector_bytes_at_end==11'd512;
wire [23:0] div_trial={div_remainder[22:0],div_numerator[22]};
wire div_step=div_trial>={8'd0,div_divisor};
wire [22:0] div_next_quotient=COMPACT_HEADERS?{13'd0,div_quotient[8:0],div_step}:{div_quotient[21:0],div_step};
always @(posedge clk or posedge rst)begin
 if(rst)write_ack_sync<=0;else if(SOFT_CANCEL_ENABLED&&soft_cancel)write_ack_sync<=0;else write_ack_sync<={write_ack_sync[0],write_req_ack};
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=IDLE;rd_cnt<=0;signature0_ok<=0;signature1_ok<=0;file_len_full<=0;file_len_low<=0;file_len_high<=0;pixel_offset_full<=0;pixel_offset_low<=0;pixel_offset_high<=0;dib_size_full<=0;dib_size_low<=0;dib_size_high<=0;
  width_full<=0;width_low<=0;width_high<=0;height_full<=0;height_low<=0;height_high<=0;planes_zero<=3;planes_one<=0;bpp_zero<=3;bpp_twentyfour<=0;compression_zero<=15;scan_sector<=0;load_sector_latched<=0;
  scan_done<=0;scan_found_valid<=0;scan_found_sector<=0;scan_found_total<=0;scanning_pause<=0;request_pending<=0;row_started<=0;row_finished<=0;
  write_req<=0;sd_sec_read<=0;sd_sec_read_addr<=0;load_error<=0;load_error_code<=0;
  byte_position<=0;payload_count<=0;row_byte_bounded<=0;channel<=0;row_index_bounded<=0;row_start_offset_bounded<=0;row_end_offset<=0;bmp_data_wr_en<=0;bmp_data<=0;
  row_bytes_latched_bounded<=0;row_stride_latched_bounded<=0;payload_bytes_latched<=0;
  large_row_bytes_limited<=0;large_row_stride<=0;large_payload_bytes<=0;file_end<=0;header_error<=0;
  source_width<=0;source_height<=0;source_pixels<=0;orig_width<=0;orig_height<=0;
  fit_width_bounded<=0;fit_height_bounded<=0;x_phase_bounded<=0;y_phase_bounded<=0;div_numerator<=0;div_quotient_bounded<=0;
  div_remainder_bounded<=0;div_divisor_bounded<=0;div_count<=0;div_wide_source<=0;
  end else if(SOFT_CANCEL_ENABLED&&soft_cancel)begin
   // Abort private loading while retaining catalog progress. A scan sector
   // interrupted before publication is retried; a published next sector stays.
   state<=IDLE;rd_cnt<=0;sd_sec_read<=0;request_pending<=0;write_req<=0;
   load_error<=0;load_error_code<=0;scan_found_valid<=0;bmp_data_wr_en<=0;
   row_started<=0;row_finished<=0;channel<=0;
   if(!scan_done)scanning_pause<=1;
  end else begin
   load_error<=0;scan_found_valid<=0;bmp_data_wr_en<=0;
  if(request_pending)begin sd_sec_read<=1;request_pending<=0;end
  if(sector_active&&sd_sec_read_data_valid&&rd_cnt<10'd513)rd_cnt<=rd_cnt+1'b1;
  if(sector_active&&sd_sec_read_end)rd_cnt<=0;
  if((state==SCAN||state==HEADER)&&sd_sec_read_data_valid&&rd_cnt<10'd512)begin
   // Each little-endian header field is consumed only after the complete
   // sector. Shift complete fields through one shared byte enable instead of
   // synthesizing variable part-select writes and per-lane update enables.
   // All geometry fields finish by byte25 and format fields by byte33.
   // Compute during the remaining header bytes, without delaying public state
   // or accepting a short sector. A valid512-byte sector always includes all
   // five stages; reset/cancel and the original length guard remain dominant.
   case(rd_cnt)
    34:large_row_bytes_limited<=large_row_bytes[14:0];
    35:large_row_stride<=(large_row_bytes_limited+15'd3)&15'h7ffc;
    36:large_payload_bytes<=large_row_stride[13:0]*height[12:0];
    37:file_end<={15'd0,pixel_offset[12:0]}+{1'b0,payload_bytes[26:0]};
    38:header_error<=header_error_next;
    default:;
   endcase
   case(rd_cnt)
    0:signature0_ok<=sd_sec_read_data=="B";1:signature1_ok<=sd_sec_read_data=="M";
    2,3,4,5:if(!COMPACT_HEADERS)file_len_full<={sd_sec_read_data,file_len_full[31:8]};
else case(rd_cnt)
 2:begin file_len_low[7:0]<=sd_sec_read_data;file_len_high<=0; end
 3:begin file_len_low[15:8]<=sd_sec_read_data; end
 4:begin file_len_low[23:16]<=sd_sec_read_data; end
 5:begin file_len_low[24:24]<=sd_sec_read_data[0:0];file_len_high<=file_len_high||(|sd_sec_read_data[7:1]); end
endcase
    10,11,12,13:if(!COMPACT_HEADERS)pixel_offset_full<={sd_sec_read_data,pixel_offset_full[31:8]};
else case(rd_cnt)
 10:begin pixel_offset_low[7:0]<=sd_sec_read_data;pixel_offset_high<=0; end
 11:begin pixel_offset_low[12:8]<=sd_sec_read_data[4:0];pixel_offset_high<=pixel_offset_high||(|sd_sec_read_data[7:5]); end
 12:begin pixel_offset_high<=pixel_offset_high|||sd_sec_read_data; end
 13:begin pixel_offset_high<=pixel_offset_high|||sd_sec_read_data; end
endcase
    14,15,16,17:if(!COMPACT_HEADERS)dib_size_full<={sd_sec_read_data,dib_size_full[31:8]};
else case(rd_cnt)
 14:begin dib_size_low[7:0]<=sd_sec_read_data;dib_size_high<=0; end
 15:begin dib_size_low[12:8]<=sd_sec_read_data[4:0];dib_size_high<=dib_size_high||(|sd_sec_read_data[7:5]); end
 16:begin dib_size_high<=dib_size_high|||sd_sec_read_data; end
 17:begin dib_size_high<=dib_size_high|||sd_sec_read_data; end
endcase
    18,19,20,21:if(!COMPACT_HEADERS)width_full<={sd_sec_read_data,width_full[31:8]};
else case(rd_cnt)
 18:begin width_low[7:0]<=sd_sec_read_data;width_high<=0; end
 19:begin width_low[12:8]<=sd_sec_read_data[4:0];width_high<=width_high||(|sd_sec_read_data[7:5]); end
 20:begin width_high<=width_high|||sd_sec_read_data; end
 21:begin width_high<=width_high|||sd_sec_read_data; end
endcase
    22,23,24,25:if(!COMPACT_HEADERS)height_full<={sd_sec_read_data,height_full[31:8]};
else case(rd_cnt)
 22:begin height_low[7:0]<=sd_sec_read_data;height_high<=0; end
 23:begin height_low[12:8]<=sd_sec_read_data[4:0];height_high<=height_high||(|sd_sec_read_data[7:5]); end
 24:begin height_high<=height_high|||sd_sec_read_data; end
 25:begin height_high<=height_high|||sd_sec_read_data; end
endcase
    26,27:begin planes_zero<={sd_sec_read_data==0,planes_zero[1]};planes_one<={sd_sec_read_data==1,planes_one[1]};end
    28,29:begin bpp_zero<={sd_sec_read_data==0,bpp_zero[1]};bpp_twentyfour<={sd_sec_read_data==24,bpp_twentyfour[1]};end
    30,31,32,33:compression_zero<={sd_sec_read_data==0,compression_zero[3:1]};
    default:;
   endcase
  end
  case(state)
   IDLE:begin
    write_req<=0;sd_sec_read<=0;rd_cnt<=0;
    if(sd_init_done&&scan_start)begin
     scan_sector<=scan_start_sector;scan_found_total<=0;scan_done<=0;scanning_pause<=0;
     sd_sec_read_addr<=scan_start_sector;sd_sec_read<=1;state<=SCAN;
    end else if(sd_init_done&&scan_resume&&scanning_pause&&!scan_done)begin
     scanning_pause<=0;sd_sec_read_addr<=scan_sector;sd_sec_read<=1;state<=SCAN;
    end else if(sd_init_done&&load_start)begin
     load_sector_latched<=load_sector;sd_sec_read_addr<=load_sector;sd_sec_read<=1;state<=HEADER;
    end
   end
   SCAN:if(sd_sec_read_end&&sector_length_ok)begin
    sd_sec_read<=0;rd_cnt<=0;
    if(header_error==0)begin
     scan_found_valid<=1;scan_found_sector<=scan_sector;scan_found_total<=scan_found_total+1'b1;
     scan_sector<=scan_sector+sector_count[31:0];scanning_pause<=1;state<=IDLE;
     if(scan_found_total+1>=scan_target_count||{1'b0,scan_sector}+sector_count>{1'b0,scan_max_sector})scan_done<=1;
    end else if(scan_sector>=scan_max_sector)begin scan_done<=1;state<=IDLE;end
    else begin scan_sector<=scan_sector+1'b1;sd_sec_read_addr<=scan_sector+1'b1;request_pending<=1;end
   end
   HEADER:if(sd_sec_read_end&&sector_length_ok)begin
    sd_sec_read<=0;rd_cnt<=0;orig_width<=width[12:0];orig_height<=height[12:0];
    if(header_error!=0)begin load_error<=1;load_error_code<=header_error;state<=IDLE;end
    else if(large_size)begin
     row_bytes_latched_bounded<=row_bytes;row_stride_latched_bounded<=row_stride;payload_bytes_latched<=payload_bytes;
     row_start_offset_bounded<=pixel_offset+last_row_offset;
     div_wide_source<=contain_width_limited;
     div_numerator<=contain_width_limited?source_aspect_tall[22:0]:source_aspect_wide[22:0];
     div_divisor_bounded<=contain_width_limited?width[15:0]:height[15:0];
     div_quotient_bounded<=0;div_remainder_bounded<=0;div_count<=0;state<=SCALE_DIVIDE;
    end else begin
     row_bytes_latched_bounded<=row_bytes;row_stride_latched_bounded<=row_stride;payload_bytes_latched<=payload_bytes;
     row_start_offset_bounded<=pixel_offset+last_row_offset;
     source_width<=width[15:0];source_height<=height[15:0];source_pixels<=accepted_pixels;
     fit_width_bounded<=width[15:0];fit_height_bounded<=height[15:0];write_req<=1;state<=WAIT_WRITE;
    end
   end
   SCALE_DIVIDE:begin
    div_numerator<={div_numerator[21:0],1'b0};
    div_remainder_bounded<=div_step?div_trial-{8'd0,div_divisor}:div_trial;
    div_quotient_bounded<=div_next_quotient;
    if(div_count==5'd22)begin
     if(div_next_quotient==0)begin load_error<=1;load_error_code<=8'h32;state<=IDLE;end
      else if(div_wide_source)begin
      fit_width_bounded<=bmp_width;fit_height_bounded<=div_next_quotient[15:0];
      source_width<=bmp_width;source_height<=div_next_quotient[15:0];
      source_pixels<={16'd0,bmp_width}*{16'd0,div_next_quotient[15:0]};
      end else begin
      fit_width_bounded<=div_next_quotient[15:0];fit_height_bounded<=bmp_height;
      source_width<=div_next_quotient[15:0];source_height<=bmp_height;
      source_pixels<={16'd0,div_next_quotient[15:0]}*{16'd0,bmp_height};
     end
     write_req<=1;state<=WAIT_WRITE;
    end else div_count<=div_count+1'b1;
   end
   WAIT_WRITE:if(write_ack_sync[1])begin
    write_req<=0;row_index_bounded<=height[12:0]-13'd1;row_started<=0;row_finished<=0;
     row_end_offset<=row_start_offset+{17'd0,row_stride_latched};
     sd_sec_read_addr<=load_sector_latched+(row_start_offset>>9);sd_sec_read<=1;state<=PIXELS;
     byte_position<={row_start_offset[31:9],9'd0};payload_count<=0;row_byte_bounded<=0;channel<=0;
    x_phase_bounded<=width[15:0]-fit_width;y_phase_bounded<=height[15:0]-fit_height;
   end
   PIXELS:begin
    if(sd_sec_read_data_valid&&rd_cnt<10'd512)begin
     if(!use_row_completion)byte_position<=byte_position+1'b1;
     if(pixel_byte)begin
      if(!use_row_completion)payload_count<=payload_count+1'b1;
      else row_started<=1;
       if(row_byte==row_stride_latched-1)begin
       row_byte_bounded<=0;if(use_row_completion)row_finished<=1;
       if(large_size)begin
        x_phase_bounded<=width[15:0]-fit_width;
        y_phase_bounded<=large_y_pick?y_phase_sum-height[15:0]:y_phase_sum[15:0];
       end
      end else row_byte_bounded<=row_byte+1'b1;
       if(row_byte<row_bytes_latched)begin
       case(channel)
        0:bmp_data[7:0]<=sd_sec_read_data;
        1:bmp_data[15:8]<=sd_sec_read_data;
        2:begin bmp_data[23:16]<=sd_sec_read_data;
         if(!large_size||large_x_pick&&large_y_pick)bmp_data_wr_en<=1;
        end
        default:;
       endcase
       if(large_size&&channel==2&&row_byte!=row_stride_latched-1)
        x_phase_bounded<=large_x_pick?x_phase_sum-width[15:0]:x_phase_sum;
       channel<=channel==2?2'd0:channel+1'b1;
      end
     end
    end
    if(sd_sec_read_end)begin
     sd_sec_read<=0;
     if(use_row_completion?!row_finished_at_end:byte_position_at_end<row_end_offset)begin
      if(sd_sec_read_addr>=scan_max_sector)begin load_error<=1;load_error_code<=8'h36;state<=IDLE;end
      else begin sd_sec_read_addr<=sd_sec_read_addr+1'b1;byte_position<={byte_position_at_end[31:9],9'd0};request_pending<=1;end
      end else if(use_row_completion?row_index==0:payload_count_at_end==payload_bytes_latched)state<=IDLE;
     else if(row_index==0)begin load_error<=1;load_error_code<=8'h36;state<=IDLE;end
     else begin
       row_index_bounded<=row_index-1'b1;row_started<=0;row_finished<=0;row_start_offset_bounded<=previous_row_start;row_end_offset<=row_start_offset;
      row_byte_bounded<=0;channel<=0;sd_sec_read_addr<=load_sector_latched+(previous_row_start>>9);
      byte_position<=previous_row_sector;request_pending<=1;
     end
    end
   end
   default:state<=IDLE;
  endcase
  // A malformed transfer cannot advance a row/scan, publish another request,
  // or report a successful frame. Earlier streamed pixels remain private to
  // the caller's operation and must be canceled on this existing error path.
  if(sector_active&&sd_sec_read_end&&!sector_length_ok)begin
   state<=IDLE;sd_sec_read<=0;request_pending<=0;write_req<=0;
   bmp_data_wr_en<=0;load_error<=1;load_error_code<=8'h36;
   if(state==SCAN)begin scan_done<=1;scan_found_valid<=0;scanning_pause<=0;end
  end
 end
end
endmodule
