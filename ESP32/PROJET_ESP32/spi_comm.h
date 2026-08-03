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
// de reponse des le decodage (drapeau r_preload), ~5 cycles a 12 MHz apres
// le dernier front MONTANT de l'octet de commande. SPI_Slave fige l'octet
// suivant au dernier front DESCENDANT du meme octet. A 1 MHz ces deux
// instants ne sont separes que de ~80-170 ns : la course changeait de
// vainqueur d'un bitstream a l'autre (apres un simple re-routage, logits
// decales d'un rang, 23/24 divergents avec le dernier juste par accident).
//
// A SPI_HZ_READ = 250 kHz la fenetre passe a 2 us : le prechargement gagne
// toujours, les donnees commencent a l'indice 1 sur n'importe quel build.
#define MISO_DATA_OFFSET  1

// Ecritures (image, start) : MISO inutilise, aucune course -> pleine vitesse.
// Lectures (logits, status) : ralenties pour fixer la course, cf. ci-dessus.
// Cout : 26 octets a 250 kHz = 0.8 ms par lecture, negligeable a 1 Hz.
#define SPI_HZ_WRITE  1000000
#define SPI_HZ_READ    250000

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