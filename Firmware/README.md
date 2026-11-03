# Schreibtisch-Sensor (ESP32-S3 + Waveshare HMMD mmWave + VEML7700)

ESPHome-Firmware für den optionalen Sensor von ScreenDim. Er meldet Anwesenheit am
Schreibtisch und das Umgebungslicht in Lux; die App schaltet bei Abwesenheit die
Bildschirme schwarz und regelt die Helligkeit nach dem Licht.

## Stückliste

| Teil | Genau | Hinweis |
|------|-------|---------|
| Mikrocontroller | [ESP32-S3-DevKitC-1](https://www.espressif.com/en/products/devkits/esp32-s3-devkitc-1), Variante N8R8 (8 MB Flash, 8 MB PSRAM) | Nachbauten mit demselben Pinout gehen auch (getestet mit 8 MB Flash, 8 MB PSRAM, natives USB). Die Firmware setzt `flash_size: 8MB`; bei 16 MB den Wert in `screendim-desk.yaml` anpassen. |
| Radar (Anwesenheit) | [Waveshare HMMD mmWave Sensor](https://www.waveshare.com/hmmd-mmwave-sensor.htm) (24 GHz, 20 × 20 mm) | Erkennt Mikrobewegungen (Atmen, Tippen), nicht nur Gehen. Pinbelegung im [Wiki](https://www.waveshare.com/wiki/HMMD_mmWave_Sensor). |
| Lichtsensor | VEML7700-Modul (Vishay VEML7700 auf Breakout mit Spannungsregler und Pegelwandler, „Vin/logic 3–5 V“, Pins VIN, 3Vo, GND, SCL, SDA) | I2C-Adresse 0x10, Messbereich bis 120 000 lx. Verbreitetes Layout (Adafruit 4162 und Nachbauten); ein Modul ohne Regler (nur 3,3 V) geht genauso. |
| Verbindung | 9 Dupont-Kabel Buchse–Buchse, 10 cm | Oder direkt löten; beide Module kommen mit Stiftleiste. |
| Strom | USB-C-Kabel an den Port „USB“ des Boards | Zum Flashen am Mac, danach an jedem USB-Netzteil. |

Beide Module sind optional: Ohne Radar meldet der Sensor „anwesend“, ohne VEML7700
fehlt nur das Licht (ESPHome markiert den Sensor beim Start als ausgefallen, der Rest
läuft).

## Schaltplan

![Verdrahtung: ESP32-S3-DevKitC-1 mit Waveshare HMMD mmWave Sensor (fünf Leitungen) und VEML7700 (vier Leitungen)](schaltplan.svg)

| HMMD (J2) | ESP32-S3 | Zweck |
|-----------|----------|-------|
| 1 · 3V3 | 3V3 | Versorgung (3,0–3,6 V, **nicht 5 V**) |
| 2 · GND | GND | Masse |
| 3 · TX | GPIO18 (RX) | UART 115200, vorerst nur mitgelesen |
| 4 · RX | GPIO17 (TX) | UART, für spätere Einstellungen |
| 5 · OT2 | GPIO4 | Anwesenheit: HIGH = anwesend |

| VEML7700 | ESP32-S3 | Zweck |
|----------|----------|-------|
| VIN | 3V3 | Versorgung über den Regler des Moduls (3–5 V) |
| GND | GND | Masse |
| SCL | GPIO9 | I2C-Takt |
| SDA | GPIO8 | I2C-Daten, Adresse 0x10 |
| 3Vo | – | Ausgang des Reglers, bleibt frei |

Das DevKitC-1 hat zwei 3V3-Pins und mehrere GND-Pins, es reicht also für beide Module
ohne Steckplatine. Die Pull-up-Widerstände für I2C sitzen auf dem Modul.

Die Pins stehen oben in `screendim-desk.yaml` unter `substitutions`. Ohne angeschlossenes
Radar zieht ein Pull-up GPIO4 auf HIGH: Der Sensor meldet „anwesend“, die Bildschirme
bleiben an.

Die RGB-LED sitzt bei den meisten DevKitC-1-Nachbauten an GPIO48, beim DevKitC-1 v1.1 an
GPIO38 (`led_pin`). Der BOOT-Taster (GPIO0) dient der Kopplung, siehe unten.

Aufstellung: Das Radar mit der Antennenseite (ohne Bauteile) zum Sitzplatz, nicht hinter
Metall. Auf dem Schreibtisch neben dem Monitor reicht; ein Gehäuse aus Kunststoff stört
das Radar nicht. Der VEML7700 soll das Licht sehen, das auch auf den Schreibtisch fällt:
Sensorfenster nach oben, nicht direkt auf den Monitor gerichtet und nicht hinter dem
Monitor; ein Gehäuse braucht an dieser Stelle eine Öffnung.

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
  Zeit holt die App den Code ohne Login (`GET /text_sensor/Pairing Code`); alles andere
  (Weboberfläche, OTA, Zustände) bleibt hinter dem Login.
- **BOOT 10 s halten:** neuer Code, die LED blinkt rot. Die App meldet „Kopplung verloren“;
  danach öffnet sich das Kopplungsfenster von selbst.
- Außerhalb des Fensters verlangt der Webserver Digest-Login: Nutzer `screendim`, Passwort
  der Code ohne Bindestrich.

## Was die App erwartet

Feste Angaben in `ScreenDimKit/Sources/ScreenDimKit/Sensor/SensorEvent.swift`
(`SensorProtocol`):

- mDNS `_screendim._tcp`, TXT `proto=esphome-sse` und `fw=<Version>`
- `GET /events`: SSE mit `state` (`binary_sensor/Presence`, `sensor/Ambient Light`) und
  `ping` alle 10 s
- `GET /binary_sensor/Presence`, `GET /sensor/Ambient Light`,
  `GET /text_sensor/Pairing Code`
- Lux kommt bei 3 % Änderung, sonst alle 30 s: Nach 45 s ohne Ereignis gilt der Sensor
  in der App als ausgefallen, und die Lichtregelung stoppt.

## Offen

- UART-Format des HMMD auslesen (die Firmware loggt die Rohdaten) und daraus Entfernung
  und Einstellungen (Abfallverzögerung, Reichweite) machen.
- VEML7700 am Gerät prüfen: Lux im Log und unter `GET /sensor/Ambient Light`, Heartbeat
  alle 30 s im SSE-Strom. Die Konfiguration ist bisher nur mit `esphome config` geprüft.
