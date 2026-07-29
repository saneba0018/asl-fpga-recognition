#ifndef CAMERA_PREPROCESS_H
#define CAMERA_PREPROCESS_H

#include <Arduino.h>
#include "esp_camera.h"
#include "board_config.h"

#define OUT_W 28
#define OUT_H 28

void setupCamera();
bool captureAndPreprocess(uint8_t *out);

void resizeNearestNeighbor(camera_fb_t *fb, uint8_t *out);
void cropCenterAndResize(camera_fb_t *fb, uint8_t *out);

void printAsciiImage(uint8_t *img);
void printImageStats(uint8_t *img);
void printPGMImage(uint8_t *img);

#endif