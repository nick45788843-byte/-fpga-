// Root-owned publication epochs and the necessary-record body lease.
// A value which returns to an earlier value still receives a new epoch (ABA).
module a_board_commit_state #(parameter HEADER_CACHE=0,STYLE_PERSISTENCE=0)(input clk,rst_n,
 input [2:0] desired_mode,output reg [31:0] mode_epoch,
 input mode_ack_valid,input [31:0] mode_ack_epoch,input [2:0] mode_ack_word,
 output mode_current,
 input [71:0] settings,output reg [31:0] settings_epoch,
 input settings_ack_valid,input [31:0] settings_ack_epoch,input [32:0] settings_ack_word,
 output settings_current,
 input [90:0] gallery_word,input [31:0] media_generation,
 output reg [31:0] gallery_epoch,input gallery_retired,input [31:0] retired_epoch,
 output media_retired,output [31:0] retired_media_generation,
 output exhausted,
 input char_we,char_bank,input [5:0] char_address,input [7:0] char_data,
 input text_commit,input [15:0] committed_descriptor,
 input save_intent,input [2:0] save_mode,input text_settled,
 output save_valid,input save_ready,output reg [31:0] save_token,
 output [71:0] save_values,output [2:0] save_mode_word,
 output save_custom,output [6:0] save_count,
 input [5:0] save_address,output reg [7:0] save_byte,
 input source_lock,save_busy,save_done,input [31:0] saved_token,input [7:0] save_error,
 output persist_busy,persist_confirm,persist_failed,output [2:0] persisted_mode,
 output text_write_allowed,output [90:0] gallery_snapshot,
 input header_write_valid,input [5:0] header_write_address,input [7:0] header_write_byte,input header_read_select,
 input style_commit);
reg [2:0] last_mode;
reg [71:0] last_settings;
reg [90:0] last_gallery;reg [31:0] last_media_generation;
reg [15:0] text_descriptor;
reg [7:0] glyphs[0:127];
reg queued,owned;reg [2:0] queued_mode,owned_mode;
reg [71:0] held_values;reg [15:0] held_descriptor;
assign mode_current=last_mode==desired_mode&&mode_ack_valid&&mode_ack_epoch==mode_epoch&&mode_ack_word==desired_mode;
assign settings_current=last_settings==settings&&settings_ack_valid&&settings_ack_epoch==settings_epoch&&
 settings_ack_word=={settings[0],settings[71:40]};
assign exhausted=mode_epoch==32'hffffffff||settings_epoch==32'hffffffff||gallery_epoch==32'hffffffff||save_token==32'hffffffff;
// The snapshot and its epoch change in the same clock. Publish this stored
// descriptor rather than pairing a raw desired word with the preceding epoch.
assign gallery_snapshot=last_gallery;
assign media_retired=gallery_retired&&retired_epoch==gallery_epoch&&last_media_generation==media_generation&&last_gallery==gallery_word;
assign retired_media_generation=last_media_generation;
assign save_valid=queued&&!owned&&!save_busy&&text_settled&&!text_commit&&(!STYLE_PERSISTENCE||!style_commit)&&!source_lock&&!exhausted;
assign save_values=owned?held_values:settings;
assign save_mode_word=owned?owned_mode:queued_mode;
assign save_custom=owned?(held_descriptor!=0):(text_descriptor!=0);
assign save_count=owned?held_descriptor[6:0]:text_descriptor[6:0];
assign persist_busy=owned||queued||save_busy;
assign persist_confirm=save_done&&owned&&saved_token==save_token&&save_error==0;
assign persist_failed=save_done&&owned&&saved_token==save_token&&save_error!=0;
assign persisted_mode=owned_mode;
// Keep the bank leased until the private copy and flash transaction finish.
assign text_write_allowed=!owned&&!queued&&!source_lock&&!save_busy;
always @(posedge clk)begin
 if(HEADER_CACHE&&header_write_valid&&owned)glyphs[{!held_descriptor[7],header_write_address}]<=header_write_byte;
 else if(char_we)glyphs[{char_bank,char_address}]<=char_data;
 save_byte<=glyphs[{held_descriptor[7]^(HEADER_CACHE?header_read_select:1'b0),save_address}];
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  mode_epoch<=1;settings_epoch<=1;gallery_epoch<=1;save_token<=1;
  last_mode<=1;last_settings<=72'h3232646400000bb800;last_gallery<=0;last_media_generation<=0;
  text_descriptor<=0;queued<=0;owned<=0;queued_mode<=1;owned_mode<=1;
  held_values<=72'h3232646400000bb800;held_descriptor<=0;
 end else begin
  if(last_mode!=desired_mode&&mode_epoch!=32'hffffffff)begin last_mode<=desired_mode;mode_epoch<=mode_epoch+1'b1;end
  if(last_settings!=settings&&settings_epoch!=32'hffffffff)begin last_settings<=settings;settings_epoch<=settings_epoch+1'b1;end
  if((last_gallery!=gallery_word||last_media_generation!=media_generation)&&gallery_epoch!=32'hffffffff)begin
   last_gallery<=gallery_word;last_media_generation<=media_generation;gallery_epoch<=gallery_epoch+1'b1;
  end
  if(text_commit)text_descriptor<=committed_descriptor;
  if(save_valid&&save_ready)begin
   queued<=0;owned<=1;owned_mode<=queued_mode;held_values<=settings;held_descriptor<=text_descriptor;
  end
  if(save_done&&owned&&saved_token==save_token)begin owned<=0;if(save_token!=32'hffffffff)save_token<=save_token+1'b1;end
  // A newer save intent wins over accepting the preceding queued one.
  if(save_intent)begin queued<=1;queued_mode<=save_mode;end
 end
end
endmodule
