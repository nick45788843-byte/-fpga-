// 应急保底完全由逻辑/字库产生，不读取TF或SDRAM图片；故障层始终最高。
module emergency_osd #(parameter PHOTO_BACKDROP=0,LAYOUT_ENABLED=0,PCM_WAVEFORM_ENABLED=0,MENU_ENABLED=0,SCROLL_ENABLED=0,FONT_FILE="../../../user_source/hdl_source/media/font.mem",EMERGENCY_FONT_FILE="../../../user_source/hdl_source/media/emergency32.mem")(input clk,rst,input config_clk,input hs,vs,de,input [23:0] rgb,input photo_background,
 input emergency,input [1:0] preset,input [25:0] fault,
 input [15:0] text_descriptor,input char_we,input char_bank,input [5:0] char_addr,input [7:0] char_data,
 output reg ohs,ovs,ode,output reg [23:0] out_rgb,input [192:0] layout,
 input pcm_valid,input [23:0] pcm_left,pcm_right,input [40:0] menu,input [7:0] emergency_descriptor,input emergency_font_we,
 input [12:0] emergency_font_address,input [31:0] emergency_font_data,input [39:0] subtitle_style,input [7:0] emergency_style,input normal_fallback,input [7:0] title_descriptor,input title_font_we,
 input [9:0] title_font_address,input [15:0] title_font_data,
 input program_valid,program_bank,input [6:0] program_count,input [71:0] program_rates,input [31:0] program_uid,input program_sample_tick,
 input program_font_we,input [10:0] program_font_address,input [15:0] program_font_data,
 input font_stream_job_start,input [1:0] font_stream_job_target,font_stream_job_size,input font_stream_job_bank,
 input [6:0] font_stream_job_glyph_count,input [7:0] font_stream_job_utf8_bytes,
 input font_stream_font_we,input [14:0] font_stream_font_address,input [7:0] font_stream_font_data,input font_stream_font_bank,
 input font_stream_raw_we,input [7:0] font_stream_raw_address,font_stream_raw_data,input font_stream_raw_bank,
 input font_stream_meta_valid,input [5:0] font_stream_meta_index,input [15:0] font_stream_meta_codepoint,input [1:0] font_stream_meta_size,
 input font_stream_commit_valid,font_stream_commit_bank,input [6:0] font_stream_commit_count,input [1:0] font_stream_commit_size,font_stream_commit_target,
 output [7:0] font_stream_render_error,
 // A96: original-size text for the size badge (see a_size_text in top_a_redo.v).
 input [36:0] size_text);
reg [9:0] x;reg [8:0] y;reg old_vs;
wire program_visible=program_valid&&!emergency&&!normal_fallback;
wire [15:0] active_text_descriptor=program_visible?{8'd1,program_bank,program_count}:text_descriptor;
reg program0,program1;reg [10:0] program_address0;wire [15:0] program_bits;
a_program_bitmap16 program_bitmap(config_clk,program_font_we,program_font_address,program_font_data,clk,program_address0,program_bits);
wire font_stream_pixel_valid,font_stream_pixel;wire [23:0] font_stream_pixel_colour,font_stream_pixel_background;
wire [2:0] font_stream_pixel_background_alpha;
wire [3:0] font_stream_active_regions;
a_font_stream_osd font_stream_osd(.clk(clk),.rst_n(!rst),.x(x),.y(y),.emergency(emergency),
 .subtitle_style(subtitle_style),.legacy_title_present(title_descriptor[5:0]!=0),
 .job_start(font_stream_job_start),.job_target(font_stream_job_target),.job_bank(font_stream_job_bank),.job_size(font_stream_job_size),
 .job_glyph_count(font_stream_job_glyph_count),.job_utf8_bytes(font_stream_job_utf8_bytes),
 .font_we(font_stream_font_we),.font_address(font_stream_font_address),.font_data(font_stream_font_data),.font_bank(font_stream_font_bank),
 .raw_we(font_stream_raw_we),.raw_address(font_stream_raw_address),.raw_data(font_stream_raw_data),.raw_bank(font_stream_raw_bank),
 .glyph_meta_valid(font_stream_meta_valid),.glyph_meta_index(font_stream_meta_index),.glyph_meta_codepoint(font_stream_meta_codepoint),.glyph_meta_size(font_stream_meta_size),
 .commit_valid(font_stream_commit_valid),.commit_bank(font_stream_commit_bank),.commit_count(font_stream_commit_count),
 .commit_size(font_stream_commit_size),.commit_target(font_stream_commit_target),
 .pixel_valid(font_stream_pixel_valid),.pixel(font_stream_pixel),.pixel_colour(font_stream_pixel_colour),
 .pixel_background(font_stream_pixel_background),.pixel_background_alpha(font_stream_pixel_background_alpha),
 .render_error(font_stream_render_error),.active_regions(font_stream_active_regions),.frame_boundary(old_vs&&!vs));
wire custom_front=emergency_descriptor[6:0]!=0&&(!emergency_style[0]||emergency_style[2:1]==preset);
// Font ROM32K initialization is generated from the frozen media/font.mem.

reg [4:0] erow,ecol,ecol0,ecol1;reg [5:0] epos;
reg arrow;
(* preserve=1,allow_backward_retiming=0,allow_forward_retiming=0 *) reg arrow0,arrow1;
reg hires,hires0,hires1,ecustom,ecustom0,ecustom1;reg [5:0] epos0;reg [4:0] erow0;reg extension,extension0;
wire [31:0] emergency_bits;wire custom_pixel;
wire [5:0] large_title_y=y-9'd32,large_action_y=y-9'd200;
reg [1:0] product_font,product_font0,product_font1;
reg [13:0] product_address,product_address0;wire alert_bit,public_bit;
wire [9:0] alert_dx=x-10'd192,public_dx=x-10'd48,public_main_dx=x-10'd64,road_dx=x-10'd376;
wire [8:0] alert_dy=y-9'd40,public_dy=y-9'd40,public_main_dy=y-9'd216;
wire [9:0] walker_abs_x=x>=448?x-10'd448:10'd448-x;
wire [8:0] walker_abs_y=y>=268?y-9'd268:9'd268-y;
wire [10:0] xy_sum={1'b0,x}+{2'b0,y},xy_difference={1'b0,x}+11'd480-{2'b0,y};
a_product_alert64 product_alert_font(clk,product_address0,alert_bit);
a_product_public32 product_public_font(clk,product_address0,public_bit);


reg [7:0] text_ram[0:127];always @(posedge config_clk)if(char_we)text_ram[{char_bank,char_addr}]<=char_data;

wire [9:0] emergency_dx=x-10'd64;wire [8:0] emergency_dy=y-9'd208;reg old_de;reg [5:0] blink;
reg [12:0] scroll_progress;reg [15:0] scroll_identity;reg [1:0] scroll_zoom;
reg [7:0] default_id0,text_id0;reg use_custom0,ink0,ink1;reg [3:0] row0,col0,col1;
wire [15:0] bits;reg [23:0] base0,base1,fg0,fg1;reg [2:0] flag0,flag1;
reg use_title,title0,title1;reg [9:0] title_address0;wire [15:0] title_bits;
wire [5:0] title_count=title_descriptor[5:0];
wire title_zone=title_count!=0&&y<9'd96;
wire normal_zoom=subtitle_style[3]?subtitle_style[0]:(active_text_descriptor[6:0]>32?1'b0:subtitle_style[0]);
wire [6:0] coordinate_count=title_zone?{1'b0,title_count}:active_text_descriptor[6:0];
wire coordinate_zoom=title_zone?title_descriptor[6]:normal_zoom;
wire coordinate_scroll=!title_zone&&subtitle_style[3];
wire [6:0] coordinate_capacity=coordinate_zoom?7'd16:7'd32;
wire two_rows=!coordinate_scroll&&coordinate_count>coordinate_capacity;
wire [6:0] centered_columns=two_rows?(coordinate_count+7'd1)>>1:coordinate_count;
wire [6:0] signage_height=coordinate_zoom?7'd32:7'd16;
wire [8:0] total_text_height=two_rows?{1'b0,signage_height,1'b0}:{2'd0,signage_height};
wire [9:0] fixed_width=coordinate_zoom?centered_columns<<5:centered_columns<<4;
wire [9:0] centered_x=(10'd640-fixed_width)>>1;
wire [8:0] signage_y=title_zone?9'd24:subtitle_style[2]?(title_count!=0?9'd96:9'd24):9'd464-total_text_height;
wire [8:0] signage_dy=y-signage_y;
wire [12:0] scroll_extent=normal_zoom?({6'd0,active_text_descriptor[6:0]}<<5):({6'd0,active_text_descriptor[6:0]}<<4);
reg [12:0] program_scroll,program_scroll_frame;reg [23:0] program_phase;reg [31:0] scroll_program_uid;
wire [13:0] scroll_sum={4'd0,x}+{1'b0,(program_visible?program_scroll_frame:scroll_progress)};
wire [13:0] scroll_x=coordinate_scroll?scroll_sum-14'd640:{4'd0,x}-{4'd0,centered_x};
wire [13:0] signage_logical_x=coordinate_zoom?scroll_x>>1:scroll_x;
wire [8:0] signage_logical_y=coordinate_zoom?signage_dy>>1:signage_dy;
wire [6:0] fixed_read_pos=(two_rows&&signage_dy>=signage_height?centered_columns:7'd0)+signage_logical_x[10:4];
wire coordinate_region=coordinate_scroll?
 x<640&&y>=signage_y&&signage_dy<signage_height&&scroll_sum>=640&&scroll_x<scroll_extent:
 x>=centered_x&&x<centered_x+fixed_width&&y>=signage_y&&signage_dy<total_text_height;
wire title_region=title_zone&&coordinate_region&&!emergency;
wire [5:0] title_cell=fixed_read_pos[5:0];
wire [3:0] title_row=signage_logical_y[3:0];
wire [9:0] title_dx=x-centered_x;
a_title_bitmap16 title_bitmap(config_clk,title_font_we,title_font_address,title_font_data,clk,title_address0,title_bits);
reg [23:0] shade,shade0;reg [2:0] shade_alpha,shade_alpha0;
reg [7:0] glyph;reg [3:0] rowbit,colbit;reg ink,use_custom;reg [23:0] base,fg;
a_static_normal_font16_rom normal_rom(clk,{use_custom0?text_id0:default_id0,row0},bits);
a_emergency_font32_rom emergency_rom(clk,{default_id0,erow0},emergency_bits);
a_emergency_bitmap32 emergency_bitmap(config_clk,emergency_font_we,emergency_font_address,emergency_font_data,
 clk,{emergency_descriptor[7],extension0,epos0,erow0},,ecol0,custom_pixel);
wire waveform_ink;wire [23:0] waveform_colour;
generate if(PCM_WAVEFORM_ENABLED)begin: pcm_waveform_enabled
 a_pcm_waveform wave(clk,rst,old_vs&&!vs,pcm_valid,pcm_left,pcm_right,!emergency&&!normal_fallback,de,x,y,
  waveform_ink,waveform_colour,);
end else begin: pcm_waveform_disabled
 assign waveform_ink=1'b0;assign waveform_colour=24'd0;
end endgenerate
wire [9:0] bx=x-64;wire [8:0] by=y-160;wire [5:0] body_pos={by[4],bx[8:4]};
// Long fixed text uses at most two centered rows. Reduce its integer scale
// before adding more rows; all original characters remain present (max64).
wire [23:0] signage_fg={subtitle_style[23:19],subtitle_style[23:21],subtitle_style[18:13],subtitle_style[18:17],subtitle_style[12:8],subtitle_style[12:10]};
wire [23:0] signage_bg={subtitle_style[39:35],subtitle_style[39:37],subtitle_style[34:29],subtitle_style[34:33],subtitle_style[28:24],subtitle_style[28:26]};
wire layout_normal=LAYOUT_ENABLED&&layout[192]&&!emergency;
wire [15:0] text_x=layout_normal?layout[47:32]:16'd64,text_y=layout_normal?layout[63:48]:16'd160;
wire [9:0] text_dx=x-text_x[9:0];wire [8:0] text_dy=y-text_y[8:0];
wire [7:0] zoom=layout_normal?layout[15:8]:8'd0,columns=layout_normal?layout[23:16]:8'd2;
wire [9:0] logical_x=zoom==2?text_dx>>2:zoom==1?text_dx>>1:text_dx;
wire [8:0] logical_y=zoom==2?text_dy>>2:zoom==1?text_dy>>1:text_dy;
wire [5:0] column_count=columns==0?6'd8:columns==1?6'd16:6'd32;
wire [3:0] row_count=columns==0?4'd8:columns==1?4'd4:4'd2;
wire [6:0] normal_body_pos=columns==0?{logical_y[6:4],logical_x[6:4]}:
 columns==1?{logical_y[5:4],logical_x[7:4]}:{logical_y[4],logical_x[8:4]};
wire fixed_normal_text=(!layout_normal||layout[0])&&x>=text_x&&y>=text_y&&
 logical_x[9:4]<column_count&&logical_y[8:4]<row_count&&normal_body_pos<active_text_descriptor[6:0];
wire [23:0] program_rate=normal_zoom?program_rates[47:24]:program_rates[23:0];
always @(posedge clk or posedge rst)begin
 if(rst)begin program_scroll<=0;program_scroll_frame<=0;program_phase<=0;scroll_program_uid<=0;end
 else begin
  if(!program_visible||program_uid!=scroll_program_uid)begin program_scroll<=0;program_phase<=0;scroll_program_uid<=program_uid;end
  else if(program_sample_tick)begin
   if(program_phase+1>=program_rate)begin
    program_phase<=0;
    if(program_scroll>=13'd640+scroll_extent-1)program_scroll<=0;else program_scroll<=program_scroll+1'b1;
   end else program_phase<=program_phase+1'b1;
  end
  if(old_vs&&!vs)program_scroll_frame<=program_scroll;
 end
end
wire normal_text=SCROLL_ENABLED?(!title_zone&&coordinate_region):fixed_normal_text;
wire [5:0] normal_read_pos=SCROLL_ENABLED?(coordinate_scroll?signage_logical_x[9:4]:fixed_read_pos[5:0]):normal_body_pos[5:0];
wire [15:0] pattern_x=layout[79:64],pattern_y=layout[95:80],pattern_width=layout[111:96],pattern_height=layout[127:112];
wire [9:0] pattern_dx=x-pattern_x[9:0];wire [8:0] pattern_dy=y-pattern_y[8:0];
wire pattern_box=layout_normal&&layout[1]&&x>=pattern_x&&y>=pattern_y&&pattern_dx<pattern_width&&pattern_dy<pattern_height;
wire pattern_ink=layout[31:24]==0||layout[31:24]==1&&(pattern_dx<2||pattern_dy<2||pattern_dx+2>=pattern_width||pattern_dy+2>=pattern_height)||
 layout[31:24]==2&&(pattern_dx[3]^pattern_dy[3])||layout[31:24]==3&&pattern_dx[3:0]==pattern_dy[3:0];
wire [23:0] text_rgb={layout[135:128],layout[143:136],layout[151:144]};
wire [23:0] pattern_rgb={layout[159:152],layout[167:160],layout[175:168]};
// Arrow pixels are compiled into otherwise blank static font slots.
wire [9:0] arrow_local_x=x-10'd472;wire [8:0] arrow_local_y=y-9'd336;
reg [1:0] arrow_rom_bank;
always @(*)case(emergency_style[5:3])
 1:arrow_rom_bank=0;2:arrow_rom_bank=1;3:arrow_rom_bank=2;default:arrow_rom_bank=3;
endcase
reg [1:0] menu_alpha,size_alpha,size_extent;reg [2:0] size_geometry;reg [34:0] fade_menu;
wire [9:0] menu_dx=x-10'd32,size_dx=x-10'd544;
wire compact_parameter=fade_menu[33:31]<5&&fade_menu[30:29]==2&&fade_menu[28];
wire [9:0] parameter_dx=x-10'd24;
wire [9:0] value_dx=x-(fade_menu[33:31]==3?10'd76:10'd60);
wire [2:0] first_digit=fade_menu[19:16]!=0?0:fade_menu[15:12]!=0?1:fade_menu[11:8]!=0?2:fade_menu[7:4]!=0?3:4;
wire [3:0] digit_index={1'b0,first_digit}+{1'b0,value_dx[5:3]};
wire [3:0] compact_digit=fade_menu[19-digit_index*4-:4];
wire [9:0] parameter_box_dx=x-10'd16,size_box_dx=x-10'd536;
wire [8:0] notice_dy=y-9'd16;
wire parameter_round=!((parameter_box_dx<2||parameter_box_dx>=94)&&(notice_dy<2||notice_dy>=22))&&!((parameter_box_dx<4||parameter_box_dx>=92)&&(notice_dy==0||notice_dy==23));
wire size_round=!((size_box_dx<2||size_box_dx>=86)&&(notice_dy<2||notice_dy>=22))&&!((size_box_dx<4||size_box_dx>=84)&&(notice_dy==0||notice_dy==23));
wire [3:0] size_position=size_dx[6:3];wire [3:0] size_code=size_text[size_position*4+:4];
// Preserve the existing rounded notice bounds above streamed captions.
wire menu_notice_region=MENU_ENABLED&&menu_alpha!=0&&!emergency&&y>=16&&y<40&&x>=16&&(compact_parameter?(x<112&&parameter_round):x<272);
wire size_notice_region=MENU_ENABLED&&size_alpha!=0&&!emergency&&!fault[25]&&y>=16&&y<40&&x>=536&&x<624&&size_round;

// Compact status words use 16 native glyphs in otherwise unused bit-ROM space.
function [3:0] fault_glyph;input [3:0] pos;input lost,recovered;begin
 fault_glyph=15;
 if(recovered)case(pos)0:fault_glyph=2;1:fault_glyph=3;2:fault_glyph=12;3:fault_glyph=13;4:fault_glyph=14;endcase
 else if(lost)begin if(pos<6)fault_glyph=pos;end
 else begin if(pos<6)fault_glyph=6+pos;end
end endfunction
wire [9:0] fault_dx=x-10'd480;wire [8:0] fault_dy=y-9'd12;
function [7:0] hexglyph;input [3:0] v;begin hexglyph=v<10?(8'd16+v):(8'd33+v-10);end endfunction
// B supplies BCD and actual result status. No binary division on A.
function [7:0] menu_glyph;input [2:0] item;input [5:0] pos;input help;
 reg [3:0] digit;begin
 menu_glyph=0;digit=0;
 case(pos)
  0:case(item)
   0:menu_glyph=fade_menu[30:29]==2&&fade_menu[27:20]==1?218:210;
   1:menu_glyph=212;2:menu_glyph=214;3:menu_glyph=39;
   4:menu_glyph=216;5:menu_glyph=51;6:menu_glyph=36;7:menu_glyph=37;
  endcase
  1:case(item)
   0:menu_glyph=fade_menu[30:29]==2&&fade_menu[27:20]==1?210:211;
   1:menu_glyph=213;2:menu_glyph=215;3:menu_glyph=33;
   4:menu_glyph=217;5:menu_glyph=33;6:menu_glyph=37;7:menu_glyph=56;
  endcase
  2:case(item)3:menu_glyph=45;5:menu_glyph=54;6:menu_glyph=38;7:menu_glyph=52;default:menu_glyph=0;endcase
  3:if(item<5)menu_glyph=26;
  4,5,6,7,8:if(item<5&&fade_menu[28])begin
   case(pos)4:digit=fade_menu[19:16];5:digit=fade_menu[15:12];6:digit=fade_menu[11:8];7:digit=fade_menu[7:4];default:digit=fade_menu[3:0];endcase
   menu_glyph={4'b0001,digit};
   if((pos==4&&fade_menu[19:16]==0)||(pos==5&&fade_menu[19:12]==0)||(pos==6&&fade_menu[19:8]==0)||(pos==7&&fade_menu[19:4]==0))menu_glyph=0;
  end
  10:case(fade_menu[30:29])1:menu_glyph=55;2:menu_glyph=47;3:menu_glyph=37;default:menu_glyph=fade_menu[28]?0:31;endcase
  12:if(fade_menu[30:29]==3)menu_glyph=hexglyph(fade_menu[27:24]);
  13:if(fade_menu[30:29]==3)menu_glyph=hexglyph(fade_menu[23:20]);
  default:menu_glyph=0;
 endcase
end endfunction
wire [5:0] shared_menu_position=compact_parameter?parameter_dx[9:4]:menu_dx[9:4];
wire [7:0] shared_menu_glyph=menu_glyph(fade_menu[33:31],shared_menu_position,1'b0);
// Disjoint regions share the existing single character-ROM read port.
function [7:0] size_glyph;input [3:0] pos;begin
 size_glyph=0;
 case(pos)
  0:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd19;2:size_glyph=8'd19;default:size_glyph=8'd21;endcase
   2:case(size_extent)1:size_glyph=8'd17;2:size_glyph=8'd17;default:size_glyph=8'd18;endcase
   3:case(size_extent)1:size_glyph=8'd17;2:size_glyph=8'd17;default:size_glyph=8'd18;endcase
   4:case(size_extent)1:size_glyph=8'd18;2:size_glyph=8'd18;default:size_glyph=8'd20;endcase
   default:case(size_extent)1:size_glyph=8'd22;2:size_glyph=8'd22;default:size_glyph=8'd17;endcase
  endcase
  1:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd18;2:size_glyph=8'd18;default:size_glyph=8'd16;endcase
   2:case(size_extent)1:size_glyph=8'd22;2:size_glyph=8'd22;default:size_glyph=8'd21;endcase
   3:case(size_extent)1:size_glyph=8'd18;2:size_glyph=8'd18;default:size_glyph=8'd16;endcase
   4:case(size_extent)1:size_glyph=8'd21;2:size_glyph=8'd21;default:size_glyph=8'd16;endcase
   default:case(size_extent)1:size_glyph=8'd20;2:size_glyph=8'd20;default:size_glyph=8'd16;endcase
  endcase
  2:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd5;endcase
   2:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd5;endcase
   3:case(size_extent)1:size_glyph=8'd24;2:size_glyph=8'd24;default:size_glyph=8'd16;endcase
   4:case(size_extent)1:size_glyph=8'd22;2:size_glyph=8'd22;default:size_glyph=8'd16;endcase
   default:size_glyph=8'd16;
  endcase
  3:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd88;2:size_glyph=8'd88;default:size_glyph=8'd0;endcase
   2:case(size_extent)1:size_glyph=8'd88;2:size_glyph=8'd88;default:size_glyph=8'd0;endcase
   3:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd5;endcase
   4:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd5;endcase
   default:case(size_extent)1:size_glyph=8'd88;2:size_glyph=8'd88;default:size_glyph=8'd5;endcase
  endcase
  4:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd18;2:size_glyph=8'd17;default:size_glyph=8'd0;endcase
   2:case(size_extent)1:size_glyph=8'd17;2:size_glyph=8'd25;default:size_glyph=8'd0;endcase
   3:case(size_extent)1:size_glyph=8'd88;2:size_glyph=8'd88;default:size_glyph=8'd0;endcase
   4:case(size_extent)1:size_glyph=8'd88;2:size_glyph=8'd88;default:size_glyph=8'd0;endcase
   default:case(size_extent)1:size_glyph=8'd20;2:size_glyph=8'd19;default:size_glyph=8'd0;endcase
  endcase
  5:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd20;2:size_glyph=8'd24;default:size_glyph=8'd0;endcase
   2:case(size_extent)1:size_glyph=8'd18;2:size_glyph=8'd16;default:size_glyph=8'd0;endcase
   3:case(size_extent)1:size_glyph=8'd25;2:size_glyph=8'd23;default:size_glyph=8'd0;endcase
   4:case(size_extent)1:size_glyph=8'd17;2:size_glyph=8'd17;default:size_glyph=8'd0;endcase
   default:case(size_extent)1:size_glyph=8'd24;2:size_glyph=8'd22;default:size_glyph=8'd0;endcase
  endcase
  6:case(size_geometry)
   1:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd0;endcase
   2:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd0;default:size_glyph=8'd0;endcase
   3:case(size_extent)1:size_glyph=8'd22;2:size_glyph=8'd18;default:size_glyph=8'd0;endcase
   4:case(size_extent)1:size_glyph=8'd25;2:size_glyph=8'd20;default:size_glyph=8'd0;endcase
   default:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd0;endcase
  endcase
  7:case(size_geometry)
   1:size_glyph=8'd0;
   2:size_glyph=8'd0;
   3:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd0;endcase
   4:case(size_extent)1:size_glyph=8'd18;2:size_glyph=8'd20;default:size_glyph=8'd0;endcase
   default:size_glyph=8'd0;
  endcase
  8:case(size_geometry)
   1:size_glyph=8'd0;
   2:size_glyph=8'd0;
   3:size_glyph=8'd0;
   4:case(size_extent)1:size_glyph=8'd16;2:size_glyph=8'd16;default:size_glyph=8'd0;endcase
   default:size_glyph=8'd0;
  endcase
  default:size_glyph=0;
 endcase
end endfunction

function [7:0] waveform_glyph;input [3:0] pos;reg [127:0] caption;begin
 caption="PCM L  5.33 ms  ";waveform_glyph=caption[127-pos*8-:8]-32;
end endfunction
function [23:0] blend_half;input [23:0] a,b;reg [7:0] r,g,bl;begin
 r={1'b0,a[23:17]}+{1'b0,b[23:17]};g={1'b0,a[15:9]}+{1'b0,b[15:9]};
 bl={1'b0,a[7:1]}+{1'b0,b[7:1]};blend_half={r,g,bl};
end endfunction
function [23:0] overlay_alpha;input [23:0] below,over;input [1:0] level;begin
 case(level)0:overlay_alpha=below;1:overlay_alpha=blend_half(below,blend_half(below,over));
  2:overlay_alpha=blend_half(below,over);default:overlay_alpha=blend_half(over,blend_half(below,over));endcase
end endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin menu_alpha<=0;fade_menu<=0;size_alpha<=0;size_extent<=0;size_geometry<=0;end
 else if(old_vs&&!vs)begin
  if(menu[34]&&!emergency)begin fade_menu<=menu[34:0];if(menu_alpha!=3)menu_alpha<=menu_alpha+1'b1;end
  else if(menu_alpha!=0)menu_alpha<=menu_alpha-1'b1;
  if(menu[37]&&!emergency)begin size_extent<=size_text[36]?2'd0:menu[36:35];size_geometry<=menu[40:38];if(size_alpha!=3)size_alpha<=size_alpha+1'b1;end
  else if(size_alpha!=0)size_alpha<=size_alpha-1'b1;
 end
end
// Bounded preset screen rows are compiled into ROM32K; no runtime text lookup tree.




always @(*)begin
 arrow=0;
 product_font=0;product_address=0;extension=0;use_title=0;hires=0;ecustom=0;erow=0;ecol=0;epos=0;
 base=rgb;shade=24'd0;shade_alpha=0;fg=24'hffffff;glyph=0;rowbit=y[3:0];colbit=x[3:0];ink=0;use_custom=0;
 if(pattern_box&&pattern_ink)begin shade=pattern_rgb;shade_alpha=4;end
 // A self-contained fixed public-service poster. No TF, B, SDRAM asset or
 // network is needed. It reuses the existing glyph ROM and raster pipeline.
 if(normal_fallback&&!emergency)begin
  shade=y<112?24'h172132:24'hf5f3ef;shade_alpha=4;ink=0;
  if(x>=48&&x<176&&y>=40&&y<72)begin
   product_font=2;product_address={1'b0,1'b0,public_dx[6:5],public_dy[4:0],public_dx[4:0]};fg=24'hffffff;ink=1;
  end else if(x>=64&&x<192&&y>=216&&y<248)begin
   product_font=2;product_address={1'b0,1'b1,public_main_dx[6:5],public_main_dy[4:0],public_main_dx[4:0]};fg=24'h334155;ink=1;
  end
  if(x>=64&&x<192&&y>=408&&y<440)begin product_font=2;product_address={1'b1,1'b0,public_main_dx[6:5],y[4:0]-5'd24,public_main_dx[4:0]};fg=24'h6b7280;ink=1;end
  // Fixed vector pedestrian and crossing, without multipliers or image RAM.
  if(walker_abs_x<96&&walker_abs_y<96&&walker_abs_x+walker_abs_y<144)shade=24'hffffff;
  if((x>=440&&x<456&&y>=220&&y<252)||(x>=434&&x<462&&y>=226&&y<246)||
    (x>=442&&x<454&&y>=254&&y<298)||
    (x>=418&&x<448&&y>=258&&y<290&&xy_sum>=708&&xy_sum<716)||
    (x>=448&&x<478&&y>=258&&y<288&&xy_difference>=662&&xy_difference<670)||
    (x>=410&&x<448&&y>=290&&y<330&&xy_sum>=734&&xy_sum<742)||
    (x>=444&&x<480&&y>=290&&y<334&&xy_difference>=630&&xy_difference<638))shade=24'hd97720;
  if(y>=336&&y<344&&x>=48&&x<592)shade=24'hd97720;
  if(x>=376&&x<552&&y>=364&&y<382&&road_dx[5:0]<24)shade=24'hd97720;
 end
 if(!font_stream_active_regions[0]&&!emergency&&!normal_fallback&&!title_zone&&active_text_descriptor[15:8]!=0&&active_text_descriptor[6:0]!=0&&y>=signage_y-4&&y<signage_y+total_text_height+4&&
    (subtitle_style[3] || x+8>=centered_x&&x<centered_x+fixed_width+8))begin
  shade=signage_bg;shade_alpha=subtitle_style[4]?3'd4:subtitle_style[7:6]==1?3'd0:
    subtitle_style[7:6]==2?3'd1:subtitle_style[7:6]==3?3'd3:3'd2;
 end
 if(emergency)begin
  case(preset)
   0:shade=24'ha91424;1:shade=24'h895100;2:shade=24'h0b4768;default:shade=24'h213b52;
  endcase
  // A fixed Flash background remains visible as a subdued supporting layer.
  shade_alpha=PHOTO_BACKDROP&&photo_background?3'd2:3'd4;
  fg=24'hffffff;epos=0;erow=0;ecol=0;ink=0;hires=1;
  // Restore a bounded flashing warning edge; the large instruction text
  // and photo remain steady for reading.
  if(x<8||x>=632||y<8||y>=472)begin shade=blink[5]?24'hffd655:24'hd01e31;shade_alpha=4;end
  if(!custom_front)begin
   // Native 64px generic alarm; category and instructions remain native 32px.
   // No magnified 32px heading is presented as a higher-resolution glyph.
   if(x>=192&&x<448&&y>=40&&y<104)begin product_font=1;product_address={alert_dx[7:6],alert_dy[5:0],alert_dx[5:0]};ink=1;end
   else if(x>=64&&x<320&&y>=120&&y<152)begin epos=(x-64)>>5;erow=y-120;ecol=x-64;fg=24'hffe497;ink=1;end
   else if(x>=64&&x<576&&y>=164&&y<196)begin epos=8+((x-64)>>5);erow=y-164;ecol=x-64;ink=1;end
   else if(x>=64&&x<320&&y>=224&&y<256)begin epos=24+((x-64)>>5);erow=y-224;ecol=x-64;ink=1;end
   else if(x>=64&&x<576&&y>=284&&y<316)begin epos=32+((x-64)>>5);erow=y-284;ecol=x-64;ink=1;end
   else if(x>=64&&x<320&&y>=352&&y<384)begin epos=48+((x-64)>>5);erow=y-352;ecol=x-64;ink=1;end
   else if(x>=64&&x<320&&y>=416&&y<448)begin epos=56+((x-64)>>5);erow=y-416;ecol=x-64;ink=1;end
   glyph={preset,epos};
   if(epos[5:4]==2'b11&&epos[2:1]==2'b11)ink=0;
  end else if(emergency_style[0])begin
   if(x>=64&&x<576&&y>=32&&y<96)begin epos=(x-64)>>6;erow=(y-32)>>1;ecol=(x-64)>>1;ink=1;end
   else if(x>=64&&x<576&&y>=128&&y<160)begin epos=8+((x-64)>>5);erow=y-128;ecol=x-64;fg=24'hffe497;ink=1;end
   else if(y>=200&&y<264)begin
    if(emergency_style[7])begin
     if(x>=64&&x<320&&y<232)begin epos=24+((x-64)>>5);erow=y-200;ecol=x-64;ink=1;end
    end else if(x>=64&&x<576)begin epos=24+((x-64)>>6);erow=(y-200)>>1;ecol=(x-64)>>1;ink=1;end
   end
   else if(x>=64&&x<576&&y>=296&&y<328)begin epos=32+((x-64)>>5);erow=y-296;ecol=x-64;ink=1;end
   else if(x>=64&&x<320&&y>=368&&y<400)begin epos=48+((x-64)>>5);erow=y-368;ecol=x-64;ink=1;end
   else if(x>=64&&x<320&&y>=416&&y<448)begin epos=56+((x-64)>>5);erow=y-416;ecol=x-64;ink=1;end
   glyph={preset,epos};
   if(!custom_front&&epos[5:4]==2'b11&&epos[2:1]==2'b11)ink=0;
   if(custom_front)begin
    ecustom=1;ink=ink&&epos<emergency_descriptor[6:0];
    if(emergency_style[7]&&ink&&(y>=32&&y<96))begin
     extension=1;
     epos={1'b0,emergency_dx[8:6],large_title_y[5],emergency_dx[5]};
     erow=y-9'd32;ecol=emergency_dx[4:0];
    end
   end
  end else begin
   // Compatibility for an older h21 free-text upload; its independent bank is retained.
   if(x>=64&&x<576&&y>=32&&y<96)begin epos=(x-64)>>6;erow=(y-32)>>1;ecol=(x-64)>>1;ink=1;glyph={preset,epos};end
   else if(x>=64&&x<576&&y>=192&&y<320)begin epos=((y-192)>>5)*16+((x-64)>>5);erow=y-192;ecol=x-64;ink=epos<emergency_descriptor[6:0];ecustom=1;end
  end
  // A committed stream replaces its entire legacy heading/body region,
  // including old preset lines outside the new phrase's own glyph bounds.
  if((font_stream_active_regions[2]&&y>=32&&y<112)||
     (font_stream_active_regions[3]&&y>=112&&y<464))begin ink=0;product_font=0;ecustom=0;end
  // Direction remains independent of the editable heading and body.
  if(custom_front&&emergency_style[0]&&emergency_style[5:3]!=0&&x>=472&&x<600&&y>=352&&y<448)begin
   arrow=1;shade=24'hb85e15;shade_alpha=4;fg=24'hffd655;ink=1;hires=1;ecustom=0;
   glyph={arrow_rom_bank,2'b11,arrow_local_y[6],2'b11,arrow_local_x[6]};erow=arrow_local_y[5:1];ecol=arrow_local_x[5:1];
  end
 end else if(!font_stream_active_regions[0]&&!normal_fallback&&active_text_descriptor[15:8]!=0&&normal_text)begin
  use_custom=1;ink=1;fg=signage_fg;rowbit=SCROLL_ENABLED?signage_logical_y[3:0]:logical_y[3:0];colbit=SCROLL_ENABLED?signage_logical_x[3:0]:logical_x[3:0];
 end

 // 图片下保留文字条背景，避免白色文字落到白色照片上不可读。

 if(title_region&&!font_stream_active_regions[1])begin
  use_title=1;hires=0;ink=1;fg=signage_fg;
  rowbit=title_row;colbit=signage_logical_x[3:0];
  // A small translucent backing follows the title's own bounds only.
  shade=24'h10151f;shade_alpha=2;
 end
 // This descriptor is frame-latched independently of the subtitle RAM owner.
 if(menu_notice_region)begin
  shade=24'h101e30;shade_alpha={1'b0,(menu_alpha==3?2'd2:menu_alpha)};fg=menu_alpha==3?(fade_menu[30:29]==3?24'hffce58:24'hffffff):overlay_alpha(rgb,24'hffffff,menu_alpha);ink=0;use_custom=0;use_title=0;
  if(!compact_parameter&&x>=32&&x<256&&y>=20&&y<36)begin
   ink=1;rowbit=y-20;colbit=menu_dx;product_font=0;
   glyph=shared_menu_glyph;
  end
 end
 if(MENU_ENABLED&&compact_parameter&&menu_alpha!=0&&!emergency&&x>=24&&x<104&&y>=20&&y<36)begin
  rowbit=y-20;product_font=0;use_custom=0;use_title=0;
  if(parameter_dx<(fade_menu[33:31]==3?48:32))begin
   ink=1;colbit=parameter_dx;glyph=shared_menu_glyph;
  end else if(x>=(fade_menu[33:31]==3?76:60)&&digit_index<5)begin
   ink=1;glyph=8'd16+compact_digit;colbit={1'b0,value_dx[2:0]}+(compact_digit==4?4'd3:4'd4);
  end
 end
 // Dimensions never replace a left parameter notice or its fade state.
 if(size_notice_region)begin
  shade=24'h101e30;shade_alpha={1'b0,(size_alpha==3?2'd2:size_alpha)};fg=size_alpha==3?24'hffffff:overlay_alpha(rgb,24'hffffff,size_alpha);ink=0;use_custom=0;use_title=0;
  if(x>=544&&x<616&&y>=20&&y<36)begin
   ink=1;rowbit=y-20;product_font=0;glyph=size_text[36]&&size_geometry==0?(size_position>8?8'd0:size_code<10?8'd16+size_code:size_code==10?8'd88:8'd0):size_glyph(size_position);
   colbit={1'b0,size_dx[2:0]}+(glyph==8'd20 ? 4'd3 : 4'd4);
  end
 end
 // A small status badge never replaces the mode or covers the lower subtitles.
 if(fault[25]&&y>=8&&y<32&&x>=464&&x<624)begin
  hires=0;ecustom=0;use_title=0;use_custom=0;
  shade=fault[24]?24'h59242c:24'h9a4e13;shade_alpha=3;fg=24'hffffff;ink=0;
  if(x>=480&&x<576&&y>=12&&y<28)begin
   product_font=2;product_address={2'b11,fault_glyph(fault_dx[7:4],fault[7:0]==8'hc0,!fault[24]),fault_dy[3:0],fault_dx[3:0]};ink=1;
  end
 end

end
wire [23:0] pixel_shade=waveform_ink&&subtitle_style[5]?waveform_colour:shade0;
wire [2:0] pixel_alpha=waveform_ink&&subtitle_style[5]?3'd2:shade_alpha0;
reg font_stream_pixel_q,font_stream_valid_q;reg [23:0] font_stream_colour_q;
reg [23:0] font_stream_background_q;reg [2:0] font_stream_background_alpha_q;
reg fault_region0,fault_region1,hud_region0,hud_region1;
wire legacy_ink=ink1&&(product_font1==1?alert_bit:product_font1==2?public_bit:hires1?(ecustom1?custom_pixel:emergency_bits[31-ecol1]):(title1?title_bits[15-col1]:program1?program_bits[15-col1]:bits[15-col1]));
wire [23:0] legacy_rgb=legacy_ink?(arrow1?24'hffd655:fg1):base1;
always @(posedge clk or posedge rst)begin
 if(rst)begin fault_region0<=0;fault_region1<=0;hud_region0<=0;hud_region1<=0;end
 else begin fault_region0<=fault[25]&&y>=8&&y<32&&x>=464&&x<624;fault_region1<=fault_region0;hud_region0<=menu_notice_region||size_notice_region;hud_region1<=hud_region0;end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin arrow0<=0;arrow1<=0;product_font0<=0;product_font1<=0;product_address0<=0;shade0<=0;shade_alpha0<=0;program0<=0;program1<=0;program_address0<=0;title0<=0;title1<=0;title_address0<=0;hires0<=0;hires1<=0;ecustom0<=0;ecustom1<=0;erow0<=0;ecol0<=0;ecol1<=0;epos0<=0;extension0<=0;x<=0;y<=0;old_de<=0;old_vs<=1;blink<=0;scroll_progress<=0;scroll_identity<=0;scroll_zoom<=0;default_id0<=0;text_id0<=0;use_custom0<=0;row0<=0;col0<=0;col1<=0;ink0<=0;ink1<=0;base0<=0;base1<=0;fg0<=0;fg1<=0;flag0<=0;flag1<=0;font_stream_pixel_q<=0;font_stream_valid_q<=0;font_stream_colour_q<=0;font_stream_background_q<=0;font_stream_background_alpha_q<=0;ohs<=0;ovs<=0;ode<=0;out_rgb<=0;end
 else begin
  old_de<=de;old_vs<=vs;if(old_vs&&!vs)begin
   x<=0;y<=0;blink<=blink+1'b1;
   if(!SCROLL_ENABLED||emergency||active_text_descriptor[15:8]==0||active_text_descriptor[6:0]==0||scroll_identity!=text_descriptor||scroll_zoom!={1'b0,normal_zoom})begin
    scroll_progress<=0;scroll_identity<=text_descriptor;scroll_zoom<={1'b0,normal_zoom};
   end else if(scroll_progress>=13'd640+scroll_extent-13'd2)scroll_progress<=0;
   else scroll_progress<=scroll_progress+13'd2;
  end
  else begin if(de)x<=x+1'b1;else x<=0;if(old_de&&!de)y<=y+1'b1;end
  arrow0<=arrow;arrow1<=arrow0;
  font_stream_pixel_q<=font_stream_pixel;font_stream_valid_q<=font_stream_pixel_valid;font_stream_colour_q<=font_stream_pixel_colour;
  font_stream_background_q<=font_stream_pixel_background;font_stream_background_alpha_q<=font_stream_pixel_background_alpha;
  program0<=program_visible&&use_custom&&!use_title;program1<=program0;program_address0<={program_bank,normal_read_pos,signage_logical_y[3:0]};title0<=use_title;title1<=title0;title_address0<={title_descriptor[7],title_cell[4:0],title_row};hires0<=hires;hires1<=hires0;ecustom1<=ecustom0;ecustom0<=ecustom;extension0<=extension;erow0<=erow;ecol0<=ecol;ecol1<=ecol0;epos0<=epos;
  product_font0<=product_font;product_font1<=product_font0;product_address0<=product_address;
  default_id0<=glyph;text_id0<=text_ram[{active_text_descriptor[7],emergency?body_pos:normal_read_pos}];use_custom0<=use_custom;row0<=rowbit;col0<=colbit;ink0<=ink;base0<=rgb;shade0<=shade;shade_alpha0<=shade_alpha;fg0<=fg;flag0<={hs,vs,de};
  col1<=col0;ink1<=ink0;base1<=pixel_alpha==4?pixel_shade:overlay_alpha(base0,pixel_shade,pixel_alpha[1:0]);fg1<=fg0;flag1<=flag0;
  out_rgb<=(fault_region1||hud_region1)?legacy_rgb:font_stream_valid_q?(font_stream_pixel_q?font_stream_colour_q:
   (font_stream_background_alpha_q==4?font_stream_background_q:overlay_alpha(base1,font_stream_background_q,font_stream_background_alpha_q[1:0]))):
   legacy_rgb;{ohs,ovs,ode}<=flag1;
 end
end
endmodule

// Read-only single-bit font planes keep native 64px contours and use only the
// needed bit rather than a 64-bit wide mux. Valid pixel tags hide startup data.
module a_product_alert64(input clk,input [13:0] address,output reg data);
(* force_ram=1,ram_style="bram_9k" *) reg memory[0:16383];
initial $readmemh("../../../user_source/hdl_source/media/product_alert64.mem",memory);
always @(posedge clk)data<=memory[address];
endmodule
module a_product_public32(input clk,input [13:0] address,output reg data);
(* force_ram=1,ram_style="bram_9k" *) reg memory[0:16383];
initial $readmemh("../../../user_source/hdl_source/media/product_public32.mem",memory);
always @(posedge clk)data<=memory[address];
endmodule
