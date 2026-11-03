// B computes the existing fixed-point brightness/contrast result, then applies
// a ROM gamma map. The final sample retains its owner through output backpressure.
module b_colour_curve_gamma #(parameter ROM_FILE="gamma_curve.mem")(
 input clk,rst_n,start,input [7:0] brightness,contrast,gamma,
 input [31:0] token,output busy,output reg done,error,output reg [31:0] result_token,
 output reg valid,input ready,output reg [7:0] index,data);
(* force_ram=1,ram_style="bram" *) reg [7:0] gamma_table[0:2047];
initial $readmemh(ROM_FILE,gamma_table);
reg owned,finished;reg [2:0] held_gamma;
wire core_busy,core_done,core_error,core_valid;
wire [31:0] core_token;wire [7:0] core_index,core_data;
wire accept=start&&!owned&&!valid;
wire core_ready=!valid||ready;
assign busy=owned;
b_colour_curve base_curve(clk,rst_n,accept&&gamma<8,brightness,contrast,token,
 core_busy,core_done,core_error,core_token,core_valid,core_ready,core_index,core_data);
always @(posedge clk)if(rst_n&&core_valid&&core_ready)
 data<=gamma_table[{held_gamma,core_data}];
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin owned<=0;finished<=0;held_gamma<=2;done<=0;error<=0;result_token<=0;valid<=0;index<=0;end
 else begin
  done<=0;
  if(valid&&ready)valid<=0;
  if(accept)begin
   result_token<=token;finished<=0;error<=gamma>=8;
   if(gamma>=8)done<=1;
   else begin owned<=1;held_gamma<=gamma[2:0];end
  end
  if(core_valid&&core_ready)begin valid<=1;index<=core_index;end
  if(core_done)begin
   error<=core_error;
   if(core_error||!valid||ready)begin owned<=0;finished<=0;done<=1;end
   else finished<=1;
  end
  if(finished&&(!valid||ready))begin owned<=0;finished<=0;done<=1;end
 end
end
endmodule
