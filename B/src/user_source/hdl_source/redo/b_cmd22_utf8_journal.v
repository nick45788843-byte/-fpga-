// Four CMD22 targets, two 4KiB slots each at 7e0000..7e7fff.
// UTX1 v1 header and CRC are compatible with the retained format model.
// Bytes 0..11 header, 12..13 CRC16, 14..205 exact UTF8; byte4095=A5 LAST.
// Byte5: bit7=size-present, bits3:2=actual size, bits1:0=target.
// Old byte5=target records retain target defaults (0/0/2/1). A committed
// zero-length record is a tombstone, retained as the newest valid generation.
// Glyph count is recovered by strict BMP UTF8 validation.
module b_cmd22_utf8_journal(
 input clk,rst_n,
 input capture_start,input [1:0] capture_target,input [7:0] capture_length,
 input capture_valid,input [7:0] capture_byte,input capture_cancel,
 input save_valid,output save_ready,output reg save_done,output reg [7:0] save_error,
 output reg boot_done,output reg [7:0] boot_error,output idle,
 input [1:0] query_target,input [7:0] query_address,output [7:0] query_byte,
 output [3:0] target_valid,output [7:0] query_length,output [6:0] query_glyph_count,
 output [31:0] query_generation,
 output journal_lease,journal_valid,input journal_ready,output reg [2:0] journal_operation,
 output reg [23:0] journal_address,output reg [6:0] journal_length,output [7:0] journal_write_byte,
 input [5:0] journal_write_index,input journal_done,journal_error,input [7:0] journal_error_code,
 input journal_byte_valid,input [7:0] journal_byte,input [5:0] journal_index,
 input [1:0] capture_size,output [1:0] query_size);
localparam SCAN_INIT=0,READ=1,READ_WAIT=2,MARK_READ=3,MARK_WAIT=4,ACCEPT=5,IDLE=6,
 CRC_HEAD=7,CRC_ADDR=8,CRC_WAIT=9,CRC_STEP=10,ERASE=11,ERASE_WAIT=12,
 HEAD_WRITE=13,HEAD_WAIT=14,BODY_WRITE=15,BODY_WAIT=16,VERIFY_INIT=17,
 COMMIT=18,COMMIT_WAIT=19,COMMIT_READ=20,COMMIT_READ_WAIT=21;
reg [4:0] state;
reg [2:0] slot;
reg [3:0] valid_front,front_slot;
reg [31:0] generation[0:3];
reg [7:0] lengths[0:3];
reg [6:0] glyphs[0:3];
reg [1:0] sizes[0:3];
reg [1:0] owner_size,read_size;
(* force_ram=1,ram_style="bram_9k" *) reg [7:0] cache[0:2047];
reg [7:0] ram_byte;
reg capturing,verifying,abort_pending;
reg [1:0] owner_target;
reg owner_slot;
reg [7:0] owner_length,capture_index,body_offset,crc_cursor;
reg [31:0] owner_generation;
reg [15:0] save_crc,read_crc,stored_crc;
reg [7:0] read_length,read_length_high,marker;
reg [31:0] read_generation;
reg header_ok,utf8_ok;
reg [1:0] continuation;
// The only strict BMP continuation exceptions are E0 A0..BF and ED 80..9F.
reg continuation_min_a0,continuation_max_9f;
// Eight bits prevent 128..192 ASCII codepoints from wrapping into a legal
// <=64 glyph count while scanning a CRC-valid but semantically invalid slot.
reg [7:0] read_glyphs;
wire [7:0] absolute_index=body_offset+{2'd0,journal_index};
wire scanning=state==READ_WAIT;
wire [7:0] payload_index=absolute_index-8'd14;
wire payload_byte=absolute_index>=14&&payload_index<read_length;
wire [2:0] owner_cache_slot={owner_target,owner_slot};
wire crc_body=state==CRC_ADDR||state==CRC_WAIT||state==CRC_STEP;
wire program_body=state==BODY_WRITE||state==BODY_WAIT;
wire [10:0] ram_address=crc_body?{owner_cache_slot,crc_cursor}:
 program_body?{owner_cache_slot,body_offset+{2'd0,journal_write_index}}:
 {query_target,front_slot[query_target],query_address};
assign query_byte=ram_byte;
assign target_valid=valid_front;
assign query_length=lengths[query_target];
assign query_glyph_count=glyphs[query_target];
assign query_generation=generation[query_target];
assign query_size=sizes[query_target];
assign idle=state==IDLE&&!capturing;
assign save_ready=state==IDLE&&capturing;
assign journal_lease=state!=IDLE;
wire commit_stage=state==COMMIT_WAIT||state==COMMIT_READ||state==COMMIT_READ_WAIT;
assign journal_valid=(state==READ||state==MARK_READ||state==ERASE||state==HEAD_WRITE||
 state==BODY_WRITE||state==COMMIT||state==COMMIT_READ)&&
 !(capture_cancel&&verifying&&!commit_stage);
function [15:0] crc_byte;
 input [15:0] prior;input [7:0] data;reg [15:0] c;integer k;
 begin c=prior^{data,8'd0};for(k=0;k<8;k=k+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
endfunction
function [7:0] header_byte;
 input [5:0] index;
 begin case(index)
  0:header_byte=8'h55;1:header_byte=8'h54;2:header_byte=8'h58;3:header_byte=8'h31;
  4:header_byte=1;5:header_byte={1'b1,3'd0,owner_size,owner_target};
  6:header_byte=owner_generation[7:0];7:header_byte=owner_generation[15:8];
  8:header_byte=owner_generation[23:16];9:header_byte=owner_generation[31:24];
  10:header_byte=owner_length;11:header_byte=0;
  12:header_byte=save_crc[7:0];13:header_byte=save_crc[15:8];
  default:header_byte=8'hff;
 endcase end
endfunction
// Scan and save CRC steps are mutually exclusive; one unrolled byte CRC
// retains the original one-byte-per-clock interface throughput.
wire [15:0] crc_prior=scanning?read_crc:save_crc;
wire [7:0] crc_input=scanning?journal_byte:
 state==CRC_HEAD?header_byte({2'd0,crc_cursor[3:0]}):ram_byte;
wire [15:0] crc_next=crc_byte(crc_prior,crc_input);
assign journal_write_byte=state==COMMIT||state==COMMIT_WAIT?8'ha5:
 program_body?ram_byte:header_byte(journal_write_index);
always @(*)begin
 journal_operation=0;journal_length=64;
 journal_address={9'h0fc,slot,4'd0,body_offset};
 case(state)
  MARK_READ,MARK_WAIT:begin journal_address={9'h0fc,slot,12'hfff};journal_length=1;end
  ERASE,ERASE_WAIT:begin journal_operation=2;journal_address={9'h0fc,owner_cache_slot,12'd0};journal_length=0;end
  HEAD_WRITE,HEAD_WAIT:begin journal_operation=1;journal_address={9'h0fc,owner_cache_slot,12'd0};journal_length=14;end
  BODY_WRITE,BODY_WAIT:begin journal_operation=1;journal_address={9'h0fc,owner_cache_slot,4'd0,(body_offset+8'd14)};
   journal_length=owner_length-body_offset>64?7'd64:owner_length-body_offset;end
  COMMIT,COMMIT_WAIT:begin journal_operation=1;journal_address={9'h0fc,owner_cache_slot,12'hfff};journal_length=1;end
  COMMIT_READ,COMMIT_READ_WAIT:begin journal_address={9'h0fc,owner_cache_slot,12'hfff};journal_length=1;end
  default:;
 endcase
end
wire marker_now=journal_byte_valid?journal_byte==8'ha5:marker==8'ha5;
wire size_valid=(slot[2:1]==0&&read_size==0)||(slot[2:1]==1&&read_size<=1)||
 (slot[2:1]==2&&read_size==2)||(slot[2:1]==3&&read_size==1);
wire record_valid=header_ok&&size_valid&&read_length_high==0&&read_length<=192&&
 read_generation!=0&&read_crc==stored_crc&&utf8_ok&&continuation==0&&
 ((read_length==0&&read_glyphs==0)||(read_length!=0&&read_glyphs!=0))&&
 read_glyphs<=64&&(slot[2:1]!=1||read_glyphs<=32)&&(slot[2:1]!=2||read_glyphs<=8)&&
 (slot[2:1]!=3||read_glyphs<=32);
integer t;
task finish_save;input [7:0] code;
 begin save_done<=1;save_error<=code;capturing<=0;verifying<=0;abort_pending<=0;state<=IDLE;end
endtask
always @(posedge clk)begin
 ram_byte<=cache[ram_address];
 if(scanning&&journal_byte_valid&&payload_byte)cache[{slot,payload_index}]<=journal_byte;
 if(capture_valid&&capturing&&state==IDLE&&capture_index<owner_length)cache[{owner_cache_slot,capture_index}]<=capture_byte;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=SCAN_INIT;slot<=0;valid_front<=0;front_slot<=0;capturing<=0;verifying<=0;abort_pending<=0;
  boot_done<=0;boot_error<=0;save_done<=0;save_error<=0;
  owner_target<=0;owner_slot<=0;owner_length<=0;owner_generation<=0;capture_index<=0;owner_size<=0;read_size<=0;
  body_offset<=0;crc_cursor<=0;save_crc<=16'hffff;read_crc<=16'hffff;stored_crc<=0;
  read_length<=0;read_length_high<=0;read_generation<=0;marker<=0;header_ok<=1;utf8_ok<=1;
  continuation<=0;continuation_min_a0<=0;continuation_max_9f<=0;read_glyphs<=0;
  for(t=0;t<4;t=t+1)begin generation[t]<=0;lengths[t]<=0;glyphs[t]<=0;sizes[t]<=t==2?2:t==3?1:0;end
 end else begin
  save_done<=0;
  if(capture_valid&&capturing&&state==IDLE&&capture_index<owner_length)capture_index<=capture_index+1'b1;
  if(capture_cancel&&capturing&&!commit_stage)abort_pending<=1;
  if(scanning&&journal_byte_valid)begin
   if(absolute_index<12||payload_byte)read_crc<=crc_next;
   case(absolute_index)
    0:if(journal_byte!=8'h55)header_ok<=0;
    1:if(journal_byte!=8'h54)header_ok<=0;
    2:if(journal_byte!=8'h58)header_ok<=0;
    3:if(journal_byte!=8'h31)header_ok<=0;
    4:if(journal_byte!=1)header_ok<=0;
    5:begin
     if(journal_byte[1:0]!=slot[2:1]||
        (journal_byte[7]?(journal_byte[6:4]!=0||journal_byte[3:2]>2):journal_byte[7:2]!=0))header_ok<=0;
     read_size<=journal_byte[7]?journal_byte[3:2]:(slot[2:1]==2?2'd2:slot[2:1]==3?2'd1:2'd0);
    end
    6:read_generation[7:0]<=journal_byte;7:read_generation[15:8]<=journal_byte;
    8:read_generation[23:16]<=journal_byte;9:read_generation[31:24]<=journal_byte;
    10:read_length<=journal_byte;11:read_length_high<=journal_byte;
    12:stored_crc[7:0]<=journal_byte;13:stored_crc[15:8]<=journal_byte;
    default:;
   endcase
   if(payload_byte)begin
    if(continuation!=0)begin
     if(journal_byte[7:6]!=2'b10||(continuation_min_a0&&!journal_byte[5])||(continuation_max_9f&&journal_byte[5]))utf8_ok<=0;
     continuation<=continuation-1'b1;continuation_min_a0<=0;continuation_max_9f<=0;
    end else begin
     read_glyphs<=read_glyphs+1'b1;
     if(journal_byte<8'h80)begin if(journal_byte==0)utf8_ok<=0;end
     else if(journal_byte>=8'hc2&&journal_byte<=8'hdf)continuation<=1;
     else if(journal_byte>=8'he0&&journal_byte<=8'hef)begin
      continuation<=2;continuation_min_a0<=journal_byte==8'he0;
      continuation_max_9f<=journal_byte==8'hed;
     end else utf8_ok<=0;
    end
   end
  end
  if(state==MARK_WAIT&&journal_byte_valid)marker<=journal_byte;
  if(state==COMMIT_READ_WAIT&&journal_byte_valid)marker<=journal_byte;
  case(state)
   SCAN_INIT,VERIFY_INIT:begin
    body_offset<=0;read_crc<=16'hffff;stored_crc<=0;header_ok<=1;utf8_ok<=1;
    read_length<=0;read_length_high<=0;read_generation<=0;marker<=0;read_size<=0;
    continuation<=0;continuation_min_a0<=0;continuation_max_9f<=0;read_glyphs<=0;state<=READ;
   end
   READ:if(verifying&&(abort_pending||capture_cancel))finish_save(8'ha7);
    else if(journal_valid&&journal_ready)state<=READ_WAIT;
   READ_WAIT:if(journal_done)begin
    if(journal_error)begin
     if(verifying)finish_save(journal_error_code);else begin boot_error<=journal_error_code;state<=ACCEPT;header_ok<=0;end
    end else if(body_offset==192)state<=verifying?ACCEPT:MARK_READ;
    else begin body_offset<=body_offset+64;state<=READ;end
   end
   MARK_READ:if(journal_valid&&journal_ready)state<=MARK_WAIT;
   MARK_WAIT:if(journal_done)begin if(journal_error)header_ok<=0;state<=ACCEPT;end
   ACCEPT:if(verifying)begin
    if(abort_pending||capture_cancel)finish_save(8'ha7);
    else if(!record_valid||read_generation!=owner_generation||read_length!=owner_length||stored_crc!=save_crc)finish_save(8'ha5);
    else state<=COMMIT;
   end else begin
    if(record_valid&&marker==8'ha5&&(!valid_front[slot[2:1]]||read_generation>generation[slot[2:1]]))begin
     valid_front[slot[2:1]]<=1;front_slot[slot[2:1]]<=slot[0];generation[slot[2:1]]<=read_generation;
     lengths[slot[2:1]]<=read_length;glyphs[slot[2:1]]<=read_glyphs[6:0];sizes[slot[2:1]]<=read_size;
    end
    if(slot==7)begin boot_done<=1;state<=IDLE;end
    else begin slot<=slot+1'b1;state<=SCAN_INIT;end
   end
   IDLE:begin
    if(capture_cancel&&capturing)begin capturing<=0;abort_pending<=0;end
    else if(capture_start&&!capturing&&capture_length<=192)begin
     capturing<=1;owner_target<=capture_target;owner_slot<=valid_front[capture_target]?!front_slot[capture_target]:1'b0;
     owner_length<=capture_length;owner_size<=capture_size;capture_index<=0;abort_pending<=0;save_error<=0;
     owner_generation<=generation[capture_target]+1'b1;
    end else if(save_valid&&save_ready)begin
     if(capture_index!=owner_length)finish_save(8'ha2);
     else if(owner_generation==0)finish_save(8'ha8);
     else begin save_crc<=16'hffff;crc_cursor<=0;state<=CRC_HEAD;end
    end
   end
   CRC_HEAD:begin
    save_crc<=crc_next;
    if(crc_cursor==11)begin crc_cursor<=0;state<=owner_length==0?ERASE:CRC_ADDR;end else crc_cursor<=crc_cursor+1'b1;
   end
   CRC_ADDR:state<=CRC_WAIT;
   CRC_WAIT:state<=CRC_STEP;
   CRC_STEP:begin
    save_crc<=crc_next;
    if(crc_cursor+1'b1==owner_length)state<=ERASE;
    else begin crc_cursor<=crc_cursor+1'b1;state<=CRC_ADDR;end
   end
   ERASE:if(abort_pending||capture_cancel)finish_save(8'ha7);else if(journal_valid&&journal_ready)state<=ERASE_WAIT;
   ERASE_WAIT:if(journal_done)begin if(journal_error)finish_save(journal_error_code);else state<=HEAD_WRITE;end
   HEAD_WRITE:if(abort_pending||capture_cancel)finish_save(8'ha7);else if(journal_valid&&journal_ready)state<=HEAD_WAIT;
   HEAD_WAIT:if(journal_done)begin
    if(journal_error)finish_save(journal_error_code);else begin
     body_offset<=0;
     if(owner_length==0)begin slot<=owner_cache_slot;verifying<=1;state<=VERIFY_INIT;end
     else state<=BODY_WRITE;
    end
   end
   BODY_WRITE:if(abort_pending||capture_cancel)finish_save(8'ha7);else if(journal_valid&&journal_ready)state<=BODY_WAIT;
   BODY_WAIT:if(journal_done)begin
    if(journal_error)finish_save(journal_error_code);
    else if({1'b0,body_offset}+journal_length>=owner_length)begin slot<=owner_cache_slot;verifying<=1;state<=VERIFY_INIT;end
    else begin body_offset<=body_offset+64;state<=BODY_WRITE;end
   end
   COMMIT:if(abort_pending||capture_cancel)finish_save(8'ha7);else if(journal_valid&&journal_ready)state<=COMMIT_WAIT;
   COMMIT_WAIT:if(journal_done)begin if(journal_error)finish_save(journal_error_code);else begin marker<=0;state<=COMMIT_READ;end end
   COMMIT_READ:if(journal_valid&&journal_ready)state<=COMMIT_READ_WAIT;
   COMMIT_READ_WAIT:if(journal_done)begin
    if(journal_error)finish_save(journal_error_code);
    else if(!marker_now)finish_save(8'ha5);
    else begin
     valid_front[owner_target]<=1;front_slot[owner_target]<=owner_slot;generation[owner_target]<=owner_generation;
     lengths[owner_target]<=owner_length;glyphs[owner_target]<=read_glyphs[6:0];sizes[owner_target]<=owner_size;finish_save(0);
    end
   end
   default:state<=SCAN_INIT;
  endcase
 end
end
endmodule
