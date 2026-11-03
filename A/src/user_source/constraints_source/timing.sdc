# Independent A root: 50MHz input and retained PLL clocks.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {data_plane/sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {data_plane/video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {data_plane/video_pll_m0/pll_inst.clkc[1]}]
# Production B uses HALF_CYCLES=3 at 50MHz. Minimum adjacent complete
# SPI bit spacing is 2*3*20ns=120ns; byte preparation adds slower gaps.
# An 80ns clock described the earlier divider and is no longer the paired root.
create_clock -name board_spi -period 120 -waveform {0 60} [get_ports {board_sclk}]
# Inherited short-wire budget. This is an explicit design envelope, not a
# measurement of external board wires or final IO/CDC timing acceptance.
set_input_delay -clock [get_clocks {board_spi}] -clock_fall -max 10 [get_ports {board_mosi}]
set_input_delay -clock [get_clocks {board_spi}] -clock_fall -min 0 [get_ports {board_mosi}]
set_output_delay -clock [get_clocks {board_spi}] -max 10 [get_ports {board_miso}]
set_output_delay -clock [get_clocks {board_spi}] -min 0 [get_ports {board_miso}]
# Each actual CDC first stage and remaining external IO require a separate
# path/ownership audit. No blanket clock groups or clock-wide false paths.

# Actual A user NOR: control25 / (2*FLASH_DIV=8), MISO sample every DIV=4.
# Input25ns/output10ns are explicit wire+device envelopes, not measurements.
create_generated_clock -name user_flash_spi_out -master_clock video_clk -source [get_pins {data_plane/video_pll_m0/pll_inst.clkc[0]}] -divide_by 8 [get_ports {user_flash_sclk}]
set_input_delay -clock [get_clocks {user_flash_spi_out}] -clock_fall -max 25 [get_ports {user_flash_miso}]
set_input_delay -clock [get_clocks {user_flash_spi_out}] -clock_fall -min 0 [get_ports {user_flash_miso}]
set_output_delay -clock [get_clocks {user_flash_spi_out}] -max 10 [get_ports {user_flash_mosi user_flash_cs_n}]
set_output_delay -clock [get_clocks {user_flash_spi_out}] -min 0 [get_ports {user_flash_mosi user_flash_cs_n}]
set_multicycle_path -setup -end -from [get_ports {user_flash_miso}] 4
set_multicycle_path -hold -end -from [get_ports {user_flash_miso}] 3
set_multicycle_path -hold -start -to [get_ports {user_flash_mosi user_flash_cs_n}] 4
# B's first SCLK sample follows CS assertion by preparation + HALF_CYCLES.
set_input_delay -clock [get_clocks {board_spi}] -clock_fall -max 10 [get_ports {board_cs_n}]
set_input_delay -clock [get_clocks {board_spi}] -clock_fall -min 0 [get_ports {board_cs_n}]
