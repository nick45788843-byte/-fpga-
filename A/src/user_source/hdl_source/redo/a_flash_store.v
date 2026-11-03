// One actual physical transport, shared by compatibility scan, necessary v3/v4 writer and fixed asset reads.
// The writer receives a real private glyph snapshot; no normal config service lives here.
module a_flash_store #(parameter CLOCK_HZ=50000000,SPI_DIV=4,CRC_POOL_ENABLED=0,ROOT_LEASE=0,CACHED_HEADER=0,STYLE_PERSISTENCE=0)(input clk,rst_n,
 output boot_ready,boot_found,boot_unknown,boot_corrupt,output [7:0] boot_error,output [23:0] jedec_id,
 output [71:0] boot_values,output [2:0] boot_mode,output boot_custom,output [6:0] boot_count,
 input [5:0] restore_address,output [7:0] restore_byte,
 input save_valid,output save_ready,input [31:0] save_token,input [71:0] save_values,
 input [2:0] save_mode,input save_custom,input [6:0] save_count,
 output [5:0] source_address,input [7:0] source_byte,output source_lock,
 output save_done,input save_done_ready,output [31:0] saved_token,output [7:0] save_error,
 output stored_valid,output [31:0] saved_sequence,output [71:0] saved_values,output [2:0] saved_mode,
 output saved_custom,output [6:0] saved_count,output save_busy,can_save,
 input asset_start,input [23:0] asset_address,input [6:0] asset_length,
 output asset_ready,asset_busy,output reg asset_done,asset_error,output reg [7:0] asset_error_code,
 output asset_byte_valid,output [7:0] asset_byte,output [5:0] asset_byte_index,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso,output flash_wp_n,flash_hold_n,
 output header_write_valid,output [5:0] header_write_address,output [7:0] header_write_byte,output header_read_select,
 output [47:0] boot_styles,input [47:0] save_styles,output style_source_lock);
 // Boot scanner permanently finishes before any initialized writer request.
 wire scan_h_clear,scan_h_enable,scan_b_clear,scan_b_enable;
 wire write_h_clear,write_h_enable,write_b_clear,write_b_enable;
 wire [7:0] scan_h_byte,scan_b_byte,write_h_byte,write_b_byte;
 wire [15:0] pool_header_crc,pool_body_crc;
 reg writer_crc_owner;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)writer_crc_owner<=0;else if(boot_ready)writer_crc_owner<=1;
 end
 wire owner_change=boot_ready&&!writer_crc_owner;
 wire [15:0] writer_header_crc=writer_crc_owner?pool_header_crc:16'hffff;
 wire [15:0] writer_body_crc=writer_crc_owner?pool_body_crc:16'hffff;
 generate if(CRC_POOL_ENABLED)begin:shared_store_crc
  crc_byte_lut_pair table_pair(clk,rst_n,
   owner_change||(boot_ready?write_h_clear:scan_h_clear),boot_ready?write_h_enable:scan_h_enable,
   boot_ready?write_h_byte:scan_h_byte,pool_header_crc,
   owner_change||(boot_ready?write_b_clear:scan_b_clear),boot_ready?write_b_enable:scan_b_enable,
   boot_ready?write_b_byte:scan_b_byte,pool_body_crc);
 end else begin:no_store_crc_pool
  assign pool_header_crc=16'hffff;assign pool_body_crc=16'hffff;
 end endgenerate
 wire boot_start;wire [2:0] boot_operation;wire [23:0] boot_address;wire [6:0] boot_length;
 wire [23:0] physical_jedec;wire [31:0] boot_sequence;wire [7:0] boot_slot,saved_slot;
 wire main_busy,main_done,main_error,main_read_valid;
 wire [7:0] main_read_byte,main_error_code;wire [5:0] main_read_index;
 a_record_scan #(.CLOCK_HZ(CLOCK_HZ),.SPI_DIV(SPI_DIV),.EXTERNAL_CRC(CRC_POOL_ENABLED),.STYLE_PERSISTENCE(STYLE_PERSISTENCE)) reader(
  clk,rst_n,boot_ready,boot_found,boot_unknown,boot_corrupt,boot_error,jedec_id,boot_sequence,boot_values,boot_mode,boot_custom,boot_count,
  restore_address,restore_byte,boot_slot,boot_start,boot_operation,boot_address,boot_length,
  main_done&&!boot_ready,main_error,main_error_code,main_read_valid&&!boot_ready,main_read_byte,main_read_index,physical_jedec,scan_h_clear,scan_h_enable,scan_h_byte,scan_b_clear,scan_b_enable,scan_b_byte,pool_header_crc,pool_body_crc,boot_styles);
 wire writer_start,writer_done,writer_error,writer_busy;
 wire [2:0] writer_operation;wire [23:0] writer_address;wire [6:0] writer_length;
 wire [7:0] writer_byte;wire [5:0] main_index;
 reg main_start;reg [2:0] main_operation;reg [23:0] main_address;reg [6:0] main_length;
 reg asset_active,writer_active,writer_pending;reg [2:0] pending_operation;reg [23:0] pending_address;reg [6:0] pending_length;
 reg writer_done_reg,writer_error_reg;reg [7:0] writer_error_code;
 assign writer_done=writer_done_reg;assign writer_error=writer_error_reg;
 assign save_busy=writer_busy||writer_pending||writer_active;
 a_necessary_record_writer #(.EXTERNAL_CRC(CRC_POOL_ENABLED),.ROOT_LEASE(ROOT_LEASE),.CACHED_HEADER(CACHED_HEADER),.STYLE_PERSISTENCE(STYLE_PERSISTENCE)) writer(clk,rst_n,boot_ready,boot_found,boot_error==0&&!boot_unknown,boot_sequence,boot_slot,boot_values,boot_mode,boot_custom,boot_count,
  save_valid,save_ready,save_token,save_values,save_mode,save_custom,save_count,source_address,source_byte,source_lock,
  save_done,save_done_ready,saved_token,save_error,stored_valid,saved_sequence,saved_slot,saved_values,saved_mode,saved_custom,saved_count,
  writer_busy,can_save,writer_start,writer_operation,writer_address,writer_length,writer_byte,main_index,
  writer_done,writer_error,writer_error_code,main_read_valid&&writer_active,main_read_index,main_read_byte,write_h_clear,write_h_enable,write_h_byte,write_b_clear,write_b_enable,write_b_byte,writer_header_crc,writer_body_crc,header_write_valid,header_write_address,header_write_byte,header_read_select,save_styles,style_source_lock);
 assign asset_ready=boot_ready&&!writer_busy&&!writer_pending&&!writer_active&&!asset_active&&!main_busy&&!main_start;
 assign asset_busy=asset_active;
 assign asset_byte_valid=main_read_valid&&asset_active;assign asset_byte=main_read_byte;assign asset_byte_index=main_read_index;
 wire [487:0] unused_read_data;
 flash_spi_transport #(.CLOCK_HZ(CLOCK_HZ),.CLK_DIV(SPI_DIV),.STREAM_SUPPORT(1),.SNAPSHOT_SUPPORT(0),.ASSET_READ_SUPPORT(1)) transport(
  .clk(clk),.rst_n(rst_n),.start(boot_ready?main_start:boot_start),.operation(boot_ready?main_operation:boot_operation),.address(boot_ready?main_address:boot_address),.write_stream_mode(1'b1),.write_stream_byte(writer_byte),.write_stream_index(main_index),
  .length(boot_ready?main_length:boot_length),.write_data(512'd0),.busy(main_busy),.done(main_done),.error(main_error),.error_code(main_error_code),
  .read_data({unused_read_data,physical_jedec}),.read_byte_valid(main_read_valid),.read_byte(main_read_byte),.read_index(main_read_index),.cs_n(flash_cs_n),.sclk(flash_sclk),.mosi(flash_mosi),.miso(flash_miso),
  .hold_n(),
  .wp_n(),
  .status());
 assign flash_wp_n=1'b1;assign flash_hold_n=1'b1;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin main_start<=0;main_operation<=0;main_address<=0;main_length<=0;asset_active<=0;writer_active<=0;writer_pending<=0;
   pending_operation<=0;pending_address<=0;pending_length<=0;writer_done_reg<=0;writer_error_reg<=0;writer_error_code<=0;
   asset_done<=0;asset_error<=0;asset_error_code<=0;
  end else begin
   main_start<=0;writer_done_reg<=0;asset_done<=0;
   if(main_done)begin
    if(asset_active)begin asset_done<=1;asset_error<=main_error;asset_error_code<=main_error_code;asset_active<=0;end
    if(writer_active)begin writer_done_reg<=1;writer_error_reg<=main_error;writer_error_code<=main_error_code;writer_active<=0;end
   end
   // A writer request may arrive after an asset already consumed its ready credit.
   // Queue that real transaction instead of dropping either registered start pulse.
   if(writer_start&&(main_busy||main_start||asset_active||writer_active))begin
    writer_pending<=1;pending_operation<=writer_operation;pending_address<=writer_address;pending_length<=writer_length;
   end
   if(boot_ready&&!main_busy&&!main_start&&!asset_active&&!writer_active)begin
    if(writer_pending)begin main_start<=1;main_operation<=pending_operation;main_address<=pending_address;main_length<=pending_length;writer_active<=1;writer_pending<=0;end
    else if(writer_start)begin main_start<=1;main_operation<=writer_operation;main_address<=writer_address;main_length<=writer_length;writer_active<=1;end
    else if(asset_start&&asset_ready)begin
     if(boot_error!=0)begin asset_done<=1;asset_error<=1;asset_error_code<=boot_error;end
     else begin main_start<=1;main_operation<=0;main_address<=asset_address;main_length<=asset_length;asset_active<=1;end
    end
   end
  end
 end
endmodule
