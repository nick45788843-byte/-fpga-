// Two immutable 64-byte reply banks in one true dual-clock byte RAM.
// A may write only the bank opposite the last published bank and cannot
// publish again until SPI has actually captured the previous bank at byte3.
// SPI selects a bank once per frame; stopping its clock holds that bank forever.
module a_spi_reply_store6 #(parameter TRACK_MEDIA=0)(input clk,rst_n,
 input write_valid,input [5:0] write_address,input [7:0] write_byte,input publish,
 output write_ready,input spi_clk,spi_cs_n,output miso,
 output reg snapshot_valid,input media_descriptor,output media_command_captured);
(* force_ram=1,ram_style="bram" *) reg [7:0] bytes[0:127];
reg published,has_frame;
reg spi_ack;(* async_reg=1,preserve=1 *) reg ack_meta,ack_sync;
(* async_reg=1,preserve=1 *) reg bank_meta,bank_sync,valid_meta,valid_sync;
reg selected_bank;reg [9:0] tx_index;reg [7:0] read_byte;
reg [1:0] media_banks;reg spi_media_toggle;
(* async_reg=1,preserve=1 *) reg media_meta,media_sync;
reg media_seen;
(*preserve=1*) reg published_phase,has_frame_phase;
(*preserve=1*) reg [1:0] media_banks_phase;
(*async_reg=1,preserve=1*) reg ack_phase,media_phase;
always @(negedge clk or negedge rst_n)begin
 if(!rst_n)begin published_phase<=0;has_frame_phase<=0;media_banks_phase<=0;ack_phase<=0;media_phase<=0;end
 else begin published_phase<=published;has_frame_phase<=has_frame;media_banks_phase<=media_banks;
  ack_phase<=spi_ack;media_phase<=spi_media_toggle;end
end
assign media_command_captured=media_sync!=media_seen;
wire write_bank=!published;
assign write_ready=published==ack_sync;
always @(posedge clk)if(rst_n&&write_valid&&write_ready)bytes[{write_bank,write_address}]<=write_byte;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin published<=0;has_frame<=0;ack_meta<=0;ack_sync<=0;media_banks<=0;media_meta<=0;media_sync<=0;media_seen<=0;end
 else begin
  ack_meta<=ack_phase;ack_sync<=ack_meta;
  media_meta<=media_phase;media_sync<=media_meta;media_seen<=media_sync;
  if(publish&&write_ready)begin published<=!published;has_frame<=1;media_banks[write_bank]<=TRACK_MEDIA&&media_descriptor;end
 end
end
wire frame_reset=!rst_n||spi_cs_n;
// CS deasserts reset before the first rising edge. A dedicated single-change
// flag releases negative-edge TX reset after that first positive edge, giving
// a real half SPI cycle of removal margin without shifting the header bits.
(*preserve=1*) reg frame_started;
always @(posedge spi_clk or posedge frame_reset)
 if(frame_reset)frame_started<=0;else frame_started<=1;
// Raw reset/CS already clears frame_started asynchronously, without any
// clock. Derive TX reset solely from that flag: a redundant direct raw OR
// would leave the original coincident-edge removal path in the real netlist.
wire tx_frame_reset=!frame_started;
reg [5:0] rx_header_bit;
always @(posedge spi_clk or posedge frame_reset)begin
 if(frame_reset)rx_header_bit<=0;
 else if(rx_header_bit<32)rx_header_bit<=rx_header_bit+1'b1;
end
always @(posedge spi_clk or negedge rst_n)begin
 if(!rst_n)begin bank_meta<=0;bank_sync<=0;valid_meta<=0;valid_sync<=0;selected_bank<=0;spi_ack<=0;snapshot_valid<=0;spi_media_toggle<=0;end
 else begin
  bank_meta<=published_phase;bank_sync<=bank_meta;valid_meta<=has_frame_phase;valid_sync<=valid_meta;
  if(!spi_cs_n&&rx_header_bit==31)begin
   selected_bank<=bank_sync;snapshot_valid<=valid_sync;
   if(valid_sync)spi_ack<=bank_sync;
   // This tag follows the immutable published bank, including repeated polls.
   // It drives scheduling only; it is not a CRC-qualified execution ACK.
   if(valid_sync&&TRACK_MEDIA&&media_banks_phase[bank_sync])spi_media_toggle<=!spi_media_toggle;
  end
 end
end
// BRAM read is synchronous to falling SPI clock. The constant 32-bit header
// gives enough clocks to capture the lease before the first RAM data byte.
wire [9:0] next_index=tx_index+10'd1;
wire [5:0] byte_address=next_index[8:3];
always @(negedge spi_clk)read_byte<=bytes[{selected_bank,byte_address}];
always @(negedge spi_clk or posedge tx_frame_reset)begin
 if(tx_frame_reset)tx_index<=0;else if(tx_index<1023)tx_index<=tx_index+1'b1;
end
localparam [31:0] HEADER=32'h434e0681;
// Header + 58 zero bytes; no valid operation/UID or execution ACK.
localparam [15:0] EMPTY_WIRE_CRC=16'hdcac;
assign miso=spi_cs_n?1'b0:tx_index<32?HEADER[31-tx_index]:
 tx_index<512?(snapshot_valid?read_byte[7-tx_index[2:0]]:
 (tx_index>=496?EMPTY_WIRE_CRC[511-tx_index]:1'b0)):1'b0;
endmodule
