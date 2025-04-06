#!/bin/bash

# fb-voicemailtools.sh
# Version: 1.31
# Zweck: Auflisten und Herunterladen von Voicemail-Nachrichten von einer Fritz!Box
#        über die Web-GUI (Lua-Schnittstelle / data.lua). Nutzt Regex-Parser.
# Features:
#   - Liste (--list) mit Filtern (all, latest, index, known, unknown)
#   - Download (--download) von Nachrichten (all, latest, index)
#   - Auswahl des Anrufbeantworters (--tam)
#   - Ausgabeformate (--format): table, json, simple, csv
#   - Optionale Konvertierung (--audio-format wav|ogg|mp3) via ffmpeg
#   - Optionale Debug-Ausgabe (--verbose / -v) inkl. curl -v
#   - Ausgabe der reinen Liste in Datei (--output-file) oder bei Umleitung (> / |)
#   - Sauberes Beenden mit Strg+C (SIGINT trap)
# Autor: [Ihr Name/Nickname], Basierend auf Vorlage und Ideen von Claude 3 Opus / Gemini
# Datum: 2025-04-06

# === Standard-Konfiguration ===
DEFAULT_TAM_INDEX=0         # Standard Anrufbeantworter-Index (oft 0)
DEFAULT_LIST_FORMAT="table" # Standard Ausgabeformat für Liste
SCRIPT_VERSION="1.31"       # Finale Version mit Formatierungskorrekturen
# ============================

# === Globale Variablen ===
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0") # Verzeichnis des Skripts
CREDENTIALS_FILE="${SCRIPT_DIR}/fb-credentials" # Anmeldedaten im selben Verzeichnis
LIB_SCRIPT="${SCRIPT_DIR}/fb_lib.sh"            # Bibliothek im selben Verzeichnis
PARSER_SCRIPT="${SCRIPT_DIR}/_parse_voicemail_html.sh" # Parser im selben Verzeichnis

FRITZBOX_URL=""             # Wird aus Credentials geladen
FRITZBOX_USER=""            # Wird aus Credentials geladen
FRITZBOX_PASSWORD=""        # Wird aus Credentials geladen
SID=""                      # Session ID
VERBOSE=0                   # Debug-Ausgabe (0=aus, 1=an)
TMP_DOWNLOAD_FILE=""        # Globale Variable für temporäre Download-Datei (für Trap)

# Variablen für Aktionen/Optionen
ACTION=""                   # list oder download
TAM_INDEX=$DEFAULT_TAM_INDEX
MESSAGE_INDEX=""            # Index für Download (Zahl, 'latest', 'all')
OUTPUT_FILENAME=""          # Zieldatei/Verzeichnis für --download
LIST_OUTPUT_FILE=""         # Zieldatei für --list Ausgabe (--output-file)
LIST_FORMAT=$DEFAULT_LIST_FORMAT
LIST_FILTER="all"           # Filter für Liste (all, latest, known, unknown, index)
AUDIO_FORMAT=""             # Explizites Ziel-Audioformat (wav, ogg, mp3) oder leer
# ========================

# === Trap- und Cleanup-Funktionen ===

# Wird aufgerufen, wenn das Skript normal oder durch ein Signal beendet wird (via EXIT Trap).
# Führt notwendige Aufräumarbeiten durch (SID Logout, Temp-Datei löschen).
function cleanup() {
    local exit_code=$? # Speichere den Exit-Code des aufrufenden Befehls/Signals
    # Führe Cleanup nur aus, wenn wir nicht gerade im Interrupt-Handler sind (um doppeltes Logging zu vermeiden)
    if [[ $exit_code -ne 130 ]]; then
        log_debug "Cleanup wird ausgeführt (Skript-Exit-Code: $exit_code)..."
    fi
    # Logout nur versuchen, wenn URL und SID gültig aussehen
    if [[ -n "$FRITZBOX_URL" && -n "$SID" && "$SID" != "0000000000000000" ]]; then
        logout_sid "$FRITZBOX_URL" "$SID"
    fi
    # Lösche eine eventuell übrig gebliebene temporäre Download-Datei
    if [[ -n "$TMP_DOWNLOAD_FILE" && -f "$TMP_DOWNLOAD_FILE" ]]; then
        log_debug "Entferne temporäre Download-Datei: $TMP_DOWNLOAD_FILE"
        rm -f "$TMP_DOWNLOAD_FILE"
    fi
    # Stelle sicher, dass der ursprüngliche Exit-Code erhalten bleibt,
    # es sei denn, wir wurden durch SIGINT (Code 130) beendet.
    if [[ $exit_code -ne 130 ]]; then
       exit $exit_code
    fi
}

# Wird speziell aufgerufen, wenn Strg+C (SIGINT) gedrückt wird.
function cleanup_on_interrupt() {
    local terminal="/dev/tty"
    # Fallback auf stderr, wenn tty nicht schreibbar ist
    if [ ! -w "$terminal" ]; then
        terminal="/dev/stderr"
    fi
    # Schreibe direkt auf tty oder stderr, um sicherzustellen, dass die Meldung sichtbar ist
    echo "" > "$terminal"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: Abbruch durch Benutzer (Strg+C) erkannt..." > "$terminal"
    # Beendet das Skript mit Exit-Code 130.
    # Der EXIT-Trap wird *danach* automatisch aufgerufen, um cleanup() auszuführen.
    exit 130 # Standard Exit-Code für Abbruch durch SIGINT
}

# Setze die Traps:
trap cleanup_on_interrupt INT
trap cleanup EXIT

# --- Bibliotheks-Einbindung ---
if [[ -f "$LIB_SCRIPT" ]]; then
    # shellcheck source=fb_lib.sh
    source "$LIB_SCRIPT"
else
    # Fallback, falls fb_lib.sh fehlt
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: Bibliotheksdatei '$LIB_SCRIPT' nicht gefunden!" >&2
    # Definiere Minimal-Logfunktionen, damit das Skript nicht sofort abbricht
    function log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: $@" >&2; }
    function log_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $@" >&2; }
    function log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: $@" >&2; }
    function log_debug() { :; } # Debug im Fallback deaktivieren
    # Hinweis: Ohne Bibliothek wird das Skript nicht viel tun können
fi
# ============================


# === Funktionsdefinitionen ===

# Zeigt die Hilfe / Verwendung an
function usage() {
    echo "Verwendung: $SCRIPT_NAME <Aktion> [Optionen]"
    echo ""
    echo "Aktionen:"
    echo "  --list [Filter]          Listet Voicemails auf."
    echo "                         Filter: latest    (neueste Nachricht)"
    echo "                                 <index>   (Nachricht mit dieser Nummer)"
    echo "                                 known     (Anrufer im Telefonbuch)"
    echo "                                 unknown   (Anrufer nicht im Telefonbuch)"
    echo "                                 all       (alle Nachrichten, Standard)"
    echo "  --download <Index|all|latest>"
    echo "                         Lädt Voicemails herunter."
    echo "                         Index: <index>   (Nachricht mit dieser Nummer)"
    echo "                                latest    (neueste Nachricht)"
    echo "                                all       (alle Nachrichten)"
    echo ""
    echo "Optionen:"
    echo "  --output <Datei|Verz.>   Zieldatei (für index/latest) oder Zielverzeichnis"
    echo "                           (für all). Erforderlich für --download."
    echo "                           Dateiendung (.ogg/.mp3) bei index/latest aktiviert Konvertierung."
    echo "  --output-file <Datei>    Schreibt die *reine* Ausgabe von --list in diese Datei."
    echo "                           Alternative: Ausgabeumleitung > oder | nutzen."
    echo "  --audio-format <format>  Gewünschtes Audioformat für heruntergeladene Dateien:"
    echo "                           wav (Standard, keine Konvertierung),"
    echo "                           ogg, mp3 (Konvertierung mit ffmpeg)."
    echo "                           Überschreibt Dateiendung von --output bei index/latest."
    echo "                           Nötig für Konvertierung bei '--download all'."
    echo "  --tam <index>            Index des Anrufbeantworters (Standard: ${DEFAULT_TAM_INDEX})."
    echo "  --format <format>        Ausgabeformat für --list:"
    echo "                           table  (Tabelle, Standard, benötigt 'column')"
    echo "                           json   (JSON-Format, benötigt 'jq')"
    echo "                           simple (Einfache Textzeilen)"
    echo "                           csv    (Semikolon-getrennte Werte)"
    echo "  -v, --verbose            Aktiviert ausführliche Debug-Ausgaben auf Stderr."
    echo "  -h, --help               Zeigt diese Hilfe an."
    echo ""
    echo "Beispiele:"
    echo "  $SCRIPT_NAME --list"
    echo "  $SCRIPT_NAME --list --format table --output-file liste.txt"
    echo "  $SCRIPT_NAME --list unknown --format simple -v"
    echo "  $SCRIPT_NAME --list --format json | jq '.[0]'"
    echo "  $SCRIPT_NAME --list --format csv > liste.csv"
    echo "  $SCRIPT_NAME --download latest --output neue_nachricht.ogg" # Auto-Konvertierung
    echo "  $SCRIPT_NAME --download all --output ./voicemails_mp3/ --audio-format mp3" # Explizit MP3
    echo ""
    echo "Voraussetzungen: bash (v4+ empfohlen), curl, md5sum, iconv, awk, grep(GNU mit -P), sed, file"
    echo "                 Optional: jq (für JSON/Download), column (für Tabelle), ffmpeg (für Konvertierung)"
    echo "                 Datei: ${CREDENTIALS_FILE}"
}

# Parst eine einzelne Pipe-getrennte Zeile vom Parser in separate Variablen.
# Verwendet awk für robustes Splitting.
# Argument $1: Die zu parsende Zeile
# Setzt globale Variablen: G_IDX, G_NEU, G_BEKANNT, G_DATUM, G_NAME_NR, G_EIGENE_NR, G_DAUER, G_PFAD
# Gibt 0 bei Erfolg zurück, 1 bei Fehler.
function parse_daten_zeile() {
    local line="$1"
    local awk_output
    local G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD # Lokale Variablen

    # Verwende awk, um die Felder zu extrahieren und mit einem seltenen Zeichen (ETX) zu trennen
    awk_output=$(echo "$line" | awk 'BEGIN{FS="|"; OFS="\x03"} {print $1,$2,$3,$4,$5,$6,$7,$8}')
    if [[ $? -ne 0 ]]; then
        log_warn "AWK fehlgeschlagen beim Parsen der Zeile: $line"
        return 1
    fi

    # Lese die durch ETX getrennten Felder in die lokalen Variablen
    IFS=$'\x03' read -r G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD <<< "$awk_output"

    # Prüfe, ob der Index (wichtigstes Feld) gelesen wurde
    if [[ -z "$G_IDX" ]]; then
        log_warn "Index konnte nicht aus AWK-Output gelesen werden: $awk_output"
        # Setze Variablen explizit leer, um Seiteneffekte zu vermeiden
        G_IDX=""; G_NEU=""; G_BEKANNT=""; G_DATUM=""; G_NAME_NR=""; G_EIGENE_NR=""; G_DAUER=""; G_PFAD=""
        return 1
    fi

    # Rückgabe über globale Variablen (in aufrufender Funktion deklariert)
    return 0
}

# Holt und formatiert die Voicemail-Liste
# Gibt die formatierte Liste auf Stdout aus.
# Gibt bei Fehlern 1 zurück.
function list_voicemails_main() {
    # Funktionsargumente und lokale Variablen
    local sid="$1"
    local tam_idx="$2"
    local list_filter="$3"
    local list_format="$4"
    local output_file="$LIST_OUTPUT_FILE"
    local is_redirected=0
    local pure_output=0
    local data_url="${FRITZBOX_URL}/data.lua"
    local post_data="sid=${sid}&page=tam&xhr=1&tamidx=${tam_idx}&useajax=1&no_sidrenew=1"
    local response_html=""
    local curl_exit_code=0
    local messages=()
    local filtered_messages=()
    local formatted_output=""
    local output_buffer=""
    local counter=0
    # Globale Variablen für parse_daten_zeile (werden in der Funktion gesetzt)
    declare G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD

    # Prüft, ob Stdout (FD 1) kein Terminal ist
    if ! [ -t 1 ]; then
        is_redirected=1
    fi

    # Bestimme, ob "reine" Ausgabe benötigt wird
    if [[ -n "$output_file" || $is_redirected -eq 1 ]]; then
        pure_output=1
    fi
    if [[ $VERBOSE -eq 1 && $pure_output -eq 1 ]]; then
        log_debug "Reine Ausgabe aktiviert (Datei: '${output_file:-<keine>}', Umleitung erkannt: $is_redirected)."
    fi

    # --- Schritt 1: HTML von Fritz!Box holen ---
    log_ts "Rufe Voicemail-HTML von data.lua für TAM ${tam_idx} ab..."
    response_html=$(curl --connect-timeout 10 --max-time 20 -s \
                         -H "Content-Type: application/x-www-form-urlencoded" \
                         --data "$post_data" "$data_url")
    curl_exit_code=$?
    log_debug "curl Exit-Code: $curl_exit_code"
    if [[ $curl_exit_code -ne 0 ]]; then log_error "Verbindungsfehler zu data.lua."; return 1; fi
    if ! echo "$response_html" | grep -q 'id="uiTamCalls"'; then log_error "Unerwartete Antwort von data.lua."; return 1; fi

    # --- Schritt 2: HTML parsen ---
    log_ts "Übergebe HTML an Parser ($PARSER_SCRIPT)..."
    local parsed_output
    parsed_output=$(echo "$response_html" | "$PARSER_SCRIPT") # VERBOSE wird vererbt
    local parse_exit_code=$?
    if [[ $parse_exit_code -ne 0 ]]; then log_error "Parser fehlgeschlagen (Code: $parse_exit_code)."; return 1; fi

    # Das interne Format "pipe" gibt die Rohdaten direkt zurück
    if [[ "$list_format" == "pipe" ]]; then
        if [[ -n "$parsed_output" ]]; then printf "%s\n" "$parsed_output"; else printf ""; fi
        return 0
    fi

    # Für andere Formate: weiterverarbeiten
    if [[ -z "$parsed_output" ]] || ! echo "$parsed_output" | grep -q "|"; then
         if [[ $pure_output -eq 0 ]]; then echo "Keine Nachrichten gefunden."; else log_ts "Keine Nachrichten gefunden."; fi
         return 0
    fi
    mapfile -t messages < <(echo "$parsed_output")
    log_ts "${#messages[@]} Nachrichten vom Parser erhalten."

    # --- Schritt 3: Nachrichten filtern ---
    log_debug "Wende Filter '$list_filter' an..."
    filtered_messages=()
    case "$list_filter" in
        latest)
            if [[ ${#messages[@]} -gt 0 ]]; then
                filtered_messages+=("${messages[0]}")
            fi
            ;;
        all)
            filtered_messages=("${messages[@]}")
            ;;
        known)
            for msg in "${messages[@]}"; do
                if [[ "$(echo "$msg" | awk 'BEGIN{FS="|"}{print $3}')" == "Ja" ]]; then
                    filtered_messages+=("$msg")
                fi
            done
            ;;
        unknown)
            for msg in "${messages[@]}"; do
                if [[ "$(echo "$msg" | awk 'BEGIN{FS="|"}{print $3}')" == "Nein" ]]; then
                    filtered_messages+=("$msg")
                fi
            done
            ;;
        *)
            if [[ "$list_filter" =~ ^[0-9]+$ ]]; then
                local found=0
                for msg in "${messages[@]}"; do
                    if [[ "$(echo "$msg" | awk 'BEGIN{FS="|"}{print $1}')" == "$list_filter" ]]; then
                        filtered_messages+=("$msg")
                        found=1
                        break
                    fi
                done
                if [[ $found -eq 0 ]]; then log_error "Index '$list_filter' nicht gefunden."; return 1; fi
            else
                 log_error "Ungültiger Filter '$list_filter'."
                 return 1
            fi
            ;;
    esac # Ende Filter Case

    log_debug "${#filtered_messages[@]} Nachrichten nach Filterung."
    if [[ ${#filtered_messages[@]} -eq 0 ]]; then
        if [[ $pure_output -eq 0 ]]; then echo "Keine Nachrichten entsprechen Filter '$list_filter'."; fi
        return 0
    fi

    # --- Schritt 4: Ausgabe formatieren und sammeln ---
    output_buffer="" # Puffer leeren
    case "$list_format" in
        table)
            local header="Index|Neu?|Bekannt?|Datum/Zeit|Anrufer/Name|Eigene Nr.|Dauer|Pfad"
            local table_data=""
            for msg in "${filtered_messages[@]}"; do
                table_data+="${msg}\n"
            done
            local full_table_content
            full_table_content=$(printf "%s\n%b" "$header" "$table_data")

            if command -v column >/dev/null; then
                 output_buffer=$(echo -e "$full_table_content" | column -t -s '|')
            else
                 if [[ $pure_output -eq 0 ]]; then log_warn "'column' fehlt, Tabellenformatierung rudimentär."; fi
                 output_buffer="$full_table_content"
            fi

            if [[ $pure_output -eq 1 ]]; then
                formatted_output="$output_buffer"
            else
                local start="--- Voicemail-Liste (TAM ${tam_idx}, Filter: ${list_filter}) ---"
                local end="--- Ende Liste (Anzahl: ${#filtered_messages[@]}) ---"
                formatted_output=$(printf "%s\n%s\n%s" "$start" "$output_buffer" "$end")
            fi
            ;; # Ende table case

        json)
            if ! command -v jq &> /dev/null; then log_error "jq fehlt."; return 1; fi
            log_debug "[JSON Format] Generiere JSON..."
            output_buffer+="[\n"; local first=1; counter=0
            for msg in "${filtered_messages[@]}"; do
                ((counter++))
                if ! parse_daten_zeile "$msg"; then
                    log_warn "[JSON] Überspringe Zeile $counter: Parsing-Fehler."
                    continue
                fi
                if [[ $first -eq 0 ]]; then output_buffer+=",\n"; fi
                output_buffer+=$(printf "  {\n")
                output_buffer+=$(printf "    \"index\": %s,\n" "$(jq -n --arg s "${G_IDX:?}" '$s')")
                output_buffer+=$(printf "    \"neu\": %s,\n" "$( [[ "$G_NEU" == "Ja" ]] && echo true || echo false )")
                output_buffer+=$(printf "    \"bekannt\": %s,\n" "$( [[ "$G_BEKANNT" == "Ja" ]] && echo true || echo false )")
                output_buffer+=$(printf "    \"datum\": %s,\n" "$(jq -n --arg s "${G_DATUM:-?}" '$s')")
                output_buffer+=$(printf "    \"anrufer_name\": %s,\n" "$(jq -n --arg s "${G_NAME_NR:-N/A}" '$s')")
                output_buffer+=$(printf "    \"eigene_nr\": %s,\n" "$(jq -n --arg s "${G_EIGENE_NR:-?}" '$s')")
                output_buffer+=$(printf "    \"dauer\": %s,\n" "$(jq -n --arg s "${G_DAUER:-?}" '$s')")
                output_buffer+=$(printf "    \"pfad\": %s\n" "$(jq -n --arg s "${G_PFAD:-?}" '$s')")
                output_buffer+=$(printf "  }")
                first=0
            done
            output_buffer+="\n]"
            formatted_output="$output_buffer"
            log_debug "[JSON Format] Ende."
            ;; # Ende json case

        simple)
             log_debug "[Simple Format] Generiere simple..."; counter=0; output_buffer=""
             for msg in "${filtered_messages[@]}"; do
                 ((counter++))
                 if ! parse_daten_zeile "$msg"; then
                     log_warn "[Simple] Überspringe Zeile $counter: Parsing-Fehler."
                     continue
                 fi
                 output_buffer+=$(printf "%s: Neu=%s Bekannt=%s Datum=%s Von=%s EigeneNr=%s Dauer=%s Pfad=%s\n" \
                                         "${G_IDX:?}" "${G_NEU:?}" "${G_BEKANNT:?}" "${G_DATUM:?}" \
                                         "${G_NAME_NR:-N/A}" "${G_EIGENE_NR:?}" "${G_DAUER:?}" "${G_PFAD:?}")
             done
             formatted_output="$output_buffer" # Enthält Zeilenumbrüche
             log_debug "[Simple Format] Ende."
             ;; # Ende simple case

        csv)
             log_debug "[CSV Format] Generiere CSV..."; local csv_header="Index;Neu;Bekannt;Datum;AnruferNameNummer;EigeneNr;Dauer;Pfad"; output_buffer=""
             if [[ $pure_output -eq 0 ]]; then output_buffer+="${csv_header}"; output_buffer+=$'\n'; fi; counter=0
             for msg in "${filtered_messages[@]}"; do
                 ((counter++))
                 if ! parse_daten_zeile "$msg"; then log_warn "[CSV] Überspringe Zeile $counter: Parsing-Fehler."; continue; fi
                 local escaped_name_nr="\"${G_NAME_NR//\"/\"\"}\"" # Escaping
                 local csv_line=$(printf "%s;%s;%s;%s;%s;%s;%s;%s" "${G_IDX:?}" "${G_NEU:?}" "${G_BEKANNT:?}" "${G_DATUM:?}" "${escaped_name_nr}" "${G_EIGENE_NR:?}" "${G_DAUER:?}" "${G_PFAD:?}")
                 output_buffer+="${csv_line}"; output_buffer+=$'\n'; # Füge Zeile + Umbruch hinzu
             done
             formatted_output="$output_buffer" # Enthält Zeilenumbrüche
             log_debug "[CSV Format] Ende."
             ;; # Ende csv case

        *)
             log_error "Interner Fehler: Unbekanntes Format '$list_format'."
             return 1
             ;;
    esac # Ende Format Case

    # --- Schritt 5: Finale Ausgabe ---
    # Stelle sicher, dass die Ausgabe immer mit einem Zeilenumbruch endet.
    if [[ -n "$output_file" ]]; then
        log_ts "Schreibe Ausgabe -> $output_file"
        if ! printf "%s\n" "$formatted_output" > "$output_file"; then
            log_error "Fehler beim Schreiben in '$output_file'."
            if [[ $is_redirected -eq 0 ]]; then echo "Fehler, gebe hier aus:" >&2; printf "%s\n" "$formatted_output"; fi
            return 1
        fi
    else
        printf "%s\n" "$formatted_output"
    fi
    return 0
}

# Lädt eine oder alle Voicemail-Dateien herunter und konvertiert sie optional
function download_voicemail() {
    # Funktionsargumente und lokale Variablen
    local sid="$1"; local tam_idx="$2"; local msg_idx_filter="$3"; local output_target="$4"
    local audio_format_param="$AUDIO_FORMAT" # Hole globales Setting
    local download_script_path="/lua/photo.lua"
    local indices_to_download=() # Array leer initialisieren
    local final_filenames=()     # Array für die finalen Dateinamen
    local all_successful=true
    local total_files=0
    local i=0
    local final_ext="wav"         # Standard-Endung
    local convert_to_format=""    # Abgeleitetes Konvertierungsformat

    # --- Schritt 1: Indizes, Dateinamen und Konvertierungsformat bestimmen ---
    log_debug "Beginne Bestimmung der Indizes für Filter: $msg_idx_filter"

    # A) Bestimme das ZIELFORMAT (final_ext) und ob konvertiert werden muss (convert_to_format)
    if [[ -n "$audio_format_param" ]]; then
         # Explizites Format via --audio-format gegeben
         final_ext="$audio_format_param"
         if [[ "$final_ext" == "ogg" || "$final_ext" == "mp3" ]]; then convert_to_format="$final_ext"; log_debug "Zielformat explizit: '$final_ext', Konvertierung aktiv.";
         else convert_to_format=""; final_ext="wav"; log_debug "Zielformat explizit: '$final_ext', keine Konvertierung."; fi
    elif [[ "$msg_idx_filter" != "all" ]]; then
         # KEIN --audio-format, ABER spezifischer Index oder latest -> Endung von --output prüfen
         local target_ext_lower=$(echo "${output_target##*.}" | tr '[:upper:]' '[:lower:]')
         if [[ "$target_ext_lower" == "ogg" || "$target_ext_lower" == "mp3" ]]; then final_ext="$target_ext_lower"; convert_to_format="$final_ext"; log_debug "Zielformat aus Dateiendung '$output_target' -> '$final_ext', Konvertierung aktiv.";
         else final_ext="wav"; convert_to_format=""; if [[ "$output_target" != *.* ]]; then output_target+=".wav"; elif [[ "$target_ext_lower" != "wav" ]]; then log_warn "Unbekannte Endung '.$target_ext_lower', speichere als WAV."; output_target="${output_target%.*}.wav"; fi; log_debug "Kein Konvertierungsformat erkannt/angegeben. Zielformat: wav"; fi
    else # Fall: --download all OHNE --audio-format -> Standard WAV
         final_ext="wav"; convert_to_format=""; log_debug "Kein Konvertierungsformat für 'all' angegeben. Zielformat: wav"
    fi

    # Prüfe ffmpeg Abhängigkeit *nachdem* convert_to_format bestimmt wurde
    if [[ -n "$convert_to_format" ]] && ! command -v ffmpeg &> /dev/null; then log_error "'ffmpeg' wird für Konvertierung nach '$convert_to_format' benötigt."; return 1; fi

    # B) Bestimme Indizes und finale Dateinamen
    if [[ "$msg_idx_filter" == "all" ]]; then
        log_ts "Rufe Index-Liste für Download 'all' ab..."
        local pipe_lines=(); mapfile -t pipe_lines < <(list_voicemails_main "$sid" "$tam_idx" "all" "pipe"); if [[ $? -ne 0 ]] || [[ ${#pipe_lines[@]} -eq 0 ]]; then log_error "Nachrichtenliste für 'all' nicht abrufbar."; return 1; fi
        log_debug "${#pipe_lines[@]} Pipe-Zeilen erhalten."
        indices_to_download=(); log_debug "Beginne Index-Extraktion..."; for line in "${pipe_lines[@]}"; do local idx_part="${line%%|*}"; if [[ "$idx_part" =~ ^[0-9]+$ ]]; then indices_to_download+=("$idx_part"); else log_warn "Ignoriere Zeile: $line"; fi; done
        log_debug "Gefundene Indizes (${#indices_to_download[@]}): ${indices_to_download[*]}"
        if [[ ${#indices_to_download[@]} -eq 0 ]]; then log_error "Keine gültigen Indizes für 'all' extrahiert."; return 1; fi
        final_filenames=(); for index in "${indices_to_download[@]}"; do final_filenames+=("${output_target%/}/tam${tam_idx}_msg${index}.${final_ext}"); done # Nutze finale Endung
        total_files=${#indices_to_download[@]}; log_ts "Download von ${total_files} Dateien nach '$output_target' (Format: ${final_ext})."
        if ! mkdir -p "$output_target"; then log_error "Zielverzeichnis '$output_target' nicht erstellt."; return 1; fi

    elif [[ "$msg_idx_filter" == "latest" ]]; then
        log_ts "Ermittle Index für 'latest'..."; local latest_pipe_line; latest_pipe_line=$(list_voicemails_main "$sid" "$tam_idx" "latest" "pipe"); if [[ $? -ne 0 ]] || [[ -z "$latest_pipe_line" ]]; then log_error "Index für 'latest' nicht ermittelt."; return 1; fi
        local latest_idx; latest_idx=$(echo "$latest_pipe_line" | cut -d'|' -f1); if [[ -z "$latest_idx" ]]; then log_error "Index für 'latest' nicht extrahiert."; return 1; fi
        indices_to_download=("$latest_idx")
        final_filenames=("$output_target") # Name aus --output (ggf. korrigiert/angepasst)
        total_files=1; log_ts "Download neueste (Index $latest_idx) -> '${final_filenames[0]}'."

    else # Spezifischer Index
        indices_to_download=("$msg_idx_filter")
        final_filenames=("$output_target") # Name aus --output (ggf. korrigiert/angepasst)
        total_files=1; log_ts "Download Index ${msg_idx_filter} -> '${final_filenames[0]}'."
    fi

    # Finale Prüfung
    if [[ $total_files -eq 0 || ${#indices_to_download[@]} -eq 0 ]]; then log_error "Keine gültigen Indizes zum Download bestimmt."; return 1; fi
    log_debug "Anzahl zu ladender Dateien final: $total_files (${#indices_to_download[@]} Indizes im Array)."

    # --- Schritt 2: Download-Schleife ---
    TMP_DOWNLOAD_FILE=""; i=0
    log_debug "Vor der Download-Schleife: Indizes (${#indices_to_download[@]}): ${indices_to_download[*]}"
    log_debug "Vor der Download-Schleife: Zieldateinamen (${#final_filenames[@]}): ${final_filenames[*]}"

    for current_idx in "${indices_to_download[@]}"; do
        local final_filename="${final_filenames[$i]}"
        # Der Dateiname, unter dem die WAV *initial* immer gespeichert wird.
        local initial_wav_filename="${final_filename%.*}.wav"

        log_debug "--- Beginn Download-Schleife für Index: $current_idx ---"
        log_debug "Initialer WAV-Name: $initial_wav_filename"
        log_debug "Finaler Zielname:   $final_filename"

        if [[ -z "$initial_wav_filename" || -z "$final_filename" ]]; then log_error "Interner Fehler: Dateiname nicht bestimmbar (Index $i)."; all_successful=false; break; fi
        ((i++)) # Zähler erhöhen

        echo ""; log_ts "Verarbeite DL Index $current_idx -> '$final_filename' ($i/$total_files)..."

        # Direkte Pfad-Konstruktion MIT PADDING
        local padded_idx; padded_idx=$(printf "%03d" "$current_idx")
        local file_path_raw="/data/tam/rec/rec.${tam_idx}.${padded_idx}"; log_debug "Konstruierter interner Pfad (gepadded): $file_path_raw"

        # URL bauen & kodieren
        local file_path_encoded; if ! command -v jq &> /dev/null; then log_error "'jq' wird benötigt."; return 1; fi
        file_path_encoded=$(printf %s "$file_path_raw" | jq -sRr @uri)
        local download_url="${FRITZBOX_URL}/cgi-bin/luacgi_notimeout?sid=${sid}&script=${download_script_path}&myabfile=${file_path_encoded}"; log_debug "Download URL: $download_url"

        # Temporäre Datei erstellen & global speichern für Trap
        TMP_DOWNLOAD_FILE=$(mktemp --suffix=.wav); if [[ -z "$TMP_DOWNLOAD_FILE" ]]; then log_error "Temp-Datei nicht erstellt."; all_successful=false; continue; fi; log_debug "Temp-Datei: $TMP_DOWNLOAD_FILE"

        # Download mit curl
        log_ts "Starte Download via curl mit spezifischen Headern..."; local http_code
        local curl_opts=(-w "%{http_code}" -o "$TMP_DOWNLOAD_FILE" --connect-timeout 10 --max-time 300 -s --fail -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0" -H "Accept: audio/webm,audio/ogg,audio/wav,audio/*;q=0.9,application/ogg;q=0.7,video/*;q=0.6,*/*;q=0.5" -H "Accept-Language: de,en-US;q=0.7,en;q=0.3" -H "Range: bytes=0-" -H "Sec-Fetch-Dest: audio" -H "Sec-Fetch-Mode: no-cors" -H "Sec-Fetch-Site: same-origin" -H "Referer: ${FRITZBOX_URL}/")
        if [[ "$VERBOSE" -eq 1 ]]; then log_debug "Aktiviere curl verbose (-v) Ausgabe."; http_code=$(curl "${curl_opts[@]}" -v "$download_url" 2> >(sed 's/^/curl-stderr: /' >&2)); else http_code=$(curl "${curl_opts[@]}" "$download_url"); fi
        local curl_dl_exit_code=$?

        # Download-Prüfung
        if [[ $curl_dl_exit_code -ne 0 ]] || [[ ! -s "$TMP_DOWNLOAD_FILE" ]]; then
            log_error "Download Index $current_idx fehlgeschlagen."
            if [[ $curl_dl_exit_code -eq 0 ]]; then log_error "HTTP Status: $http_code, Dateigröße: $(wc -c < "$TMP_DOWNLOAD_FILE" 2>/dev/null || echo 0) Bytes."; else log_error "Curl Exit Code: $curl_dl_exit_code (HTTP: $http_code)."; if [[ $curl_dl_exit_code -eq 22 ]]; then log_error "HTTP Status war wahrscheinlich: $http_code"; fi; fi
            if [[ "$VERBOSE" -eq 1 ]]; then log_debug "Anfang der Datei '$TMP_DOWNLOAD_FILE':"; head -c 100 "$TMP_DOWNLOAD_FILE" >&2; echo "" >&2; fi
            all_successful=false; continue
        fi

        # Temporäre Datei zum *initialen* WAV-Ziel verschieben
        log_ts "Download Index $current_idx OK (HTTP $http_code)."
        mkdir -p "$(dirname "$initial_wav_filename")" # Sicherstellen, dass Verzeichnis existiert
        mv "$TMP_DOWNLOAD_FILE" "$initial_wav_filename";
        if [[ $? -ne 0 ]]; then log_error "Verschieben nach '$initial_wav_filename' fehlgeschlagen."; all_successful=false; continue; fi
        TMP_DOWNLOAD_FILE="" # WICHTIG: Variable leeren nach Erfolg!
        log_ts "Datei '$initial_wav_filename' initial gespeichert."

        # --- Konvertierung (wenn nötig) ---
        if [[ -n "$convert_to_format" ]]; then
             if [[ "$initial_wav_filename" == "$final_filename" ]]; then
                 log_debug "Initialer und finaler Dateiname sind identisch ('$final_filename'). Keine Konvertierung nötig."
             else
                 log_ts "Konvertiere '$initial_wav_filename' nach $convert_to_format -> '$final_filename'..."
                 local ffmpeg_cmd=(); local ffmpeg_rc=1 # Standardmäßig Fehler annehmen
                 case "$convert_to_format" in
                     ogg) ffmpeg_cmd=(ffmpeg -i "$initial_wav_filename" -c:a libvorbis -q:a 4 -ac 1 -vn -y "$final_filename");;
                     mp3) ffmpeg_cmd=(ffmpeg -i "$initial_wav_filename" -c:a libmp3lame -q:a 7 -ac 1 -vn -y "$final_filename");;
                     *) log_error "Interner Fehler: Format '$convert_to_format'"; ffmpeg_cmd=();;
                 esac
                 if [[ ${#ffmpeg_cmd[@]} -gt 0 ]]; then
                     log_debug "Führe aus: ${ffmpeg_cmd[*]}"
                     if [[ "$VERBOSE" -eq 1 ]]; then "${ffmpeg_cmd[@]}"; ffmpeg_rc=$?; else "${ffmpeg_cmd[@]}" >/dev/null 2>&1; ffmpeg_rc=$?; fi
                     if [[ $ffmpeg_rc -eq 0 ]]; then
                         log_ts "Konvertierung erfolgreich: '$final_filename' erstellt."
                         log_debug "Lösche '$initial_wav_filename'"; rm -f "$initial_wav_filename"
                     else
                         log_error "ffmpeg Konvertierung fehlgeschlagen (Code: $ffmpeg_rc) für '$initial_wav_filename'."
                         log_warn "Original WAV-Datei '$initial_wav_filename' bleibt erhalten."
                         all_successful=false
                     fi
                 fi # Ende if ffmpeg_cmd nicht leer
             fi # Ende Check if initial == final
        else
             log_debug "Keine Konvertierung nötig/angefordert."
             # Hier ist initial_wav_filename == final_filename
        fi # Ende if Konvertierung
        # -----------------------------------------
        log_debug "--- Ende Download-Schleife für Index: $current_idx ---"
    done # Ende Download-Schleife

    # --- Schritt 3: Ergebnis melden ---
    echo ""; if [[ "$all_successful" == true ]]; then log_ts "Alle Downloads und Konvertierungen erfolgreich."; return 0; else log_warn "Einige Downloads oder Konvertierungen sind fehlgeschlagen."; return 1; fi
}
# ==========================

# === Skriptstart ===
log_ts "Skript gestartet."

# --- Argumentenverarbeitung ---
if [[ $# -eq 0 ]]; then usage; exit 1; fi; ACTION=""; TAM_INDEX=$DEFAULT_TAM_INDEX; MESSAGE_INDEX=""; OUTPUT_FILENAME=""; LIST_FORMAT=$DEFAULT_LIST_FORMAT; LIST_FILTER="all"; VERBOSE=0; LIST_OUTPUT_FILE=""; AUDIO_FORMAT=""
while [[ $# -gt 0 ]]; do case "$1" in --list) ACTION="list"; shift; if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then LIST_FILTER="$1"; shift; fi ;; --download) ACTION="download"; shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--download: Index fehlt."; usage; exit 1; fi; MESSAGE_INDEX="$1"; shift ;; --output) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--output: Wert fehlt."; usage; exit 1; fi; OUTPUT_FILENAME="$1"; shift ;; --output-file) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--output-file: Dateiname fehlt."; usage; exit 1; fi; LIST_OUTPUT_FILE="$1"; shift ;; --format) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--format: Wert fehlt."; usage; exit 1; fi; if [[ "$1" != "table" && "$1" != "json" && "$1" != "simple" && "$1" != "csv" && "$1" != "pipe" ]]; then log_error "Ungültiges Format '$1'."; usage; exit 1; fi; LIST_FORMAT="$1"; shift ;; --tam) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--tam: Index fehlt."; usage; exit 1; fi; if ! [[ "$1" =~ ^[0-9]+$ ]]; then log_error "--tam: Index '$1' muss Zahl sein."; usage; exit 1; fi; TAM_INDEX="$1"; shift ;; --audio-format) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--audio-format: Format fehlt."; usage; exit 1; fi; if [[ "$1" != "wav" && "$1" != "ogg" && "$1" != "mp3" ]]; then log_error "Ungültiges Format für --audio-format: '$1'."; usage; exit 1; fi; AUDIO_FORMAT="$1"; shift ;; -v|--verbose) VERBOSE=1; shift ;; -h|--help) usage; exit 0 ;; *) log_error "Unbekannte Option '$1'."; usage; exit 1 ;; esac; done

# --- Validierung der Argumente ---
if [[ -z "$ACTION" ]]; then log_error "Aktion (--list/--download) fehlt."; usage; exit 1; fi
if [[ "$ACTION" == "download" && -n "$LIST_OUTPUT_FILE" ]]; then log_error "--output-file nicht mit --download kombinierbar."; usage; exit 1; fi
if [[ "$ACTION" == "list" && -n "$AUDIO_FORMAT" ]]; then log_error "--audio-format nicht mit --list kombinierbar."; usage; exit 1; fi

if [[ "$ACTION" == "download" ]]; then if [[ -z "$MESSAGE_INDEX" ]]; then log_error "--download: Index fehlt."; usage; exit 1; fi; if [[ -z "$OUTPUT_FILENAME" ]]; then log_error "--download: --output fehlt."; usage; exit 1; fi; if ! command -v jq &> /dev/null; then log_error "'jq' wird für --download benötigt."; exit 1; fi; if [[ "$MESSAGE_INDEX" == "all" && -e "$OUTPUT_FILENAME" && ! -d "$OUTPUT_FILENAME" ]]; then log_error "--output '$OUTPUT_FILENAME' muss Verzeichnis sein für 'all'."; exit 1; fi; if [[ "$MESSAGE_INDEX" != "all" && -d "$OUTPUT_FILENAME" ]]; then log_error "--output '$OUTPUT_FILENAME' darf kein Verzeichnis sein für '$MESSAGE_INDEX'."; exit 1; fi
elif [[ "$ACTION" == "list" ]]; then if [[ "$LIST_FORMAT" == "json" && ! -x "$(command -v jq)" ]]; then log_error "'jq' wird für '--format json' benötigt."; exit 1; fi; if [[ "$LIST_FORMAT" == "table" && ! -x "$(command -v column)" ]]; then log_warn "'column' nicht gefunden."; fi; fi
# ffmpeg Prüfung wird jetzt in download_voicemail gemacht
log_ts "Aktion: '$ACTION', TAM: '$TAM_INDEX', Filter: '$LIST_FILTER', Format: '$LIST_FORMAT', DL Index: '$MESSAGE_INDEX', DL Output: '$OUTPUT_FILENAME', List Output File: '$LIST_OUTPUT_FILE', Audio Format: '${AUDIO_FORMAT:-automatisch/wav}', Verbose: $VERBOSE"

# --- Abhängigkeitsprüfung ---
log_ts "Prüfe benötigte Werkzeuge..."; for cmd in curl md5sum iconv awk sed grep file; do if ! command -v $cmd &> /dev/null; then log_error "Werkzeug '$cmd' fehlt."; exit 1; fi; done; if ! grep -V | grep -q "GNU grep"; then log_warn "Kein GNU grep gefunden."; fi; log_ts "Kernwerkzeuge vorhanden."
# ========================

# === Hauptlogik ===
export VERBOSE # Mache Verbose-Status für Sub-Skripte/Funktionen verfügbar
creds_data=$(load_credentials "$CREDENTIALS_FILE"); if [[ $? -ne 0 ]]; then exit 1; fi; IFS='|' read -r FRITZBOX_URL FRITZBOX_USER FRITZBOX_PASSWORD <<< "$creds_data"
SID=$(get_sid "$FRITZBOX_URL" "$FRITZBOX_USER" "$FRITZBOX_PASSWORD"); if [[ $? -ne 0 ]]; then log_error "Fehler beim Holen der SID."; exit 1; fi

# Aktion ausführen
case "$ACTION" in
    list) if ! list_voicemails_main "$SID" "$TAM_INDEX" "$LIST_FILTER" "$LIST_FORMAT"; then log_error "Fehler beim Auflisten."; exit 1; fi ;;
    download) if ! download_voicemail "$SID" "$TAM_INDEX" "$MESSAGE_INDEX" "$OUTPUT_FILENAME"; then log_error "Fehler beim Download."; exit 1; fi ;;
    *) log_error "Interner Fehler: Unbekannte Aktion '$ACTION'."; exit 1 ;; # Sollte nicht passieren
esac

log_ts "Skript erfolgreich beendet."
exit 0 # Erfolgreicher Abschluss