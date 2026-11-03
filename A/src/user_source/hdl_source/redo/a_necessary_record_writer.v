// Specialized CNFG v3/v4 append/rollover writer. No UART/config-management/asset parser.
// Caller supplies the validated legacy anchor and holds the glyph source during source_lock.
module a_necessary_record_writer #(parameter EXTERNAL_CRC=0,ROOT_LEASE=0,CACHED_HEADER=0,STYLE_PERSISTENCE=0)(input clk,rst_n,
 input boot_ready,boot_found,boot_write_allowed,input [31:0] boot_sequence,input [7:0] boot_slot,
 input [71:0] boot_values,input [2:0] boot_mode,input boot_custom,input [6:0] boot_count,
 input request_valid,output request_ready,input [31:0] request_token,input [71:0] request_values,
 input [2:0] request_mode,input request_custom,input [6:0] request_count,
 output [5:0] glyph_address,input [7:0] glyph_byte,output source_lock,
 output reg done_valid,input done_ready,output reg [31:0] done_token,output reg [7:0] done_error,
 output reg stored_valid,output reg [31:0] saved_sequence,output reg [7:0] saved_slot,
 output reg [71:0] saved_values,output reg [2:0] saved_mode,output reg saved_custom,output reg [6:0] saved_count,
 output busy,can_save,
 output reg bus_start,output reg [2:0] bus_operation,output reg [23:0] bus_address,output reg [6:0] bus_length,
 output [7:0] bus_write_byte,input [5:0] bus_stream_index,
 input bus_done,bus_error,input [7:0] bus_error_code,
 input bus_read_valid,input [5:0] bus_read_index,input [7:0] bus_read_byte,output header_crc_clear,header_crc_enable,output [7:0] header_crc_byte,
 output body_crc_clear,body_crc_enable,output [7:0] body_crc_byte,input [15:0] external_header_crc,external_body_crc,
 output header_write_valid,output [5:0] header_write_address,output [7:0] header_write_byte,
 output header_read_select,
 input [47:0] request_styles,output style_source_lock);
 localparam MAX_VERSION=STYLE_PERSISTENCE?4:3;
 localparam IDLE=0,S_ADDR=1,S_WAIT=2,S_COPY=3,H_CRC=4,F_HEAD=5,F_HEAD_WAIT=6,F_BODY=7,F_BODY_WAIT=8,
  P_BODY=9,P_BODY_WAIT=10,P_HEAD=11,P_HEAD_WAIT=12,V_BODY=13,V_BODY_WAIT=14,V_HEAD=15,V_HEAD_WAIT=16,
  COMMIT=17,COMMIT_WAIT=18,FINAL=19,FINAL_WAIT=20,ACCEPT=21,ERASE=22,ERASE_WAIT=23;
 reg [4:0] state;reg initialized,protected_format,attempt_started;reg [31:0] private_owner,sequence_id;reg [71:0] private_values;
 wire [31:0] record_sequence=sequence_id+{31'd0,!attempt_started};
 reg [2:0] private_mode;reg private_custom;reg [6:0] private_count;reg [47:0] private_styles;
 wire [31:0] owner=ROOT_LEASE?request_token:private_owner;
 wire [71:0] values=ROOT_LEASE?request_values:private_values;
 wire [2:0] mode=ROOT_LEASE?request_mode:private_mode;
 wire custom=ROOT_LEASE?request_custom:private_custom;
 wire [6:0] count=ROOT_LEASE?request_count:private_count;
 wire [47:0] styles=ROOT_LEASE?request_styles:private_styles;
 reg [5:0] copy_address;
 wire body_access=state==P_BODY||state==P_BODY_WAIT||state==V_BODY||state==V_BODY_WAIT;
 wire header_access=state==P_HEAD||state==P_HEAD_WAIT||state==V_HEAD||state==V_HEAD_WAIT||state==FINAL||state==FINAL_WAIT;
 wire use_header_cache=ROOT_LEASE&&CACHED_HEADER;
 assign header_read_select=use_header_cache&&header_access;
 assign glyph_address=ROOT_LEASE&&(body_access||(CACHED_HEADER&&header_access))?bus_stream_index:copy_address;
 reg [5:0] index;reg [7:0] cursor,target,probed;
 reg [2:0] sector;reg erase_group;reg blank,verified;reg [31:0] magic;reg [7:0] version,marker;
 reg [15:0] private_body_crc,private_header_crc;
 wire [15:0] body_crc=EXTERNAL_CRC?external_body_crc:private_body_crc;
 wire [15:0] header_crc=EXTERNAL_CRC?external_header_crc:private_header_crc;wire [7:0] snapshot_byte;
 wire [7:0] normalized=custom&&{1'b0,index}<count?glyph_byte:8'd0;
 assign busy=state!=IDLE;assign source_lock=ROOT_LEASE?busy:(state==S_ADDR||state==S_WAIT||state==S_COPY);
 // sequence_id is the attempt watermark; a committed but unreadable attempt
 // must never share its sequence with a later, different payload.
 assign can_save=initialized&&boot_write_allowed&&!protected_format&&sequence_id!=32'hffffffff;
 assign style_source_lock=STYLE_PERSISTENCE&&ROOT_LEASE&&busy&&
  (!CACHED_HEADER||state==S_ADDR||state==S_WAIT||state==S_COPY||state==H_CRC);
 assign request_ready=initialized&&state==IDLE&&!done_valid;
 function [15:0] step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;step={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
 function valid_values;input [71:0] v;begin valid_values=v[71:64]<=100&&v[63:56]>=20&&v[63:56]<=100&&v[55:48]<=200&&v[47:40]<=200&&v[39:8]>=1000&&v[39:8]<=60000&&v[7:0]<=1;end endfunction
 function valid_styles;input [47:0] s;reg [7:0] emergency;begin
  emergency=s[47:40];valid_styles=!s[1]&&(emergency==0||(!emergency[6]&&emergency[5:3]<=4&&emergency[0]));
 end endfunction
 function [7:0] header;input [5:0] n;input committed;
 begin header=255;case(n)
  0:header=8'h43;1:header=8'h4e;2:header=8'h46;3:header=8'h47;4:header=STYLE_PERSISTENCE?4:3;5:header=64;
  8:header=record_sequence[7:0];9:header=record_sequence[15:8];10:header=record_sequence[23:16];11:header=record_sequence[31:24];
  12:header=values[71:64];13:header=values[63:56];14:header=values[55:48];15:header=values[47:40];
  16:header=values[15:8];17:header=values[23:16];18:header=values[31:24];19:header=values[39:32];20:header=values[7:0];
  21:header={5'd0,mode};22:header={7'd0,custom};23:header={1'b0,count};24:header=1;
  25:header=body_crc[7:0];26:header=body_crc[15:8];
  27:if(STYLE_PERSISTENCE)header=styles[7:0];28:if(STYLE_PERSISTENCE)header=styles[15:8];
  29:if(STYLE_PERSISTENCE)header=styles[23:16];30:if(STYLE_PERSISTENCE)header=styles[31:24];
  31:if(STYLE_PERSISTENCE)header=styles[39:32];32:if(STYLE_PERSISTENCE)header=styles[47:40];
  60:header=header_crc[7:0];61:header=header_crc[15:8];63:header=committed?8'd0:8'hff;
 endcase end endfunction
 assign body_crc_clear=state==IDLE&&request_valid&&request_ready;
 assign body_crc_enable=state==S_COPY&&!(custom&&index<count&&(normalized>251||normalized==95));
 assign body_crc_byte=normalized;
 assign header_crc_clear=state==S_COPY&&body_crc_enable&&index==63;
 assign header_crc_enable=state==H_CRC;
 wire [7:0] generated_header=header(index,1'b0);
 assign header_crc_byte=generated_header;
 // The unchanged blank-slot probe takes thousands of clocks. Its first four
 // clocks finish the CRC/reserved tail before any header programming can start.
 reg [2:0] header_tail;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)header_tail<=4;
  else if(state==IDLE)header_tail<=4;
  else if(state==H_CRC&&index==59)header_tail<=0;
  else if(header_tail<4)header_tail<=header_tail+1'b1;
 end
 assign header_write_valid=use_header_cache&&(state==H_CRC||(header_tail<4&&state!=IDLE));
 assign header_write_address=state==H_CRC?index:6'd60+{3'd0,header_tail};
 assign header_write_byte=state==H_CRC?generated_header:header_tail==0?header_crc[7:0]:header_tail==1?header_crc[15:8]:8'hff;
 assign bus_write_byte=state==P_BODY_WAIT?snapshot_byte:state==COMMIT_WAIT?8'd0:use_header_cache?glyph_byte:header(bus_stream_index,1'b0);
 wire body_matches_now=verified&&(!bus_read_valid||bus_read_byte==snapshot_byte);
 wire header_matches_now=verified&&(!bus_read_valid||bus_read_byte==(use_header_cache?(state==FINAL_WAIT&&bus_read_index==63?8'd0:glyph_byte):header(bus_read_index,state==FINAL_WAIT)));
 // ROOT_LEASE requires synchronous, immutable root storage until done.
 // The original validation walk and SPI prefetch latency remain unchanged.
 generate if(ROOT_LEASE)begin: leased_body
  reg [5:0] returned_index;
  always @(posedge clk)returned_index<=bus_stream_index;
  assign snapshot_byte=custom&&{1'b0,returned_index}<count?glyph_byte:8'd0;
 end else begin: private_body
  (* force_ram=1,ram_style="bram" *) reg [7:0] snapshot[0:63];
  reg [7:0] byte_reg;
  always @(posedge clk)begin
   if(rst_n&&state==S_COPY)snapshot[index]<=normalized;
   byte_reg<=snapshot[bus_stream_index];
  end
  assign snapshot_byte=byte_reg;
 end endgenerate
 task finish;input [7:0] e;begin done_valid<=1;done_token<=owner;done_error<=e;state<=IDLE;cursor<=target+1'b1;end endtask
 task next_slot;begin
  if(probed==255)begin
   if(stored_valid)begin erase_group<=!saved_slot[7];sector<=0;state<=ERASE;end
   else finish(8'h75);
  end else begin target<=target+1'b1;probed<=probed+1'b1;state<=F_HEAD;end
 end endtask
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;initialized<=0;protected_format<=0;attempt_started<=0;private_owner<=0;sequence_id<=0;private_values<=0;private_mode<=1;private_custom<=0;private_count<=0;private_styles<=48'h001105ffff08;index<=0;cursor<=0;target<=0;probed<=0;sector<=0;erase_group<=0;
   blank<=1;verified<=1;magic<=0;version<=0;marker<=255;private_body_crc<=16'hffff;private_header_crc<=16'hffff;copy_address<=0;
   done_valid<=0;done_token<=0;done_error<=0;stored_valid<=0;saved_sequence<=0;saved_slot<=0;saved_values<=0;saved_mode<=1;saved_custom<=0;saved_count<=0;
   bus_start<=0;bus_operation<=0;bus_address<=24'h7f0000;bus_length<=0;
  end else begin
   bus_start<=0;if(done_valid&&done_ready)done_valid<=0;
   if(!initialized&&boot_ready)begin initialized<=1;stored_valid<=boot_found;saved_sequence<=boot_sequence;sequence_id<=boot_sequence;saved_slot<=boot_slot;
    saved_values<=boot_values;saved_mode<=boot_mode;saved_custom<=boot_custom;saved_count<=boot_count;cursor<=boot_found?boot_slot+1'b1:8'd0;end
   if(bus_read_valid&&(state==F_HEAD_WAIT||state==F_BODY_WAIT))begin blank<=blank&&bus_read_byte==255;
    if(state==F_HEAD_WAIT)case(bus_read_index)0,1,2,3:magic<={magic[23:0],bus_read_byte};4:version<=bus_read_byte;63:marker<=bus_read_byte;endcase
   end
   if(bus_read_valid&&state==V_BODY_WAIT)verified<=verified&&bus_read_byte==snapshot_byte;
   if(bus_read_valid&&(state==V_HEAD_WAIT||state==FINAL_WAIT))verified<=header_matches_now;
   case(state)
    IDLE:if(request_valid&&request_ready)begin
     private_owner<=request_token;private_values<=request_values;private_mode<=request_mode;private_custom<=request_custom;private_count<=request_count;private_styles<=request_styles;attempt_started<=0;index<=0;private_body_crc<=16'hffff;target<=cursor;probed<=0;
     if(!can_save)begin done_valid<=1;done_token<=request_token;done_error<=8'h75;end
     else if(!valid_values(request_values)||request_count>64||(!request_custom&&request_count!=0)||(STYLE_PERSISTENCE&&!valid_styles(request_styles)))begin done_valid<=1;done_token<=request_token;done_error<=8'h47;end
     else state<=S_ADDR;
    end
    S_ADDR:begin copy_address<=index;state<=S_WAIT;end
    S_WAIT:state<=S_COPY;
    S_COPY:if(custom&&index<count&&(normalized>251||normalized==95))finish(8'h51);
     else begin private_body_crc<=step(body_crc,normalized);
      if(index==63)begin index<=0;private_header_crc<=16'hffff;state<=H_CRC;end else begin index<=index+1'b1;state<=S_ADDR;end
     end
    H_CRC:begin private_header_crc<=step(header_crc,header(index,1'b0));if(index==59)state<=F_HEAD;else index<=index+1'b1;end
    F_HEAD:begin bus_operation<=0;bus_address<={8'h7f,target,8'd0};bus_length<=64;bus_start<=1;blank<=1;magic<=0;version<=0;marker<=255;state<=F_HEAD_WAIT;end
    F_HEAD_WAIT:if(bus_done)begin
     if(bus_error)finish(bus_error_code);
     else if(magic==32'h434e4647&&marker==0&&(version<1||version>MAX_VERSION))begin protected_format<=1;finish(8'h70);end
     else if(blank)state<=F_BODY;else next_slot();
    end
    F_BODY:begin bus_operation<=0;bus_address<={8'h7f,target,8'd64};bus_length<=64;bus_start<=1;blank<=1;state<=F_BODY_WAIT;end
    F_BODY_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else if(blank)state<=P_BODY;else next_slot();end
    P_BODY:begin
     if(!attempt_started)begin sequence_id<=record_sequence;attempt_started<=1;end
     bus_operation<=1;bus_address<={8'h7f,target,8'd64};bus_length<=64;bus_start<=1;state<=P_BODY_WAIT;
    end
    P_BODY_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else state<=P_HEAD;end
    P_HEAD:if(!use_header_cache||header_tail==4)begin bus_operation<=1;bus_address<={8'h7f,target,8'd0};bus_length<=64;bus_start<=1;state<=P_HEAD_WAIT;end
    P_HEAD_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else state<=V_BODY;end
    V_BODY:begin bus_operation<=0;bus_address<={8'h7f,target,8'd64};bus_length<=64;bus_start<=1;verified<=1;state<=V_BODY_WAIT;end
    V_BODY_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else if(!body_matches_now)finish(8'h74);else state<=V_HEAD;end
    V_HEAD:begin bus_operation<=0;bus_address<={8'h7f,target,8'd0};bus_length<=64;bus_start<=1;verified<=1;state<=V_HEAD_WAIT;end
    V_HEAD_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else if(!header_matches_now)finish(8'h74);else state<=COMMIT;end
    COMMIT:begin bus_operation<=1;bus_address<={8'h7f,target,8'd63};bus_length<=1;bus_start<=1;state<=COMMIT_WAIT;end
    COMMIT_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else state<=FINAL;end
    FINAL:begin bus_operation<=0;bus_address<={8'h7f,target,8'd0};bus_length<=64;bus_start<=1;verified<=1;state<=FINAL_WAIT;end
    FINAL_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);else if(!header_matches_now)finish(8'h74);else state<=ACCEPT;end
    ACCEPT:begin stored_valid<=1;saved_sequence<=sequence_id;saved_slot<=target;saved_values<=values;saved_mode<=mode;saved_custom<=custom;saved_count<=count;finish(0);end
    ERASE:begin
     if(!attempt_started)begin sequence_id<=record_sequence;attempt_started<=1;end
     bus_operation<=2;bus_address<={8'h7f,erase_group,sector,12'd0};bus_length<=0;bus_start<=1;state<=ERASE_WAIT;
    end
    ERASE_WAIT:if(bus_done)begin if(bus_error)finish(bus_error_code);
     else if(sector==7)begin target<={erase_group,7'd0};state<=F_HEAD;end else begin sector<=sector+1'b1;state<=ERASE;end
    end
    default:finish(8'h76);
   endcase
  end
 end
endmodule
