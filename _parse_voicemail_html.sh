#!/bin/bash

# _parse_voicemail_html.sh
# Version: 1.11
# Zweck: Parst HTML-Input (stdin) von data.lua (Voicemail-Liste)
#        und gibt die Daten pro Nachricht als Pipe (|) getrennte Zeile aus.
# Methode: Verwendet AWK zum Aufteilen in Blöcke und eine Hilfsfunktion mit
#          grep -oP (Perl Compatible Regex) zur Extraktion der Felder.
# Encoding: Erzwingt UTF-8 für alle Operationen via LC_ALL.
# Autor: Marc Guhr
# Datum: 2025-04-07

# --- Locale auf UTF-8 setzen ---
export LC_ALL=C.UTF-8
# -------------------------------

# --- Bibliotheks-Einbindung ---
LIB_SCRIPT_DIR=$(dirname "$0")
LIB_SCRIPT="${LIB_SCRIPT_DIR}/fb_lib.sh"
if [[ -f "$LIB_SCRIPT" ]]; then source "$LIB_SCRIPT"
else function log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER(Parser): $@" >&2; }
function log_ts()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO(Parser): $@" >&2; }
function log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG(Parser): $@" >&2; }
function log_debug() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG(Parser): $@" >&2; }
log_error "Bibliothek '$LIB_SCRIPT' nicht gefunden!"; fi
# --- Ende Bibliothek ---

# === Hilfsfunktion ===
function extrahiere_feld_regex() {
    local muster="$1"; local html_block="$2"; local ergebnis
    if [[ -z "$muster" || -z "$html_block" ]]; then echo ""; return 1; fi
    # '-P' sollte mit C.UTF-8 Locale korrekt arbeiten. Stderr Umleitung bleibt.
    ergebnis=$(echo "$html_block" | grep -oP "$muster" 2>/dev/null | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$ergebnis"; return 0
}

# === Hauptlogik ===
mapfile -t HTML_LINES <&0; HTML_CONTENT=$(printf '%s\n' "${HTML_LINES[@]}"); unset HTML_LINES
if ! echo "$HTML_CONTENT" | grep -q 'id="uiTamCalls"'; then log_error "Tabelle 'uiTamCalls' nicht gefunden."; exit 1; fi

log_debug "Starte HTML-Verarbeitung..."; mapfile -d '' rows < <(echo "$HTML_CONTENT" | awk 'BEGIN { RS="</tr>"; ORS="\0" } /id="uiTamCalls"/ { in_table=1 } in_table && /<button[^>]+name="delete"/ { print $0 "</tr>" }'); num_rows=${#rows[@]}
log_debug "$num_rows potenzielle Nachrichten-Blöcke gefunden."
if [[ $num_rows -eq 0 ]]; then log_debug "Keine Nachrichten-Blöcke gefunden."; exit 0; fi

output_lines=0
for row_html in "${rows[@]}"; do
    if [[ -z "$row_html" ]]; then continue; fi

    index=$(extrahiere_feld_regex 'name="delete"\s+value="\K\d+' "$row_html")
    if [[ -z "$index" ]]; then log_warn "Index nicht gefunden, überspringe Block."; continue; fi
    log_debug "Index $index: Extrahiere Felder..."

    neu="Nein"; if echo "$row_html" | grep -q 'src="/assets/icons/ic_star_yellow.gif"'; then neu="Ja"; fi
    bekannt="Nein"; if echo "$row_html" | grep -qP '<button[^>]+name="fonbook"[^>]*>'; then if ! echo "$row_html" | grep -qP '<button[^>]+name="fonbook"[^>]*disabled[^>]*>'; then bekannt="Ja"; fi; fi
    # Das Muster für Datum sollte UTF-8 unabhängig sein
    datum_roh=$(extrahiere_feld_regex '<td>\s*(\d{2}\.\d{2}\.\d{2}\s+\d{2}:\d{2})\s*</td>' "$row_html")
    datum=$(echo "$datum_roh" | sed -e 's~</\?td>~~g' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Extraktion von Textinhalten: [^<]+ ist generell UTF-8 sicher
    name_rufnummer=$(extrahiere_feld_regex 'datalabel="Name/Rufnummer">\K[^<]+' "$row_html")
    eigene_nr=$(extrahiere_feld_regex 'datalabel="Eigene Rufnummer">\K[^<]+' "$row_html")
    dauer_raw=$(extrahiere_feld_regex 'datalabel="Dauer">\K[^<]+' "$row_html")
    path_encoded=$(extrahiere_feld_regex 'myabfile=\K[^"]+' "$row_html")

    pfad_decoded=""; if [[ -n "$path_encoded" ]]; then pfad_decoded=$(printf '%b' "${path_encoded//%/\\x}"); fi
    dauer_decoded=$(echo "${dauer_raw:-N/A}" | sed 's/&lt;/</g') # sed hier unkritisch

    log_debug "Index $index: Neu=$neu | Bekannt=$bekannt | Datum=$datum | Name/Nr=$name_rufnummer ..."
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "${index:-?}" "${neu:-?}" "${bekannt:-?}" "${datum:-?}" "${name_rufnummer:-N/A}" "${eigene_nr:-?}" "${dauer_decoded:-?}" "${pfad_decoded:-?}"
    ((output_lines++))
done

log_debug "$output_lines Zeilen erfolgreich verarbeitet."
if [[ $num_rows -gt 0 && $output_lines -ne $num_rows ]]; then log_warn "Nicht alle Blöcke ($num_rows) konnten geparst werden ($output_lines)."; fi
exit 0