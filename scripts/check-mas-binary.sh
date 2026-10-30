#!/bin/bash
# Prüft ein gebautes ScreenDim.app (Mac-App-Store-Variante) auf private API.
# Baut nichts. Exit 0: sauber, 1: Treffer, 2: Aufruffehler.
#
#   scripts/check-mas-binary.sh /pfad/zu/ScreenDim.app
set -u

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
    echo "Aufruf: $0 <Pfad zu ScreenDim.app>" >&2
    exit 2
fi
app="$1"

# Zeichenketten, die nur private API mit sich bringt: IOAVService (DDC über den DCP),
# DisplayServices (Helligkeit des eingebauten Displays), CoreBrightness (Auto-Helligkeit),
# private Frameworks, SkyLight und CoreDisplay-Interna; dazu die nicht öffentlichen
# Funktionen des HID-Event-Systems (Lichtsensor des MacBooks).
string_pattern='IOAVService|DisplayServices|CoreBrightness|BrightnessSystemClient|PrivateFrameworks|SkyLight|CoreDisplay_|IOHIDServiceClientCopyEvent|IOHIDEventSystemClient(Create$|SetMatching|RegisterEventCallback|ScheduleWith)|IOHIDEventGet'
# Importierte Symbole: Nachladen von Bibliotheken und private Funktionen (CGS…/SLS…
# sind private CoreGraphics/SkyLight-Aufrufe; öffentliche wie CGSetDisplay… passen nicht).
symbol_pattern='^_(dlopen|IOAVService|DisplayServices|CoreDisplay_|CGS[A-Z]|SLS[A-Z]|IOHIDServiceClientCopyEvent|IOHIDEventSystemClient(Create$|SetMatching|RegisterEventCallback|ScheduleWith)|IOHIDEventGet)'
# `_dlsym` allein ist kein Treffer: clangs Laufzeit für Verfügbarkeitsprüfungen
# (`__isPlatformVersionAtLeast`, von SwiftUI-Code eingebettet) importiert es in jeder
# SwiftUI-App und sucht damit nur CoreFoundation-Funktionen. Private Namen, die per
# dlsym gesucht würden, stünden als Zeichenkette im Binary und fielen oben auf.

found=0
checked=0
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q 'Mach-O' || continue
    checked=$((checked + 1))
    rel="${file#"$app"/}"

    hits=$(strings -a "$file" | grep -E "$string_pattern" | sort -u)
    if [ -n "$hits" ]; then
        echo "TREFFER Strings in $rel:"
        echo "$hits" | sed 's/^/    /'
        found=1
    fi

    symbols=$(nm -u "$file" 2>/dev/null | grep -E "$symbol_pattern" | sort -u)
    if [ -n "$symbols" ]; then
        echo "TREFFER importierte Symbole in $rel:"
        echo "$symbols" | sed 's/^/    /'
        found=1
    fi

    if nm -u "$file" 2>/dev/null | grep -qx '_dlsym'; then
        echo "Hinweis: $rel importiert _dlsym. Ohne Treffer stammt das aus clangs Laufzeit für Verfügbarkeitsprüfungen."
    fi

    libs=$(otool -L "$file" 2>/dev/null | grep -F '/PrivateFrameworks/')
    if [ -n "$libs" ]; then
        echo "TREFFER private Frameworks in $rel:"
        echo "$libs" | sed 's/^/    /'
        found=1
    fi
done < <(find "$app" -type f -print0)

if [ "$checked" -eq 0 ]; then
    echo "Kein Mach-O-Binary in $app gefunden." >&2
    exit 2
fi
if [ "$found" -ne 0 ]; then
    echo "FEHLER: private API in $app ($checked Binaries geprüft)."
    exit 1
fi
echo "OK: keine private API in $app ($checked Binaries geprüft)."
