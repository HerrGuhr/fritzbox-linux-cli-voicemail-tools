#!/bin/bash

# _parse_voicemail_html.sh
# Version: 1.8
# Zweck: Parst HTML-Input (stdin) von data.lua (Voicemail-Liste)
#        und gibt die Daten pro Nachricht als Pipe (|) getrennte Zeile aus.
# Methode: Verwendet AWK zum Aufteilen in Blöcke und eine Hilfsfunktion mit
#          grep -oP (Perl Compatible Regex) zur Extraktion der Felder.
#          Dieser Ansatz ist notwendig, da das HTML der Fritz!Box fehlerhaft
#          sein kann und Standard-HTML-Parser (pup, hxselect) daran scheitern können.

# --- Bibliotheks-Einbindung ---
# Versucht, die zentrale Logging-Bibliothek zu laden.
# Diese sollte die Umgebungsvariable VERBOSE=1 beachten.
LIB_SCRIPT_DIR=$(dirname "$0") # Erwartet fb_lib.sh im selben Verzeichnis
LIB_SCRIPT="${LIB_SCRIPT_DIR}/fb_lib.sh"
if [[ -f "$LIB_SCRIPT" ]]; then
    # shellcheck source=fb_lib.sh
    source "$LIB_SCRIPT"
else
    # Fallback Logging-Funktionen, falls Bibliothek fehlt
    # Beachten die VERBOSE-Variable NICHT!
    function log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER(Parser): $@" >&2; }
    function log_ts()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO(Parser): $@" >&2; }
    function log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG(Parser): $@" >&2; }
    function log_debug() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG(Parser): $@" >&2; } # Fallback ist immer an
    log_error "Bibliothek '$LIB_SCRIPT' nicht gefunden!"
fi
# --- Ende Bibliothek ---

# === Hilfsfunktion ===

# Extrahiert ein einzelnes Feld aus einem HTML-Block mithilfe von Regex.
# Nimmt nur das erste gefundene Vorkommen und entfernt Leerzeichen.
# Gibt das gefundene Feld auf Stdout aus, oder eine leere Zeichenkette bei Fehler/Nichtfund.
# Argument $1: Das grep -oP Muster (Perl-kompatible Regex)
# Argument $2: Der zu durchsuchende HTML-Textblock
function extrahiere_feld_regex() {
    local muster="$1"
    local html_block="$2"
    local ergebnis

    # Prüfe, ob Muster und Block nicht leer sind
    if [[ -z "$muster" || -z "$html_block" ]]; then
        echo "" # Leeres Ergebnis zurückgeben
        return 1
    fi

    # Führe grep aus, nimm erste Zeile, entferne Leerzeichen
    # Fehler von grep werden unterdrückt (2>/dev/null)
    ergebnis=$(echo "$html_block" | grep -oP "$muster" 2>/dev/null | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$ergebnis"
    # Prüfe nicht explizit den Exit-Code, leeres Ergebnis reicht als Indikator
    return 0
}

# === Hauptlogik ===

# Lese gesamten HTML-Inhalt von Stdin
# Verwende mapfile, um den gesamten Input auf einmal zu lesen (effizienter bei großen Inputs)
mapfile -t HTML_LINES <&0
HTML_CONTENT=$(printf '%s\n' "${HTML_LINES[@]}")
unset HTML_LINES # Speicher freigeben

# Schnelle Prüfung, ob die erwartete Tabelle überhaupt da ist.
if ! echo "$HTML_CONTENT" | grep -q 'id="uiTamCalls"'; then
    log_error "Tabelle 'uiTamCalls' nicht im empfangenen HTML gefunden."
    exit 1
fi

# --- PARSING v26 (AWK Split + Regex Helper Function) ---
log_debug "Starte HTML-Verarbeitung mit AWK und Regex-Hilfsfunktion..."

# AWK zum Aufteilen des HTML in Blöcke, die wahrscheinlich Nachrichten-Zeilen sind.
# - Trennt bei </tr> (Record Separator)
# - Sucht nach Zeilen, die einen Delete-Button enthalten (<button ... name="delete")
# - Gibt gefundene Blöcke mit Null-Byte getrennt aus (für mapfile -d '')
mapfile -d '' rows < <(echo "$HTML_CONTENT" \
    | awk 'BEGIN { RS="</tr>" ; FS="\n"; ORS="\0" }
           /id="uiTamCalls"/ { in_table=1 }  # Merker, wenn wir in der Tabelle sind
           in_table && /<button[^>]+name="delete"/ { print $0 "</tr>" }' # Nur Blöcke mit delete-button ausgeben
)

num_rows=${#rows[@]}
log_debug "$num_rows potenzielle Nachrichten-Blöcke gefunden."

if [[ $num_rows -eq 0 ]]; then
    log_debug "Keine Nachrichten-Blöcke mit delete-Button identifiziert."
    exit 0 # Normaler Exit, wenn keine Nachrichten da sind
fi

output_lines=0
# Iteriere durch die gefundenen HTML-Blöcke
for row_html in "${rows[@]}"; do
    # Überspringe leere Array-Elemente (könnte durch mapfile/awk entstehen)
    if [[ -z "$row_html" ]]; then
        log_debug "Überspringe leeres Array-Element."
        continue
    fi

    # 1. Index extrahieren (wichtigster Anker)
    #    Sucht nach 'name="delete" value="(\d+)"', extrahiert die Zahl (\d+).
    #    \K in der Regex entfernt den vorderen Teil aus dem Match.
    index=$(extrahiere_feld_regex 'name="delete"\s+value="\K\d+' "$row_html")
    if [[ -z "$index" ]]; then
        log_warn "Konnte Index nicht aus folgendem HTML-Block extrahieren, überspringe Block:"
        log_warn "${row_html:0:100}..." # Nur Anfang loggen
        continue # Nächster Block
    fi
    log_debug "Index $index: Beginne Extraktion der Felder..."

    # 2. "Neu?"-Status prüfen
    #    Sucht nach dem Bildnamen des gelben Sterns.
    neu="Nein"
    if echo "$row_html" | grep -q 'src="/assets/icons/ic_star_yellow.gif"'; then
        neu="Ja"
    fi

    # 3. "Bekannt?"-Status prüfen
    #    Sucht nach 'name="fonbook"'-Button, der NICHT 'disabled' enthält.
    bekannt="Nein"
    if echo "$row_html" | grep -qP '<button[^>]+name="fonbook"[^>]*>'; then
       if ! echo "$row_html" | grep -qP '<button[^>]+name="fonbook"[^>]*disabled[^>]*>'; then
          bekannt="Ja"
       fi
    fi

    # 4. Datum extrahieren
    #    Sucht nach DD.MM.YY HH:MM in einem <td> Tag.
    datum=$(extrahiere_feld_regex '<td>\s*\K(\d{2}\.\d{2}\.\d{2}\s+\d{2}:\d{2})\s*</td>' "$row_html")

    # 5. Name/Rufnummer extrahieren
    name_rufnummer=$(extrahiere_feld_regex 'datalabel="Name/Rufnummer">\K[^<]+' "$row_html")

    # 6. Eigene Rufnummer extrahieren
    eigene_nr=$(extrahiere_feld_regex 'datalabel="Eigene Rufnummer">\K[^<]+' "$row_html")

    # 7. Dauer (Rohformat) extrahieren
    dauer_raw=$(extrahiere_feld_regex 'datalabel="Dauer">\K[^<]+' "$row_html")

    # 8. Pfad (kodiert) extrahieren
    #    Sucht nach 'myabfile=...' in einem Link (href="...").
    #    Das Muster [^"]+ matcht alle Zeichen bis zum nächsten Anführungszeichen.
    path_encoded=$(extrahiere_feld_regex 'myabfile=\K[^"]+' "$row_html")

    # Dekodierungen
    pfad_decoded=""
    if [[ -n "$path_encoded" ]]; then
        # Wandelt URL-Kodierung (%XX) in Zeichen um
        pfad_decoded=$(printf '%b' "${path_encoded//%/\\x}")
        log_debug "Index $index: Pfad dekodiert zu '$pfad_decoded'"
    fi
    # Wandelt HTML-Entity (&lt;) in der Dauer zurück zu '<'
    dauer_decoded=$(echo "${dauer_raw:-N/A}" | sed 's/&lt;/</g')

    # Konsistenzprüfung (nur im Debug-Modus ausgeben)
    log_debug "Index $index: Neu=$neu | Bekannt=$bekannt | Datum=$datum | Name/Nr=$name_rufnummer | EigeneNr=$eigene_nr | Dauer=$dauer_decoded | Pfad=$pfad_decoded"

    # Ausgabe der geparsten Daten im Pipe-Format auf Stdout
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "${index:-?}" \
        "${neu:-?}" \
        "${bekannt:-?}" \
        "${datum:-?}" \
        "${name_rufnummer:-N/A}" \
        "${eigene_nr:-?}" \
        "${dauer_decoded:-?}" \
        "${pfad_decoded:-?}" # Pfad ist dekodiert

    ((output_lines++))
done
# --- ENDE PARSING ---

log_debug "$output_lines Zeilen erfolgreich verarbeitet und ausgegeben."

# Warnung, falls nicht alle gefundenen Blöcke erfolgreich geparst wurden
if [[ $num_rows -gt 0 && $output_lines -ne $num_rows ]]; then
    log_warn "Nicht alle potenziellen Blöcke ($num_rows) konnten vollständig geparst werden ($output_lines)."
fi

exit 0