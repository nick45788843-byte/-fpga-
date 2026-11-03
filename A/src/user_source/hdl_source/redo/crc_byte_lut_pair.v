// Two independent, byte-per-clock CRC-CCITT states. The linear XOR form is
// algebraically identical to eight 0x1021 shifts, without a serial mux chain.
module crc_byte_lut_pair(input clk,rst_n,
 input clear_a,enable_a,input [7:0] byte_a,output reg [15:0] crc_a,
 input clear_b,enable_b,input [7:0] byte_b,output reg [15:0] crc_b);
function [15:0] step;input [15:0] old;input [7:0] data;reg [7:0] x;
 begin x=old[15:8]^data;x=x^(x>>4);
  step={old[7:0],8'd0}^{x[3:0],12'd0}^{3'd0,x,5'd0}^{8'd0,x};end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin crc_a<=16'hffff;crc_b<=16'hffff;end
 else begin
  if(enable_a)crc_a<=step(clear_a?16'hffff:crc_a,byte_a);else if(clear_a)crc_a<=16'hffff;
  if(enable_b)crc_b<=step(clear_b?16'hffff:crc_b,byte_b);else if(clear_b)crc_b<=16'hffff;
 end
end
endmodule

// Immutable native dual-read ROM: two 8-bit lanes retain independent CRC clients.
module crc_byte_bram_pair(input clk,rst_n,
 input clear_a,enable_a,input [7:0] byte_a,output [15:0] crc_a,
 input clear_b,enable_b,input [7:0] byte_b,output [15:0] crc_b);
wire [15:0] ta,tb;reg [7:0] low_a,low_b;reg init_a,init_b;
assign crc_a=init_a?({low_a,8'd0}^ta):16'hffff;
assign crc_b=init_b?({low_b,8'd0}^tb):16'hffff;
wire [15:0] pa=clear_a?16'hffff:crc_a,pb=clear_b?16'hffff:crc_b;
wire [7:0] ia=pa[15:8]^byte_a,ib=pb[15:8]^byte_b;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin init_a<=0;init_b<=0;low_a<=0;low_b<=0;end
 else begin
  if(clear_a||enable_a)begin init_a<=enable_a;if(enable_a)low_a<=pa[7:0];end
  if(clear_b||enable_b)begin init_b<=enable_b;if(enable_b)low_b<=pb[7:0];end
 end
end
wire unused_a0,unused_b0;
EG_PHY_BRAM #(
 .MODE("DP8K"),
 .DATA_WIDTH_A("9"),
 .DATA_WIDTH_B("9"),
 .REGMODE_A("NOREG"),
 .REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),
 .WRITEMODE_B("NORMAL"),
 .WEAMUX("0"),
 .WEBMUX("0"),
 .RSTAMUX("0"),
 .RSTBMUX("0"),
 .OCEAMUX("1"),
 .OCEBMUX("1"),
 .CSA0("1"),
 .CSA1("1"),
 .CSA2("1"),
 .CSB0("1"),
 .CSB1("1"),
 .CSB2("1"),
 .INIT_00(256'hdeff9cbd5a7b1839d6f794b552731031efcead8c6b4a2908e7c6a58463422100),
 .INIT_01(256'hbc9dfedf38197a5bb495f6d7301172538daccfee09284b6a85a4c7e601204362),
 .INIT_02(256'h1a3b58799ebfdcfd1233507196b7d4f52b0a6948af8eedcc23026140a786e5c4),
 .INIT_03(256'h78593a1bfcddbe9f70513213f4d5b69749680b2acdec8fae41600322c5e487a6),
 .INIT_04(256'h56771435d2f390b15e7f1c3ddafb98b967462504e3c2a1806f4e2d0cebcaa988),
 .INIT_05(256'h34157657b091f2d33c1d7e5fb899fadb0524476681a0c3e20d2c4f6e89a8cbea),
 .INIT_06(256'h92b3d0f1163754759abbd8f91e3f5c7da382e1c027066544ab8ae9c82f0e6d4c),
 .INIT_07(256'hf0d1b29374553617f8d9ba9b7c5d3e1fc1e083a245640726c9e88baa4d6c0f2e)) rom0(
.dia(9'd0),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({2'b00,ia,3'b111}),.addrb({2'b00,ib,3'b111}),
.cea(rst_n&&enable_a),.ceb(rst_n&&enable_b),.ocea(1'b1),.oceb(1'b1),.clka(clk),.clkb(clk),.wea(1'b0),.web(1'b0),.rsta(1'b0),.rstb(1'b0),
.doa({unused_a0,ta[7:0]}),.dob({unused_b0,tb[7:0]}));
wire unused_a1,unused_b1;
EG_PHY_BRAM #(
 .MODE("DP8K"),
 .DATA_WIDTH_A("9"),
 .DATA_WIDTH_B("9"),
 .REGMODE_A("NOREG"),
 .REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),
 .WRITEMODE_B("NORMAL"),
 .WEAMUX("0"),
 .WEBMUX("0"),
 .RSTAMUX("0"),
 .RSTBMUX("0"),
 .OCEAMUX("1"),
 .OCEBMUX("1"),
 .CSA0("1"),
 .CSA1("1"),
 .CSA2("1"),
 .CSB0("1"),
 .CSB1("1"),
 .CSB2("1"),
 .INIT_00(256'he3f3c3d3a3b383936272425222320212f1e1d1c1b1a191817060504030201000),
 .INIT_01(256'hc7d7e7f78797a7b74656667606162636d5c5f5e59585b5a55444746414043424),
 .INIT_02(256'habbb8b9bebfbcbdb2a3a0a1a6a7a4a5ab9a99989f9e9d9c93828180878685848),
 .INIT_03(256'h8f9fafbfcfdfefff0e1e2e3e4e5e6e7e9d8dbdadddcdfded1c0c3c2c5c4c7c6c),
 .INIT_04(256'h7262524232221202f3e3d3c3b3a393836070405020300010e1f1c1d1a1b18191),
 .INIT_05(256'h5646766616063626d7c7f7e79787b7a74454647404142434c5d5e5f58595a5b5),
 .INIT_06(256'h3a2a1a0a7a6a5a4abbab9b8bfbebdbcb2838081868784858a9b98999e9f9c9d9),
 .INIT_07(256'h1e0e3e2e5e4e7e6e9f8fbfafdfcfffef0c1c2c3c4c5c6c7c8d9dadbdcdddedfd)) rom1(
.dia(9'd0),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({2'b00,ia,3'b111}),.addrb({2'b00,ib,3'b111}),
.cea(rst_n&&enable_a),.ceb(rst_n&&enable_b),.ocea(1'b1),.oceb(1'b1),.clka(clk),.clkb(clk),.wea(1'b0),.web(1'b0),.rsta(1'b0),.rstb(1'b0),
.doa({unused_a1,ta[15:8]}),.dob({unused_b1,tb[15:8]}));
endmodule
