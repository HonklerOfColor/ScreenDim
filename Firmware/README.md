# Schreibtisch-Sensor (ESP32-S3 + Waveshare HMMD mmWave)

ESPHome-Firmware für den optionalen Sensor von ScreenDim. Er meldet Anwesenheit am
Schreibtisch; die App schaltet bei Abwesenheit die Bildschirme schwarz. Ein Lichtsensor
(`sensor/Ambient Light`) kommt später dazu.

## Teile

- ESP32-S3-Board (getestet: ESP32-S3 mit 8 MB Flash, 8 MB PSRAM, natives USB)
- Waveshare HMMD mmWave Sensor (24 GHz, S3KM1110), 3,3 V

## Verdrahtung

| HMMD | ESP32-S3 | Zweck |
|------|----------|-------|
| 3V3  | 3V3      | Versorgung (3,0–3,6 V, **nicht 5 V**) |
| GND  | GND      | |
| OT2 (GPIO OUT) | GPIO4 | Anwesenheit: HIGH = anwesend |
| TX   | GPIO18 (RX) | UART 115200, vorerst nur mitgelesen |
| RX   | GPIO17 (TX) | UART, für spätere Einstellungen |

Die Pins stehen oben in `screendim-desk.yaml` unter `substitutions`. Ohne angeschlossenes
Radar zieht ein Pull-up GPIO4 auf HIGH: Der Sensor meldet „anwesend“, die Bildschirme
bleiben an.

Die RGB-LED sitzt bei den meisten DevKitC-1-Nachbauten an GPIO48, beim DevKitC-1 v1.1 an
GPIO38 (`led_pin`).

## Bauen und flashen

ESPHome 2026.10 oder neuer. Den Build-Ordner außerhalb von iCloud halten:

```bash
uv venv --python 3.12 ~/.venvs/esphome && VIRTUAL_ENV=~/.venvs/esphome uv pip install esphome
```

```bash
cd Firmware && ESPHOME_DATA_DIR=/tmp/screendim-esphome ~/.venvs/esphome/bin/esphome run screendim-desk.yaml --device /dev/cu.usbmodem*
```

Nur die Logs über USB:

```bash
cd Firmware && ESPHOME_DATA_DIR=/tmp/screendim-esphome ~/.venvs/esphome/bin/esphome logs screendim-desk.yaml --device /dev/cu.usbmodem*
```

Spätere Updates gehen auch über die Weboberfläche des Sensors (Login `screendim`, Passwort
= Kopplungscode).

## WLAN einrichten

Ohne gespeichertes WLAN öffnet der Sensor den Zugangspunkt `screendim-desk-xxxxxx`. Mit dem
Mac oder iPhone verbinden, im Captive Portal das WLAN wählen. Alternativ über USB mit
Chrome auf <https://web.esphome.io> („Connect“ → „Configure Wi-Fi“, Improv).

## Kopplung

- Beim ersten Start erzeugt der Sensor einen Kopplungscode (8 Zeichen, `ABCD-EFGH`) und
  speichert ihn.
- **BOOT kurz drücken:** Kopplungsfenster für 2 Minuten, die LED pulsiert blau. In dieser
  Zeit holt die App den Code ohne Login (`GET /text_sensor/Pairing Code`).
- **BOOT 10 s halten:** neuer Code, die LED blinkt rot. Die App meldet „Kopplung verloren“;
  danach öffnet sich das Kopplungsfenster von selbst.
- Außerhalb des Fensters verlangt der Webserver Digest-Login: Nutzer `screendim`, Passwort
  der Code ohne Bindestrich.

## Was die App erwartet

Feste Angaben in `ScreenDimKit/Sources/ScreenDimKit/Sensor/SensorEvent.swift`
(`SensorProtocol`):

- mDNS `_screendim._tcp`, TXT `proto=esphome-sse` und `fw=<Version>`
- `GET /events`: SSE mit `state` (`binary_sensor/Presence`) und `ping` alle 10 s
- `GET /binary_sensor/Presence`, `GET /text_sensor/Pairing Code`

## Offen

- UART-Format des HMMD auslesen (die Firmware loggt die Rohdaten) und daraus Entfernung
  und Einstellungen (Abfallverzögerung, Reichweite) machen.
- Lichtsensor `sensor/Ambient Light`: Lux bei 3 % Änderung, sonst alle 30 s.
