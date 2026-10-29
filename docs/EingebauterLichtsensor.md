# Eingebauter Lichtsensor als Lichtquelle

Stand: 2026-10-29, Prototyp, nur „ScreenDim Direct“. Vorrang und Rückfall zwischen beiden
Lichtquellen: ebenfalls 2026-10-29.

## Ergebnis

Der Umgebungslichtsensor (ALS) eines MacBooks lässt sich auf Apple Silicon ohne Sandbox
und mit Hardened Runtime ohne Entitlement lesen, ereignisgesteuert im Takt von 1 s. Er ist
die zweite Lichtquelle neben dem ESP32-Sensor, mit wählbarem Vorrang und gegenseitigem
Rückfall; Anwesenheit liefert er nicht. In der App-Store-Variante geht das nicht (private
API).

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
| Mac mini, Mac Studio, Intel | kein Dienst mit 0xFF00/4 und `Built-In` | `BuiltInLightSensor()` ist `nil`. Wählbar nur „Schreibtisch-Sensor“ oder „Aus“. Eine gespeicherte Wahl mit „eingebaut“ wirkt wie „nur Schreibtisch-Sensor“ und bleibt gespeichert. Diagnose: „Dieser Mac hat keinen eingebauten Lichtsensor.“ |
| App-Store-Variante | keine Fabrik | wie Mac mini. Einstellungen und Diagnose: „Nur in ScreenDim Direct verfügbar – der App Store erlaubt keinen Zugriff auf den Lichtsensor.“ (ohne Hardware-Erkennung) |
| MacBook, Deckel zu | eingebautes Display nicht in `DisplayManager.monitors` (macOS nimmt es im Clamshell-Betrieb offline; die Liste folgt schon dem Reconfiguration-Callback) | Werte zählen nicht, der Sensor gilt sofort als nicht verfügbar; der Schreibtisch-Sensor springt ein, wenn die Wahl ihn enthält. Nach dem Aufklappen gilt der nächste Wert. |
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
- `SensorController.LightSource` (Einstellung „Helligkeit anpassen nach“):

  | Wahl | Wirkung |
  |---|---|
  | `deskSensorFirst` (Standard) | Schreibtisch-Sensor, Rückfall eingebaut |
  | `builtInFirst` | eingebaut, Rückfall Schreibtisch-Sensor |
  | `deskSensorOnly` | nur Schreibtisch-Sensor |
  | `builtInOnly` | nur eingebaut |
  | `off` | aus |

  Gespeicherte Werte früherer Versionen werden gelesen, nicht umgeschrieben:
  `deskSensor` → `deskSensorFirst`, `builtIn` → `builtInFirst`, `off` → `off`. Der ältere
  Schalter „Helligkeit ans Umgebungslicht anpassen“ (aus) wird zu `off`. Ohne
  eingebauten Sensor wirkt jede Wahl außer „aus“ wie `deskSensorOnly`
  (`effectiveLightSource`).
- `LightSourceSelector` (rein, getestet) wählt die aktive Quelle:
  - Schreibtisch-Sensor verfügbar: verbunden und letztes Lux höchstens 10 s alt.
  - Eingebaut verfügbar: Sensor vorhanden, Deckel offen, letzter Wert höchstens 5 s alt.
  - Aktiv ist die bevorzugte Quelle, wenn verfügbar, sonst die andere, sonst keine.
  - Sperre gegen Hin-und-her: Eine verfügbare aktive Quelle bleibt mindestens 5 s, bevor
    die bevorzugte sie wieder ablöst. Fällt die aktive aus, wird sofort gewechselt.
  - Beim Wechsel beginnt die Hysterese neu, und der letzte Wert der neuen Quelle gilt
    sofort. `activeLightOrigin` ist die tatsächlich aktive Quelle, `isLightFallback`
    sagt, ob sie einspringt.
  - Geprüft wird nach jedem Ereignis und jeder Einstellung. Für das Ablaufen ohne neues
    Ereignis gibt es einen einzelnen, neu gesetzten Task-Sleep bis zum nächsten Termin
    (Ablauf einer Quelle oder Ende einer Sperre, die gerade einen Wechsel zurückhält);
    kein Polling.
- Lux vom Schreibtisch-Sensor regeln alle Monitore samt eingebautem Display. Lux vom
  eingebauten Sensor regeln **nur die externen Monitore**
  (`setAllBrightness(_:includingBuiltIn: false)`). Das eingebaute Display regelt macOS mit
  demselben Sensor; beide gleichzeitig würden gegeneinander arbeiten. Anwesenheit kommt
  nur vom Schreibtisch-Sensor. Kurve und Hysterese sind für beide Quellen gleich;
  `SensorController.builtInLuxFactor` (1,0, ohne UI) korrigiert den eingebauten Sensor
  hinter dem Glas, sobald er kalibriert ist.
- Der eingebaute Sensor liest nur, wenn die (wirksame) Wahl ihn enthält und keine Demo
  läuft, oder wenn die Sensor-Diagnose offen ist. Mit dem Standard `deskSensorFirst` liest
  er auf einem MacBook also immer mit, damit er sofort einspringen kann.
- Einstellungen: unter der Wahl „Aktiv: Schreibtisch-Sensor / Eingebauter Lichtsensor /
  Keine Quelle“ mit Grund („Schreibtisch-Sensor getrennt – der eingebaute Sensor springt
  ein.“, „Deckel zu“, …). Sensor-Diagnose: aktive Quelle mit Kennzeichen „Rückfall“,
  Verfügbarkeit beider Quellen; das Protokoll markiert Quellwechsel.
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
- [ ] Faktor `builtInLuxFactor` bzw. eigene Kurve für den eingebauten Sensor auf Hardware
      kalibrieren (gleiche Lampe, ESP32 und MacBook nebeneinander).
- [ ] Deckel zu und wieder auf (Clamshell mit externem Monitor): Rückfall auf den
      Schreibtisch-Sensor bzw. „Deckel zu“, danach wieder Werte.
- [ ] ESP32-Firmware: Lux mindestens alle 10 s melden (`update_interval`, kein Filter, der
      gleiche Werte unterdrückt). Sonst gilt der Schreibtisch-Sensor bei ruhigem Licht als
      abgelaufen, und der eingebaute Sensor springt ein.
- [ ] Mac Studio: nur „Schreibtisch-Sensor“ und „Aus“ wählbar.
- [ ] Notarisierter Direct-Build: Lesen weiterhin ohne Rückfrage.
