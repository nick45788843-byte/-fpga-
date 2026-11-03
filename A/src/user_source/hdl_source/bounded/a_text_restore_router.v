// One writer owns both boot restore and subsequent text transactions.
// New text observations permanently suppress a late restore; an in-flight restore
// is cancelled and its real frame rollback drained before the new request starts.
module a_text_restore_router(input clk,rst_n,
 input reader_ready,reader_found,input [7:0] reader_error,input reader_custom,input [6:0] reader_count,
 output [5:0] reader_address,input [7:0] reader_byte,
 input request_valid,output request_ready,input [31:0] request_token,input [6:0] request_count,
 output [5:0] source_address,input [7:0] source_glyph,
 input cancel_valid,input [31:0] cancel_token,input finalize_valid,input [31:0] finalize_token,
 output char_we,char_bank,output [5:0] char_address,output [7:0] char_data,
 output publish_valid,output [31:0] publish_token,output [15:0] publish_descriptor,
 input applied_valid,input [31:0] applied_token,input [15:0] applied_descriptor,
 output response_valid,input response_ready,output [31:0] response_token,output [7:0] response_error,
 output result_revoke_valid,output reg restore_settled,restore_applied,restore_skipped);
 reg touched,boot_active,decided;
 wire ready,valid;wire [31:0] token;wire [7:0] error;wire [5:0] address;
 wire boot_candidate=!decided&&!touched&&!request_valid&&reader_ready&&reader_found&&reader_error==0;
 wire take_boot=boot_candidate&&ready;
 assign request_ready=ready&&!boot_active;
 assign reader_address=address;assign source_address=address;
 assign response_valid=valid&&!boot_active;
 assign response_token=token;assign response_error=error;
 wire boot_cancel=boot_active&&(touched||request_valid);
 a_text_apply #(.TWO_PHASE(1),.CUSTOM_SELECT_ENABLED(1)) apply(
  clk,rst_n,!boot_active&&(request_valid||boot_candidate),ready,boot_candidate?32'd0:request_token,
  boot_candidate?(reader_custom?reader_count:7'd0):request_count,address,boot_active?reader_byte:source_glyph,
  boot_cancel||cancel_valid,boot_cancel?32'd0:cancel_token,char_we,char_bank,char_address,char_data,
  publish_valid,publish_token,publish_descriptor,applied_valid,applied_token,applied_descriptor,
  valid,boot_active?1'b1:response_ready,token,error,
  boot_active?(valid&&error==0&&!boot_cancel):finalize_valid,boot_active?32'd0:finalize_token,
  result_revoke_valid,boot_candidate?reader_custom:1'b1);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin touched<=0;boot_active<=0;decided<=0;restore_settled<=0;restore_applied<=0;restore_skipped<=0;end
  else begin
   if(request_valid)touched<=1;
   if(take_boot)begin boot_active<=1;decided<=1;end
   if(!decided&&reader_ready&&!boot_candidate)begin decided<=1;restore_settled<=1;restore_skipped<=1;end
   if(boot_active&&ready)begin boot_active<=0;restore_settled<=1;restore_applied<=!touched&&!request_valid;restore_skipped<=touched||request_valid;end
  end
 end
endmodule
