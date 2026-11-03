// One physical NOR engine, three clients. Journal erase/program/verify/marker
// retains one lease and never steals an in-flight configuration save lease.
module b_flash_font_mux #(parameter CLOCK_HZ=50000000,SPI_DIV=4,TIMEOUT_MS=5000,JOURNAL_ENABLED=0)(
 input clk,rst_n,cfg_lease,cfg_start,input [2:0] cfg_operation,
 input [23:0] cfg_address,input [6:0] cfg_length,input [7:0] cfg_write_byte,
 output [5:0] cfg_write_index,output cfg_busy,cfg_done,cfg_error,
 output [7:0] cfg_error_code,cfg_status,output [511:0] cfg_read_data,
 output cfg_byte_valid,output [7:0] cfg_byte,output [5:0] cfg_index,
 input font_valid,output font_ready,input [23:0] font_address,input [6:0] font_length,
 output font_done,font_error,output [7:0] font_error_code,
 output font_byte_valid,output [7:0] font_byte,output [5:0] font_index,
 input journal_lease,journal_valid,output journal_ready,input [2:0] journal_operation,
 input [23:0] journal_address,input [6:0] journal_length,input [7:0] journal_write_byte,
 output [5:0] journal_write_index,output journal_done,journal_error,
 output [7:0] journal_error_code,output journal_byte_valid,output [7:0] journal_byte,output [5:0] journal_index,
 output flash_cs_n,flash_sclk,flash_mosi,input flash_miso,output flash_wp_n,flash_hold_n);
localparam CFG=0,FONT=1,JOURNAL=2;
reg cfg_pending,active,engine_start,journal_owned;
reg [1:0] owner;
reg [2:0] pending_op,engine_op;
reg [23:0] pending_address,engine_address;
reg [6:0] pending_length,engine_length;
wire engine_done,engine_error,engine_busy,engine_valid;
wire [7:0] engine_error_code,engine_byte;
wire [5:0] engine_index,engine_write_index;
wire journal_wants=JOURNAL_ENABLED&&journal_lease;
assign journal_ready=JOURNAL_ENABLED&&rst_n&&!active&&
 (journal_owned||(!cfg_pending&&!cfg_start&&!cfg_lease));
assign font_ready=rst_n&&!active&&!cfg_pending&&!cfg_start&&!cfg_lease&&!journal_owned&&!journal_wants;
assign cfg_busy=cfg_pending||(active&&owner==CFG);
assign cfg_done=active&&owner==CFG&&engine_done;
assign cfg_error=engine_error;assign cfg_error_code=engine_error_code;
assign cfg_byte_valid=active&&owner==CFG&&engine_valid;
assign cfg_byte=engine_byte;assign cfg_index=engine_index;
assign cfg_write_index=engine_write_index;
assign font_done=active&&owner==FONT&&engine_done;
assign font_error=engine_error;assign font_error_code=engine_error_code;
assign font_byte_valid=active&&owner==FONT&&engine_valid;
assign font_byte=engine_byte;assign font_index=engine_index;
assign journal_done=active&&owner==JOURNAL&&engine_done;
assign journal_error=engine_error;assign journal_error_code=engine_error_code;
assign journal_byte_valid=active&&owner==JOURNAL&&engine_valid;
assign journal_byte=engine_byte;assign journal_index=engine_index;
assign journal_write_index=engine_write_index;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  cfg_pending<=0;active<=0;owner<=CFG;engine_start<=0;journal_owned<=0;
  pending_op<=0;pending_address<=0;pending_length<=0;
  engine_op<=0;engine_address<=0;engine_length<=0;
 end else begin
  engine_start<=0;
  if(cfg_start)begin cfg_pending<=1;pending_op<=cfg_operation;pending_address<=cfg_address;pending_length<=cfg_length;end
  if(journal_owned&&!journal_wants&&!active)journal_owned<=0;
  if(active)begin if(engine_done)active<=0;end
  else if(JOURNAL_ENABLED&&journal_owned)begin
   if(journal_valid&&journal_ready)begin
    active<=1;owner<=JOURNAL;engine_start<=1;
    engine_op<=journal_operation;engine_address<=journal_address;engine_length<=journal_length;
   end
  end else if(cfg_pending&&!cfg_start)begin
   cfg_pending<=0;active<=1;owner<=CFG;engine_start<=1;
   engine_op<=pending_op;engine_address<=pending_address;engine_length<=pending_length;
  end else if(JOURNAL_ENABLED&&journal_valid&&journal_ready)begin
   journal_owned<=journal_wants;active<=1;owner<=JOURNAL;engine_start<=1;
   engine_op<=journal_operation;engine_address<=journal_address;engine_length<=journal_length;
  end else if(font_valid&&font_ready)begin
   active<=1;owner<=FONT;engine_start<=1;engine_op<=0;engine_address<=font_address;engine_length<=font_length;
  end
 end
end
wire [7:0] engine_write_byte=owner==JOURNAL?journal_write_byte:cfg_write_byte;
flash_spi_transport #(.STREAM_SUPPORT(1),.SNAPSHOT_SUPPORT(0),.CLOCK_HZ(CLOCK_HZ),
 .CLK_DIV(SPI_DIV),.TIMEOUT_MS(TIMEOUT_MS),.READ_ONLY_SUPPORT(1),.JOURNAL_SUPPORT(JOURNAL_ENABLED),
 .READ_ONLY_BEGIN(24'h100000),.READ_ONLY_END(24'h680000)) physical(
 .clk(clk),.rst_n(rst_n),.start(engine_start),.operation(engine_op),.address(engine_address),.length(engine_length),
 .write_stream_mode(1'b1),.write_stream_byte(engine_write_byte),.write_stream_index(engine_write_index),.write_data(512'd0),
 .busy(engine_busy),.done(engine_done),.error(engine_error),.error_code(engine_error_code),
 .read_data(cfg_read_data),.status(cfg_status),.read_byte_valid(engine_valid),.read_byte(engine_byte),.read_index(engine_index),
 .cs_n(flash_cs_n),.sclk(flash_sclk),.mosi(flash_mosi),.miso(flash_miso),.wp_n(flash_wp_n),.hold_n(flash_hold_n));
endmodule
