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
#include "esphome/components/web_server_idf/web_server_idf.h"

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

// Kopplungsfenster offen: Nur der Code ist ohne Login abrufbar.
inline bool pairing_open = false;

inline void set_pairing_open(bool open) { pairing_open = open; }

// Beantwortet im Kopplungsfenster `GET /text_sensor/Pairing Code` ohne Login, wie es der
// ESPHome-Webserver mit Login täte. Alles andere (Weboberfläche, OTA, Zustände, Ereignisse)
// bleibt immer hinter dem Digest-Login; früher fiel im Fenster das Passwort ganz weg.
class PairingCodeHandler : public esphome::web_server_idf::AsyncWebHandler {
 public:
  bool canHandle(esphome::web_server_idf::AsyncWebServerRequest *request) const override {
    if (!pairing_open || request->method() != HTTP_GET)
      return false;
    char url[esphome::web_server_idf::AsyncWebServerRequest::URL_BUF_SIZE];
    return request->url_to(url) == "/text_sensor/Pairing Code";
  }

  void handleRequest(esphome::web_server_idf::AsyncWebServerRequest *request) override {
    std::string code = std::string(code_raw, 4) + "-" + std::string(code_raw + 4, 4);
    std::string json = "{\"id\":\"text_sensor-pairing_code\",\"value\":\"" + code + "\",\"state\":\"" + code + "\"}";
    request->send(200, "application/json", json.c_str());
  }
};

// Einmal beim Start, vor dem Webserver (on_boot 600, Webserver 249): Passwort = Code (der
// Webserver hält nur den Zeiger, ein neuer Code gilt sofort), Handler fürs Kopplungsfenster
// vor den Handlern des Webservers.
inline void setup_web_auth() {
  auto *base = esphome::web_server_base::global_web_server_base;
  if (base == nullptr)
    return;
  base->set_auth_password(code_raw);
  base->add_handler_without_auth(new PairingCodeHandler());
}

}  // namespace screendim
