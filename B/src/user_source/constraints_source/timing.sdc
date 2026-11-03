create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
create_generated_clock -name board_spi_out -master_clock clk -source [get_ports {clk}] -divide_by 6 [get_ports {board_sclk}]
create_generated_clock -name flash_spi_out -master_clock clk -source [get_ports {clk}] -divide_by 8 [get_ports {flash_sclk}]
create_generated_clock -name tf_spi_out -master_clock clk -source [get_ports {clk}] -divide_by 4 [get_ports {tf_sclk}]
# Explicit input25ns/output10ns SPI envelope; not a measured board result.
set_input_delay -clock [get_clocks {board_spi_out}] -clock_fall -max 25 [get_ports {board_miso}]
set_input_delay -clock [get_clocks {board_spi_out}] -clock_fall -min 0 [get_ports {board_miso}]
set_output_delay -clock [get_clocks {board_spi_out}] -max 10 [get_ports {board_mosi board_cs_n}]
set_output_delay -clock [get_clocks {board_spi_out}] -min 0 [get_ports {board_mosi board_cs_n}]
set_input_delay -clock [get_clocks {flash_spi_out}] -clock_fall -max 25 [get_ports {flash_miso}]
set_input_delay -clock [get_clocks {flash_spi_out}] -clock_fall -min 0 [get_ports {flash_miso}]
set_output_delay -clock [get_clocks {flash_spi_out}] -max 10 [get_ports {flash_mosi flash_cs_n}]
set_output_delay -clock [get_clocks {flash_spi_out}] -min 0 [get_ports {flash_mosi flash_cs_n}]
set_input_delay -clock [get_clocks {tf_spi_out}] -clock_fall -max 25 [get_ports {tf_miso}]
set_input_delay -clock [get_clocks {tf_spi_out}] -clock_fall -min 0 [get_ports {tf_miso}]
set_output_delay -clock [get_clocks {tf_spi_out}] -max 10 [get_ports {tf_mosi tf_cs_n}]
set_output_delay -clock [get_clocks {tf_spi_out}] -min 0 [get_ports {tf_mosi tf_cs_n}]
set_multicycle_path -setup -end -from [get_ports {board_miso}] 3
set_multicycle_path -hold -end -from [get_ports {board_miso}] 2
set_multicycle_path -setup -end -from [get_ports {flash_miso}] 4
set_multicycle_path -hold -end -from [get_ports {flash_miso}] 3
set_multicycle_path -setup -end -from [get_ports {tf_miso}] 2
set_multicycle_path -hold -end -from [get_ports {tf_miso}] 1
set_multicycle_path -hold -start -to [get_ports {board_mosi board_cs_n}] 3
set_multicycle_path -hold -start -to [get_ports {flash_mosi flash_cs_n}] 4
set_multicycle_path -hold -start -to [get_ports {tf_mosi tf_cs_n}] 2
