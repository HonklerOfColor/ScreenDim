# Eingebauter Lichtsensor als Lichtquelle

Stand: 2026-10-29, Prototyp, nur „ScreenDim Direct“.

## Ergebnis

Der Umgebungslichtsensor (ALS) eines MacBooks lässt sich auf Apple Silicon ohne Sandbox
und mit Hardened Runtime ohne Entitlement lesen, ereignisgesteuert im Takt von 1 s. Er
ersetzt den ESP32-Sensor als Lichtquelle; Anwesenheit liefert er nicht. In der
App-Store-Variante geht das nicht (private API).

Geprüft auf einem MacBook Air M4 (Mac16,13), macOS 27, mit einem eigenen Prüfprogramm
(ad hoc signiert, `--options=runtime`, ohne Entitlements) und dem echten Quelltext von
`BuiltInLightSensor`. Die App selbst lief dabei nicht.

## API

Öffentlich (IOKit/hidsystem) sind nur `IOHIDEventSystemClientCreateSimpleClient`,
`IOHIDEventSystemClientCopyServices`, `IOHIDServiceClientConformsTo`,
`IOHIDServiceClientCopyProperty` und `IOHIDServiceClientSetProperty`. Für Messwerte
braucht es private Funktionen aus IOKit, geladen per `dlsym`:

| Funktion | Zweck |
|---|---|
| `IOHIDEventSystemClientCreate` | vollwertiger Client |
| `IOHIDEventSystemClientSetMatching` | nur der Lichtsensor (`PrimaryUsagePage` 0xFF00, `PrimaryUsage` 4) |
| `IOHIDServiceClientCopyEvent` | aktueller Wert (Typ 12, `kIOHIDEventTypeAmbientLightSensor`) |
| `IOHIDEventGetType`, `IOHIDEventGetFloatValue` | Feld `12 << 16` = Lux |
| `IOHIDEventSystemClientRegisterEventCallback` / `Unregister…` | Ereignisse |
| `IOHIDEventSystemClientScheduleWithDispatchQueue` / `Unschedule…` | Zustellung auf eigener Queue |

Messungen:

- **Einfacher Client** (`…CreateSimpleClient`, öffentlich): findet den Dienst „als“, aber
  `CopyEvent` liefert `nil` und es kommen keine Ereignisse. Unbrauchbar.
- **Vollwertiger Client** (`IOHIDEventSystemClientCreate`): `CopyEvent` liefert Lux
  (abends im dunklen Raum 0–2 lx). Kein Entitlement nötig, keine Rückfrage von macOS.
- **Ereignisse**: Ohne gesetztes `ReportInterval` kam in 8 s kein einziges Ereignis
  (Licht unverändert). Mit `ReportInterval` = 1 000 000 µs am Dienst
  (`IOHIDServiceClientSetProperty`, öffentlich) kommt jede Sekunde ein Ereignis, auch bei
  gleichem Licht. Das Intervall gilt pro Client: Der Wert, den macOS selbst nutzt
  (etwa 197 ms für die Auto-Helligkeit), stand nach Ende des Prüfprogramms unverändert im
  Registry.
- Der Dienst trägt `Built-In = Yes` und `Transport = SPU`. ScreenDim filtert darauf, damit
  ein Bildschirm mit eigenem Lichtsensor (etwa am Mac mini) nicht als eingebauter Sensor
  gilt.

### Warum 1 Hz

Der Sensor meldet einem Client nichts von selbst; Ereignisse gibt es nur im angeforderten
Takt. Echte Änderungsmeldungen gibt es also nicht, aber auch kein eigenes Polling: Die
Werte schiebt das HID-System auf eine Dispatch-Queue. 1 s ist für Raumlicht schnell
genug. Die Helligkeit ändert sich trotzdem selten: `AmbientLightCurve` und 5 % Hysterese
im `SensorController` lassen nur deutliche Lichtwechsel durch, DDC-Writes bleiben rar.

## Erkennung

| Fall | Erkennung | Verhalten |
|---|---|---|
| Mac mini, Mac Studio, Intel | kein Dienst mit 0xFF00/4 und `Built-In` | `BuiltInLightSensor()` ist `nil`, Option ausgeblendet. Eine gespeicherte Wahl gilt als „aus“. |
| App-Store-Variante | keine Fabrik | Option ausgeblendet |
| MacBook, Deckel zu | eingebautes Display nicht in `DisplayManager.monitors` (macOS nimmt es im Clamshell-Betrieb offline; die Liste folgt schon dem Reconfiguration-Callback) | Werte zählen nicht, Hinweis „Deckel zu: Der Lichtsensor ist pausiert.“ Nach dem Aufklappen gilt der nächste Wert. |
| iMac | hat einen Sensor, eingebautes Display immer da | wie MacBook mit offenem Deckel (nicht auf Hardware geprüft) |

Bei zugeklapptem Deckel liest der Strom weiter im 1-s-Takt; die Werte werden nur
verworfen. Abschalten und wieder Anmelden lohnt bei einem Ereignis pro Sekunde nicht.

## Umsetzung

- `ScreenDim/Direct/BuiltInLightSensor.swift`: `SensorSource`, meldet
  `.connection(.connected)`, sofort einen ersten Wert per `CopyEvent`, danach `.lux` im
  Takt. Ein Client je Strom; Abbruch des Stroms meldet den Callback ab.
- `DirectControls.lightSensor` reicht die Quelle als Fabrik an
  `SensorController(manager:makeBuiltInLightSensor:)`, wie `makeExternalControl` beim
  `DisplayManager`. `ScreenDimKit` enthält weder private API noch deren Namen.
- `SensorController.LightSource`: Schreibtisch-Sensor (Standard), eingebauter Sensor,
  aus. Ersetzt den Schalter „Helligkeit ans Umgebungslicht anpassen“; ein gespeichertes
  „aus“ wird übernommen.
- Mit dem eingebauten Sensor regelt ScreenDim **nur die externen Monitore**
  (`setAllBrightness(_:includingBuiltIn: false)`). Das eingebaute Display regelt macOS mit
  demselben Sensor; beide gleichzeitig würden gegeneinander arbeiten.
- Demo-Modus: Das simulierte Licht ersetzt jede Lichtquelle außer „aus“; der eingebaute
  Sensor ist dann getrennt.
- `scripts/check-mas-binary.sh` sucht zusätzlich nach den privaten HID-Namen.

## Alternative ohne ALS-API: externe Monitore folgen dem eingebauten Display („Sync“)

Idee: macOS regelt das eingebaute Display per Auto-Helligkeit; die externen Monitore
übernehmen dessen Helligkeit.

- **Lesen**: Im Direct geht das über den vorhandenen `BuiltInDisplayControl`
  (`DisplayServicesGetBrightness`). Das ist ebenfalls private API. Öffentlich lässt sich
  die Helligkeit des eingebauten Displays auf Apple Silicon nicht lesen; für die
  App-Store-Variante bringt Sync also nichts.
- **Änderungen erkennen**: DisplayServices exportiert
  `DisplayServicesRegisterForBrightnessChangeNotifications` (Symbol vorhanden, Signatur
  nicht dokumentiert und nicht geprüft). Ohne sie bliebe nur Abfragen im Takt.
- **Vorteile**: macOS liefert eine geglättete, an den Nutzer angepasste Kurve; manuelle
  Änderungen mit den Helligkeitstasten wirken auf alle Monitore.
- **Nachteile**: Das eingebaute Display wird auch aus Gründen dunkler, die mit Raumlicht
  nichts zu tun haben: „Auf Batterie leicht abdunkeln“, Abdunkeln vor dem Ruhezustand,
  Energiesparen, Helligkeitstasten. Die externen Monitore folgen dem ungewollt. Ein
  Prozentwert des eingebauten Panels (bis 500 bzw. 1000 nits) entspricht nicht dem
  Prozentwert eines externen Monitors; es bräuchte eine eigene Abbildung. Bei
  zugeklapptem Deckel gibt es nichts zu folgen. Die Logik „Helligkeit folgt Helligkeit“
  passt nicht zur vorhandenen Lux-Kurve mit Hysterese, sie wäre ein zweiter Weg.

**Bewertung**: Der eingebaute Sensor als Lichtquelle ist die bessere Wahl. Er misst das
Licht selbst, nutzt die vorhandene Kurve und Hysterese und braucht im Direct-Build nicht
mehr Rechte als Sync. Sync wäre als zusätzlicher Modus denkbar („wie eingebautes
Display“), wenn jemand die Helligkeitstasten für alle Monitore nutzen will; dafür zuerst
die Signatur der DisplayServices-Benachrichtigung prüfen.

## Offen

- [ ] Auf Hardware: Lux bei Tageslicht und Schreibtischlampe mit der Kurve (10 lx → 20 %,
      1000 lx → 100 %) vergleichen. Abends lieferte der Sensor 0–2 lx; nach der Kurve
      gingen die Monitore damit auf 20 %. Eventuell braucht der eingebaute Sensor eine
      eigene Kurve, weil er hinter dem Displayglas sitzt und anders misst als der
      ESP32-Sensor.
- [ ] Deckel zu und wieder auf (Clamshell mit externem Monitor): Hinweis erscheint,
      danach wieder Werte.
- [ ] Mac Studio: Option fehlt.
- [ ] Notarisierter Direct-Build: Lesen weiterhin ohne Rückfrage.
