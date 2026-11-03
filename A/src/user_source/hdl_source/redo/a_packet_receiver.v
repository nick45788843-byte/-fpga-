// Physical RX -> CRC-qualified descriptor. RX RAM banks remain leased after
// descriptor acceptance until explicit backend capture/cancel release. When
// both banks are held, short emergency commands still have inline arguments.
module a_packet_receiver #(parameter CLOCK_HZ=50000000,CLKS_PER_BIT=434)(input clk,rst_n,rx,
 output reg packet_valid,input packet_ready,
 output reg [15:0] session,sequence_id,length,output reg [7:0] command,output reg [47:0] arguments,
 output reg packet_bank,packet_has_bank,input release_valid,release_bank,
 input read_bank,input [7:0] read_address,output reg [7:0] read_byte,output reg [15:0] dropped);
localparam HUNT=0,MAGIC=1,HEADER=2,BODY=3,CRC_LOW=4,CRC_HIGH=5;
localparam [8:0] MAX_LEGACY_BODY_BYTES=9'd192,MAX_CMD22_BODY_BYTES=9'd198;
localparam GAP_LIMIT=CLOCK_HZ/20,TOTAL_LIMIT=CLOCK_HZ/10,TW=$clog2(TOTAL_LIMIT+1);
reg [2:0] state,header_index;reg [TW-1:0] gap_time,total_time;
reg [15:0] crc,rx_session,rx_sequence,rx_length,remaining;reg [7:0] rx_command,low_crc;
reg [47:0] rx_arguments;reg [8:0] body_index;reg version_ok,receive_bank,reserved;
reg [1:0] owned;wire [7:0] b;wire byte_valid,framing_error;
wire [8:0] body_capacity=(rx_command==8'd22)?MAX_CMD22_BODY_BYTES:MAX_LEGACY_BODY_BYTES;
(* force_ram=1,ram_style="bram" *) reg [7:0] body_memory[0:511];
uart_rx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) receiver(clk,rst_n,rx,b,byte_valid,framing_error);
function [15:0] crc_step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;crc_step={old[7:0],8'd0}^({16{x[0]}}&16'h1021)^({16{x[1]}}&16'h2042)^({16{x[2]}}&16'h4084)^({16{x[3]}}&16'h8108)^({16{x[4]}}&16'h1231)^({16{x[5]}}&16'h2462)^({16{x[6]}}&16'h48c4)^({16{x[7]}}&16'h9188);end
endfunction
always @(posedge clk)begin
 read_byte<=body_memory[{read_bank,read_address}];
 if(byte_valid&&state==BODY&&reserved&&body_index<body_capacity&&!framing_error)body_memory[{receive_bank,body_index[7:0]}]<=b;
end
task lose;begin if(dropped!=16'hffff)dropped<=dropped+1'b1;end endtask
task abandon;begin state<=HUNT;if(reserved)owned[receive_bank]<=0;reserved<=0;end endtask
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=HUNT;header_index<=0;gap_time<=0;total_time<=0;crc<=16'hffff;rx_session<=0;rx_sequence<=0;rx_length<=0;
  remaining<=0;rx_command<=0;low_crc<=0;rx_arguments<=0;body_index<=0;version_ok<=0;receive_bank<=0;reserved<=0;
  owned<=0;packet_valid<=0;session<=0;sequence_id<=0;length<=0;command<=0;arguments<=0;packet_bank<=0;packet_has_bank<=0;dropped<=0;
 end else begin
  if(packet_valid&&packet_ready)packet_valid<=0;
  if(release_valid)owned[release_bank]<=0;
  if(state==HUNT)begin gap_time<=0;total_time<=0;end
  else begin
   if(gap_time<GAP_LIMIT)gap_time<=gap_time+1'b1;
   if(total_time<TOTAL_LIMIT)total_time<=total_time+1'b1;
  end
  if(framing_error||(state!=HUNT&&(gap_time>=GAP_LIMIT-1||total_time>=TOTAL_LIMIT-1)))begin abandon();lose();end
  else if(byte_valid)begin
   gap_time<=0;
   case(state)
    HUNT:if(b==8'h43)begin
     state<=MAGIC;crc<=crc_step(16'hffff,b);total_time<=0;
     receive_bank<=!owned[0]?1'b0:1'b1;reserved<=owned!=2'b11;
     if(owned!=2'b11)owned[!owned[0]?0:1]<=1;
    end
    MAGIC:if(b==8'h4e)begin state<=HEADER;header_index<=0;crc<=crc_step(crc,b);end
     else if(b==8'h43)begin crc<=crc_step(16'hffff,b);total_time<=0;end else abandon();
    HEADER:begin
     crc<=crc_step(crc,b);header_index<=header_index+1'b1;
     case(header_index)
      0:begin version_ok<=b==2;rx_arguments<=0;body_index<=0;end
      1:rx_session[7:0]<=b;2:rx_session[15:8]<=b;
      3:rx_sequence[7:0]<=b;4:rx_sequence[15:8]<=b;5:rx_command<=b;6:rx_length[7:0]<=b;
      7:begin rx_length[15:8]<=b;
       if({b,rx_length[7:0]}>500)begin abandon();lose();end
       else if({b,rx_length[7:0]}==0)state<=CRC_LOW;
       else begin remaining<={b,rx_length[7:0]};state<=BODY;end
      end
     endcase
    end
    BODY:begin
     crc<=crc_step(crc,b);if(body_index<6)rx_arguments[body_index*8+:8]<=b;
     body_index<=body_index+1'b1;remaining<=remaining-1'b1;if(remaining==1)state<=CRC_LOW;
    end
    CRC_LOW:begin low_crc<=b;state<=CRC_HIGH;end
    CRC_HIGH:begin
     state<=HUNT;
     if(version_ok&&{b,low_crc}==crc&&(!packet_valid||packet_ready))begin
      packet_valid<=1;session<=rx_session;sequence_id<=rx_sequence;length<=rx_length;command<=rx_command;
      arguments<=rx_arguments;packet_bank<=receive_bank;
      packet_has_bank<=reserved&&(rx_length<=MAX_LEGACY_BODY_BYTES||
        (rx_command==8'd22&&rx_length<=MAX_CMD22_BODY_BYTES));
      // Unsupported long lengths have no complete RAM body and cannot execute.
      if(reserved&&!(rx_length<=MAX_LEGACY_BODY_BYTES||
        (rx_command==8'd22&&rx_length<=MAX_CMD22_BODY_BYTES)))owned[receive_bank]<=0;
     end else begin if(reserved)owned[receive_bank]<=0;lose();end
     reserved<=0;
    end
    default:abandon();
   endcase
  end
 end
end
endmodule
