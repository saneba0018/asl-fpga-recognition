##-----------------------------------------------------------------------------
## top_mock.xdc - Cmod A7-35T
## Tous les signaux SPI sur le connecteur Pmod JA
##-----------------------------------------------------------------------------

set_property CFGBVS VCCO        [current_design];
set_property CONFIG_VOLTAGE 3.3 [current_design];

## Horloge systeme 12 MHz
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { sysclk }];

## SPI - Pmod JA
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports { spi_sck }];   ;# JA1
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports { spi_mosi }];  ;# JA2
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports { spi_miso }];  ;# JA3
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports { spi_cs_n }];  ;# JA4
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { o_ready }];   ;# JA10

## LED RGB
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { led }];
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports { led_g }];
set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS33 } [get_ports { led_b }];

## Pull-ups internes
set_property PULLTYPE PULLUP [get_ports spi_miso];
set_property PULLTYPE PULLUP [get_ports spi_cs_n];

## SPI SCK sur broche non clock-capable
## JA1 (G17) n'est pas une broche CCIO. Le routage dedie vers le BUFG est
## impossible, d'ou le passage par le routage generique. Acceptable a 1 MHz.
## Pour monter en frequence, ramener SCK sur A16 (IO_L12P_T1_MRCC_16).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets spi_sck_IBUF];

create_clock -name spi_sck_pin -period 1000.00 [get_ports { spi_sck }];
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_pin] \
    -group [get_clocks spi_sck_pin]