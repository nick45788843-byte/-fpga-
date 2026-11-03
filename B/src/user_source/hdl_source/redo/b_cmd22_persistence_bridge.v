// Preserves CMD22 ownership: user success is emitted only after NOR marker
// readback. Boot replay obtains a fresh A-authorized UID through the existing
// text-grant allocator and reuses the unchanged production font stream.
module b_cmd22_persistence_bridge #(parameter DEGRADED_STARTUP_ENABLED=0)(
 input clk,rst_n,enabled,
 input live_start,input [1:0] live_target,input [7:0] live_length,
 input live_raw_valid,input [7:0] live_raw_byte,input cancel_valid,
 input stream_complete,input [7:0] stream_error,input stream_drained,
 output reg durable_complete,output reg [7:0] durable_error,
 input normal_idle,font_initialized,notice_valid,notice_session,
 output startup_ready,output restore_active,output restore_start,input restore_start_ready,
 output [31:0] restore_uid,output [1:0] restore_target,restore_size,
 output [6:0] restore_glyphs,output [7:0] restore_length,
 output restore_raw_valid,input restore_raw_ready,output [7:0] restore_raw_byte,output restore_raw_last,
 output restore_grant_needed,input restore_grant_valid,input [31:0] restore_granted_uid,
 output [7:0] restore_error,
 output journal_lease,journal_valid,input journal_ready,output [2:0] journal_operation,
 output [23:0] journal_address,output [6:0] journal_length,output [7:0] journal_write_byte,
 input [5:0] journal_write_index,input journal_done,journal_error,input [7:0] journal_error_code,
 input journal_byte_valid,input [7:0] journal_byte,input [5:0] journal_index,
 input [7:0] font_boot_error,
 input [1:0] live_size);
localparam R_BOOT=0,R_SELECT=1,R_GRANT=2,R_START=3,R_ADDR=4,R_WAIT=5,R_SEND=6,R_COMPLETE=7,R_DONE=8,R_DRAIN=9;
localparam S_IDLE=0,S_START=1,S_WAIT=2;
reg [3:0] restore_state;
reg [1:0] target;
reg [7:0] cursor;
reg [31:0] uid;
reg [1:0] save_state;
reg [7:0] last_restore_error;
wire boot_done,journal_idle,save_ready,save_done;
wire [7:0] boot_error,save_error,query_byte,query_length;
wire [3:0] target_valid;
wire [6:0] query_glyphs;wire [31:0] query_generation;wire [1:0] query_size;
// A terminal font failure must not hold unrelated parameter RPCs forever.
// Keep the font unavailable and the journal intact; a reset with a usable
// font follows the original restoration path before startup is released.
wire font_failed=DEGRADED_STARTUP_ENABLED&&!font_initialized&&font_boot_error!=0;
assign startup_ready=!enabled||(restore_state==R_DONE&&journal_idle&&save_state==S_IDLE);
assign restore_active=enabled&&(restore_state==R_START||restore_state==R_ADDR||restore_state==R_WAIT||restore_state==R_SEND||restore_state==R_COMPLETE||restore_state==R_DRAIN);
assign restore_start=enabled&&restore_state==R_START&&!notice_valid;
assign restore_uid=uid;assign restore_target=target;
assign restore_size=query_size;
assign restore_glyphs=query_glyphs;assign restore_length=query_length;
assign restore_raw_valid=enabled&&restore_state==R_SEND&&!notice_valid;
assign restore_raw_byte=query_byte;assign restore_raw_last=cursor+1'b1==query_length;
assign restore_grant_needed=enabled&&restore_state==R_GRANT&&!notice_valid;
assign restore_error=last_restore_error!=0?last_restore_error:boot_error;
b_cmd22_utf8_journal journal(.clk(clk),.rst_n(rst_n),
 .capture_start(enabled&&live_start),.capture_target(live_target),.capture_length(live_length),
 .capture_valid(enabled&&live_raw_valid),.capture_byte(live_raw_byte),
 .capture_cancel(cancel_valid||(stream_complete&&stream_error!=0&&!restore_active)),.capture_size(live_size),.query_size(query_size),
 .save_valid(save_state==S_START),.save_ready(save_ready),.save_done(save_done),.save_error(save_error),
 .boot_done(boot_done),.boot_error(boot_error),.idle(journal_idle),
 .query_target(target),.query_address(cursor),.query_byte(query_byte),.target_valid(target_valid),
 .query_length(query_length),.query_glyph_count(query_glyphs),.query_generation(query_generation),
 .journal_lease(journal_lease),.journal_valid(journal_valid),.journal_ready(journal_ready),.journal_operation(journal_operation),
 .journal_address(journal_address),.journal_length(journal_length),.journal_write_byte(journal_write_byte),.journal_write_index(journal_write_index),
 .journal_done(journal_done),.journal_error(journal_error),.journal_error_code(journal_error_code),
 .journal_byte_valid(journal_byte_valid),.journal_byte(journal_byte),.journal_index(journal_index));
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  restore_state<=R_BOOT;target<=0;cursor<=0;uid<=0;save_state<=S_IDLE;
  durable_complete<=0;durable_error<=0;last_restore_error<=0;
 end else begin
  durable_complete<=0;
  if(!enabled)begin
   restore_state<=R_DONE;
   if(stream_complete)begin durable_complete<=1;durable_error<=stream_error;end
  end else begin
   case(save_state)
    S_IDLE:if(stream_complete&&!restore_active)begin
     if(stream_error!=0)begin durable_complete<=1;durable_error<=stream_error;end
     else save_state<=S_START;
    end
    S_START:if(save_ready&&!cancel_valid)save_state<=S_WAIT;
     else if(cancel_valid&&journal_idle)begin durable_complete<=1;durable_error<=8'ha7;save_state<=S_IDLE;end
    S_WAIT:if(save_done)begin durable_complete<=1;durable_error<=save_error;save_state<=S_IDLE;end
    default:save_state<=S_IDLE;
   endcase
   if(notice_valid&&notice_session)restore_state<=R_DRAIN;
   else case(restore_state)
    R_BOOT:if(boot_done&&normal_idle&&(font_initialized||font_failed))begin
     target<=0;
     restore_state<=R_SELECT;
     if(font_failed)last_restore_error<=font_boot_error;
    end
    R_SELECT:if(!target_valid[target])begin
     if(target==3)restore_state<=R_DONE;else target<=target+1'b1;
    end else if(font_failed&&query_length!=0)begin
     if(target==3)restore_state<=R_DONE;else target<=target+1'b1;
    end else if((font_initialized||query_length==0)&&normal_idle&&stream_drained)restore_state<=R_GRANT;
    R_GRANT:if(restore_grant_valid)begin uid<=restore_granted_uid;cursor<=0;restore_state<=R_START;end
    R_START:if(restore_start&&restore_start_ready)restore_state<=query_length==0?R_COMPLETE:R_ADDR;
    R_ADDR:restore_state<=R_WAIT;
    R_WAIT:restore_state<=R_SEND;
    R_SEND:if(restore_raw_valid&&restore_raw_ready)begin
     if(restore_raw_last)restore_state<=R_COMPLETE;
     else begin cursor<=cursor+1'b1;restore_state<=R_ADDR;end
    end
    R_COMPLETE:if(stream_complete)begin
     if(stream_error!=0)last_restore_error<=stream_error;
     if(target==3)restore_state<=R_DONE;else begin target<=target+1'b1;restore_state<=R_SELECT;end
    end
    R_DRAIN:if(stream_drained&&journal_idle&&save_state==S_IDLE)begin target<=0;restore_state<=R_BOOT;end
    default:;
   endcase
  end
 end
end
endmodule
