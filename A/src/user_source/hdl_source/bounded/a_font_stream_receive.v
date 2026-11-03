// FS2 A endpoint for the B glyph stream (see b_font_stream_packetizer FS2).
// One F2 receipt per command; the latest receipt stays published until the
// next command replaces it, and a duplicate (uid,kind,sequence) replays it.
// DATA payload is one linear byte stream: raw UTF-8 at offset 0 (zero padded
// to a word), then glyph bitmaps back to back from the aligned raw end.
// Single-bank OSD: job_start hides the target until the frame-boundary commit.
// Ports are unchanged from the FS1 receiver; FS1-only outputs are retained.
module a_font_stream_receive #(parameter MAX_SHADOW_BYTES=32768,SHARED_DESCRIPTOR=0)(
 input clk,rst_n,
 input command_valid,output command_ready,
 input [7:0] command_kind,command_arg,input [6:0] command_count,
 input [15:0] command_sequence,command_tag,command_crc,
 input [31:0] command_uid,
 output reg [5:0] read_address,input [31:0] read_word,
 output reg font_write_valid,output reg [14:0] font_write_address,
 output reg [7:0] font_write_data,output reg font_write_bank,
 output reg raw_write_valid,output reg [7:0] raw_write_address,raw_write_data,output reg raw_write_bank,
 output reg glyph_meta_valid,output reg [5:0] glyph_meta_index,
 output reg [15:0] glyph_meta_codepoint,output reg [1:0] glyph_meta_size,
 output reg commit_valid,output reg commit_bank,output reg [6:0] commit_glyph_count,
 output reg [7:0] commit_utf8_bytes,output reg [1:0] commit_size,commit_target,
 output reg job_start,output [1:0] current_target,output reg [3:0] active_banks,
 input frame_boundary,
 output reg response_valid,input response_ready,output [255:0] response_fragment,
 output reg busy,output reg [7:0] last_error,input [7:0] render_error,
 output [6:0] current_glyph_count,output [7:0] current_utf8_bytes,output [1:0] current_size);

 localparam IDLE=0,ADDR=1,WAIT0=2,WAIT1=3,COPY=4,RELEASE=5,COMMIT_WAIT=6;
 localparam ERR_SIZE=8'ha0,ERR_UID=8'ha1,ERR_PROTOCOL=8'ha2;
 reg [2:0] state;
 reg [31:0] owner_uid;
 reg [6:0] expected_glyphs;
 reg [7:0] expected_utf8;
 reg [1:0] size_code,target_code;
 reg job_active;
 reg [15:0] next_offset;   // next expected linear byte offset
 reg [15:0] glyph_start;   // word-aligned end of the raw text
 reg [15:0] cursor;        // linear offset of the byte being copied
 reg [6:0] word_cursor,words_total;
 reg [1:0] byte_lane;
 reg [7:0] held_kind;reg [15:0] held_sequence;reg [31:0] held_uid;
 reg [7:0] response_kind,response_error;reg [31:0] response_uid;reg [15:0] response_sequence;
 assign response_fragment={8'hf2,8'd0,response_error,response_kind,response_uid,response_sequence,176'd0};
 assign current_target=target_code;
 assign current_glyph_count=expected_glyphs;
 assign current_utf8_bytes=expected_utf8;
 assign current_size=size_code;

 function [9:0] bytes_for_size;
  input [1:0] s;
  begin case(s)0:bytes_for_size=10'd32;1:bytes_for_size=10'd128;2:bytes_for_size=10'd512;default:bytes_for_size=0;endcase end
 endfunction
 // Total linear bytes of a job: aligned raw text plus all glyph bitmaps.
 wire [15:0] glyph_region=size_code==0?{4'd0,expected_glyphs,5'd0}:
   size_code==1?{2'd0,expected_glyphs,7'd0}:{expected_glyphs,9'd0};
 wire [15:0] job_bytes=glyph_start+glyph_region;
 wire command_is_stream=command_kind==8'h60||command_kind==8'h61||command_kind==8'h64||command_kind==8'h65;
 wire matching_job=job_active&&command_uid==owner_uid;
 wire duplicate=response_valid&&command_uid==response_uid&&command_kind==response_kind&&
   command_sequence==response_sequence;
 wire [7:0] payload_byte=read_word[byte_lane*8+:8];
 wire [15:0] glyph_offset=cursor-glyph_start;
 wire [9:0] glyph_mask=bytes_for_size(size_code)-1'b1;
 wire data_valid=matching_job&&command_arg=={6'd0,size_code}&&command_count!=0&&
   command_tag==0&&command_sequence==next_offset&&
   {7'd0,command_count,2'b00}<=job_bytes-next_offset&&
   (command_sequence!=0||expected_utf8==0||command_count==((expected_utf8+8'd3)>>2));
 wire commit_valid_header=matching_job&&command_arg==1&&command_count==0&&
   command_tag==0&&command_sequence==job_bytes&&next_offset==job_bytes;

 // Every stream command is consumed in IDLE except an accepted DATA payload,
 // which holds the mailbox word RAM until RELEASE, and COMMIT, which waits
 // for the frame boundary.
 assign command_ready=(state==RELEASE)||(state==COMMIT_WAIT&&frame_boundary)||
   (state==IDLE&&command_valid&&command_is_stream&&
    (duplicate||!((command_kind==8'h61&&data_valid)||(command_kind==8'h65&&commit_valid_header))));

 task respond;
  input [7:0] kind;input [31:0] uid;input [15:0] seq;input [7:0] err;
  begin
   response_valid<=1;response_uid<=uid;response_kind<=kind;response_sequence<=seq;response_error<=err;
   if(err!=0)last_error<=err;
  end
 endtask

 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;owner_uid<=0;expected_glyphs<=0;expected_utf8<=0;size_code<=0;target_code<=0;job_active<=0;
   next_offset<=0;glyph_start<=0;cursor<=0;word_cursor<=0;words_total<=0;byte_lane<=0;read_address<=0;
   held_kind<=0;held_sequence<=0;held_uid<=0;
   font_write_valid<=0;font_write_address<=0;font_write_data<=0;font_write_bank<=0;
   raw_write_valid<=0;raw_write_address<=0;raw_write_data<=0;raw_write_bank<=0;
   glyph_meta_valid<=0;glyph_meta_index<=0;glyph_meta_codepoint<=0;glyph_meta_size<=0;
   commit_valid<=0;commit_bank<=0;commit_glyph_count<=0;commit_utf8_bytes<=0;commit_size<=0;commit_target<=0;
   active_banks<=0;job_start<=0;
   response_valid<=0;response_uid<=0;response_kind<=0;response_sequence<=0;response_error<=0;
   busy<=0;last_error<=0;
  end else begin
   font_write_valid<=0;raw_write_valid<=0;glyph_meta_valid<=0;commit_valid<=0;job_start<=0;
   case(state)
    IDLE:begin
     busy<=0;
     if(command_valid&&command_is_stream&&duplicate)begin
      // Lost receipt: the retained receipt is already published; consume.
     end else if(command_valid&&command_kind==8'h60)begin
      if(job_active||command_uid==0)respond(8'h60,command_uid,command_sequence,ERR_UID);
      else if(command_arg[7:4]!=2||command_arg[3:2]>2||
          (command_arg[1:0]==0&&command_arg[3:2]!=0)||
          (command_arg[1:0]==1&&command_arg[3:2]>1)||
          (command_arg[1:0]==2&&command_arg[3:2]!=2)||
          (command_arg[1:0]==3&&command_arg[3:2]!=1))
       respond(8'h60,command_uid,command_sequence,ERR_SIZE);
      else if(command_count!=0||command_tag>192||command_sequence>64||command_sequence==0&&command_tag!=0||
          (command_arg[1:0]==1&&command_sequence>32)||(command_arg[1:0]==2&&command_sequence>8)||
          (command_arg[1:0]==3&&command_sequence>32))
       respond(8'h60,command_uid,command_sequence,ERR_PROTOCOL);
      else begin
       owner_uid<=command_uid;expected_glyphs<=command_sequence[6:0];expected_utf8<=command_tag[7:0];
       size_code<=command_arg[3:2];target_code<=command_arg[1:0];job_active<=1;
       next_offset<=0;glyph_start<={6'd0,(command_tag[9:0]+10'd3)&10'h3fc};
       job_start<=1;respond(8'h60,command_uid,command_sequence,0);
      end
     end else if(command_valid&&command_kind==8'h64)begin
      if(!matching_job)respond(8'h64,command_uid,command_sequence,ERR_UID);
      else begin job_active<=0;respond(8'h64,command_uid,command_sequence,0);end
     end else if(command_valid&&command_kind==8'h61)begin
      if(!data_valid)respond(8'h61,command_uid,command_sequence,matching_job?ERR_PROTOCOL:ERR_UID);
      else begin
       held_kind<=8'h61;held_uid<=command_uid;held_sequence<=command_sequence;
       cursor<=command_sequence;words_total<=command_count;word_cursor<=0;byte_lane<=0;
       state<=ADDR;busy<=1;
      end
     end else if(command_valid&&command_kind==8'h65)begin
      if(!commit_valid_header)respond(8'h65,command_uid,command_sequence,matching_job?ERR_PROTOCOL:ERR_UID);
      else begin held_kind<=8'h65;held_uid<=command_uid;held_sequence<=command_sequence;state<=COMMIT_WAIT;busy<=1;end
     end
    end
    ADDR:begin read_address<=word_cursor[5:0];state<=WAIT0;end
    WAIT0:state<=WAIT1;
    WAIT1:begin byte_lane<=0;state<=COPY;end
    COPY:begin
     if(cursor<glyph_start)begin
      if(cursor<{8'd0,expected_utf8})begin
       raw_write_valid<=1;raw_write_address<=cursor[7:0];raw_write_data<=payload_byte;
      end
     end else begin
      font_write_valid<=1;font_write_address<=glyph_offset[14:0];font_write_data<=payload_byte;
      if((glyph_offset[9:0]&glyph_mask)==glyph_mask)begin
       glyph_meta_valid<=1;glyph_meta_size<=size_code;glyph_meta_codepoint<=0;
       glyph_meta_index<=size_code==0?glyph_offset[10:5]:size_code==1?glyph_offset[12:7]:glyph_offset[14:9];
      end
     end
     cursor<=cursor+1'b1;
     if(byte_lane==3)begin
      byte_lane<=0;
      if(word_cursor+1'b1==words_total)begin next_offset<=cursor+1'b1;state<=RELEASE;end
      else begin word_cursor<=word_cursor+1'b1;state<=ADDR;end
     end else byte_lane<=byte_lane+1'b1;
    end
    RELEASE:if(command_valid&&command_ready)begin
     respond(held_kind,held_uid,held_sequence,0);state<=IDLE;busy<=0;
    end
    COMMIT_WAIT:if(frame_boundary)begin
     job_active<=0;state<=IDLE;busy<=0;
     if(render_error!=0)respond(8'h65,held_uid,held_sequence,render_error);
     else begin
      commit_valid<=1;commit_bank<=0;commit_glyph_count<=expected_glyphs;
      commit_utf8_bytes<=expected_utf8;commit_size<=size_code;commit_target<=target_code;
      respond(8'h65,held_uid,held_sequence,0);
     end
    end
    default:begin state<=IDLE;busy<=0;end
   endcase
  end
 end
endmodule
