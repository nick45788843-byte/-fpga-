// Immutable eight-byte F7 result from actual CRC-qualified media consumption.
// Retried data is serialized in the SPI mailbox; this descriptor remains until
// the next actual result. Polls and heartbeat echoes never manufacture success.
module a_media_ack32(input clk,rst_n,
 input completed,input [31:0] completed_uid,input [15:0] completed_tag,input [7:0] completed_error,
 input rejected,input [31:0] rejected_uid,input [15:0] rejected_tag,input [7:0] rejected_error,
 output reg valid,output reg [63:0] header);
function [63:0] pack;input [31:0] uid;input [15:0] tag;input [7:0] error;
 begin pack={8'hf7,error,tag[7:0],tag[15:8],uid[7:0],uid[15:8],uid[23:16],uid[31:24]};end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin valid<=0;header<=0;end
 else if(rejected)begin valid<=1;header<=pack(rejected_uid,rejected_tag,rejected_error);end
 else if(completed&&completed_uid!=0)begin valid<=1;header<=pack(completed_uid,completed_tag,completed_error);end
end
endmodule
