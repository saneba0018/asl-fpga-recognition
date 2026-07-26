##-----------------------------------------------------------------------------
## top_mock.xdc - Cmod A7-35T
## Broches reprises du gabarit Digilent, uniquement celles deja presentes dans
## votre Cmod_A7_35T.xdc (aucune position inventee).
##-----------------------------------------------------------------------------

##-----------------------------------------------------------------------------
## Horloge systeme 12 MHz
##-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { sysclk }];

##-----------------------------------------------------------------------------
## Interface SPI vers l'ESP32-S3
##
## spi_sck sur A16 : broche MRCC (clock-capable). Le coeur Nandland utilise SCK
## directement comme horloge, donc cette broche DOIT etre clock-capable, sinon
## Vivado emet un warning critique et le routage de l'horloge est mediocre.
##-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 } [get_ports { spi_sck }];   ;# pio[03] IO_L12P_T1_MRCC_16
set_property -dict { PACKAGE_PIN M3  IOSTANDARD LVCMOS33 } [get_ports { spi_mosi }];  ;# pio[01]
set_property -dict { PACKAGE_PIN L3  IOSTANDARD LVCMOS33 } [get_ports { spi_miso }];  ;# pio[02]
set_property -dict { PACKAGE_PIN K3  IOSTANDARD LVCMOS33 } [get_ports { spi_cs_n }];  ;# pio[04]

##-----------------------------------------------------------------------------
## Ligne READY dediee vers l'ESP32
##-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports { o_ready }];   ;# pio[05]

##-----------------------------------------------------------------------------
## LED RGB de diagnostic
##   led   (rouge) : allume pendant busy
##   led_g (vert)  : battement de coeur ~1,4 Hz
##   led_b (bleu)  : inutilise
##-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports { led }];    ;# Sch=led0_r
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports { led_g }];  ;# Sch=led0_g
set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS33 } [get_ports { led_b }];  ;# Sch=led0_b

##-----------------------------------------------------------------------------
## Pull-ups internes - remplacent les resistances externes
##-----------------------------------------------------------------------------

## MISO est mis en haute impedance quand CS est haut (assign o_SPI_MISO =
## i_SPI_CS_n ? 1'bZ : ...). Sans pull-up, la ligne flotte entre les
## transactions et l'ESP32 peut lire du bruit.
set_property PULLTYPE PULLUP [get_ports spi_miso];

## CS_n flotte tant que l'ESP32 n'a pas configure ses GPIO (demarrage, reset).
## Sans pull-up il peut descendre et le decodeur interprete du bruit comme des
## commandes. Symptome typique : fonctionne, puis repond n'importe quoi apres
## un reset de l'ESP32.
set_property PULLTYPE PULLUP [get_ports spi_cs_n];

##-----------------------------------------------------------------------------
## Contraintes temporelles
##-----------------------------------------------------------------------------

## Declarer SCK comme une horloge de 1 MHz (periode 1000 ns).
## Sans cela Vivado n'analyse pas les chemins du domaine SPI.
create_clock -name spi_sck_pin -period 1000.00 [get_ports { spi_sck }];

## Les deux horloges sont asynchrones : ne pas analyser les chemins croises.
## Sans cette ligne, un mur d'erreurs de timing sans objet.
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_pin] \
    -group [get_clocks spi_sck_pin]
