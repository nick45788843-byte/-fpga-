// Sources expose only an eight-byte descriptor; request body bytes remain
// in the original RX bank. Fair rotation advances on physical SPI poll completion,
// including polls whose RX mailbox cannot yet be consumed.
// The selected metadata/status stays stable throughout one frame construction.
module a_spi_reply_mux_ram #(parameter MEDIA32=0,PCM_CAPTURE=0,EXTERNAL_CRC=0,PROGRAM_REPLY=0)(input clk,rst_n,input poll_consumed,
 input [239:0] status_body,
 input request_valid,input [63:0] request_header,input [7:0] request_byte,
 output [4:0] request_address,output request_locked,input request_abort,
 input control_valid,input [63:0] control_header,
 input glyph_valid,input [63:0] glyph_header,input [191:0] glyph_body,
 input receipt_valid,input [63:0] receipt_header,
 input store_ready,output write_valid,output [5:0] write_address,output [7:0] write_byte,output publish,
 output frame_valid,output font_receipt_captured,output glyph_receipt_captured,output rpc_receipt_captured,
 input media_result_valid,input [63:0] media_result_header,
 input media_command_valid,input [63:0] media_command_header,
 input pcm_valid,input [63:0] pcm_header,input [7:0] pcm_byte,
 output [4:0] pcm_address,output pcm_locked,output media_command_frame,output crc_clear,crc_enable,output [7:0] crc_byte,input [15:0] external_crc,input program_result_valid,input [63:0] program_result_header);
localparam SOURCES=PROGRAM_REPLY?8:PCM_CAPTURE?7:MEDIA32?6:4;
wire [7:0] valid={PROGRAM_REPLY&&program_result_valid,PCM_CAPTURE&&pcm_valid,MEDIA32&&media_command_valid,MEDIA32&&media_result_valid,receipt_valid,glyph_valid,control_valid,request_valid};
reg [2:0] cursor,selected;reg selected_valid;
reg [303:0] metadata;reg [191:0] glyph_body_snapshot;
reg [2:0] choice;reg choice_valid;reg [63:0] choice_header;integer n;
wire [7:0] later_sources=valid&(8'hff<<cursor);
wire [7:0] eligible_sources=(|later_sources)?later_sources:valid;
always @(*)begin
 choice=cursor;choice_valid=0;
 // One masked priority encoder, with the exact original circular order.
 for(n=0;n<SOURCES;n=n+1)begin
  if(!choice_valid&&eligible_sources[n])begin choice=n;choice_valid=1;end
 end
end
// The previous clock's proposal is only a source index, never a copied body.
// Check present source validity at the real build. If it withdrew, publish
// status-only; never read its old body or claim a result. One full header and
// status snapshot is still captured together at build in metadata below.
reg [2:0] proposed;reg proposed_valid;
wire accepted_choice=proposed_valid&&valid[proposed];
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin proposed<=0;proposed_valid<=0;end
 else begin proposed<=choice;proposed_valid<=choice_valid;end
end
always @(*)begin
 case(proposed)0:choice_header=request_header;1:choice_header=control_header;
  2:choice_header=glyph_header;3:choice_header=receipt_header;
  4:choice_header=media_result_header;5:choice_header=media_command_header;6:choice_header=pcm_header;default:choice_header=program_result_header;endcase
 if(!accepted_choice)choice_header=0;
end
wire [5:0] byte_address;wire ready,writing;
wire abort=request_abort&&selected_valid&&selected==0;
// The two physical banks bound publication rate. Refresh on real free-bank
// credit instead of retaining a second purpose for the whole-byte snapshot.
wire build=ready&&!abort&&(!( |valid)||accepted_choice);
assign request_address=byte_address-6'd30;
assign request_locked=writing&&selected_valid&&selected==0;
assign pcm_address=byte_address-6'd30;
assign pcm_locked=writing&&selected_valid&&selected==6;
assign media_command_frame=selected_valid&&selected==5;
// A source may be released only after its complete F3 frame (including CRC)
// has been accepted by the reply store. The selected header is snapshotted.
wire receipt_publish=publish&&selected_valid&&selected==2&&metadata[63:56]==8'hf3;
assign font_receipt_captured=receipt_publish&&metadata[39:32]>=8'h60&&metadata[39:32]<=8'h66;
assign glyph_receipt_captured=receipt_publish&&metadata[39:32]==8'h49;
assign rpc_receipt_captured=publish&&selected_valid&&selected==3&&metadata[63:56]==8'hf5&&metadata[39:32]==8'h40;
reg [7:0] snapshot_byte;
always @(*)begin
 case(byte_address)
 6'd0:snapshot_byte=metadata[303:296];
 6'd1:snapshot_byte=metadata[295:288];
 6'd2:snapshot_byte=metadata[287:280];
 6'd3:snapshot_byte=metadata[279:272];
 6'd4:snapshot_byte=metadata[271:264];
 6'd5:snapshot_byte=metadata[263:256];
 6'd6:snapshot_byte=metadata[255:248];
 6'd7:snapshot_byte=metadata[247:240];
 6'd8:snapshot_byte=metadata[239:232];
 6'd9:snapshot_byte=metadata[231:224];
 6'd10:snapshot_byte=metadata[223:216];
 6'd11:snapshot_byte=metadata[215:208];
 6'd12:snapshot_byte=metadata[207:200];
 6'd13:snapshot_byte=metadata[199:192];
 6'd14:snapshot_byte=metadata[191:184];
 6'd15:snapshot_byte=metadata[183:176];
 6'd16:snapshot_byte=metadata[175:168];
 6'd17:snapshot_byte=metadata[167:160];
 6'd18:snapshot_byte=metadata[159:152];
 6'd19:snapshot_byte=metadata[151:144];
 6'd20:snapshot_byte=metadata[143:136];
 6'd21:snapshot_byte=metadata[135:128];
 6'd22:snapshot_byte=metadata[127:120];
 6'd23:snapshot_byte=metadata[119:112];
 6'd24:snapshot_byte=metadata[111:104];
 6'd25:snapshot_byte=metadata[103:96];
 6'd26:snapshot_byte=metadata[95:88];
 6'd27:snapshot_byte=metadata[87:80];
 6'd28:snapshot_byte=metadata[79:72];
 6'd29:snapshot_byte=metadata[71:64];
 6'd30:snapshot_byte=metadata[63:56];
 6'd31:snapshot_byte=metadata[55:48];
 6'd32:snapshot_byte=metadata[47:40];
 6'd33:snapshot_byte=metadata[39:32];
 6'd34:snapshot_byte=metadata[31:24];
 6'd35:snapshot_byte=metadata[23:16];
 6'd36:snapshot_byte=metadata[15:8];
 6'd37:snapshot_byte=metadata[7:0];
 default:snapshot_byte=0;
 endcase
end
reg [7:0] glyph_snapshot_byte;
always @(*)begin
 case(byte_address)
 6'd38:glyph_snapshot_byte=glyph_body_snapshot[191:184];
 6'd39:glyph_snapshot_byte=glyph_body_snapshot[183:176];
 6'd40:glyph_snapshot_byte=glyph_body_snapshot[175:168];
 6'd41:glyph_snapshot_byte=glyph_body_snapshot[167:160];
 6'd42:glyph_snapshot_byte=glyph_body_snapshot[159:152];
 6'd43:glyph_snapshot_byte=glyph_body_snapshot[151:144];
 6'd44:glyph_snapshot_byte=glyph_body_snapshot[143:136];
 6'd45:glyph_snapshot_byte=glyph_body_snapshot[135:128];
 6'd46:glyph_snapshot_byte=glyph_body_snapshot[127:120];
 6'd47:glyph_snapshot_byte=glyph_body_snapshot[119:112];
 6'd48:glyph_snapshot_byte=glyph_body_snapshot[111:104];
 6'd49:glyph_snapshot_byte=glyph_body_snapshot[103:96];
 6'd50:glyph_snapshot_byte=glyph_body_snapshot[95:88];
 6'd51:glyph_snapshot_byte=glyph_body_snapshot[87:80];
 6'd52:glyph_snapshot_byte=glyph_body_snapshot[79:72];
 6'd53:glyph_snapshot_byte=glyph_body_snapshot[71:64];
 6'd54:glyph_snapshot_byte=glyph_body_snapshot[63:56];
 6'd55:glyph_snapshot_byte=glyph_body_snapshot[55:48];
 6'd56:glyph_snapshot_byte=glyph_body_snapshot[47:40];
 6'd57:glyph_snapshot_byte=glyph_body_snapshot[39:32];
 6'd58:glyph_snapshot_byte=glyph_body_snapshot[31:24];
 6'd59:glyph_snapshot_byte=glyph_body_snapshot[23:16];
 6'd60:glyph_snapshot_byte=glyph_body_snapshot[15:8];
 6'd61:glyph_snapshot_byte=glyph_body_snapshot[7:0];
 default:glyph_snapshot_byte=0;
 endcase
end
wire [7:0] byte_value=byte_address<38 ? snapshot_byte:
 selected_valid&&selected==2?glyph_snapshot_byte:selected_valid&&selected==0?request_byte:selected_valid&&selected==6?pcm_byte:8'd0;
reg direct_body;
wire choice_direct=!accepted_choice||(proposed!=0&&proposed!=6)||choice_header[39:32]==0;
a_spi_reply_writer #(.EXTERNAL_CRC(EXTERNAL_CRC)) builder(clk,rst_n,build,abort,ready,byte_address,byte_value,
 store_ready,write_valid,write_address,write_byte,publish,frame_valid,writing,direct_body,crc_clear,crc_enable,crc_byte,external_crc);
// These data registers need no reset: the publisher starts invalid and only
// exposes a bank after all bytes/CRC were initialized by an accepted build.
always @(posedge clk)if(rst_n)begin
 if(build)metadata<={status_body,choice_header};
 if(build)glyph_body_snapshot<=accepted_choice&&proposed==2?glyph_body:192'd0;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin cursor<=0;selected<=0;selected_valid<=0;direct_body<=1;end
 else begin
  if(poll_consumed)cursor<=selected==SOURCES-1?3'd0:selected+3'd1;
  if(build)begin selected<=proposed;selected_valid<=accepted_choice;direct_body<=choice_direct;end
 end
end
endmodule
