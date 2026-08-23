#ifndef SPI_COMM_H
#define SPI_COMM_H

#include <Arduino.h>
#include <SPI.h>

#define PIN_SCK    7
#define PIN_MOSI   9
#define PIN_MISO   8
#define PIN_CS     4
#define PIN_READY  43

#define FPGA_IMG_SIZE   784
#define FPGA_NUM_CLASS  24

#define CMD_LOAD_WEIGHTS  0x01
#define CMD_SEND_IMAGE    0x02
#define CMD_START_CONV    0x03
#define CMD_READ_RESULT   0x04
#define CMD_GET_STATUS    0x05

#define FPGA_STATUS_BUSY  0x80
#define FPGA_STATUS_DONE  0x40

// Trame de lecture : [CMD][donnees...]
//
// L'octet 0 transporte la commande. Le decodeur precharge le premier octet
// de reponse des le decodage (drapeau r_preload), quelques cycles clk apres
// le dernier front MONTANT de l'octet de commande. SPI_Slave fige l'octet
// suivant (r_TX_Shift <= r_TX_Byte) au dernier front DESCENDANT du meme
// octet. Qui gagne cette course decide de l'alignement des donnees, et donc
// de la valeur de cette constante :
//
//   prechargement gagne -> result[0] sur l'octet 1  -> OFFSET 1  (ce build)
//   prechargement perd  -> result[0] sur l'octet 2  -> OFFSET 2
//
// Ce n'est pas le cablage qui tranche, mais le rapport R = f_clk / f_spi,
// ou f_clk est l'horloge INTERNE du FPGA. Seuil mesure par balayage en
// simulation (scripts de tb_race) : R <= 7 donne l'offset 2, R = 8 ne donne
// AUCUN alignement valide, R >= 10 donne l'offset 1.
//
//   12 MHz / 1 MHz   R = 12   1,3x le seuil -> marginal. C'est l'historique :
//                             la course changeait de vainqueur d'un bitstream
//                             a l'autre, logits decales d'un rang, 23/24
//                             divergents. D'ou le bridage a 250 kHz (R = 48).
//   50 MHz / 1 MHz   R = 50   5,6x le seuil -> lectures pleine vitesse.
//
// mem_streamer.v porte desormais l'horloge interne a 50 MHz par MMCM, ce qui
// rend l'offset 1 stable et permet de lire aussi vite qu'on ecrit.
#define MISO_DATA_OFFSET  1

// Une seule vitesse dans les deux sens.
//
// DEUX CONDITIONS AVANT DE MONTER PLUS HAUT :
//   1. Garder R = f_clk / f_spi >= 30. A 50 MHz cela plafonne vers 1,7 MHz.
//      Accelerer le SPI sans accelerer le MMCM ramene la course marginale.
//   2. SCK est sur JA1 (G17), qui n'est pas une broche clock-capable : le
//      .xdc doit y forcer CLOCK_DEDICATED_ROUTE FALSE et seul 1 MHz est
//      valide sur ce routage generique. Au-dela, recabler SCK sur A16.
//
// ATTENTION : si le bitstream est synthetise avec NO_MMCM (horloge interne
// laissee a 12 MHz), il FAUT ramener SPI_HZ_READ a 250000 -- sinon R tombe
// a 12 et les logits reviennent decales d'un rang.
#define SPI_HZ_WRITE  500000
#define SPI_HZ_READ   250000

extern const char FPGA_LETTERS[FPGA_NUM_CLASS + 1];

void setupSPI();

uint8_t fpgaGetStatus();
bool fpgaIsReady();

void fpgaQuantize(const uint8_t *src, uint8_t *dst, size_t n);

bool fpgaSendImage(const uint8_t *img);
bool fpgaStart();
bool fpgaWaitDone(unsigned long timeoutMs);
bool fpgaReadLogits(int8_t *logits);

bool fpgaInfer(const uint8_t *img, int *idx, int *margin);

// Meme chose, mais recopie aussi les 24 logits bruts. logitsOut peut etre NULL.
bool fpgaInferEx(const uint8_t *img, int *idx, int *margin, int8_t *logitsOut);

#endif