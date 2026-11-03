// Sequential byte/CRC writer. No 512-bit register frame or lane-enable array.
// A complete unpublished bank is discarded on abort; published SPI banks retain
// their lease until actual SPI capture, including stopped clocks/partial polls.
module a_spi_reply_writer #(parameter EXTERNAL_CRC=0)(input clk,rst_n,input build_valid,build_abort,
 output build_ready,output [5:0] source_address,input [7:0] source_byte,
 input store_ready,output write_valid,output [5:0] write_address,output [7:0] write_byte,
 output publish,output reg frame_valid,output building,input direct_body,output crc_clear,crc_enable,output [7:0] crc_byte,input [15:0] external_crc);
localparam IDLE=0,ADDR=1,WAIT_BYTE=2,COPY=3,CRC_LOW=4,CRC_HIGH=5;
reg [2:0] state;reg [5:0] address;reg [15:0] private_crc;
wire [15:0] crc=EXTERNAL_CRC?external_crc:private_crc;
// CRC16 is linear: old low byte shifts once, while old high XOR data
// contributes eight constant polynomial basis vectors. No conditional loop mux.
function [15:0] step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;step={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
assign crc_clear=build_abort||(state==IDLE&&build_valid&&store_ready);
assign crc_enable=!build_abort&&state==COPY;
assign crc_byte=source_byte;
assign building=state!=IDLE;
assign build_ready=state==IDLE&&store_ready;
assign source_address=address;
assign write_valid=!build_abort&&(state==COPY||state==CRC_LOW||state==CRC_HIGH);
assign write_address=state==CRC_LOW?6'd62:state==CRC_HIGH?6'd63:address;
assign write_byte=state==CRC_LOW?crc[7:0]:state==CRC_HIGH?crc[15:8]:source_byte;
assign publish=state==CRC_HIGH&&!build_abort&&store_ready;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;address<=0;private_crc<=16'hffff;frame_valid<=0;end
 else if(build_abort)begin state<=IDLE;frame_valid<=0;end
 else case(state)
  IDLE:if(build_valid&&store_ready)begin state<=COPY;address<=0;private_crc<=16'hffff;frame_valid<=0;end
  ADDR:state<=WAIT_BYTE;
  WAIT_BYTE:state<=COPY;
  COPY:begin private_crc<=step(crc,source_byte);if(address==61)state<=CRC_LOW;else begin address<=address+1'b1;
   if(address<37||direct_body)state<=COPY;else state<=ADDR;
  end end
  CRC_LOW:state<=CRC_HIGH;
  CRC_HIGH:if(store_ready)begin state<=IDLE;frame_valid<=1;end
 endcase
end
endmodule
