// A's program endpoint retains the CRC-qualified shared SPI RAM lease.
// The existing local text frontend owns all original-text query responses.
module a_program_receive(input clk,rst_n,frame_boundary,cancel,
 input valid,output reg consume,input [7:0] kind,input [6:0] count,input [15:0] tag,packet_crc,
 input [31:0] value,expected_uid,input session_ready,
 output reg [5:0] read_address,input [31:0] read_word,
 output reg reply_valid,output [63:0] reply_header,output reg busy,
 output font_we,output [10:0] font_address,output [15:0] font_data,
 output reg front_valid,front_bank,output reg [3:0] front_image,output reg front_released,
 output reg [6:0] front_count,output reg [7:0] front_length,output reg [71:0] samples_per_pixel,
 output reg [31:0] front_uid,
 output raw_we,raw_bank,output [7:0] raw_address,output [7:0] raw_byte,input query_hold);
localparam IDLE=0,UID_ADDR=1,UID_WAIT=2,UID_CHECK=3,DATA_ADDR=4,DATA_WAIT=5,DATA_GET=6,
 COPY=7,COMMIT=8,FINISH=9;
reg [3:0] state;reg upload,shadow_bank;reg [1:0] copy_lane;reg [31:0] upload_uid;
// read_address and the mailbox body bank stay owned until consume. Reuse that
// stable synchronous RAM output instead of snapshotting every word twice.
reg [9:0] received_words;reg [5:0] index;
reg magic_ok,geometry_ok,frames_ok;reg [2:0] rates_ok;
reg [3:0] work_image;reg [6:0] work_count;reg [7:0] work_length;reg [71:0] rates;
reg [15:0] last_tag,last_crc;reg [3:0] last_kind;reg [7:0] last_error,result_error;reg last_valid;
reg [31:0] reply_uid;reg [15:0] reply_tag;
wire raw_section=received_words>=6&&received_words<54;
wire [5:0] raw_word_index=received_words[5:0]-6'd6;
assign raw_we=upload&&index!=0&&state==COPY&&raw_section&&!cancel;
assign raw_bank=shadow_bank;assign raw_address={raw_word_index,copy_lane};
assign raw_byte=read_word[{copy_lane,3'b000}+:8];
assign font_we=upload&&index!=0&&state==COPY&&received_words>=54&&received_words<566&&!cancel;
wire [8:0] font_word_index=received_words-10'd54;
assign font_address={shadow_bank,font_word_index,copy_lane[0]};
assign font_data=copy_lane[0]?read_word[31:16]:read_word[15:0];
assign reply_header={8'hf7,result_error,reply_tag[7:0],reply_tag[15:8],reply_uid[7:0],reply_uid[15:8],reply_uid[23:16],reply_uid[31:24]};
task finish;input [7:0] e;begin
 result_error<=e;reply_tag<=tag;reply_valid<=1;
 last_tag<=tag;last_crc<=packet_crc;last_kind<=kind[3:0];last_error<=e;last_valid<=1;
 consume<=1;busy<=0;state<=FINISH;
end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;consume<=0;busy<=0;copy_lane<=0;upload<=0;shadow_bank<=1;upload_uid<=0;
  received_words<=0;index<=0;read_address<=0;magic_ok<=0;geometry_ok<=0;frames_ok<=0;rates_ok<=0;rates<=0;
  work_image<=0;work_count<=0;work_length<=0;last_tag<=0;last_crc<=0;last_kind<=0;last_error<=0;last_valid<=0;
  reply_valid<=0;reply_uid<=0;reply_tag<=0;result_error<=0;
  front_valid<=0;front_bank<=0;front_image<=0;front_count<=0;front_length<=0;samples_per_pixel<=1;front_uid<=0;front_released<=0;
 end else begin
  consume<=0;
  case(state)
   IDLE:if(valid&&!consume)begin busy<=1;read_address<=0;state<=UID_ADDR;end
   UID_ADDR:state<=UID_WAIT;
   UID_WAIT:state<=UID_CHECK;
   UID_CHECK:begin
    reply_uid<=read_word;
    if(!session_ready||read_word==0||read_word!=expected_uid)begin
     result_error<=8'h49;reply_uid<=read_word;reply_tag<=tag;reply_valid<=1;consume<=1;busy<=0;state<=FINISH;
    end else if(last_valid&&upload_uid==read_word&&tag==last_tag)begin
     result_error<=packet_crc==last_crc&&kind[3:0]==last_kind?last_error:8'hd4;
     reply_uid<=read_word;reply_tag<=tag;reply_valid<=1;consume<=1;busy<=0;state<=FINISH;
    end else if(kind==8'h5a&&count==1&&front_valid&&read_word==front_uid)begin front_released<=1;index<=0;state<=DATA_GET;end
    else if(kind==8'h56&&count==1&&value==2264)begin
     upload<=1;upload_uid<=read_word;shadow_bank<=!front_bank;received_words<=0;magic_ok<=0;geometry_ok<=0;frames_ok<=0;rates_ok<=0;index<=0;state<=DATA_GET;
    end else if(kind==8'h57&&upload&&upload_uid==read_word&&count>=2&&count<=64&&
                value[31:12]==0&&value[1:0]==0&&value[11:2]==received_words&&
                {1'b0,received_words}+{4'd0,count}-11'd1<=11'd566)begin
     read_address<=1;index<=1;state<=DATA_ADDR;
    end else if(kind==8'h58&&count==1&&value==2264&&upload&&upload_uid==read_word&&received_words==566&&magic_ok&&geometry_ok&&frames_ok&&(&rates_ok))state<=COMMIT;
    else finish(8'hd2);
   end
   DATA_ADDR:state<=DATA_WAIT;
   DATA_WAIT:state<=DATA_GET;
   DATA_GET:if(index==0)finish(0);else begin copy_lane<=0;state<=COPY;end
   COPY:begin
    if(copy_lane==0)begin
     case(received_words)
      0:magic_ok<=read_word==32'h32504e43;
      1:begin
       work_image<=read_word[3:0];work_count<=read_word[22:16];work_length<=read_word[31:24];
       geometry_ok<=read_word[7:0]>=1&&read_word[7:0]<=8&&read_word[15:8]==read_word[7:0]+8'd4&&read_word[23:16]<=64&&read_word[31:24]<=192&&
        (read_word[23:16]==0?read_word[31:24]==0:read_word[31:24]>=read_word[23:16]);
      end
      2:frames_ok<=read_word!=0;
      3:begin rates[23:0]<=read_word[23:0];rates_ok[0]<=read_word!=0&&read_word[31:24]==0;end
      4:begin rates[47:24]<=read_word[23:0];rates_ok[1]<=read_word!=0&&read_word[31:24]==0;end
      5:begin rates[71:48]<=read_word[23:0];rates_ok[2]<=read_word!=0&&read_word[31:24]==0;end
     endcase
    end
    if(copy_lane==(raw_section?2'd3:2'd1))begin
     received_words<=received_words+1'b1;copy_lane<=0;
     if(index+1==count)finish(0);
     else begin index<=index+1'b1;read_address<=index+1'b1;state<=DATA_ADDR;end
    end else copy_lane<=copy_lane+1'b1;
   end
   COMMIT:if(frame_boundary&&!query_hold)begin
    front_bank<=shadow_bank;front_image<=work_image;front_count<=work_count;front_length<=work_length;
    samples_per_pixel<=rates;front_uid<=upload_uid;front_valid<=1;front_released<=0;upload<=0;finish(0);
   end
   FINISH:if(!valid)state<=IDLE;
  endcase
  if(cancel)begin
   upload<=0;front_valid<=0;front_released<=0;
   if(state!=IDLE&&state!=FINISH)finish(8'h43);
  end
 end
end
endmodule

