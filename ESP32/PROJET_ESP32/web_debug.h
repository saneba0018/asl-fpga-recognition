// web_debug.h - page web de diagnostic : affiche cote a cote la trame brute
// de la camera, le 28x28 envoye au FPGA et le resultat d'inference. Par
// defaut l'ESP cree son propre point d'acces (WEB_DEBUG_AP_SSID,
// http://192.168.4.1) ; mettre WEB_DEBUG_AP_MODE a 0 pour rejoindre un
// reseau existant via WIFI_SSID/WIFI_PASS.

#ifndef WEB_DEBUG_H
#define WEB_DEBUG_H

#include <Arduino.h>

#define WEB_DEBUG_AP_MODE  1
#define WEB_DEBUG_AP_SSID  "asl-fpga-debug"
#define WEB_DEBUG_AP_PASS  "aslfpga2026"   // WPA2 : 8 caracteres minimum

#define WIFI_SSID  ""
#define WIFI_PASS  ""

// Capacite du tampon de trame brute. QQVGA en niveaux de gris = 19200 octets.
// Une trame plus grande n'est pas recopiee, le 28x28 reste correct.
#define WEB_RAW_CAPACITY  (160 * 120)

void webDebugBegin();
void webDebugHandle();

// Publie la derniere trame brute et le 28x28 correspondant. Les deux sont
// recopies, l'appelant peut reutiliser ses tampons ensuite.
void webDebugSetFrames(const uint8_t *raw, int rawW, int rawH,
                       const uint8_t *proc);

// Publie le resultat agrege sur la derniere fenetre d'accumulation : somme
// des logits (24 canaux) sur nFrames images, argmax idx et sa marge.
void webDebugSetWindowResult(const int32_t *logitSum, int nFrames, int idx,
                             int32_t margin);

#endif
