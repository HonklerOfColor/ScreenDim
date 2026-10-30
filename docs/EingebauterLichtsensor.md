# Eingebauter Lichtsensor als Lichtquelle

Stand: 2026-10-29, Prototyp, nur „ScreenDim Direct“. Vorrang und Rückfall zwischen beiden
Lichtquellen: ebenfalls 2026-10-29. Glättung, ein Schreiber fürs eingebaute Display und
Überblendung auf allen automatischen Wegen: 2026-10-30.

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
genug. Die Helligkeit ändert sich trotzdem selten: `LuxFilter` glättet die Werte, und die
Hysterese von 3 Punkten lässt nur deutliche Lichtwechsel durch; DDC-Writes bleiben rar.

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
  - Schreibtisch-Sensor verfügbar: verbunden, ein Lux-Wert liegt vor, und das letzte
    Ereignis (Lux, Anwesenheit oder Lebenszeichen) ist höchstens 45 s alt. Die Firmware
    meldet Lux nur bei 3 % Änderung oder im 30-s-Takt; mit 10 s auf Lux galt der Sensor
    bei ruhigem Licht regelmäßig als ausgefallen, die Quelle wechselte hin und her.
  - Eingebaut verfügbar: Sensor vorhanden, Deckel offen, letzter Wert höchstens 5 s alt.
  - Aktiv ist die bevorzugte Quelle, wenn verfügbar, sonst die andere, sonst keine.
  - Sperre gegen Hin-und-her: Eine verfügbare aktive Quelle bleibt mindestens 5 s, bevor
    die bevorzugte sie wieder ablöst. Fällt die aktive aus, wird sofort gewechselt.
  - Beim Wechsel bleibt die Hysterese: Die neue Quelle bringt ihren geglätteten Wert mit
    (ihr Filter lief schon mit) und blendet vom aktuellen Stand aus über, nur wenn er um
    mindestens 3 Punkte abweicht. `activeLightOrigin` ist die tatsächlich aktive Quelle,
    `isLightFallback` sagt, ob sie einspringt.
  - Geprüft wird nach jedem Ereignis und jeder Einstellung. Für das Ablaufen ohne neues
    Ereignis gibt es einen einzelnen, neu gesetzten Task-Sleep bis zum nächsten Termin
    (Ablauf einer Quelle oder Ende einer Sperre, die gerade einen Wechsel zurückhält);
    kein Polling.
- Jeder Monitor folgt seinem Lichtprofil (`LightCurve`), gleich aus welcher Quelle das
  Licht kommt; siehe „Lichtregelung“ unten. Anwesenheit kommt nur vom
  Schreibtisch-Sensor. `SensorController.builtInLuxFactor` (1,0, ohne UI) korrigiert den
  eingebauten Sensor hinter dem Glas, sobald er kalibriert ist.
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

## Lichtregelung

Befund (2026-10-30): „Manchmal springt die Helligkeit“, mit „nur eingebauter
Lichtsensor“, eingeschalteter Auto-Helligkeit von macOS und externen Monitoren per
Software-Dimmung. Ursachen und Abhilfe:

| Ursache | Abhilfe |
|---|---|
| ScreenDim und macOS regelten das eingebaute Display gleichzeitig. | Ein Schreiber, siehe unten. |
| Die Überblendung begann beim Merkwert, nicht beim echten Wert. | Eingebaut: echten Wert vorher lesen (nur bei freier Drossel). DDC: zuletzt bestätigter Write, kein zusätzlicher Read. Der Platzhalter 50 während der Prüfung ist nie Startwert (Display dann nicht regelbar, Wert wird nachgeholt). |
| Prüfung, Software-Rückfall und Refresh setzten Werte ohne Überblendung. | Alle automatischen Wege laufen über `DisplayManager.fadeBrightness`; Wege des Managers mit 0,5 s, Licht mit 2 s. Ein Refresh setzt Software-Dimmung vom sichtbaren Stand aus fort (neu angesteckt: vom ungedimmten). |
| Lux des eingebauten Sensors ungeglättet, Hysterese gegen den letzten Lichtwert. | `LuxFilter`; Hysterese 3 Punkte gegen den Wert, auf den der Monitor gerade zugeht. |
| Quelle wechselte bei ruhigem Licht (10 s auf Lux), mit Reset der Hysterese. | 45 s auf jedes Ereignis, kein Reset beim Wechsel. |

**Ein Schreiber fürs eingebaute Display.** Direct liest „Helligkeit automatisch anpassen“
über das private Framework CoreBrightness (`BrightnessSystemClient`,
`copyPropertyForKey:` mit `CBAutoBrightnessEnabled`, sonst `DisplayBrightnessAuto`), nur
bei Bedarf, ohne Takt. Ist sie an, lässt die Lichtregelung das eingebaute Display aus,
auch mit eigenem Profil. Unbekannt (App Store, Schlüssel fehlt): Das Profil entscheidet,
und das eingebaute Display folgt dem Licht standardmäßig nicht. Die Einstellungen zeigen
dann „macOS regelt dieses Display selbst …“ mit Knopf zu den Displays-Einstellungen.
Zusätzlich: Weicht der vor einer Überblendung gelesene Wert um mehr als 3 Punkte vom
eigenen ab, hat ein anderer Regler gewirkt (Helligkeitstasten, macOS). Der Wert wird
übernommen, nichts geschrieben, und die Lichtregelung dieses Displays ruht 60 s
(Grund „fremde Änderung“). Geprüft am MacBook Air M4: Beide Schlüssel lieferten 1 bei
eingeschalteter Auto-Helligkeit; das Umschalten selbst ist nicht geprüft.

**Glättung (`LuxFilter`, rein, getestet).** Eingebauter Sensor: Median über 5 Werte, dann
EMA im Log-Raum mit Zeitkonstante 4 s, zeitbasiert. Ein großer anhaltender Sprung
(mehr als Faktor 3, drei Werte in Folge) zieht den Mittelwert sofort nach, damit Licht
an/aus nicht träge wirkt. Schreibtisch-Sensor und Demo: durchgereicht. Die Firmware glättet
schon und meldet nur bei Änderung; jeder Median oder EMA würde eine einzelne Änderung bis
zur nächsten Meldung (bis 30 s) zurückhalten. Beide Filter laufen mit, auch wenn ihre
Quelle gerade nicht aktiv ist.

**Pausen.** Regler oder Tastenkürzel setzen sofort; der Wert ist der neue Bezug, und die
Lichtregelung dieses Monitors ruht 5 min oder bis sich das Licht um mehr als Faktor 2
ändert (`SensorController.manualHold`, `manualHoldLuxFactor`, ohne UI). Eine Pause endet
auch, wenn der Nutzer das Profil des Monitors ändert. Geprüft wird beim nächsten
Lux-Wert, ohne Timer.

**Diagnose.** Je Auftrag (nicht je Schritt) ein Eintrag im Protokoll der Sensor-Diagnose
(Spalte „Quelle / Grund“) und `log.info` (Subsystem `com.andreastrabi.ScreenDim`,
Kategorie `light`): Monitor, Merkwert und echter Wert, Ziel, Dauer. Gründe: `lux` (roh,
geglättet, Quelle), `sourceSwitch`, `profileChange`, `pendingAfterProbe`, `manual`,
`probeRestore`, `softwareFallback`, `wake`, `externalChange`. Ansehen:
`/usr/bin/log stream --predicate 'subsystem == "com.andreastrabi.ScreenDim" && category == "light"' --info`.

**Software-Dimmung.** Gamma schreibt je Schritt nur Displays mit geändertem Wert, das
Overlay fasst ebenfalls nur geänderte Fenster an.

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
- [x] ESP32 bei ruhigem Licht: Statt Lux alle 10 s zählt jedes Ereignis, Grenze 45 s
      (über dem 30-s-Takt der Firmware).
- [ ] Erkennung der Auto-Helligkeit: Folgt `CBAutoBrightnessEnabled` dem Schalter in den
      Systemeinstellungen sofort? Im notarisierten Build (Hardened Runtime) lesbar?
- [ ] Mac Studio: nur „Schreibtisch-Sensor“ und „Aus“ wählbar.
- [ ] Notarisierter Direct-Build: Lesen weiterhin ohne Rückfrage.
