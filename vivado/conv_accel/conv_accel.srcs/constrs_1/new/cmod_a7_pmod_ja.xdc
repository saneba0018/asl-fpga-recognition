##-----------------------------------------------------------------------------
## cmod_a7_pmod_ja.xdc - Cmod A7-35T, top-level memory_streamer
##
## Cablage de secours sur le Pmod JA, valide manuellement le 2026-08-21 : le
## meme RTL echouait (busy bloque, logits garbage) sur le connecteur DIP
## (cmod_a7_pio.xdc) et fonctionnait de nouveau une fois recable ici. La cause
## est donc physique (probablement la ligne o_ready du DIP, seul signal SPI
## sans pull-up dans cmod_a7_pio.xdc), pas le RTL -- voir mem_streamer.v et
## spi_cmd_decoder.v, inchanges entre les deux tests.
##
## SCK est sur JA1 (G17), qui n'est PAS clock-capable : routage dedie
## impossible, d'ou CLOCK_DEDICATED_ROUTE FALSE ci-dessous. Acceptable a
## 250 kHz (SPI_HZ_READ dans spi_comm.h), mais plafonne toute tentative
## d'accelerer le SPI plus tard -- le DIP (A16, clock-capable) reste la
## cible a long terme une fois la ligne o_ready reparee cote materiel.
##-----------------------------------------------------------------------------

## Configuration electrique
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## Horloge systeme : oscillateur 12 MHz integre. N'alimente que le MMCM
## clk_wiz_0 (voir l'en-tete de mem_streamer.v) ; toute la logique tourne sur
## son clk_out1 a 50 MHz.
##
## PAS de create_clock ici sur le port sysclk : clk_wiz_0 (IP Clocking
## Wizard, mode frequence -- pas "Board") attache deja tout seul une horloge
## racine nommee "sysclk" sur ce port via ses propres contraintes embarquees,
## avec clk_out1_clk_wiz_0/clkfbout_clk_wiz_0 comme descendance. En rajouter
## une deuxieme ici (meme avec create_clock -add) cree une lignee generee
## fantome en parallele (vu en pratique : clk_out1_clk_wiz_0_1, 19.999 ns au
## lieu de 20.000 ns) que set_clock_groups doit alors couvrir en plus de la
## vraie -- et Vivado la traite comme une horloge "reliee mais sans racine
## commune" avec la vraie, ce qui produit un faux chemin de timing entre les
## deux (constate via report_timing : "MET" avec un chiffre qui ne veut rien
## dire, entre deux noms pour le meme fil). Un seul create_clock, celui de
## l'IP, suffit et evite tout ca.
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports sysclk]

##-----------------------------------------------------------------------------
## SPI vers ESP32-S3, connecteur Pmod JA
##-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports spi_sck]
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports spi_mosi]
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports spi_miso]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports spi_cs_n]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports o_ready]

## LED RGB de diagnostic
##   rouge = busy, vert = battement de coeur ET o_ready, bleu = MMCM verrouille
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports led]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports led_g]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports led_b]

## Pull-ups internes, en remplacement de resistances externes
##   spi_miso : mis en trois-etats des que CS est relache
##   spi_cs_n : flottant pendant le demarrage de l'ESP32
set_property PULLTYPE PULLUP [get_ports spi_miso]
set_property PULLTYPE PULLUP [get_ports spi_cs_n]

##-----------------------------------------------------------------------------
## SPI SCK sur broche non clock-capable
## JA1 (G17) n'est pas CCIO : le routage dedie vers le BUFG est impossible,
## d'ou le passage par le routage generique. Acceptable a 250 kHz.
##-----------------------------------------------------------------------------
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets spi_sck_IBUF]

## Periode = le plus rapide des deux sens (SPI_HZ_WRITE=500 kHz dans
## spi_comm.h ; les lectures sont plus lentes, 250 kHz).
create_clock -period 2000.000 -name spi_sck_pin [get_ports spi_sck]

## spi_sck_pin est la seule horloge reellement independante du design (aucune
## relation de phase avec sysclk/clk_out1_clk_wiz_0 : deux oscillateurs
## distincts, l'un sur l'ESP32, l'autre sur le Cmod). Grouper par exclusion
## ("tout sauf spi_sck_pin") plutot que par inclusion nommee couvre toute la
## descendance de clk_wiz_0 sans avoir a la nommer -- utile si l'IP change de
## configuration ou de nom d'instance plus tard.
set_clock_groups -asynchronous -group [get_clocks -filter {NAME != spi_sck_pin}] -group [get_clocks spi_sck_pin]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
