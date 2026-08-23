// PROJET_ESP32.ino - capture camera, inference sur FPGA, affichage de la
// lettre. Au demarrage, un auto-test compare les logits d'une image de
// reference (golden_image.h) a ceux du modele TFLite pour prouver la chaine
// SPI/FPGA sans dependre de la camera. Page de debug sur "asl-fpga-debug" /
// http://192.168.4.1. La boucle est non bloquante.

#include <Arduino.h>
#include <NHD_US2066.h>
#include "camera_preprocess.h"
#include "spi_comm.h"
#include "web_debug.h"
#include "golden_image.h"

// Ecran OLED NHD-0216AW-IB3 (controleur US2066, interface I2C).
// SA0 est tenu bas par l'ESP32 -> adresse esclave 0x3C.
#define PIN_OLED_SA0  D0
#define PIN_OLED_SCL  D1
#define PIN_OLED_SDA  D2
#define PIN_OLED_RES  D4

// Glass "AW" (slim) : config SEG 0x00. Mettre 0x10 pour un modele "CW".
#define OLED_SEG_CONFIG  0x00

// Duree minimale d'affichage d'une lettre a l'ecran (voir oledShowLetter).
#define OLED_HOLD_MS  3000

// Fenetre d'accumulation : les logits de toutes les inferences qui tiennent
// dans cette duree sont sommes canal par canal, et la lettre retenue est
// l'argmax de la somme plutot que celui d'une seule image. Plus robuste
// qu'une inference isolee face au bruit d'une frame (flou, cadrage).
#define WINDOW_MS  1000

uint8_t image_28x28[FPGA_IMG_SIZE];
uint8_t image_quantized[FPGA_IMG_SIZE];

static uint8_t raw_frame[WEB_RAW_CAPACITY];

static int32_t windowLogitSum[FPGA_NUM_CLASS];
static int      windowFrames = 0;
static unsigned long windowStart = 0;

// Ecran OLED 2x16

// Ecrit une ligne complete : 16 caracteres, completee avec des espaces pour
// effacer l'ancien contenu sans passer par un clear (0x01) qui fait clignoter.
static void oledWriteLine(uint8_t line, const char *text) {
  command(line == 0 ? 0x80 : 0xA0);

  for (int i = 0; i < 16; i++) {
    data(*text ? (unsigned char)*text++ : ' ');
  }
}

// Affiche la lettre detectee. Une lettre reste au moins OLED_HOLD_MS a
// l'ecran, et une lettre identique n'est jamais reecrite : pas de spam.
static void oledShowLetter(char letter, int margin) {
  static char shown = '\0';
  static unsigned long shownSince = 0;

  if (letter == shown) {
    return;
  }

  if (shown != '\0' && millis() - shownSince < OLED_HOLD_MS) {
    return;
  }

  char line1[17];
  char line2[17];

  snprintf(line1, sizeof(line1), "Lettre: %c", letter);
  snprintf(line2, sizeof(line2), "Marge:  %d", margin);

  oledWriteLine(0, line1);
  oledWriteLine(1, line2);

  shown = letter;
  shownSince = millis();
}

// Auto-test : image de reference -> logits attendus
static bool fpgaSelfTest() {
  int8_t logits[FPGA_NUM_CLASS];

  Serial.println("Auto-test FPGA avec l'image de reference...");

  if (!fpgaIsReady()) {
    Serial.println("  ECHEC: FPGA occupe ou PIN_READY mal cable");
    return false;
  }

  // GOLDEN_IMAGE est deja quantifiee : pas de fpgaQuantize ici
  fpgaSendImage(GOLDEN_IMAGE);
  fpgaStart();

  if (!fpgaWaitDone(1000)) {
    Serial.println("  ECHEC: timeout, aucune fin d'inference");
    return false;
  }

  fpgaReadLogits(logits);

  int errors = 0;
  int best = 0;

  for (int i = 0; i < FPGA_NUM_CLASS; i++) {
    if (logits[i] != GOLDEN_LOGITS[i]) {
      errors++;

      if (errors <= 4) {
        Serial.print("  logit[");
        Serial.print(i);
        Serial.print("] attendu ");
        Serial.print(GOLDEN_LOGITS[i]);
        Serial.print(" recu ");
        Serial.println(logits[i]);
      }
    }

    if (logits[i] > logits[best]) {
      best = i;
    }
  }

  if (errors == 0) {
    Serial.print("  OK: 24 logits identiques au modele, lettre ");
    Serial.println(FPGA_LETTERS[best]);
    return true;
  }

  Serial.print("  ECHEC: ");
  Serial.print(errors);
  Serial.println(" / 24 logits divergent");

  // Un decalage d'un rang est la signature d'un MISO_DATA_OFFSET errone
  if (logits[0] == GOLDEN_LOGITS[1]) {
    Serial.println("  indice: les logits semblent decales d'un rang");
  }

  return false;
}

// Une capture + une inference, accumulee dans windowLogitSum (pas de
// resultat ni d'affichage par frame : voir finishWindow).
static void runOneFrame() {
  int rawW = 0;
  int rawH = 0;

  if (!captureAndPreprocessEx(image_28x28, raw_frame, sizeof(raw_frame),
                              &rawW, &rawH)) {
    Serial.println("Erreur: capture image impossible");
    return;
  }

  // Publier l'image tout de suite : meme si le FPGA ne repond pas, la page
  // de debug montre ce que la camera a vu.
  webDebugSetFrames(raw_frame, rawW, rawH, image_28x28);

  // uint8 camera -> int8 attendu par le modele (scale 1/255, zero-point -128)
  fpgaQuantize(image_28x28, image_quantized, FPGA_IMG_SIZE);

  int idx = 0;
  int margin = 0;
  int8_t logits[FPGA_NUM_CLASS];

  if (!fpgaInferEx(image_quantized, &idx, &margin, logits)) {
    Serial.println("Erreur: inference echouee");
    return;
  }

  for (int i = 0; i < FPGA_NUM_CLASS; i++) {
    windowLogitSum[i] += logits[i];
  }
  windowFrames++;
}

// Cloture la fenetre d'accumulation : argmax de la somme des logits sur
// toutes les frames vues depuis windowStart, affichage OLED + page de debug,
// puis remise a zero pour la fenetre suivante.
static void finishWindow() {
  if (windowFrames == 0) {
    windowStart = millis();
    return;
  }

  int best = 0;
  int second = 0;

  for (int i = 1; i < FPGA_NUM_CLASS; i++) {
    if (windowLogitSum[i] > windowLogitSum[best]) {
      second = best;
      best = i;
    } else if (i != best && windowLogitSum[i] > windowLogitSum[second]) {
      second = i;
    }
  }

  int32_t margin = windowLogitSum[best] - windowLogitSum[second];

  Serial.print("Lettre (");
  Serial.print(windowFrames);
  Serial.print(" frames): ");
  Serial.print(FPGA_LETTERS[best]);
  Serial.print("   marge: ");
  Serial.println(margin);

  oledShowLetter(FPGA_LETTERS[best], margin);
  webDebugSetWindowResult(windowLogitSum, windowFrames, best, margin);

  // Marge moyenne par frame, meme seuil qu'avant le passage a la somme.
  if (margin / windowFrames < 10) {
    Serial.println("Marge faible, prediction peu fiable");
  }

  memset(windowLogitSum, 0, sizeof(windowLogitSum));
  windowFrames = 0;
  windowStart = millis();
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("Starting ESP32 camera + FPGA SPI system...");

  // Ecran OLED : reset materiel, SA0 bas (adresse 0x3C), init US2066
  init_oled_i2c(PIN_OLED_SDA, PIN_OLED_SCL, PIN_OLED_RES, PIN_OLED_SA0,
                OLED_SEG_CONFIG);
  oledWriteLine(0, "ASL sur FPGA");
  oledWriteLine(1, "demarrage...");

  setupCamera();
  setupSPI();
  webDebugBegin();

  oledWriteLine(1, fpgaSelfTest() ? "auto-test OK" : "auto-test ECHEC");

  windowStart = millis();

  Serial.println("System ready");
}

void loop() {
  // Servi en continu : la page reste reactive pendant l'accumulation
  webDebugHandle();

  runOneFrame();

  if (millis() - windowStart >= WINDOW_MS) {
    finishWindow();
  }
}
