#include "camera_preprocess.h"

bool printPGM = false;

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

void printAsciiImage(uint8_t *img) {
  const char levels[] = " .:-=+*#%@";

  Serial.println("Image 28x28 ASCII:");

  for (int y = 0; y < OUT_H; y++) {
    for (int x = 0; x < OUT_W; x++) {
      uint8_t pixel = img[y * OUT_W + x];
      int index = map(pixel, 0, 255, 0, 9);
      Serial.print(levels[index]);
    }
    Serial.println();
  }
}

void printPGMImage(uint8_t *img) {
  Serial.println("PGM_START");
  Serial.println("P2");
  Serial.println("28 28");
  Serial.println("255");

  for (int y = 0; y < OUT_H; y++) {
    for (int x = 0; x < OUT_W; x++) {
      Serial.print(img[y * OUT_W + x]);
      Serial.print(" ");
    }
    Serial.println();
  }

  Serial.println("PGM_END");
}

void printImageStats(uint8_t *img) {
  uint8_t minVal = 255;
  uint8_t maxVal = 0;
  long sumVal = 0;

  for (int i = 0; i < OUT_W * OUT_H; i++) {
    if (img[i] < minVal) minVal = img[i];
    if (img[i] > maxVal) maxVal = img[i];
    sumVal += img[i];
  }

  Serial.print("Min pixel: ");
  Serial.println(minVal);

  Serial.print("Max pixel: ");
  Serial.println(maxVal);

  Serial.print("Moyenne pixel: ");
  Serial.println(sumVal / (OUT_W * OUT_H));
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

  config.fb_location = CAMERA_FB_IN_DRAM;
  config.fb_count = 1;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.jpeg_quality = 12;

  esp_err_t err = esp_camera_init(&config);

  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x\n", err);

    while (true) {
      delay(1000);
    }
  }

  sensor_t *s = esp_camera_sensor_get();

  if (s != NULL && s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);
    s->set_brightness(s, 1);
    s->set_saturation(s, -2);
  }

  Serial.println("Camera init OK");
}

bool captureAndPreprocess(uint8_t *out) {
  camera_fb_t *fb = esp_camera_fb_get();

  if (!fb) {
    return false;
  }

  Serial.println("----------------------------");

  Serial.print("Image originale largeur: ");
  Serial.println(fb->width);

  Serial.print("Image originale hauteur: ");
  Serial.println(fb->height);

  Serial.print("Taille buffer: ");
  Serial.println(fb->len);

  resizeNearestNeighbor(fb, out);

  // Si tu veux crop au centre au lieu de resize toute l'image :
  // cropCenterAndResize(fb, out);

  esp_camera_fb_return(fb);

  Serial.println("Image finale: 28x28");

  Serial.print("Nombre de pixels envoyables FPGA: ");
  Serial.println(OUT_W * OUT_H);

  if (printPGM) {
    printPGMImage(out);
  }

  return true;
}