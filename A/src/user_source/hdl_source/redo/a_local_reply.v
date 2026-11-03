// One local descriptor/status snapshot; services retain only token/cmd/error.
module a_local_reply(input clk,rst_n,
 input query_valid,output query_ready,input [31:0] query_token,input [7:0] query_command,
 input emergency_request_accept,input [31:0] emergency_request_token,input [7:0] emergency_request_command,
 input emergency_valid,output emergency_ready,input [31:0] emergency_token,input [7:0] emergency_error,
 input media_valid,output media_ready,input [31:0] media_token,input [7:0] media_command,media_error,
 input [191:0] actual_status,input [31:0] audio_status,
 output reg result_valid,input result_ready,output reg [31:0] result_token,
 input [4:0] byte_address,output reg [7:0] result_byte);
reg [31:0] emergency_owner;reg [7:0] emergency_command;reg emergency_owned;
reg [7:0] command,error;reg [191:0] status_snapshot;
wire space=!result_valid||result_ready;
wire known_emergency=emergency_owned&&emergency_token==emergency_owner;
assign emergency_ready=!known_emergency||space;
wire take_emergency=emergency_valid&&known_emergency;
assign media_ready=space&&!take_emergency;
assign query_ready=space&&!take_emergency&&!media_valid&&(query_command==1||query_command==2||query_command==15);
always @(posedge clk)begin
 if(byte_address==0)result_byte<=command;
 else if(byte_address==1)result_byte<=error!=0;
 else if(byte_address==2)result_byte<=error;
 else result_byte<=byte_address<24?status_snapshot[byte_address*8+:8]:8'd0;
end
// Unpublished bytes have no meaning. Reset only their ownership/valid flags;
// every accepted result initializes all bytes before the shared frame can read.
always @(posedge clk)if(rst_n)begin
 if(space)begin
  if(take_emergency)begin
   result_token<=emergency_token;command<=emergency_command;error<=emergency_error;status_snapshot<=actual_status;
  end else if(media_valid)begin
   result_token<=media_token;command<=media_command;error<=media_error;status_snapshot<=actual_status;
  end else if(query_valid&&query_ready)begin
   result_token<=query_token;command<=query_command;error<=0;
   status_snapshot<=query_command==15?{128'd0,audio_status,32'd0}:actual_status;
  end
 end
 if(emergency_request_accept)begin emergency_owner<=emergency_request_token;emergency_command<=emergency_request_command;end
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin result_valid<=0;emergency_owned<=0;end
 else begin
  if(result_valid&&result_ready)result_valid<=0;
  if(space)begin
   if(take_emergency)begin
    result_valid<=1;emergency_owned<=0;
   end else if(media_valid)begin
    result_valid<=1;
   end else if(query_valid&&query_ready)begin
    result_valid<=1;
   end
  end
  if(emergency_request_accept)emergency_owned<=1;
 end
end
endmodule
