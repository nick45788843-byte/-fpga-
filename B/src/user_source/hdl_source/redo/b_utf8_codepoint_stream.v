module b_utf8_codepoint_stream(
 input clk,rst_n,input start_valid,input [7:0] start_byte_count,input [6:0] start_codepoint_count,
 input cancel,input byte_valid,output byte_ready,input [7:0] byte_data,input byte_last,
 output reg codepoint_valid,input codepoint_ready,output reg [15:0] codepoint,
 output reg done,output reg [7:0] error_code);
localparam UTF8_INVALID=8'ha3,FIELD_INVALID=8'ha2,CANCELLED=8'ha7;
reg active;
reg [7:0] expected_bytes,bytes_seen;
reg [6:0] expected_codepoints,codepoints_seen;
reg [1:0] continuation_count;
reg [15:0] accumulator,minimum_scalar;
reg non_bmp_pending;
reg [7:0] four_byte_lead;
wire slot_available=!codepoint_valid||codepoint_ready;
wire byte_completes_scalar=continuation_count==0?byte_data[7:0]<8'h80:continuation_count==1;
assign byte_ready=active&&!done&&(!byte_completes_scalar||slot_available);

task fail;
 input [7:0] code;
 begin active<=0;done<=1;error_code<=code;continuation_count<=0;end
endtask

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  active<=0;expected_bytes<=0;bytes_seen<=0;expected_codepoints<=0;codepoints_seen<=0;
  continuation_count<=0;accumulator<=0;minimum_scalar<=0;non_bmp_pending<=0;four_byte_lead<=0;codepoint<=0;codepoint_valid<=0;done<=0;error_code<=0;
 end else begin
  if(codepoint_valid&&codepoint_ready)codepoint_valid<=0;
  if(start_valid)begin
   active<=start_byte_count!=0;expected_bytes<=start_byte_count;bytes_seen<=0;
   expected_codepoints<=start_codepoint_count;codepoints_seen<=0;continuation_count<=0;
   accumulator<=0;minimum_scalar<=0;non_bmp_pending<=0;four_byte_lead<=0;codepoint_valid<=0;done<=start_byte_count==0;error_code<=0;
   if(start_byte_count==0&&start_codepoint_count!=0)error_code<=FIELD_INVALID;
  end else if(cancel&&active)fail(CANCELLED);
  else if(byte_valid&&byte_ready)begin
   bytes_seen<=bytes_seen+1'b1;
   if(byte_last!=(bytes_seen+1'b1==expected_bytes))fail(FIELD_INVALID);
   else if(continuation_count==0)begin
    if(byte_data<8'h80)begin
     if(codepoints_seen>=expected_codepoints)fail(FIELD_INVALID);
     else begin
      codepoint<={8'd0,byte_data};codepoint_valid<=1;codepoints_seen<=codepoints_seen+1'b1;
      if(byte_last)begin
       active<=0;done<=1;
       if(codepoints_seen+1'b1!=expected_codepoints)error_code<=FIELD_INVALID;
      end
     end
    end else if(byte_data>=8'hc2&&byte_data<=8'hdf)begin
     accumulator<={10'd0,byte_data[4:0]};minimum_scalar<=16'h0080;continuation_count<=1;
     if(byte_last)fail(UTF8_INVALID);
    end else if(byte_data>=8'he0&&byte_data<=8'hef)begin
     accumulator<={12'd0,byte_data[3:0]};minimum_scalar<=16'h0800;continuation_count<=2;non_bmp_pending<=0;
     if(byte_last)fail(UTF8_INVALID);
    end else if(byte_data>=8'hf0&&byte_data<=8'hf4)begin
     accumulator<={13'd0,byte_data[2:0]};continuation_count<=3;non_bmp_pending<=1;four_byte_lead<=byte_data;
     if(byte_last)fail(UTF8_INVALID);
    end else fail(UTF8_INVALID);
   end else if(byte_data<8'h80||byte_data>8'hbf||
       (continuation_count==3&&four_byte_lead==8'hf0&&byte_data<8'h90)||
       (continuation_count==3&&four_byte_lead==8'hf4&&byte_data>8'h8f))fail(UTF8_INVALID);
   else begin
    accumulator<={accumulator[13:0],byte_data[5:0]};
    continuation_count<=continuation_count-1'b1;
    if(continuation_count==1)begin
     if(non_bmp_pending)fail(UTF8_INVALID);
     else if({accumulator[13:0],byte_data[5:0]}<minimum_scalar||
        ({accumulator[13:0],byte_data[5:0]}>=16'hd800&&{accumulator[13:0],byte_data[5:0]}<=16'hdfff))
      fail(UTF8_INVALID);
     else if(codepoints_seen>=expected_codepoints)fail(FIELD_INVALID);
     else begin
      codepoint<={accumulator[13:0],byte_data[5:0]};codepoint_valid<=1;codepoints_seen<=codepoints_seen+1'b1;
      if(byte_last)begin
       active<=0;done<=1;
       if(codepoints_seen+1'b1!=expected_codepoints)error_code<=FIELD_INVALID;
      end
     end
    end else if(byte_last)fail(UTF8_INVALID);
   end
  end
 end
end
endmodule
