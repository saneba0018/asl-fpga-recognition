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

#define MISO_DATA_OFFSET  1

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

#endif