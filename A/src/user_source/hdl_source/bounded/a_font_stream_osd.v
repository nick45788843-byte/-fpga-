// Four single-bank font regions. Small 16px glyphs use 9K RAM; 32px and 64px
// glyphs share an 8KiB 32K-RAM pool. All reads are synchronous. A job hides
// its region from job_start until its frame-boundary commit, so a partially
// written region is never displayed; a failed job leaves the region blank.
module a_font_stream_osd(
 input clk,rst_n,input [9:0] x,input [8:0] y,input emergency,
 input [39:0] subtitle_style,input legacy_title_present,
 input job_start,input [1:0] job_target,input job_bank,input [1:0] job_size,
 input [6:0] job_glyph_count,input [7:0] job_utf8_bytes,
 input font_we,input [14:0] font_address,input [7:0] font_data,input font_bank,
 input raw_we,input [7:0] raw_address,raw_data,input raw_bank,
 input glyph_meta_valid,input [5:0] glyph_meta_index,input [15:0] glyph_meta_codepoint,input [1:0] glyph_meta_size,
 input commit_valid,input commit_bank,input [6:0] commit_count,input [1:0] commit_size,commit_target,
 output pixel_valid,output pixel,output [23:0] pixel_colour,
 output [23:0] pixel_background,output [2:0] pixel_background_alpha,output [7:0] render_error,
 output [3:0] active_regions,input frame_boundary);

 // Separate power-of-two stores: 64 native 16px subtitle glyphs and
 // 32 native 16px/32px title glyphs. Title size is committed with its pixels.
 (* force_ram=1,ram_style="bram_9k" *) reg [7:0] small_font[0:2047];
 (* force_ram=1,ram_style="bram_9k" *) reg [7:0] title_font[0:4095];
 // 0..4095 emergency 64px (8*512), 4096..8191 large 32px (32*128).
 (* force_ram=1,ram_style="bram_32k" *) reg [7:0] large_font[0:8191];
 reg [3:0] front_valid;
 reg [1:0] normal_override;
 assign active_regions={front_valid[3:2],normal_override};
 reg [6:0] front_chars[0:3];
 reg [1:0] job_target_q,job_size_q;
 reg job_bank_q;
 reg [6:0] job_glyph_count_q,meta_count;
 reg [7:0] job_utf8_bytes_q;
 reg [1:0] utf8_need;
 reg [7:0] utf8_lead,render_error_sticky;
 reg [8:0] raw_bytes_seen;
 integer i;

 wire raw_cont=raw_data[7:6]==2'b10;
 wire raw_lead2=raw_data>=8'hc2&&raw_data<=8'hdf;
 wire raw_lead3=raw_data>=8'he0&&raw_data<=8'hef;
 wire bad_first=utf8_need==2&&raw_cont&&((utf8_lead==8'he0&&raw_data<8'ha0)||(utf8_lead==8'hed&&raw_data>=8'ha0));
 wire [1:0] need_after=utf8_need==0?(raw_lead2?1:raw_lead3?2:0):(utf8_need==2&&raw_cont&&!bad_first?1:0);
 assign render_error=render_error_sticky!=0?render_error_sticky:
   (utf8_need!=0||raw_bytes_seen!=job_utf8_bytes_q?8'ha3:(meta_count!=job_glyph_count_q?8'ha4:8'd0));

 // The same ordinary style controls streamed and legacy subtitles. Native
 // target 0 stays 16px in RAM; integer display scaling adds no glyph storage.
 // A fixed caption uses at most two centered rows. Above 32 glyphs it uses
 // 16px so all 64 glyphs remain visible. Scrolling keeps the requested size.
 reg [39:0] subtitle_style_frame;
 reg [11:0] subtitle_scroll;
 reg subtitle_emergency_frame,subtitle_restart_pending;
 reg title_size_frame;
 wire sub_scrolling=subtitle_style_frame[3];
 wire sub_zoom=sub_scrolling?subtitle_style_frame[0]:(front_chars[0]>32?1'b0:subtitle_style_frame[0]);
 wire [6:0] sub_capacity=sub_zoom?7'd16:7'd32;
 wire sub_two_rows=!sub_scrolling&&front_chars[0]>sub_capacity;
 wire [6:0] sub_columns=sub_scrolling?sub_capacity:sub_two_rows?(front_chars[0]+7'd1)>>1:front_chars[0];
 wire [6:0] sub_height=sub_zoom?7'd32:7'd16;
 wire [7:0] sub_total_height=sub_two_rows?{sub_height,1'b0}:{1'b0,sub_height};
 wire [10:0] sub_width=sub_zoom?{sub_columns,5'd0}:{1'b0,sub_columns,4'd0};
 wire [11:0] subtitle_extent=sub_zoom?{front_chars[0],5'd0}:{1'b0,front_chars[0],4'd0};
 // At least one viewport plus a gap: short text appears only once.
 wire [11:0] subtitle_cycle=(subtitle_extent<512?12'd512:subtitle_extent)+(sub_zoom?12'd128:12'd64);
 wire [5:0] large_columns=front_chars[3]>16?6'd16:front_chars[3][5:0];
 wire [9:0] sub_left=sub_scrolling?10'd64:(11'd640-sub_width)>>1;
 wire title_present=(legacy_title_present&&!normal_override[1])||(front_valid[1]&&front_chars[1]!=0);
 wire [8:0] sub_top=subtitle_style_frame[2]?(title_present?9'd96:9'd24):9'd464-sub_total_height;
 wire title_two_rows=title_size_frame&&front_chars[1]>16;
 wire [6:0] title_columns=title_two_rows?(front_chars[1]+7'd1)>>1:front_chars[1];
 wire [10:0] title_width=title_size_frame?{title_columns,5'd0}:{1'b0,title_columns,4'd0};
 wire [9:0] title_left=(11'd640-title_width)>>1;
 wire [6:0] title_height=title_size_frame?(title_two_rows?7'd64:7'd32):7'd16;
 wire [9:0] emergency_left=(10'd640-({3'd0,front_chars[2]}<<6))>>1;
 wire [9:0] large_left=(10'd640-({4'd0,large_columns}<<5))>>1;
 wire [9:0] sub_dx=x-sub_left,title_dx=x-title_left,emergency_dx=x-emergency_left,large_dx=x-large_left;
 wire [8:0] sub_dy=y-sub_top,title_dy=y-9'd24,large_dy=y-9'd192;
 wire [12:0] subtitle_sum={1'b0,subtitle_scroll}+{3'd0,sub_dx};
 wire [11:0] subtitle_source_x=sub_scrolling?
   (subtitle_sum>={1'b0,subtitle_cycle}?subtitle_sum-{1'b0,subtitle_cycle}:subtitle_sum):{2'd0,sub_dx};
 wire [10:0] subtitle_logical_x=sub_zoom?subtitle_source_x[11:1]:subtitle_source_x[10:0];
 wire [8:0] subtitle_logical_y=sub_zoom?sub_dy>>1:sub_dy;
 wire large_visible=emergency&&front_valid[3]&&front_chars[3]!=0;
 wire in_sub=!emergency&&front_valid[0]&&front_chars[0]!=0&&
   y>=sub_top&&sub_dy<sub_total_height&&x>=sub_left&&{1'b0,sub_dx}<sub_width&&
   (!sub_scrolling||subtitle_source_x<subtitle_extent);
 wire sub_backing=!emergency&&front_valid[0]&&front_chars[0]!=0&&
   y>=sub_top-9'd4&&y<sub_top+sub_total_height+9'd4&&
   (sub_scrolling||(x+11'd8>=sub_left&&{1'b0,x}<{1'b0,sub_left}+sub_width+11'd8));
 wire in_title=!emergency&&front_valid[1]&&front_chars[1]!=0&&y>=24&&title_dy<title_height&&x>=title_left&&{1'b0,title_dx}<title_width;
 wire in_emergency=emergency&&front_valid[2]&&front_chars[2]!=0&&y>=32&&y<96&&x>=emergency_left&&emergency_dx<({3'd0,front_chars[2]}<<6);
 wire in_large=large_visible&&y>=192&&y<(front_chars[3]>16?256:224)&&x>=large_left&&large_dx<({4'd0,large_columns}<<5);
 reg [1:0] read_target;
 reg [5:0] read_glyph;
 reg [5:0] read_row,read_col;
 reg region;
 reg [10:0] small_read_address,small_write_address;
 reg [11:0] title_read_address,title_write_address;
 reg [12:0] large_read_address,large_write_address;
 reg small_write,title_write,large_write;
 reg [7:0] small_byte_q,title_byte_q,large_byte_q;
 reg large_q,title_q,subtitle_q,glyph_q,valid_q;
 reg [2:0] bit_q;

 always @(*)begin
  read_target=0;read_glyph=0;read_row=0;read_col=0;region=0;
  if(in_emergency)begin read_target=2;read_glyph=emergency_dx[8:6];read_row=y-9'd32;read_col=emergency_dx[5:0];region=1;end
  else if(in_large)begin read_target=3;read_glyph={large_dy[5],large_dx[8:5]};read_row={1'b0,large_dy[4:0]};read_col={1'b0,large_dx[4:0]};region=1;end
  else if(in_title)begin
   read_target=1;
   read_glyph=title_size_frame?title_dx[8:5]+(title_two_rows&&title_dy>=32?title_columns:7'd0):title_dx[8:4];
   read_row=title_size_frame?{1'b0,title_dy[4:0]}:{2'd0,title_dy[3:0]};
   read_col=title_size_frame?{1'b0,title_dx[4:0]}:{2'd0,title_dx[3:0]};region=1;
  end
  else if(in_sub)begin
   read_target=0;read_glyph=subtitle_logical_x[9:4]+(sub_two_rows&&sub_dy>=sub_height?sub_columns:7'd0);
   read_row={2'd0,subtitle_logical_y[3:0]};read_col={2'd0,subtitle_logical_x[3:0]};region=1;
  end
  if(read_glyph>=front_chars[read_target])region=0;
  // Font files store multi-byte rows least-significant byte first.
  small_read_address={read_glyph,read_row[3:0],~read_col[3]};
  title_read_address=title_size_frame?{read_glyph[4:0],read_row[4:0],~read_col[4:3]}:
   {2'b00,read_glyph[4:0],read_row[3:0],~read_col[3]};
  // Native 64px files contain TL,TR,BL,BR 32px quadrants, in that order.
  if(read_target==2)large_read_address={1'b0,read_glyph[2:0],read_row[5],read_col[5],read_row[4:0],~read_col[4:3]};
  else large_read_address={1'b1,read_glyph[4:0],read_row[4:0],~read_col[4:3]};
  small_write_address=font_address[10:0];title_write_address=font_address[11:0];
  large_write_address={job_target_q[0],font_address[11:0]};
  small_write=font_we&&font_bank==job_bank_q&&job_target_q==0&&font_address<2048;
  title_write=font_we&&font_bank==job_bank_q&&job_target_q==1&&
    (job_size_q==1?font_address<4096:font_address<1024);
  large_write=font_we&&font_bank==job_bank_q&&job_target_q>=2&&font_address<4096;
 end
 always @(posedge clk)begin
  if(small_write)small_font[small_write_address]<=font_data;
  if(title_write)title_font[title_write_address]<=font_data;
  if(large_write)large_font[large_write_address]<=font_data;
  small_byte_q<=small_font[small_read_address];
  title_byte_q<=title_font[title_read_address];
  large_byte_q<=large_font[large_read_address];
  large_q<=read_target[1];title_q<=read_target==1;subtitle_q<=read_target==0;
  glyph_q<=region;bit_q<=read_col[2:0];valid_q<=region||sub_backing;
 end
 assign pixel_valid=valid_q;
 assign pixel=glyph_q&&(large_q?large_byte_q[7-bit_q]:title_q?title_byte_q[7-bit_q]:small_byte_q[7-bit_q]);
 wire [23:0] style_fg={subtitle_style_frame[23:19],subtitle_style_frame[23:21],subtitle_style_frame[18:13],subtitle_style_frame[18:17],subtitle_style_frame[12:8],subtitle_style_frame[12:10]};
 wire [23:0] style_bg={subtitle_style_frame[39:35],subtitle_style_frame[39:37],subtitle_style_frame[34:29],subtitle_style_frame[34:33],subtitle_style_frame[28:24],subtitle_style_frame[28:26]};
 assign pixel_colour=subtitle_q?style_fg:24'hffffff;
 assign pixel_background=subtitle_q?style_bg:24'h10151f;
 assign pixel_background_alpha=subtitle_q?(subtitle_style_frame[4]?3'd4:subtitle_style_frame[7:6]==1?3'd0:
   subtitle_style_frame[7:6]==2?3'd1:subtitle_style_frame[7:6]==3?3'd3:3'd2):(emergency?3'd0:3'd1);

 wire accepted_commit=commit_valid&&render_error==0&&commit_target==job_target_q&&commit_size==job_size_q&&commit_count==job_glyph_count_q;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin subtitle_scroll<=0;subtitle_emergency_frame<=0;subtitle_restart_pending<=0;subtitle_style_frame<=40'h1105ffff08;end
  else begin
   if(frame_boundary)begin subtitle_emergency_frame<=emergency;subtitle_restart_pending<=0;subtitle_style_frame<=subtitle_style;end
   // The receiver commits at raw VS, before the colour pipeline's display VS.
   // Hold zero through that first display boundary, even for equal-length text.
   if((job_start&&job_target==0)||(accepted_commit&&commit_target==0))begin subtitle_scroll<=0;subtitle_restart_pending<=1;end
   else if(frame_boundary)begin
    if(!front_valid[0]||!sub_scrolling||emergency||subtitle_emergency_frame||subtitle_restart_pending||subtitle_style_frame[3:0]!=subtitle_style[3:0])subtitle_scroll<=0;
    else if(subtitle_scroll>=subtitle_cycle-1'b1)subtitle_scroll<=0;
    else subtitle_scroll<=subtitle_scroll+1'b1;
   end
  end
 end

 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   front_valid<=0;normal_override<=0;job_target_q<=0;job_size_q<=0;job_bank_q<=0;
   job_glyph_count_q<=0;job_utf8_bytes_q<=0;utf8_need<=0;utf8_lead<=0;
   raw_bytes_seen<=0;meta_count<=0;render_error_sticky<=0;title_size_frame<=0;
   for(i=0;i<4;i=i+1)front_chars[i]<=0;
  end else begin
   if(job_start)begin
    front_valid[job_target]<=0;
    if(job_target<2)normal_override[job_target[0]]<=1;
    job_target_q<=job_target;job_size_q<=job_size;job_bank_q<=job_bank;
    job_glyph_count_q<=job_glyph_count;job_utf8_bytes_q<=job_utf8_bytes;
    utf8_need<=0;utf8_lead<=0;raw_bytes_seen<=0;meta_count<=0;render_error_sticky<=0;
    if((job_target==0&&job_size!=0)||(job_target==1&&job_size>1)||(job_target==2&&job_size!=2)||(job_target==3&&job_size!=1))render_error_sticky<=8'ha0;
   end
   if(font_we&&!small_write&&!title_write&&!large_write)render_error_sticky<=8'ha2;
   if(raw_we)begin
    raw_bytes_seen<={1'b0,raw_address}+9'd1;
    if(raw_bank!=job_bank_q)render_error_sticky<=8'ha2;
    if(utf8_need==0)begin
     if(raw_data<8'h80)begin if(raw_data<8'h20||raw_data==8'h7f)render_error_sticky<=8'ha3;end
     else if(raw_lead2||raw_lead3)begin utf8_lead<=raw_data;utf8_need<=raw_lead3?2'd2:2'd1;end
     else render_error_sticky<=8'ha3;
    end else if(!raw_cont||bad_first)begin utf8_need<=0;render_error_sticky<=8'ha3;end
    else if(utf8_need==2)utf8_need<=1;else utf8_need<=0;
    if({1'b0,raw_address}+9'd1==job_utf8_bytes_q&&need_after!=0)render_error_sticky<=8'ha3;
   end
   if(glyph_meta_valid)begin
    meta_count<=meta_count+1'b1;
    if(glyph_meta_size!=job_size_q)render_error_sticky<=8'ha0;
    if(glyph_meta_index!=meta_count||glyph_meta_index>=job_glyph_count_q)render_error_sticky<=8'ha2;
   end
   if(accepted_commit)begin
    front_valid[commit_target]<=commit_count!=0;front_chars[commit_target]<=commit_count;
    if(commit_target<2)normal_override[commit_target[0]]<=1;
    if(commit_target==1)title_size_frame<=commit_size==1;
   end
  end
 end
endmodule
