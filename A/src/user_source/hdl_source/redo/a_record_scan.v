// Compatibility scan algorithm retained; all physical transactions use the caller single engine.
// Independent read-only compatibility scanner. No program/erase operation exists here.
// Restored values are observations; emergency boot/transaction policy is owned separately.
module a_record_scan #(parameter CLOCK_HZ=50000000,SPI_DIV=4,EXTERNAL_CRC=0,STYLE_PERSISTENCE=0)(input clk,rst_n,
 output reg ready,found,unknown_format,corrupt_seen,output reg [7:0] error_code,
 output reg [23:0] jedec_id,output reg [31:0] saved_sequence,output reg [71:0] saved_values,
 output reg [2:0] saved_mode,output reg custom_text,output reg [6:0] glyph_count,
 input [5:0] glyph_address,output reg [7:0] glyph_byte,
 output reg [7:0] saved_slot,
 output bus_start,output [2:0] bus_operation,output [23:0] bus_address,output [6:0] bus_length,
 input bus_done,bus_error,input [7:0] bus_error_code,
 input bus_read_valid,input [7:0] bus_read_byte,input [5:0] bus_read_index,input [23:0] bus_jedec,output header_crc_clear,header_crc_enable,output [7:0] header_crc_byte,
 output body_crc_clear,body_crc_enable,output [7:0] body_crc_byte,input [15:0] external_header_crc,external_body_crc,
 output reg [47:0] saved_styles);
 localparam [47:0] DEFAULT_STYLES=48'h001105ffff08;
 localparam MAX_VERSION=STYLE_PERSISTENCE?4:3;
 localparam WAKE=0,WAKE_WAIT=1,ID=2,ID_WAIT=3,HEADER=4,HEADER_WAIT=5,CHECK=6,BODY=7,BODY_WAIT=8,BODY_CHECK=9,NEXT=10,DONE=11,DELAY=12,ID_DELAY=13;
 localparam DELAY_BITS=CLOCK_HZ/100>1?$clog2(CLOCK_HZ/100+1):1;
 reg [DELAY_BITS-1:0] delay_count;
 reg [3:0] state;reg [7:0] slot;reg start;reg [2:0] operation;reg [23:0] address;reg [6:0] length;
 wire done=bus_done,error=bus_error,rx_valid=bus_read_valid;
 wire [7:0] code=bus_error_code,rx=bus_read_byte;wire [5:0] rx_index=bus_read_index;
 wire [23:0] id_data=bus_jedec;
 assign bus_start=start;assign bus_operation=operation;assign bus_address=address;assign bus_length=length;
 // One 48-bit scratch has non-overlapping header lifetimes:
 // bytes 0..3 assemble magic; bytes 27..32 retain styles until accept.
 // The three original header comparisons retire at their last source byte.
 reg [47:0] header_scratch;
 reg magic_ok,encoding_ok,text_encoding_ok;
 reg [31:0] sequence_id;reg [71:0] values;reg [7:0] version,mode,text_custom,text_length;
 reg [15:0] private_crc,stored_crc,private_body_crc,expected_body_crc;
 wire [15:0] crc=EXTERNAL_CRC?external_header_crc:private_crc;
 wire [15:0] body_crc=EXTERNAL_CRC?external_body_crc:private_body_crc;reg [7:0] marker;reg blank,semantic;
 reg bank;reg [7:0] glyph[0:127];
 assign header_crc_clear=state==HEADER;
 assign header_crc_enable=rx_valid&&state==HEADER_WAIT&&rx_index<60;
 assign header_crc_byte=rx;
 assign body_crc_clear=state==BODY;
 assign body_crc_enable=rx_valid&&state==BODY_WAIT;
 assign body_crc_byte=rx;
 function [15:0] step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;step={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
 function valid_values;input [71:0] v;begin valid_values=v[71:64]<=100&&v[63:56]>=20&&v[63:56]<=100&&
  v[55:48]<=200&&v[47:40]<=200&&v[39:8]>=1000&&v[39:8]<=60000&&v[7:0]<=1;end endfunction
 function newer;input [31:0] candidate,reference;reg [31:0] delta;
 begin delta=candidate-reference;newer=candidate!=reference&&!delta[31];end endfunction
 function valid_styles;input [47:0] s;reg [7:0] emergency;begin
  emergency=s[47:40];valid_styles=!s[1]&&(emergency==0||(!emergency[6]&&emergency[5:3]<=4&&emergency[0]));
 end endfunction
 wire header_ok=magic_ok&&version>=1&&version<=MAX_VERSION&&encoding_ok&&marker==0&&crc==stored_crc&&
  valid_values(values)&&(version==1||mode<=7)&&(version<3||(text_custom<=1&&text_length<=64&&text_encoding_ok&&(text_custom!=0||text_length==0)))&&
  (version!=4||valid_styles(header_scratch));
 always @(posedge clk)begin glyph_byte<=glyph[{bank,glyph_address}];
  if(rx_valid&&state==BODY_WAIT)glyph[{!bank,rx_index}]<=rx;
 end
 task accept;begin found<=1;saved_sequence<=sequence_id;saved_values<=values;saved_mode<=version==1?3'd0:mode[2:0];saved_slot<=slot;
  saved_styles<=STYLE_PERSISTENCE&&version==4?header_scratch:DEFAULT_STYLES;end endtask
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=DELAY;delay_count<=0;slot<=0;start<=0;operation<=0;address<=24'h7f0000;length<=0;
   ready<=0;found<=0;unknown_format<=0;corrupt_seen<=0;error_code<=0;jedec_id<=0;saved_sequence<=0;saved_slot<=0;
   saved_values<=72'h643264640000138800;saved_mode<=0;custom_text<=0;glyph_count<=0;bank<=0;
   header_scratch<=0;magic_ok<=0;encoding_ok<=0;text_encoding_ok<=0;saved_styles<=DEFAULT_STYLES;
   sequence_id<=0;values<=0;version<=0;mode<=0;text_custom<=0;text_length<=0;
   private_crc<=16'hffff;stored_crc<=0;private_body_crc<=16'hffff;expected_body_crc<=0;marker<=255;blank<=1;semantic<=1;
  end else begin
   start<=0;
   if(rx_valid&&state==HEADER_WAIT)begin
    blank<=blank&&rx==255;if(rx_index<60)private_crc<=step(crc,rx);
    case(rx_index)
     0,1,2,3:begin
      header_scratch[31:0]<={header_scratch[23:0],rx};
      if(rx_index==3)magic_ok<=({header_scratch[23:0],rx}==32'h434e4647);
     end
     4:version<=rx;5:encoding_ok<=rx==64;
     8:sequence_id[7:0]<=rx;9:sequence_id[15:8]<=rx;10:sequence_id[23:16]<=rx;11:sequence_id[31:24]<=rx;
     12:values[71:64]<=rx;13:values[63:56]<=rx;14:values[55:48]<=rx;15:values[47:40]<=rx;
     16:values[15:8]<=rx;17:values[23:16]<=rx;18:values[31:24]<=rx;19:values[39:32]<=rx;20:values[7:0]<=rx;
     21:mode<=rx;22:text_custom<=rx;23:text_length<=rx;24:text_encoding_ok<=rx==1;
     25:expected_body_crc[7:0]<=rx;26:expected_body_crc[15:8]<=rx;
     27:if(STYLE_PERSISTENCE)header_scratch[7:0]<=rx;28:if(STYLE_PERSISTENCE)header_scratch[15:8]<=rx;
     29:if(STYLE_PERSISTENCE)header_scratch[23:16]<=rx;30:if(STYLE_PERSISTENCE)header_scratch[31:24]<=rx;
     31:if(STYLE_PERSISTENCE)header_scratch[39:32]<=rx;32:if(STYLE_PERSISTENCE)header_scratch[47:40]<=rx;
     60:stored_crc[7:0]<=rx;61:stored_crc[15:8]<=rx;63:marker<=rx;
    endcase
   end
   if(rx_valid&&state==BODY_WAIT)begin private_body_crc<=step(body_crc,rx);
    semantic<=semantic&&(text_custom!=0&&rx_index<text_length?rx<=251&&rx!=95:rx==0);end
   case(state)
    DELAY:if(delay_count>=CLOCK_HZ/100)state<=WAKE;else delay_count<=delay_count+1'b1;
    WAKE:begin operation<=4;length<=0;start<=1;state<=WAKE_WAIT;end
    WAKE_WAIT:if(done)begin if(error)begin error_code<=code;state<=DONE;end else begin delay_count<=0;state<=ID_DELAY;end end
    ID_DELAY:if(delay_count>=CLOCK_HZ/100000)state<=ID;else delay_count<=delay_count+1'b1;
    ID:begin operation<=3;length<=3;start<=1;state<=ID_WAIT;end
    ID_WAIT:if(done)begin jedec_id<=id_data[23:0];
     if(error||!(id_data[23:0]==24'hef4017||id_data[23:0]==24'hef3017))begin error_code<=error?code:8'h61;state<=DONE;end
     else state<=HEADER;
    end
    HEADER:begin operation<=0;address<={8'h7f,slot,8'd0};length<=64;start<=1;private_crc<=16'hffff;blank<=1;state<=HEADER_WAIT;end
    HEADER_WAIT:if(done)begin if(error)begin error_code<=code;state<=DONE;end else state<=CHECK;end
    CHECK:begin
     if(magic_ok&&marker==0&&(version<1||version>MAX_VERSION))unknown_format<=1;
     if(!blank&&!header_ok)corrupt_seen<=1;
     if(header_ok&&(!found||newer(sequence_id,saved_sequence)))begin
      if(version>=3)state<=BODY;else begin accept();custom_text<=0;glyph_count<=0;state<=NEXT;end
     end else state<=NEXT;
    end
    BODY:begin operation<=0;address<={8'h7f,slot,8'd64};length<=64;start<=1;private_body_crc<=16'hffff;semantic<=1;state<=BODY_WAIT;end
    BODY_WAIT:if(done)begin if(error)begin error_code<=code;state<=DONE;end else state<=BODY_CHECK;end
    BODY_CHECK:begin
     if(semantic&&body_crc==expected_body_crc)begin accept();custom_text<=text_custom[0];glyph_count<=text_length[6:0];bank<=!bank;end
     else corrupt_seen<=1;state<=NEXT;
    end
    NEXT:if(slot==255)state<=DONE;else begin slot<=slot+1'b1;state<=HEADER;end
    DONE:ready<=1;
    default:begin error_code<=8'h76;state<=DONE;end
   endcase
  end
 end
endmodule
