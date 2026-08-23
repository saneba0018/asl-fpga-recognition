#ifndef CAMERA_PREPROCESS_H
#define CAMERA_PREPROCESS_H

#include <Arduino.h>
#include "esp_camera.h"
#include "board_config.h"

#define OUT_W 28
#define OUT_H 28

void setupCamera();

// Capture + reduction en 28x28. raw recoit une copie de la trame brute avant
// reduction (pour la page de debug) et peut etre NULL. Si la trame depasse
// rawCap, elle n'est pas recopiee et *rawW / *rawH sont mis a 0, mais le
// 28x28 est produit quand meme.
bool captureAndPreprocessEx(uint8_t *out, uint8_t *raw, size_t rawCap,
                            int *rawW, int *rawH);

// Choix de la reduction : crop carre centre (fidele au dataset, qui est fait
// de vignettes carrees, defaut) ou ecrasement du cadre entier (deforme le
// rapport d'aspect). Commutable a chaud depuis la page de debug.
void setPreprocessCrop(bool useCrop);
bool getPreprocessCrop();

// Orientation du capteur (miroir horizontal / flip vertical), commutable a
// chaud depuis la page de debug. L'ASL est chirale : valider une fois que le
// 28x28 a la meme orientation que le dataset (L main droite = pouce a gauche).
void setSensorOrientation(bool hmirror, bool vflip);
bool getSensorHMirror();
bool getSensorVFlip();

// Reduction par moyenne de bloc (box filter) : contrairement au plus proche
// voisin qui jette ~17 pixels sur 18, chaque pixel source pese dans la
// moyenne. Preserve les details fins (pouce des lettres poing A/E/M/N/S/T).
void setPreprocessBox(bool useBox);
bool getPreprocessBox();

// Etirement min-max du 28x28 apres reduction : enleve l'eclairage comme
// variable. N'activer que si le modele a ete entraine avec (voir
// training_script.py).
void setContrastStretch(bool enable);
bool getContrastStretch();

void resizeNearestNeighbor(camera_fb_t *fb, uint8_t *out);
void cropCenterAndResize(camera_fb_t *fb, uint8_t *out);
void cropCenterAndResizeBox(camera_fb_t *fb, uint8_t *out);
void contrastStretch(uint8_t *img);

#endif