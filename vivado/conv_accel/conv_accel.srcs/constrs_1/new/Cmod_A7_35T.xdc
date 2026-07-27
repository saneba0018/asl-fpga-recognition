## Configuration electrique
set_property CFGBVS VCCO        [current_design];
set_property CONFIG_VOLTAGE 3.3 [current_design];

## Horloge systeme 12 MHz
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { sysclk }];

## SPI vers ESP32-S3
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 } [get_ports { spi_sck }];   ;# pio[03] IO_L12P_T1_MRCC_16
set_property -dict { PACKAGE_PIN M3  IOSTANDARD LVCMOS33 } [get_ports { spi_mosi }];  ;# pio[01]
set_property -dict { PACKAGE_PIN L3  IOSTANDARD LVCMOS33 } [get_ports { spi_miso }];  ;# pio[02]
set_property -dict { PACKAGE_PIN K3  IOSTANDARD LVCMOS33 } [get_ports { spi_cs_n }];  ;# pio[04]

## Ligne READY dediee vers ESP32 (JA10 -> D6/GPIO43 ou D5/GPIO6)
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { o_ready }];

## LED RGB de diagnostic
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { led }];    ;# Sch=led0_r
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports { led_g }];  ;# Sch=led0_g
set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS33 } [get_ports { led_b }];  ;# Sch=led0_b

## Pull-ups internes - remplacent les resistances externes
##   spi_miso : trois-etats quand CS est relache
##   spi_cs_n : flottant pendant le demarrage de l'ESP32
set_property PULLTYPE PULLUP [get_ports spi_miso];
set_property PULLTYPE PULLUP [get_ports spi_cs_n];

## SPI SCK : horloge externe 1 MHz, asynchrone au domaine systeme
create_clock -name spi_sck_pin -period 1000.00 [get_ports { spi_sck }];
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_pin] \
    -group [get_clocks spi_sck_pin]