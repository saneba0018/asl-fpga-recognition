#include <Arduino.h>
#include "camera_preprocess.h"
#include "spi_comm.h"

uint8_t image_28x28[FPGA_IMG_SIZE];
uint8_t image_quantized[FPGA_IMG_SIZE];

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("Starting ESP32 camera + FPGA SPI system...");

  setupCamera();
  setupSPI();

  Serial.println("System ready");
}

void loop() {
  unsigned long startTime = millis();

  bool ok = captureAndPreprocess(image_28x28);

  if (!ok) {
    Serial.println("Erreur: capture image impossible");
    delay(1000);
    return;
  }

  printImageStats(image_28x28);
  printAsciiImage(image_28x28);

  // Conversion uint8 caméra vers format int8 compatible FPGA
  fpgaQuantize(image_28x28, image_quantized, FPGA_IMG_SIZE);

  Serial.println("Premiers pixels envoyes apres quantization:");
  for (int i = 0; i < FPGA_NUM_CLASS; i++) {
    Serial.print((uint8_t)image_quantized[i]);
    Serial.print(" ");
  }
  Serial.println();

  Serial.print("Status FPGA avant envoi: ");
  Serial.println(fpgaGetStatus());

  bool sent = fpgaSendImage(image_quantized);

  Serial.print("Image envoyee au FPGA: ");
  Serial.println(sent ? "OK" : "ERREUR");

  Serial.print("Status FPGA apres envoi: ");
  Serial.println(fpgaGetStatus());

  int8_t echo[FPGA_NUM_CLASS];

  bool readOk = fpgaReadLogits(echo);

  Serial.print("READ_RESULT: ");
  Serial.println(readOk ? "OK" : "ERREUR");

  Serial.println("Comparaison premiers pixels envoyes / recus FPGA:");

  int errors = 0;

  for (int i = 0; i < FPGA_NUM_CLASS; i++) {
    uint8_t sentPixel = image_quantized[i];
    uint8_t receivedPixel = (uint8_t)echo[i];

    Serial.print("i=");
    Serial.print(i);

    Serial.print(" envoye=");
    Serial.print(sentPixel);

    Serial.print(" recu=");
    Serial.print(receivedPixel);

    if (receivedPixel == sentPixel) {
      Serial.println(" OK");
    } else {
      Serial.println(" ERREUR");
      errors++;
    }
  }

  if (errors == 0) {
    Serial.println("RESULTAT: TRANSFERT IMAGE FPGA OK");
  } else {
    Serial.print("RESULTAT: ERREURS TRANSFERT = ");
    Serial.println(errors);
  }

  unsigned long elapsed = millis() - startTime;

  Serial.print("Temps total ms: ");
  Serial.println(elapsed);

  Serial.print("FPS approx: ");
  if (elapsed > 0) {
    Serial.println(1000.0 / elapsed);
  } else {
    Serial.println("inf");
  }

  Serial.println("====================================");
  delay(1000);
}