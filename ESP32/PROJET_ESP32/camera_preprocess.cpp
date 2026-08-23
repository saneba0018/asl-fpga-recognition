#include "camera_preprocess.h"

// Crop carre centre par defaut : fidele au dataset (vignettes carrees).
// Le mode plein cadre ecrase 160x120 en 28x28 et deforme la main de 25%.
static bool useCropMode = true;

// Moyenne de bloc et etirement de contraste : doivent refleter le
// pretraitement du modele deploye (cf. training_script.py). Mesure sur le
// jeu hors-dataset : le plus proche voisin detruit le detail du pouce qui
// distingue les lettres poing (A/E/M/N/S/T).
static bool useBoxFilter = false;
static bool useContrast = false;

// Orientation du capteur, ajustable a chaud depuis la page de debug.
// L'ASL est chirale : une trame miroir ou inversee envoie chaque lettre
// sur une autre avec une grande confiance. A valider une fois avec un L
// de la main droite : pouce vers la gauche de l'image, index vers le haut.
static bool useHMirror = true;
static bool useVFlip = false;

void resizeNearestNeighbor(camera_fb_t *fb, uint8_t *out) {
  int srcW = fb->width;
  int srcH = fb->height;

  for (int y = 0; y < OUT_H; y++) {
    int srcY = (y * srcH) / OUT_H;

    for (int x = 0; x < OUT_W; x++) {
      int srcX = (x * srcW) / OUT_W;
      out[y * OUT_W + x] = fb->buf[srcY * srcW + srcX];
    }
  }
}

void cropCenterAndResize(camera_fb_t *fb, uint8_t *out) {
  int srcW = fb->width;
  int srcH = fb->height;

  int cropSize = (srcW < srcH) ? srcW : srcH;
  int cropX = (srcW - cropSize) / 2;
  int cropY = (srcH - cropSize) / 2;

  for (int y = 0; y < OUT_H; y++) {
    int srcY = cropY + (y * cropSize) / OUT_H;

    for (int x = 0; x < OUT_W; x++) {
      int srcX = cropX + (x * cropSize) / OUT_W;
      out[y * OUT_W + x] = fb->buf[srcY * srcW + srcX];
    }
  }
}

// Crop carre centre + moyenne de bloc. Les bornes de bloc sont les memes
// divisions entieres que le plus proche voisin : les blocs pavent le crop
// exactement, aucun pixel jete. Arrondi au plus proche ((sum + n/2) / n).
// Cout : ~1 addition par pixel du crop (14k a QQVGA), negligeable.
// Le script d'entrainement doit appliquer la meme reduction (training_script.py).
void cropCenterAndResizeBox(camera_fb_t *fb, uint8_t *out) {
  int srcW = fb->width;
  int srcH = fb->height;

  int cropSize = (srcW < srcH) ? srcW : srcH;
  int cropX = (srcW - cropSize) / 2;
  int cropY = (srcH - cropSize) / 2;

  for (int y = 0; y < OUT_H; y++) {
    int y0 = cropY + (y * cropSize) / OUT_H;
    int y1 = cropY + ((y + 1) * cropSize) / OUT_H;

    for (int x = 0; x < OUT_W; x++) {
      int x0 = cropX + (x * cropSize) / OUT_W;
      int x1 = cropX + ((x + 1) * cropSize) / OUT_W;

      uint32_t sum = 0;

      for (int sy = y0; sy < y1; sy++) {
        const uint8_t *row = fb->buf + sy * srcW;

        for (int sx = x0; sx < x1; sx++) {
          sum += row[sx];
        }
      }

      uint32_t n = (uint32_t)(y1 - y0) * (uint32_t)(x1 - x0);
      out[y * OUT_W + x] = (uint8_t)((sum + n / 2) / n);
    }
  }
}

// Etirement min-max en place : p' = (p - min) * 255 / (max - min), arrondi
// au plus proche. Ne fait rien sur une image uniforme.
// Le script d'entrainement doit appliquer le meme etirement (training_script.py).
void contrastStretch(uint8_t *img) {
  uint8_t lo = 255;
  uint8_t hi = 0;

  for (int i = 0; i < OUT_W * OUT_H; i++) {
    if (img[i] < lo) lo = img[i];
    if (img[i] > hi) hi = img[i];
  }

  if (hi <= lo) {
    return;
  }

  int span = hi - lo;

  for (int i = 0; i < OUT_W * OUT_H; i++) {
    img[i] = (uint8_t)(((img[i] - lo) * 255 + span / 2) / span);
  }
}

void setupCamera() {
  camera_config_t config = {};

  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;

  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;

  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;

  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;

  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;

  config.xclk_freq_hz = 20000000;

  config.pixel_format = PIXFORMAT_GRAYSCALE;
  config.frame_size = FRAMESIZE_QQVGA;

  // GRAB_LATEST + 2 tampons : fb_get rend la trame la plus recente sans
  // bloquer (2 x 19200 octets en DRAM a QQVGA gris). Avec un seul tampon il
  // fallait jeter une trame et re-attendre, un blocage de plus par cycle.
  config.fb_location = CAMERA_FB_IN_DRAM;
  config.fb_count = 2;
  config.grab_mode = CAMERA_GRAB_LATEST;
  config.jpeg_quality = 12;

  esp_err_t err = esp_camera_init(&config);

  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x\n", err);

    while (true) {
      delay(1000);
    }
  }

  sensor_t *s = esp_camera_sensor_get();

  if (s != NULL) {
    // Le XIAO ESP32S3 Sense a un OV2640 : l'ancien bloc gate sur OV3660_PID
    // ne s'executait jamais. L'orientation s'applique a tout capteur.
    s->set_hmirror(s, useHMirror ? 1 : 0);
    s->set_vflip(s, useVFlip ? 1 : 0);

    if (s->id.PID == OV3660_PID) {
      s->set_brightness(s, 1);
      s->set_saturation(s, -2);
    }
  }

  // Laisser converger l'auto-exposition avant la premiere inference
  for (int i = 0; i < 6; i++) {
    camera_fb_t *warm = esp_camera_fb_get();

    if (warm != NULL) {
      esp_camera_fb_return(warm);
    }

    delay(30);
  }

  Serial.println("Camera init OK");
}

void setPreprocessCrop(bool useCrop) {
  useCropMode = useCrop;
}

bool getPreprocessCrop() {
  return useCropMode;
}

void setPreprocessBox(bool useBox) {
  useBoxFilter = useBox;
}

bool getPreprocessBox() {
  return useBoxFilter;
}

void setContrastStretch(bool enable) {
  useContrast = enable;
}

bool getContrastStretch() {
  return useContrast;
}

void setSensorOrientation(bool hmirror, bool vflip) {
  useHMirror = hmirror;
  useVFlip = vflip;

  sensor_t *s = esp_camera_sensor_get();

  if (s != NULL) {
    s->set_hmirror(s, hmirror ? 1 : 0);
    s->set_vflip(s, vflip ? 1 : 0);
  }
}

bool getSensorHMirror() {
  return useHMirror;
}

bool getSensorVFlip() {
  return useVFlip;
}

bool captureAndPreprocessEx(uint8_t *out, uint8_t *raw, size_t rawCap,
                            int *rawW, int *rawH) {
  // GRAB_LATEST : la trame rendue est la plus recente, pas besoin d'en
  // jeter une d'abord.
  camera_fb_t *fb = esp_camera_fb_get();

  if (!fb) {
    return false;
  }

  if (rawW != NULL) {
    *rawW = 0;
  }

  if (rawH != NULL) {
    *rawH = 0;
  }

  // Recopie de la trame brute avant reduction, pour la page de debug
  if (raw != NULL && fb->len <= rawCap) {
    memcpy(raw, fb->buf, fb->len);

    if (rawW != NULL) {
      *rawW = fb->width;
    }

    if (rawH != NULL) {
      *rawH = fb->height;
    }
  }

  if (useCropMode && useBoxFilter) {
    cropCenterAndResizeBox(fb, out);
  } else if (useCropMode) {
    cropCenterAndResize(fb, out);
  } else {
    resizeNearestNeighbor(fb, out);
  }

  if (useContrast) {
    contrastStretch(out);
  }

  esp_camera_fb_return(fb);

  return true;
}