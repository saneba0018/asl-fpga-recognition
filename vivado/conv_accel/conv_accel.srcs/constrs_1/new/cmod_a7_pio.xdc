##-----------------------------------------------------------------------------
## cmod_a7_pio.xdc - Cmod A7-35T, top-level memory_streamer
##
## Tout le lien vers l'ESP32-S3 passe par le connecteur DIP (pio), broches 1 a
## 5, physiquement contigues sur un seul bord de la carte : un nappe de 5 fils
## suffit. Le connecteur Pmod JA n'est plus utilise.
##
## POURQUOI CE PLACEMENT PLUTOT QUE LE PMOD
## SCK est une VRAIE horloge pour le design : SPI_Slave echantillonne sur
## posedge/negedge de i_SPI_Clk. Elle doit donc atteindre un BUFG. Sur le Pmod,
## JA1 (G17) n'est pas clock-capable : il fallait forcer
##     set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets spi_sck_IBUF]
## et faire passer l'horloge par du routage generique. Ici SCK est sur A16
## (IO_L12P_T1_MRCC_16), broche clock-capable : le routage dedie fonctionne et
## cette contrainte de contournement DISPARAIT.
##
## CE QUI PLAFONNE MAINTENANT LE DEBIT SPI
## Ce n'est plus la broche mais la course de prechargement du decodeur, qui
## impose R = f_clk / f_spi >= 10 (viser 30). Avec le MMCM a 50 MHz cela borne
## le SPI vers 1,7 MHz. Voir l'en-tete de mem_streamer.v. Autrement dit :
## changer ces broches ne permet PAS a lui seul de monter a 4 ou 8 MHz.
##
## Broches relevees sur le master XDC Digilent du Cmod A7-35T.
##-----------------------------------------------------------------------------

## Configuration electrique
set_property CFGBVS VCCO        [current_design];
set_property CONFIG_VOLTAGE 3.3 [current_design];

## Horloge systeme : oscillateur 12 MHz integre.
## N'alimente que le MMCM clk_wiz_0 ; toute la logique tourne a 50 MHz.
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { sysclk }];

##-----------------------------------------------------------------------------
## SPI vers ESP32-S3, connecteur DIP pio[01..04]
##-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN M3  IOSTANDARD LVCMOS33 } [get_ports { spi_mosi }]; ;# pio[01] IO_L8N_T1_AD14N_35
set_property -dict { PACKAGE_PIN L3  IOSTANDARD LVCMOS33 } [get_ports { spi_miso }]; ;# pio[02] IO_L8P_T1_AD14P_35
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 } [get_ports { spi_sck  }]; ;# pio[03] IO_L12P_T1_MRCC_16 <- clock-capable
set_property -dict { PACKAGE_PIN K3  IOSTANDARD LVCMOS33 } [get_ports { spi_cs_n }]; ;# pio[04] IO_L7N_T1_AD6N_35

## Ligne READY dediee vers l'ESP32 (GPIO43 cote XIAO).
## Evite d'interroger le FPGA par GET_STATUS pendant l'inference.
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports { o_ready }]; ;# pio[05] IO_L11P_T1_SRCC_16

## LED RGB de diagnostic
##   rouge = busy, vert = battement de coeur ET o_ready, bleu = MMCM verrouille
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { led   }]; ;# Sch=led0_r
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports { led_g }]; ;# Sch=led0_g
set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS33 } [get_ports { led_b }]; ;# Sch=led0_b

## Pull-ups internes, en remplacement de resistances externes
##   spi_miso : mis en trois-etats des que CS est relache
##   spi_cs_n : flottant pendant le demarrage de l'ESP32
set_property PULLTYPE PULLUP [get_ports spi_miso];
set_property PULLTYPE PULLUP [get_ports spi_cs_n];

##-----------------------------------------------------------------------------
## Horloge SPI
##
## 1 MHz, asynchrone au domaine systeme. Aucun CLOCK_DEDICATED_ROUTE n'est
## necessaire : A16 est clock-capable.
##
## -include_generated_clocks est indispensable depuis l'ajout du MMCM : sans
## lui le groupe ne couvre que l'entree 12 MHz, et les chemins vers le domaine
## 50 MHz issu de clk_wiz_0 seraient analyses comme synchrones du SPI.
##-----------------------------------------------------------------------------
create_clock -name spi_sck_pin -period 1000.00 [get_ports { spi_sck }];

set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_pin] \
    -group [get_clocks spi_sck_pin]
