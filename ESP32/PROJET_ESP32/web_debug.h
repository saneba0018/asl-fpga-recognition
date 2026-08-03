//-----------------------------------------------------------------------------
// web_debug.h - page web de diagnostic du pretraitement camera
//
// Sert une page qui affiche cote a cote la trame brute de la camera et le
// 28x28 reellement envoye au FPGA, plus le resultat de l'inference. Sert a
// repondre a la question qui bloque le plus souvent une chaine de vision :
// est-ce le modele qui se trompe, ou l'image qui n'a rien a voir avec celles
// du dataset ?
//
// Par defaut l'ESP cree son propre point d'acces, donc aucun routeur ni
// identifiant n'est necessaire. Connecte-toi au reseau WEB_DEBUG_AP_SSID puis
// ouvre http://192.168.4.1
//
// Pour rejoindre un reseau existant a la place, mettre WEB_DEBUG_AP_MODE a 0
// et renseigner WIFI_SSID / WIFI_PASS. L'adresse obtenue est affichee sur le
// port serie au demarrage.
//-----------------------------------------------------------------------------

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

// Publie le dernier resultat d'inference. valid a false affiche "aucun".
void webDebugSetResult(const int8_t *logits, int idx, int margin, bool valid);

#endif
