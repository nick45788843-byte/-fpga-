// Each complete bank: 64 native32 cells and 32 headline64 quadrants.
// All 6144 valid 32-bit words fit six ROM32K macros. No copied body or bank.
module a_emergency_bitmap32(input config_clk,input we,input [12:0] write_address,input [31:0] write_data,
 input clk,input [12:0] address,output [31:0] data,input [4:0] pixel_column,output pixel);
wire [2:0] wsegment=write_address[12]?write_address[12:10]-3'd1:write_address[12:10];
wire [2:0] rsegment=address[12]?address[12:10]-3'd1:address[12:10];
wire write_valid=!(write_address[11]&&write_address[10]);
reg [1:0] page;reg read_valid;always @(posedge clk)begin page<=rsegment[2:1];read_valid<=!(address[11]&&address[10]);end
wire [47:0] lower,upper;
reg [4:0] column;always @(posedge clk)column<=pixel_column;
wire [2:0] lower_pixels,upper_pixels;
genvar pixel_page;generate for(pixel_page=0;pixel_page<3;pixel_page=pixel_page+1)begin: choose_bit_at_lane
 assign lower_pixels[pixel_page]=lower[pixel_page*16+15-column[3:0]];
 assign upper_pixels[pixel_page]=upper[pixel_page*16+15-column[3:0]];
end endgenerate
assign pixel=read_valid?(column[4]?lower_pixels[page]:upper_pixels[page]):1'b0;
assign data=read_valid?{upper[page*16+:16],lower[page*16+:16]}:32'd0;
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) page_0_lane_0(
 .doa(),.dia(write_data[0+:16]),.addra({wsegment[0],write_address[9:0]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(we&&write_valid&&wsegment[2:1]==2'd0),.clka(config_clk),.rsta(1'b0),.ocea(1'b1),
 .dob(lower[0+:16]),.dib(16'd0),.addrb({rsegment[0],address[9:0]}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) page_0_lane_1(
 .doa(),.dia(write_data[16+:16]),.addra({wsegment[0],write_address[9:0]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(we&&write_valid&&wsegment[2:1]==2'd0),.clka(config_clk),.rsta(1'b0),.ocea(1'b1),
 .dob(upper[0+:16]),.dib(16'd0),.addrb({rsegment[0],address[9:0]}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) page_1_lane_0(
 .doa(),.dia(write_data[0+:16]),.addra({wsegment[0],write_address[9:0]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(we&&write_valid&&wsegment[2:1]==2'd1),.clka(config_clk),.rsta(1'b0),.ocea(1'b1),
 .dob(lower[16+:16]),.dib(16'd0),.addrb({rsegment[0],address[9:0]}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) page_1_lane_1(
 .doa(),.dia(write_data[16+:16]),.addra({wsegment[0],write_address[9:0]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(we&&write_valid&&wsegment[2:1]==2'd1),.clka(config_clk),.rsta(1'b0),.ocea(1'b1),
 .dob(upper[16+:16]),.dib(16'd0),.addrb({rsegment[0],address[9:0]}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) page_2_lane_0(
 .doa(),.dia(write_data[0+:16]),.addra({wsegment[0],write_address[9:0]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(we&&write_valid&&wsegment[2:1]==2'd2),.clka(config_clk),.rsta(1'b0),.ocea(1'b1),
 .dob(lower[32+:16]),.dib(16'd0),.addrb({rsegment[0],address[9:0]}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG")) page_2_lane_1(
 .doa(),.dia(write_data[16+:16]),.addra({wsegment[0],write_address[9:0]}),.bytea(1'b0),.bytewea(1'b0),.csa(1'b1),.wea(we&&write_valid&&wsegment[2:1]==2'd2),.clka(config_clk),.rsta(1'b0),.ocea(1'b1),
 .dob(upper[32+:16]),.dib(16'd0),.addrb({rsegment[0],address[9:0]}),.byteb(1'b0),.byteweb(1'b0),.csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
endmodule

// Two 9K cells hold both complete title banks; read latency remains one clock.
module a_title_bitmap16(input config_clk,input we,input [9:0] write_address,input [15:0] write_data,
 input clk,input [9:0] address,output [15:0] data);
wire [8:0] q0;assign data[0+:8]=q0[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) title_lane0(
 .dia({1'b0,write_data[0+:8]}),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({write_address,3'b111}),.addrb({address,3'b111}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(config_clk),.clkb(clk),.wea(we),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(q0));
wire [8:0] q1;assign data[8+:8]=q1[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) title_lane1(
 .dia({1'b0,write_data[8+:8]}),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({write_address,3'b111}),.addrb({address,3'b111}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(config_clk),.clkb(clk),.wea(we),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(q1));
endmodule

// Four 9K cells preserve all 64-glyph front/shadow programme rows.
module a_program_bitmap16(input config_clk,input we,input [10:0] write_address,input [15:0] write_data,
 input clk,input [10:0] address,output [15:0] data);
reg bank;always @(posedge clk)bank<=address[10];
wire [15:0] low_bank,high_bank;assign data=bank?high_bank:low_bank;
wire [8:0] b0_lane0;assign low_bank[0+:8]=b0_lane0[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) b0_lane0_rows(
 .dia({1'b0,write_data[0+:8]}),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({write_address[9:0],3'b111}),.addrb({address[9:0],3'b111}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(config_clk),.clkb(clk),.wea(we&&write_address[10]==1'b0),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(b0_lane0));
wire [8:0] b0_lane1;assign low_bank[8+:8]=b0_lane1[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) b0_lane1_rows(
 .dia({1'b0,write_data[8+:8]}),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({write_address[9:0],3'b111}),.addrb({address[9:0],3'b111}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(config_clk),.clkb(clk),.wea(we&&write_address[10]==1'b0),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(b0_lane1));
wire [8:0] b1_lane0;assign high_bank[0+:8]=b1_lane0[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) b1_lane0_rows(
 .dia({1'b0,write_data[0+:8]}),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({write_address[9:0],3'b111}),.addrb({address[9:0],3'b111}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(config_clk),.clkb(clk),.wea(we&&write_address[10]==1'b1),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(b1_lane0));
wire [8:0] b1_lane1;assign high_bank[8+:8]=b1_lane1[7:0];
EG_PHY_BRAM #(.MODE("DP8K"),.DATA_WIDTH_A("9"),.DATA_WIDTH_B("9"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.CSA0("1"),.CSA1("1"),.CSA2("1"),.CSB0("1"),.CSB1("1"),.CSB2("1")) b1_lane1_rows(
 .dia({1'b0,write_data[8+:8]}),.dib(9'd0),.csa(3'b111),.csb(3'b111),.addra({write_address[9:0],3'b111}),.addrb({address[9:0],3'b111}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(config_clk),.clkb(clk),.wea(we&&write_address[10]==1'b1),.web(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(b1_lane1));
endmodule
