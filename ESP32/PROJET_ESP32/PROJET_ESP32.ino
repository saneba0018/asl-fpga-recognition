//-----------------------------------------------------------------------------
// PROJET_ESP32.ino - capture camera, inference sur FPGA, affichage de la lettre
//
// Au demarrage, un auto-test envoie une image de reference (golden_image.h)
// et compare les 24 logits recus a ceux du modele TFLite. S'ils sont
// identiques, toute la
// chaine est prouvee sans dependre de la camera : SPI, decodeur, ROM de poids,
// accelerateur. Un echec ici rend inutile tout diagnostic cote camera.
//
// Une page de debug (web_debug.h) montre la trame camera et le 28x28 envoye
// au FPGA. Par defaut l'ESP cree son propre point d'acces : se connecter au
// reseau "asl-fpga-debug" puis ouvrir http://192.168.4.1
//
// La boucle est non bloquante : le serveur web est servi en continu, une
// inference est lancee toutes les FRAME_INTERVAL_MS.
//-----------------------------------------------------------------------------

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

// Duree minimale d'affichage d'une lettre. L'inference tourne toujours a
// FRAME_INTERVAL_MS pour la page de debug, mais l'ecran ne change pas plus
// vite que ceci pour rester lisible.
#define OLED_HOLD_MS  3000

// Apercu ASCII sur le port serie. Redondant avec la page de debug, garde a 0
// sauf si le WiFi n'est pas disponible.
#define SHOW_ASCII  0

// Periode entre deux inferences. L'inference elle-meme prend ~209 ms.
#define FRAME_INTERVAL_MS  1000

// Toutes les N trames : etat du tas sur le port serie. Un "libre" qui
// descend a chaque ligne = fuite memoire; stable puis gel = pilote bloque.
#define HEAP_REPORT_FRAMES  10

uint8_t image_28x28[FPGA_IMG_SIZE];
uint8_t image_quantized[FPGA_IMG_SIZE];

static uint8_t raw_frame[WEB_RAW_CAPACITY];
static unsigned long lastFrame = 0;

//-----------------------------------------------------------------------------
// Ecran OLED 2x16
//-----------------------------------------------------------------------------

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

//-----------------------------------------------------------------------------
// Auto-test : image de reference -> logits attendus
//-----------------------------------------------------------------------------
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

//-----------------------------------------------------------------------------
// Une capture + une inference
//-----------------------------------------------------------------------------
static void runOneFrame() {
  int rawW = 0;
  int rawH = 0;

  if (!captureAndPreprocessEx(image_28x28, raw_frame, sizeof(raw_frame),
                              &rawW, &rawH)) {
    Serial.println("Erreur: capture image impossible");
    return;
  }

  // Publier l'image avant l'inference : meme si le FPGA ne repond pas, la
  // page de debug montre ce que la camera a vu.
  webDebugSetFrames(raw_frame, rawW, rawH, image_28x28);

#if SHOW_ASCII
  printImageStats(image_28x28);
  printAsciiImage(image_28x28);
#endif

  // uint8 camera -> int8 attendu par le modele (scale 1/255, zero-point -128)
  fpgaQuantize(image_28x28, image_quantized, FPGA_IMG_SIZE);

  int idx = 0;
  int margin = 0;
  int8_t logits[FPGA_NUM_CLASS];

  if (!fpgaInferEx(image_quantized, &idx, &margin, logits)) {
    Serial.println("Erreur: inference echouee");
    webDebugSetResult(NULL, 0, 0, false);
    return;
  }

  webDebugSetResult(logits, idx, margin, true);

  Serial.print("Lettre: ");
  Serial.print(FPGA_LETTERS[idx]);
  Serial.print("   marge: ");
  Serial.println(margin);

  oledShowLetter(FPGA_LETTERS[idx], margin);

  static uint32_t frameNum = 0;

  if (++frameNum % HEAP_REPORT_FRAMES == 0) {
    Serial.printf("Tas: libre %u, plus bas %u, plus gros bloc %u\n",
                  (unsigned)ESP.getFreeHeap(),
                  (unsigned)ESP.getMinFreeHeap(),
                  (unsigned)ESP.getMaxAllocHeap());
  }

  // La marge est un ecart de logits int8, pas une probabilite. Une marge
  // faible signale une hesitation entre deux lettres, souvent un cadrage
  // ou un eclairage qui s'ecarte du dataset.
  if (margin < 10) {
    Serial.println("Marge faible, prediction peu fiable");
  }
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

  Serial.println("System ready");
}

void loop() {
  // Servi en continu : la page reste reactive entre deux inferences
  webDebugHandle();

  if (millis() - lastFrame >= FRAME_INTERVAL_MS) {
    lastFrame = millis();
    runOneFrame();
  }
}
