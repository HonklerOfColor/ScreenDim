// Kopplungscode des ScreenDim-Sensors.
//
// Acht Zeichen Crockford-Base32 (0-9A-HJKMNP-TV-Z, ohne I, L, O, U), angezeigt als
// ABCD-EFGH. Der Code ist das Digest-Passwort für den Nutzer `screendim` und entspricht
// `PairingCode` in ScreenDimKit. Gespeichert wird er als 40-Bit-Zahl (globals, NVS).
#pragma once

#include <cstdint>
#include <string>

#include "bootloader_random.h"
#include "esp_random.h"
#include "esphome/components/web_server_base/web_server_base.h"

namespace screendim {

static constexpr char kAlphabet[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
static constexpr uint64_t kCodeMask = (1ULL << 40) - 1;

// Digest-Passwort ohne Bindestrich. Der Webserver hält nur den Zeiger.
inline char code_raw[9] = {};

// Neuer Code aus echtem Zufall. Vor dem WLAN-Start ist der Hardware-Zufall nur mit der
// Bootloader-Entropiequelle echt; danach liefert das Funkrauschen. Beides nicht gleichzeitig.
inline uint64_t new_code_bits(bool before_radio) {
  if (before_radio)
    bootloader_random_enable();
  uint64_t bits = 0;
  while (bits == 0) {
    esp_fill_random(&bits, sizeof(bits));
    bits &= kCodeMask;
  }
  if (before_radio)
    bootloader_random_disable();
  return bits;
}

// Schreibt `code_raw` und gibt den Code als ABCD-EFGH zurück.
inline std::string encode(uint64_t bits) {
  for (int i = 0; i < 8; i++)
    code_raw[i] = kAlphabet[(bits >> (35 - 5 * i)) & 0x1F];
  code_raw[8] = '\0';
  return std::string(code_raw, 4) + "-" + std::string(code_raw + 4, 4);
}

// Kopplungsfenster: ohne Passwort lässt der Webserver jede Anfrage durch. Sonst Digest mit
// dem Code.
inline void set_pairing_open(bool open) {
  auto *base = esphome::web_server_base::global_web_server_base;
  if (base != nullptr)
    base->set_auth_password(open ? nullptr : code_raw);
}

}  // namespace screendim
