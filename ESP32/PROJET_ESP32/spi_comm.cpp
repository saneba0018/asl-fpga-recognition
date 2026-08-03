#include "spi_comm.h"

const char FPGA_LETTERS[FPGA_NUM_CLASS + 1] = "ABCDEFGHIKLMNOPQRSTUVWXY";

static uint8_t txBuffer[900];
static uint8_t rxBuffer[900];

void setupSPI() {
  pinMode(PIN_CS, OUTPUT);
  digitalWrite(PIN_CS, HIGH);

  pinMode(PIN_READY, INPUT);

  SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI, PIN_CS);

  Serial.println("SPI init OK");
}

uint8_t spiTransferCommandWithResponse(uint8_t cmd) {
  memset(txBuffer, 0, sizeof(txBuffer));
  memset(rxBuffer, 0, sizeof(rxBuffer));

  txBuffer[0] = cmd;

  SPI.beginTransaction(SPISettings(SPI_HZ_READ, MSBFIRST, SPI_MODE0));

  digitalWrite(PIN_CS, LOW);

  for (int i = 0; i < 1 + MISO_DATA_OFFSET; i++) {
    rxBuffer[i] = SPI.transfer(txBuffer[i]);
  }

  digitalWrite(PIN_CS, HIGH);

  SPI.endTransaction();

  return rxBuffer[MISO_DATA_OFFSET];
}

uint8_t fpgaGetStatus() {
  return spiTransferCommandWithResponse(CMD_GET_STATUS);
}

bool fpgaIsReady() {
  return digitalRead(PIN_READY) == HIGH;
}

void fpgaQuantize(const uint8_t *src, uint8_t *dst, size_t n) {
  for (size_t i = 0; i < n; i++) {
    dst[i] = src[i] ^ 0x80;
  }
}

bool fpgaSendImage(const uint8_t *img) {
  memset(txBuffer, 0, sizeof(txBuffer));

  txBuffer[0] = CMD_SEND_IMAGE;

  for (int i = 0; i < FPGA_IMG_SIZE; i++) {
    txBuffer[i + 1] = img[i];
  }

  SPI.beginTransaction(SPISettings(SPI_HZ_WRITE, MSBFIRST, SPI_MODE0));

  digitalWrite(PIN_CS, LOW);

  for (int i = 0; i < 1 + FPGA_IMG_SIZE; i++) {
    SPI.transfer(txBuffer[i]);
  }

  digitalWrite(PIN_CS, HIGH);

  SPI.endTransaction();

  return true;
}

bool fpgaStart() {
  SPI.beginTransaction(SPISettings(SPI_HZ_WRITE, MSBFIRST, SPI_MODE0));

  digitalWrite(PIN_CS, LOW);

  SPI.transfer(CMD_START_CONV);

  digitalWrite(PIN_CS, HIGH);

  SPI.endTransaction();

  return true;
}

bool fpgaWaitDone(unsigned long timeoutMs) {
  unsigned long start = millis();

  // Laisser busy monter avant de le sonder. START_CONV est decode pendant la
  // trame SPI, mais o_ready ne retombe qu'ensuite : tester la GPIO tout de
  // suite ferait conclure que l'inference est finie avant qu'elle commence.
  while (fpgaIsReady() && (millis() - start) < 5) {
    // attente active, quelques microsecondes en pratique
  }

  while (millis() - start < timeoutMs) {
    if (fpgaIsReady()) {
      return true;
    }

    // Repli si PIN_READY n'est pas cable : GET_STATUS reste accepte
    // pendant busy, et done_latch n'est mis qu'a la fin de l'inference.
    uint8_t status = fpgaGetStatus();

    if (status & FPGA_STATUS_DONE) {
      return true;
    }

    delay(1);
  }

  return false;
}

bool fpgaReadLogits(int8_t *logits) {
  memset(txBuffer, 0, sizeof(txBuffer));
  memset(rxBuffer, 0, sizeof(rxBuffer));

  txBuffer[0] = CMD_READ_RESULT;

  SPI.beginTransaction(SPISettings(SPI_HZ_READ, MSBFIRST, SPI_MODE0));

  digitalWrite(PIN_CS, LOW);

  for (int i = 0; i < FPGA_NUM_CLASS + MISO_DATA_OFFSET; i++) {
    rxBuffer[i] = SPI.transfer(txBuffer[i]);
  }

  digitalWrite(PIN_CS, HIGH);

  SPI.endTransaction();

  for (int i = 0; i < FPGA_NUM_CLASS; i++) {
    logits[i] = (int8_t)rxBuffer[i + MISO_DATA_OFFSET];
  }

  return true;
}

bool fpgaInfer(const uint8_t *img, int *idx, int *margin) {
  return fpgaInferEx(img, idx, margin, NULL);
}

bool fpgaInferEx(const uint8_t *img, int *idx, int *margin, int8_t *logitsOut) {
  if (idx == NULL) {
    return false;
  }

  int8_t logits[FPGA_NUM_CLASS];

  // Le decodeur ignore SEND_IMAGE, START_CONV et READ_RESULT pendant busy.
  // Sans cette garde, l'image serait silencieusement jetee et le FPGA
  // renverrait les logits de l'inference precedente.
  if (!fpgaIsReady()) {
    Serial.println("Erreur: FPGA occupe, inference ignoree");
    return false;
  }

  fpgaSendImage(img);
  fpgaStart();

  if (!fpgaWaitDone(1000)) {
    Serial.println("Erreur: timeout FPGA");
    return false;
  }

  fpgaReadLogits(logits);

  if (logitsOut != NULL) {
    memcpy(logitsOut, logits, FPGA_NUM_CLASS);
  }

  int best = 0;
  int second = 1;

  for (int i = 1; i < FPGA_NUM_CLASS; i++) {
    if (logits[i] > logits[best]) {
      best = i;
    }
  }

  if (margin != NULL) {
    second = (best == 0) ? 1 : 0;

    for (int i = 0; i < FPGA_NUM_CLASS; i++) {
      if (i != best && logits[i] > logits[second]) {
        second = i;
      }
    }

    *margin = logits[best] - logits[second];
  }

  *idx = best;

  return true;
}