// A-local display storage. Host supplies rasterized rows; no Unicode engine on A.
// CN2 already holds the entire CRC-qualified RX body until the result is captured.
module a_emergency_content #(parameter STYLE_PERSISTENCE=0)(input clk,rst_n,frame_boundary,
 input request_valid,output request_ready,input [31:0] request_token,
 input [7:0] request_command,input [15:0] request_length,input [47:0] arguments,
 output [7:0] payload_address,input [7:0] payload_byte,
 input cancel_valid,input [31:0] cancel_token,
 output reg result_valid,input result_ready,output reg [31:0] result_token,
 input [4:0] result_address,output reg [7:0] result_byte,
 output font_we,output [12:0] font_address,output [31:0] font_data,
 output reg [7:0] descriptor,output busy,input reset_upload,output reg [39:0] subtitle_style,output reg [7:0] emergency_style,
 output title_font_we,output [9:0] title_font_address,output [15:0] title_font_data,output reg [7:0] title_descriptor,
 input tick_ms,program_raw_we,program_raw_bank,input [7:0] program_raw_address,input [7:0] program_raw_byte,
 input program_front_valid,program_front_bank,input [6:0] program_front_count,input [7:0] program_front_length,
 output program_query_hold,
 input style_restore_valid,input [47:0] restored_styles,output reg style_restore_settled,
 input style_source_lock,output style_publish);
localparam IDLE=0,GLYPH=1,RAW=2,COMMIT=3,STYLE=4;
reg [7:0] pending_emergency_style;reg extended_glyph;reg [6:0] extension_next;
reg [2:0] state;reg [1:0] read_wait;
reg query_program,program_lease,program_snapshot_bank;reg [7:0] program_snapshot_length,program_lease_age;reg [6:0] program_snapshot_count;
reg upload,upload_title,title_zoom,query_title;reg [7:0] title_front_length;reg target_bank;reg [31:0] upload_id;
reg [6:0] glyph_count,glyph_next;reg [7:0] raw_next,front_length;
reg [7:0] cursor,last_byte,reply_command,reply_error,query_offset;
reg [4:0] query_count;
reg [23:0] assembled;
reg [7:0] raw_read,program_read;
(* force_ram=1,ram_style="bram" *) reg [7:0] program_raw[0:511];
(* force_ram=1,ram_style="bram" *) reg [7:0] raw_text[0:1023];
wire owned_cancel=cancel_valid&&cancel_token==result_token;
wire [7:0] received_op=arguments[7:0],index=arguments[15:8];
wire requested_title=request_command==20&&(received_op==8'h10||received_op==8'h11||received_op==8'h12||received_op==8'h1e);
wire query_is_title=request_command==21&&received_op>=8'he0&&received_op<=8'heb;
wire query_is_program=request_command==21&&received_op>=8'hd0&&received_op<=8'hdb;
wire query_start_program=query_is_program&&received_op==8'hd0;
wire [7:0] program_query_length=query_start_program?program_front_length:program_snapshot_length;
wire [7:0] read_result_byte=query_program?program_read:raw_read;
assign program_query_hold=program_lease||(result_valid&&query_program)||(request_valid&&request_ready&&query_start_program&&program_front_valid);
wire [7:0] op=requested_title ? (received_op==8'h1e ? 8'hfe : {4'd0,received_op[3:0]}) : received_op;
wire [6:0] requested_glyphs=requested_title ? {1'b0,index[5:0]} : index[6:0];
wire [7:0] selected_length=query_is_program ? program_query_length : query_is_title ? title_front_length : front_length;
wire [7:0] requested_offset=(query_is_title||query_is_program) ? {received_op[3:0],4'd0} : received_op;
wire [31:0] nonce=arguments[47:16];
wire [7:0] raw_read_index={(query_title||query_program)?query_offset[3:0]:query_offset[7:4],result_address[3:0]^4'h8};
wire [4:0] write_row=(cursor-8'd6)>>2;
wire row_write=rst_n&&state==GLYPH&&read_wait==2&&cursor[1:0]==1&&!owned_cancel;
assign font_we=row_write&&!upload_title;
assign title_font_we=row_write&&upload_title&&!write_row[0];
assign title_font_address={target_bank,glyph_next[4:0],write_row[4:1]};
genvar title_bit;generate for(title_bit=0;title_bit<16;title_bit=title_bit+1)begin: title_downsample
 assign title_font_data[15-title_bit]=font_data[31-title_bit*2];
end endgenerate
assign font_address={target_bank,extended_glyph,extended_glyph?extension_next[5:0]:glyph_next[5:0],write_row};
assign font_data={payload_byte,assembled};
assign request_ready=state==IDLE&&!result_valid&&(!STYLE_PERSISTENCE||style_restore_settled);
// Only an actual runtime frame publication queues persistence. A cancelled
// command and the one-shot boot restore never consume a journal sequence.
assign style_publish=STYLE_PERSISTENCE&&rst_n&&style_restore_settled&&frame_boundary&&!owned_cancel&&!style_source_lock&&
 (state==STYLE||(state==COMMIT&&!upload_title));
assign busy=state!=IDLE;
assign payload_address=cursor;
always @(posedge clk)begin
 program_read<=program_raw[{program_snapshot_bank,raw_read_index}];
 if(program_raw_we)program_raw[{program_raw_bank,program_raw_address}]<=program_raw_byte;
 raw_read<=raw_text[{query_title,(query_title?title_descriptor[7]:descriptor[7]),raw_read_index}];
 if(state==RAW&&read_wait==2&&!owned_cancel)
  raw_text[{upload_title,target_bank,raw_next}]<=payload_byte;
end
always @(*)begin
 case(result_address)
 0:result_byte=reply_command;
 1:result_byte=reply_error!=0;
 2:result_byte=reply_error;
 3:result_byte=4; // revision 4: complete native-64 headline; native-32 body/action
 4:result_byte=reply_command==21?query_offset:{1'b0,glyph_next};
 5:result_byte=reply_command==21?query_count:raw_next;
 6:result_byte=query_program?{1'b0,program_snapshot_count}:query_title?{2'd0,title_descriptor[5:0]}:{1'b0,descriptor[6:0]};
 7:result_byte=query_program?program_snapshot_length:query_title?title_front_length:front_length;
 8:result_byte=reply_command==21&&query_offset==8'hf0 ?subtitle_style[7:0]:reply_command==21&&query_count>0?read_result_byte:0;
 9:result_byte=reply_command==21&&query_offset==8'hf0 ?subtitle_style[15:8]:reply_command==21&&query_count>1?read_result_byte:0;
 10:result_byte=reply_command==21&&query_offset==8'hf0 ?subtitle_style[23:16]:reply_command==21&&query_count>2?read_result_byte:0;
 11:result_byte=reply_command==21&&query_offset==8'hf0 ?subtitle_style[31:24]:reply_command==21&&query_count>3?read_result_byte:0;
 12:result_byte=reply_command==21&&query_offset==8'hf0 ?subtitle_style[39:32]:reply_command==21&&query_count>4?read_result_byte:0;
 13:result_byte=reply_command==21&&query_offset==8'hf0 ?emergency_style:reply_command==21&&query_count>5?read_result_byte:0;
 default:result_byte=reply_command==21&&query_offset!=8'hf0&&result_address-8<query_count?read_result_byte:0;
 endcase
end
task finish;input [7:0] error;begin
 reply_error<=error;result_valid<=1;state<=IDLE;read_wait<=0;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  query_program<=0;program_lease<=0;program_snapshot_bank<=0;program_snapshot_length<=0;program_snapshot_count<=0;program_lease_age<=0;
  state<=IDLE;read_wait<=0;extended_glyph<=0;extension_next<=0;upload<=0;upload_title<=0;query_title<=0;title_zoom<=0;title_front_length<=0;title_descriptor<=0;target_bank<=1;upload_id<=0;
  glyph_count<=0;glyph_next<=0;raw_next<=0;front_length<=0;cursor<=0;last_byte<=0;
  reply_command<=0;reply_error<=0;query_offset<=0;query_count<=0;assembled<=0;
  result_valid<=0;result_token<=0;descriptor<=0;subtitle_style<=40'h1105ffff08;emergency_style<=0;pending_emergency_style<=0;
  style_restore_settled<=!STYLE_PERSISTENCE;
 end else begin
  if(tick_ms&&program_lease)begin
   if(program_lease_age==249)program_lease<=0;else program_lease_age<=program_lease_age+1'b1;
  end
  if(result_valid&&result_ready)begin
   result_valid<=0;
   if(query_program&&{1'b0,query_offset[3:0],4'd0}+query_count>=program_snapshot_length)program_lease<=0;
  end
  if((owned_cancel&&query_program)||reset_upload)program_lease<=0;
  if(request_valid&&request_ready)begin
   result_token<=request_token;reply_command<=request_command;reply_error<=0;query_count<=0;query_title<=query_is_title;query_program<=query_is_program;
   if(request_command==21)begin
    query_offset<=received_op;
    query_count<=op==8'hf0 ?6:requested_offset<selected_length?(selected_length-requested_offset>=16?16:selected_length-requested_offset):0;
    if(query_is_program)begin
     if((query_start_program&&program_front_valid)||(!query_start_program&&program_lease))begin
      if(query_start_program)begin
       program_snapshot_bank<=program_front_bank;program_snapshot_length<=program_front_length;program_snapshot_count<=program_front_count;
      end
      program_lease<=1;program_lease_age<=0;finish(0);
     end else begin query_count<=0;finish(8'h55);end
    end else finish(op==8'hf0||query_is_title||op<=front_length&&op[3:0]==0?0:8'h47);
   end else if(op==3&&request_length==6&&!index[1])begin
    state<=STYLE;
   end else if(op==0&&request_length==6&&(requested_title ? !index[7]&&requested_glyphs<=32 : index<=64)&&nonce!=0)begin
    upload<=1;upload_title<=requested_title;title_zoom<=index[6];upload_id<=nonce;target_bank<=requested_title?!title_descriptor[7]:!descriptor[7];glyph_count<=requested_glyphs;
    glyph_next<=0;extension_next<=0;extended_glyph<=0;raw_next<=0;pending_emergency_style<=0;finish(0);
   end else if(!upload||nonce!=upload_id||requested_title!=upload_title)finish(8'h55);
   else if(op==4&&request_length==6&&index[6]==0&&index[5:3]<=4&&index[0])begin pending_emergency_style<=index;finish(0);end
   else if(op==1&&request_length==134&&index==glyph_next&&glyph_next<glyph_count)begin
    extended_glyph<=0;state<=GLYPH;cursor<=6;last_byte<=133;read_wait<=0;assembled<=0;
   end else if(op==5&&request_length==134&&!upload_title&&pending_emergency_style[7]&&
     glyph_count==64&&index==extension_next&&extension_next<32)begin
    extended_glyph<=1;state<=GLYPH;cursor<=6;last_byte<=133;read_wait<=0;assembled<=0;
   end else if(op==2&&request_length>6&&request_length<=192&&index==raw_next&&
     raw_next+request_length-6<=192)begin
    state<=RAW;cursor<=6;last_byte<=request_length-1'b1;read_wait<=0;
   end else if(op==8'hfe&&request_length==6&&glyph_next==glyph_count&&raw_next==index&&
     (!pending_emergency_style[7]||glyph_count==0||(glyph_count==64&&extension_next==32))&&
     ((glyph_count==0&&index==0)||(glyph_count!=0&&index!=0)))state<=COMMIT;
   else finish(8'h47);
  end
  if(state==GLYPH||state==RAW)begin
   if(read_wait!=2)read_wait<=read_wait+1'b1;
   else begin
    read_wait<=0;cursor<=cursor+1'b1;
    if(state==GLYPH)begin
     assembled<={payload_byte,assembled[23:8]};
    end else raw_next<=raw_next+1'b1;
    if(cursor==last_byte)begin
     if(state==GLYPH)begin if(extended_glyph)extension_next<=extension_next+1'b1;else glyph_next<=glyph_next+1'b1;end
     finish(0);
    end
   end
  end
  if(state==COMMIT&&frame_boundary&&!owned_cancel&&(!STYLE_PERSISTENCE||upload_title||!style_source_lock))begin
   if(upload_title)begin title_descriptor<={target_bank,title_zoom,glyph_count[5:0]};title_front_length<=raw_next;end
   else begin descriptor<={target_bank,glyph_count};emergency_style<=pending_emergency_style;front_length<=raw_next;end
   upload<=0;finish(0);
  end
  if(state==STYLE&&frame_boundary&&!owned_cancel&&(!STYLE_PERSISTENCE||!style_source_lock))begin subtitle_style<={nonce,index};finish(0);end
  // No runtime request is accepted until this whole word is published. The
  // top-level settled gate also holds all root saves and namespace reservation.
  if(STYLE_PERSISTENCE&&!style_restore_settled&&style_restore_valid&&frame_boundary&&state==IDLE&&!result_valid&&!upload&&!style_source_lock)begin
   subtitle_style<=restored_styles[39:0];emergency_style<=restored_styles[47:40];style_restore_settled<=1;
  end
  // The command controller retains arguments until this response is captured.
  // Same-edge preemption asserts owned_cancel before any publication.
  // A cancellation never exposes a partial bank, including the commit edge.
  if(owned_cancel&&state!=IDLE)begin upload<=0;finish(8'h43);end
  if(reset_upload)upload<=0;
 end
end
endmodule
