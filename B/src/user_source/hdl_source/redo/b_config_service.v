// B配置协调器：Flash记录与参数处理驻B；仅在A应用确认后提交新参数。
module b_config_service #(parameter CLOCK_HZ=50000000,SPI_DIV=4,TEXT_ENABLED=0,GAMMA_ENABLED=0,SCALE_ENABLED=0,FONT_ENABLED=0,JOURNAL_ENABLED=0)(
 input journal_lease,journal_valid,output journal_ready,input [2:0] journal_operation,
 input [23:0] journal_address,input [6:0] journal_length,input [7:0] journal_write_byte,
 output [5:0] journal_write_index,output journal_done,journal_error,
 output [7:0] journal_error_code,output journal_byte_valid,output [7:0] journal_byte,output [5:0] journal_index,
 input clk,rst_n,request_valid,output request_ready,input [31:0] request_token,input [7:0] request_cmd,input [15:0] request_length,input [47:0] request_args,
 output reply_valid,input reply_ready,output [31:0] reply_token,output [191:0] reply_payload,
 output colour_values_valid,output [71:0] colour_values,
 output actuation_request,output [31:0] actuation_token,output [71:0] actuation_values,input actuation_done,input [7:0] actuation_error,
 input [7:0] legacy_flags,legacy_text_summary,input [71:0] legacy_values,
 output reg snapshot_valid,input snapshot_ready,output reg [191:0] snapshot_payload,output [23:0] snapshot_jedec,
 output reg event_valid,output reg [127:0] event_data,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso,
 input notice_valid,input [31:0] notice_token,input notice_session,input transport_idle,
 output control_done,output [31:0] control_done_token,
 input persist_valid,input [31:0] persist_token,input [6:0] persist_count,
 output reg [5:0] persist_address,input [7:0] persist_byte,output persist_done,output [7:0] persist_error,
 output text_storage_ready,text_storage_busy,output [15:0] text_storage_descriptor,
 input text_restore_lock,input [5:0] text_restore_address,output [7:0] text_restore_byte,
 input text_restore_ack,input [15:0] text_restored_descriptor,
 output [7:0] colour_gamma,actuation_gamma,live_scale,actuation_scale,
 input font_request_valid,output font_request_ready,input [15:0] font_request_codepoint,
 input [1:0] font_request_size,input [31:0] font_request_token,input font_request_cancel,
 output font_glyph_valid,input font_glyph_ready,output [7:0] font_glyph_byte,output [8:0] font_glyph_index,
 output font_glyph_first,font_glyph_last,output [31:0] font_glyph_token,
 output font_request_complete,output [7:0] font_request_result,output font_initialized,output [7:0] font_boot_error);
localparam BOOT=0,RESTORE=1,IMPORT=2,RUN=3;
localparam T_IDLE=0,T_ADDR=1,T_WAIT=2,T_WRITE=3,T_COMMIT=4,T_SET_WAIT=5,T_SAVE=6,T_SAVING=7,T_DONE=8;
reg [3:0] text_state;reg [5:0] text_cursor,text_write_address;reg [6:0] text_count;reg text_bank;
reg [7:0] text_write_byte;
reg [31:0] text_owner;reg [15:0] pending_text_descriptor;reg [7:0] text_result;
reg text_we,text_update,text_save;
reg [1:0] state;reg importing;
reg command_owned;reg [31:0] command_owner;
wire affected=notice_valid&&(notice_session||notice_token==command_owner);
wire [31:0] stable_token=command_owned?command_owner:request_token;
wire backend_reply,backend_reply_ready;wire [31:0] backend_reply_token;wire [191:0] backend_payload;
reg [71:0] boot_values,applied_values;reg applied_valid;
reg [7:0] boot_gamma,applied_gamma;
reg [7:0] boot_scale,applied_scale;
reg boot_set,boot_save;reg [31:0] timer;
wire ready,stored,dirty,can_save,busy,rejected,load_done,save_done,save_failed;wire [7:0] error;
wire [71:0] live_values,set_values;wire [31:0] generation,saved_generation;wire [23:0] jedec;
wire set_valid,save_request,backend_ready,backend_act;wire [71:0] backend_wanted;
wire [7:0] live_gamma,saved_gamma,set_gamma,backend_gamma;
wire [7:0] saved_scale,set_scale,backend_scale;
wire font_mem_valid,font_mem_ready,font_mem_done,font_mem_error,font_mem_byte_valid;
wire [23:0] font_mem_address;wire [6:0] font_mem_length;
wire [7:0] font_mem_error_code,font_mem_byte;wire [5:0] font_mem_index;
localparam [7:0] WRITABLE=8'h3f|(GAMMA_ENABLED?8'h40:8'd0)|(SCALE_ENABLED?8'h80:8'd0);
wire [7:0] flags={3'd0,(applied_valid&&applied_values==live_values&&(!GAMMA_ENABLED||applied_gamma==live_gamma)&&(!SCALE_ENABLED||applied_scale==live_scale)),can_save,dirty,stored,ready};
wire [191:0] current_snapshot={saved_generation,generation,legacy_text_summary,error,WRITABLE,live_values[7:0],live_values[39:8],live_values[47:40],live_values[55:48],live_values[63:56],live_values[71:64],flags,8'd0,(ready?8'd0:8'd1),8'd3};
reg [191:0] previous_snapshot;reg sent_snapshot,ready_announced;reg [7:0] previous_error;
assign request_ready=state==RUN&&backend_ready&&!command_owned&&!notice_valid&&(!TEXT_ENABLED||text_state==T_IDLE);
assign reply_valid=backend_reply&&!affected;assign reply_token=backend_reply_token;assign reply_payload=backend_payload;
assign backend_reply_ready=reply_ready&&!affected||affected&&backend_reply;
assign control_done=notice_valid&&transport_idle&&!busy&&(!TEXT_ENABLED||text_state==T_IDLE)&&
 (state==RUN||state==BOOT)&&(!affected||(!command_owned&&backend_ready));
assign control_done_token=notice_token;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin command_owned<=0;command_owner<=0;end
 else begin
  if(request_valid&&request_ready)begin command_owned<=1;command_owner<=request_token;end
  if(backend_reply&&backend_reply_ready)command_owned<=0;
 end
end
assign snapshot_jedec=jedec;
assign actuation_request=state==RESTORE||state==RUN&&backend_act;
// Only a qualified APPLY/RESTORE exposes this output. command_owner was
// captured on admission before APPLY; unrelated next-request pins cannot enter
// the active cancellation/geometry cone. The backend admission still uses
// stable_token so it captures the new UID on the same acceptance edge.
assign actuation_token=state==RESTORE?32'd0:command_owner;
assign actuation_values=state==RESTORE?boot_values:backend_wanted;
assign actuation_gamma=GAMMA_ENABLED?(state==RESTORE?boot_gamma:backend_gamma):8'd2;
assign actuation_scale=SCALE_ENABLED?(state==RESTORE?boot_scale:backend_scale):8'd0;
assign colour_values_valid=actuation_request||applied_valid;
assign colour_values=actuation_request?actuation_values:applied_values;
assign colour_gamma=actuation_request?actuation_gamma:applied_gamma;
wire [15:0] storage_descriptor;
wire text_lock=TEXT_ENABLED&&(text_restore_lock||persist_valid&&text_state==T_IDLE||
 (text_state>=T_ADDR&&text_state<=T_SET_WAIT));
assign text_storage_ready=ready;assign text_storage_busy=busy;
assign text_storage_descriptor=storage_descriptor;
assign persist_done=TEXT_ENABLED&&text_state==T_DONE;assign persist_error=text_result;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  text_state<=T_IDLE;text_cursor<=0;text_count<=0;text_bank<=0;text_owner<=0;pending_text_descriptor<=0;
  text_result<=0;text_we<=0;text_update<=0;text_save<=0;persist_address<=0;text_write_address<=0;text_write_byte<=0;
 end else begin
  text_we<=0;text_update<=0;text_save<=0;
  case(text_state)
   T_IDLE:if(TEXT_ENABLED&&persist_valid&&ready&&!busy&&!command_owned&&backend_ready)begin
    text_owner<=persist_token;text_count<=persist_count;text_cursor<=0;text_bank<=!storage_descriptor[7];
    pending_text_descriptor<={(storage_descriptor[15:8]==255?8'd1:storage_descriptor[15:8]+8'd1),!storage_descriptor[7],persist_count};
    text_state<=T_ADDR;
   end
   T_ADDR:begin persist_address<=text_cursor;text_state<=T_WAIT;end
   T_WAIT:text_state<=T_WRITE;
   T_WRITE:begin
    text_we<=1;text_write_address<=text_cursor;text_write_byte<={1'b0,text_cursor}<text_count?persist_byte:8'd0;
    if(text_cursor==63)text_state<=T_COMMIT;else begin text_cursor<=text_cursor+1'b1;text_state<=T_ADDR;end
   end
   T_COMMIT:begin text_update<=1;text_state<=T_SET_WAIT;end
   T_SET_WAIT:if(storage_descriptor==pending_text_descriptor)text_state<=T_SAVE;
   T_SAVE:begin text_save<=1;text_state<=T_SAVING;end
   T_SAVING:if(save_done||save_failed)begin text_result<=save_failed?(error==0?8'h75:error):8'd0;text_state<=T_DONE;end
   T_DONE:if(!persist_valid)text_state<=T_IDLE;
   default:text_state<=T_IDLE;
  endcase
 end
end
flash_config_service #(.LEGACY_TEXT(TEXT_ENABLED),.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(SPI_DIV),.GAMMA_ENABLED(GAMMA_ENABLED),.SCALE_ENABLED(SCALE_ENABLED),.FONT_ENABLED(FONT_ENABLED),.JOURNAL_ENABLED(JOURNAL_ENABLED)) storage(.clk(clk),.rst_n(rst_n),
 .text_query_lock(text_lock),.query_address(TEXT_ENABLED?text_restore_address:6'd0),.query_byte(text_restore_byte),.live_text_descriptor(storage_descriptor),
 .glyph_we(TEXT_ENABLED&&text_we),.glyph_bank(text_bank),.glyph_address(text_write_address),.glyph_byte(text_write_byte),
 .text_update_valid(TEXT_ENABLED&&(text_update||text_restore_ack)),.text_descriptor(text_update?pending_text_descriptor:text_restored_descriptor),
 .restore_we(),.restore_bank(),.restore_valid(),.restore_address(),.restore_glyph(),.restore_descriptor(),
 .mode_update_valid(1'b0),.mode_values(3'd0),.live_mode(),.saved_mode(),
 .cfg_update_valid(boot_set||set_valid),.cfg_values(boot_set?boot_values:set_values),.save_request(boot_save||save_request||text_save),
 .ready(ready),.load_done(load_done),.update_rejected(rejected),.save_done(save_done),.save_failed(save_failed),.dirty(dirty),.stored_valid(stored),.busy(busy),.can_save(can_save),.error_code(error),.jedec_id(jedec),.live_values(live_values),.generation(generation),.saved_generation(saved_generation),
 .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),.flash_miso(flash_miso),.flash_wp_n(),.flash_hold_n(),
 .gamma_update_valid(GAMMA_ENABLED&&set_valid),.gamma_value(set_gamma),.live_gamma(live_gamma),.saved_gamma(saved_gamma),
 .scale_update_valid(SCALE_ENABLED&&set_valid),.scale_value(set_scale),.live_scale(live_scale),.saved_scale(saved_scale),
 .journal_lease(journal_lease),.journal_valid(journal_valid),.journal_ready(journal_ready),.journal_operation(journal_operation),
 .journal_address(journal_address),.journal_length(journal_length),.journal_write_byte(journal_write_byte),.journal_write_index(journal_write_index),
 .journal_done(journal_done),.journal_error(journal_error),.journal_error_code(journal_error_code),
 .journal_byte_valid(journal_byte_valid),.journal_byte(journal_byte),.journal_index(journal_index),
 .font_valid(font_mem_valid),.font_ready(font_mem_ready),.font_address(font_mem_address),.font_length(font_mem_length),
 .font_done(font_mem_done),.font_error(font_mem_error),.font_error_code(font_mem_error_code),
 .font_byte_valid(font_mem_byte_valid),.font_byte(font_mem_byte),.font_index(font_mem_index));
b_font_reader font_reader(.clk(clk),.rst_n(rst_n),.request_valid(FONT_ENABLED&&font_request_valid),.request_ready(font_request_ready),
 .request_codepoint(font_request_codepoint),.request_size(font_request_size),.request_token(font_request_token),.cancel(font_request_cancel),
 .initialized(font_initialized),.boot_error(font_boot_error),.glyph_valid(font_glyph_valid),.glyph_ready(font_glyph_ready),
 .glyph_byte(font_glyph_byte),.glyph_index(font_glyph_index),.glyph_first(font_glyph_first),.glyph_last(font_glyph_last),.glyph_token(font_glyph_token),
 .complete(font_request_complete),.result(font_request_result),.mem_valid(font_mem_valid),.mem_ready(font_mem_ready),
 .mem_address(font_mem_address),.mem_length(font_mem_length),.mem_done(font_mem_done),.mem_error(font_mem_error),.mem_error_code(font_mem_error_code),
 .mem_byte_valid(font_mem_byte_valid),.mem_byte(font_mem_byte),.mem_index(font_mem_index));
// The backend captures command/length/arguments on this same acceptance edge.
// The coordinator keeps only the owner needed for actuation and cancellation.
b_parameter_service #(.CLOCK_HZ(CLOCK_HZ),.GAMMA_ENABLED(GAMMA_ENABLED),.SCALE_ENABLED(SCALE_ENABLED),.APPLY_TIMEOUT_SECONDS(SCALE_ENABLED?30:1)) backend(.clk(clk),.rst_n(rst_n),.request_valid(request_valid&&request_ready),.request_ready(backend_ready),.request_token(stable_token),.request_cmd(request_cmd),.request_length(request_length),.request_args(request_args),
 .reply_valid(backend_reply),.reply_ready(backend_reply_ready),.reply_token(backend_reply_token),.reply_payload(backend_payload),
 .cfg_ready(ready),.cfg_stored(stored),.cfg_dirty(dirty),.cfg_can_save(can_save),.cfg_rejected(rejected),.cfg_error(error),.cfg_values(live_values),.cfg_generation(generation),.cfg_saved_generation(saved_generation),.text_summary(legacy_text_summary),
 .applied_valid(applied_valid),.applied_values(applied_values),.actuation_request(backend_act),.actuation_values(backend_wanted),.actuation_done(actuation_done&&state==RUN),.actuation_error(actuation_error),.cfg_set_valid(set_valid),.cfg_set_values(set_values),.cfg_save_request(save_request),.cfg_save_done(save_done),.cfg_save_failed(save_failed),.cfg_busy(busy),
 .cfg_gamma(live_gamma),.applied_gamma(applied_gamma),.actuation_gamma(backend_gamma),.cfg_set_gamma(set_gamma),
 .cfg_scale(live_scale),.applied_scale(applied_scale),.actuation_scale(backend_scale),.cfg_set_scale(set_scale));
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin ready_announced<=0;state<=BOOT;importing<=0;boot_values<=0;boot_gamma<=2;applied_gamma<=2;boot_scale<=0;applied_scale<=0;boot_set<=0;boot_save<=0;timer<=0;applied_values<=0;applied_valid<=0;snapshot_valid<=0;snapshot_payload<=0;previous_snapshot<=0;sent_snapshot<=0;previous_error<=0;event_valid<=0;event_data<=0;end
 else begin
  boot_set<=0;boot_save<=0;event_valid<=0;
  if(snapshot_valid&&snapshot_ready)begin snapshot_valid<=0;previous_snapshot<=snapshot_payload;sent_snapshot<=1;end
  else if(!snapshot_valid&&(!sent_snapshot||current_snapshot!=previous_snapshot))begin snapshot_payload<=current_snapshot;snapshot_valid<=1;end
  if(ready&&error!=previous_error)begin previous_error<=error;event_valid<=1;event_data<={(error==0?8'd2:8'd1),8'd9,error,8'd0,32'd0,{8'd0,jedec},32'd0};end
  if(save_done)begin event_valid<=1;event_data<={8'd4,8'd9,8'h30,8'd0,32'd0,saved_generation,32'd0};end
  if(state==RUN&&!ready_announced)begin ready_announced<=1;event_valid<=1;event_data<={8'd4,8'd9,8'h32,8'd0,32'd0,{31'd0,stored},32'd0};end
  if(state==RUN&&backend_act&&actuation_done&&actuation_error==0)begin applied_values<=backend_wanted;applied_gamma<=backend_gamma;applied_scale<=backend_scale;applied_valid<=1;end
  case(state)
   BOOT:if(ready&&legacy_flags[0]&&!notice_valid)begin importing<=!stored&&legacy_flags[1];boot_values<=(!stored&&legacy_flags[1])?legacy_values:live_values;boot_gamma<=live_gamma;boot_scale<=live_scale;state<=RESTORE;timer<=0;end
   RESTORE:if(notice_valid&&(notice_session||notice_token==32'd0))begin
    // A global flush may have already revoked the private apply ACK. Drop the
    // cancelled boot request now; the retained transport descriptor still drains
    // normally, and control_done still requires real transport idle and !busy.
    state<=BOOT;timer<=0;
   end else if(actuation_done)begin
    if(actuation_error==0)begin applied_values<=boot_values;applied_gamma<=boot_gamma;applied_scale<=boot_scale;applied_valid<=1;if(importing)begin boot_set<=1;state<=IMPORT;timer<=0;end else state<=RUN;end
    // The completed operation can report CANCELLED after its notice has
    // already drained and disappeared. A cancelled restore never established
    // applied_values; retry the immutable live record instead of opening RUN.
    else if(actuation_error==8'h43||notice_valid)state<=BOOT;
    else begin state<=RUN;event_valid<=1;event_data<={8'd1,8'd9,actuation_error,8'd0,32'd0,32'd0,32'd0};end
   end else if(timer>=CLOCK_HZ*8-1)begin state<=RUN;event_valid<=1;event_data<={8'd1,8'd9,8'h48,8'd0,32'd0,32'd0,32'd0};end else timer<=timer+1'b1;
   IMPORT:if(live_values==boot_values)begin if(can_save)boot_save<=1;state<=RUN;end
     else if(timer>=CLOCK_HZ-1)begin state<=RUN;event_valid<=1;event_data<={8'd1,8'd9,8'h48,8'd0,32'd0,32'd0,32'd0};end else timer<=timer+1'b1;
   default:state<=state;
  endcase
 end
end
endmodule
