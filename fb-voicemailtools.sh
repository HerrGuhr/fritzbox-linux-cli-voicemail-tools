#!/bin/bash

# fb-voicemailtools.sh
# Version: 1.36
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
#   - Sinnvolle Dateinamen für Downloads (JJJJMMTT_HHMM_Anrufer) mit UTF-8 Handling
# Autor: Marc Guhr
# Datum: 2025-04-07

# --- Locale auf UTF-8 setzen (wichtig für Tools wie sed, grep, awk) ---
export LC_ALL=C.UTF-8
# -----------------------------------------------------------------------

# === Standard-Konfiguration ===
DEFAULT_TAM_INDEX=0
DEFAULT_LIST_FORMAT="table"
SCRIPT_VERSION="1.36" # Korrektur: parse_daten_zeile setzt globale Variablen
# ============================

# === Globale Variablen ===
SCRIPT_NAME=$(basename "$0"); SCRIPT_DIR=$(dirname "$0")
CREDENTIALS_FILE="${SCRIPT_DIR}/fb-credentials"; LIB_SCRIPT="${SCRIPT_DIR}/fb_lib.sh"; PARSER_SCRIPT="${SCRIPT_DIR}/_parse_voicemail_html.sh"
FRITZBOX_URL=""; FRITZBOX_USER=""; FRITZBOX_PASSWORD=""; SID=""; VERBOSE=0; TMP_DOWNLOAD_FILE=""
ACTION=""; TAM_INDEX=$DEFAULT_TAM_INDEX; MESSAGE_INDEX=""; OUTPUT_FILENAME=""; LIST_OUTPUT_FILE=""; LIST_FORMAT=$DEFAULT_LIST_FORMAT; LIST_FILTER="all"; AUDIO_FORMAT=""
# ========================

# === Trap- und Cleanup-Funktionen ===
function cleanup() { local exit_code=$?; if [[ $exit_code -ne 130 ]]; then log_debug "Cleanup (Exit: $exit_code)..."; fi; if [[ -n "$FRITZBOX_URL" && -n "$SID" && "$SID" != "0000000000000000" ]]; then logout_sid "$FRITZBOX_URL" "$SID"; fi; if [[ -n "$TMP_DOWNLOAD_FILE" && -f "$TMP_DOWNLOAD_FILE" ]]; then log_debug "Entferne: $TMP_DOWNLOAD_FILE"; rm -f "$TMP_DOWNLOAD_FILE"; fi; if [[ $exit_code -ne 130 ]]; then exit $exit_code; fi; }
function cleanup_on_interrupt() { local terminal="/dev/tty"; if [ ! -w "$terminal" ]; then terminal="/dev/stderr"; fi; echo "" > "$terminal"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: Abbruch durch Benutzer (Strg+C)..." > "$terminal"; exit 130; }
trap cleanup_on_interrupt INT; trap cleanup EXIT

# --- Bibliotheks-Einbindung ---
if [[ -f "$LIB_SCRIPT" ]]; then source "$LIB_SCRIPT"; else echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: Lib '$LIB_SCRIPT' fehlt!" >&2; function log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: $@" >&2; }; function log_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $@" >&2; }; function log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: $@" >&2; }; function log_debug() { :; }; fi
# ============================


# === Funktionsdefinitionen ===

# Zeigt die Hilfe an
function usage() {
    echo "Verwendung: $SCRIPT_NAME <Aktion> [Optionen]"; echo ""
    echo "Aktionen:"; echo "  --list [Filter] (all,latest,index,known,unknown)"; echo "  --download <Index|all|latest>"; echo ""
    echo "Optionen:"; echo "  --output <Datei|Verz.>   Ziel für Download. Endung (.ogg/.mp3) bei index/latest"; echo "                           aktiviert Konvertierung. Bei Verz. für index/latest -> autom. Name."; echo "  --output-file <Datei>    Schreibt reine Listenausgabe in Datei."; echo "  --audio-format <FMT>   wav(Standard), ogg, mp3. Erzwingt Format, nötig für 'all'."; echo "  --tam <index>            AB-Index (Standard: ${DEFAULT_TAM_INDEX})."; echo "  --format <format>        Ausgabeformat für --list (table, json, simple, csv)."
    echo "  -v, --verbose            Aktiviert Debug-Ausgaben."; echo "  -h, --help               Zeigt diese Hilfe."; echo ""
    echo "Voraussetzungen: bash(v4+), curl, md5sum, iconv, awk, grep(GNU), sed, file, [jq, column, ffmpeg], ${CREDENTIALS_FILE}"; echo ""
    echo "Beispiele:"; echo "  $SCRIPT_NAME --list"; echo "  $SCRIPT_NAME --list --format csv > liste.csv"; echo "  $SCRIPT_NAME --download latest --output anruf.ogg"; echo "  $SCRIPT_NAME --download 5 --output /ablage/"; echo "  $SCRIPT_NAME --download all --output ./archiv/ --audio-format mp3"
}

# Parst eine Pipe-Zeile in globale Variablen G_*.
function parse_daten_zeile() {
    local line="$1"; local awk_output
    # Globale Variablen, KEINE lokale Deklaration hier!
    # declare G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD
    awk_output=$(echo "$line" | awk 'BEGIN{FS="|"; OFS="\x03"} {print $1,$2,$3,$4,$5,$6,$7,$8}'); if [[ $? -ne 0 ]]; then log_warn "AWK Fehler: $line"; return 1; fi
    IFS=$'\x03' read -r G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD <<< "$awk_output"; local read_rc=$?
    if [[ $read_rc -ne 0 ]] || [[ -z "$G_IDX" ]]; then log_warn "Read fehlgeschlagen (RC: $read_rc) oder Index leer: '$awk_output'"; G_IDX=""; G_NEU=""; G_BEKANNT=""; G_DATUM=""; G_NAME_NR=""; G_EIGENE_NR=""; G_DAUER=""; G_PFAD=""; return 1; fi
    return 0
}

# Bereinigt einen String für Dateinamen
function sanitize_filename() {
    local filename="$1"; filename=${filename//ä/ae}; filename=${filename//Ä/Ae}; filename=${filename//ö/oe}; filename=${filename//Ö/Oe}; filename=${filename//ü/ue}; filename=${filename//Ü/Ue}; filename=${filename//ß/ss}
    filename=$(echo "$filename" | sed -e 's/[^A-Za-z0-9._-]/_/g' -e 's/__*/_/g' -e 's/^[._]*//' -e 's/[._]*$//'); if [[ -z "$filename" ]]; then filename="Unbekannt"; fi; echo "$filename"
}

# Holt und formatiert die Voicemail-Liste
function list_voicemails_main() {
    local sid="$1"; local tam_idx="$2"; local list_filter="$3"; local list_format="$4"; local output_file="$LIST_OUTPUT_FILE"; local is_redirected=0; if ! [ -t 1 ]; then is_redirected=1; fi; local pure_output=0; if [[ -n "$output_file" || $is_redirected -eq 1 ]]; then pure_output=1; fi
    if [[ $VERBOSE -eq 1 && $pure_output -eq 1 ]]; then log_debug "Reine Ausgabe aktiviert."; fi
    local data_url="${FRITZBOX_URL}/data.lua"; local post_data="sid=${sid}&page=tam&xhr=1&tamidx=${tam_idx}&useajax=1&no_sidrenew=1"; local response_html=""; local messages=() filtered_messages=(); local formatted_output=""; local output_buffer=""; local counter=0; declare G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD

    log_ts "Rufe HTML für TAM ${tam_idx} ab..."; response_html=$(curl --connect-timeout 10 --max-time 20 -s -H "Content-Type: application/x-www-form-urlencoded" --data "$post_data" "$data_url"); local curl_rc=$?; log_debug "curl RC: $curl_rc"
    if [[ $curl_rc -ne 0 ]]; then log_error "Verbindungsfehler data.lua."; return 1; fi; if ! echo "$response_html" | grep -q 'id="uiTamCalls"'; then log_error "Unerwartete Antwort data.lua."; return 1; fi

    log_ts "Übergebe HTML an Parser..."; local parsed_output; parsed_output=$(echo "$response_html" | "$PARSER_SCRIPT"); local parse_rc=$?
    if [[ $parse_rc -ne 0 ]]; then log_error "Parser fehlgeschlagen (RC: $parse_rc)."; return 1; fi

    if [[ "$list_format" == "pipe" ]]; then if [[ -n "$parsed_output" ]]; then printf "%s\n" "$parsed_output"; else printf ""; fi; return 0; fi

    if [[ -z "$parsed_output" ]] || ! echo "$parsed_output" | grep -q "|"; then if [[ $pure_output -eq 0 ]]; then echo "Keine Nachrichten gefunden."; else log_ts "Keine Nachrichten gefunden."; fi; return 0; fi
    mapfile -t messages < <(echo "$parsed_output"); log_ts "${#messages[@]} Nachrichten erhalten."

    log_debug "Wende Filter '$list_filter' an..."; filtered_messages=()
    case "$list_filter" in latest) [[ ${#messages[@]} -gt 0 ]] && filtered_messages+=("${messages[0]}"); ;; all) filtered_messages=("${messages[@]}"); ;; known) for msg in "${messages[@]}"; do if [[ "$(echo "$msg" | awk 'BEGIN{FS="|"}{print $3}')" == "Ja" ]]; then filtered_messages+=("$msg"); fi; done ;; unknown) for msg in "${messages[@]}"; do if [[ "$(echo "$msg" | awk 'BEGIN{FS="|"}{print $3}')" == "Nein" ]]; then filtered_messages+=("$msg"); fi; done ;; *) if [[ "$list_filter" =~ ^[0-9]+$ ]]; then local found=0; for msg in "${messages[@]}"; do if [[ "$(echo "$msg" | awk 'BEGIN{FS="|"}{print $1}')" == "$list_filter" ]]; then filtered_messages+=("$msg"); found=1; break; fi; done; if [[ $found -eq 0 ]]; then log_error "Index '$list_filter' nicht gefunden."; return 1; fi; else log_error "Ungültiger Filter '$list_filter'."; return 1; fi ;; esac
    log_debug "${#filtered_messages[@]} Nachrichten nach Filterung."
    if [[ ${#filtered_messages[@]} -eq 0 ]]; then if [[ $pure_output -eq 0 ]]; then echo "Keine Nachrichten entsprechen Filter '$list_filter'."; fi; return 0; fi

    output_buffer=""; case "$list_format" in
        table) local header="Index|Neu?|Bekannt?|Datum/Zeit|Anrufer/Name|Eigene Nr.|Dauer|Pfad"; local table_data=""; for msg in "${filtered_messages[@]}"; do table_data+="${msg}\n"; done; local full_table_content=$(printf "%s\n%b" "$header" "$table_data"); if command -v column >/dev/null; then output_buffer=$(echo -e "$full_table_content" | column -t -s '|'); else if [[ $pure_output -eq 0 ]]; then log_warn "'column' fehlt."; fi; output_buffer="$full_table_content"; fi; if [[ $pure_output -eq 1 ]]; then formatted_output="$output_buffer"; else local start="--- Voicemail-Liste (TAM ${tam_idx}, Filter: ${list_filter}) ---"; local end="--- Ende Liste (Anzahl: ${#filtered_messages[@]}) ---"; formatted_output=$(printf "%s\n%s\n%s" "$start" "$output_buffer" "$end"); fi ;;
        json) if ! command -v jq &> /dev/null; then log_error "jq fehlt."; return 1; fi; log_debug "[JSON] Generiere..."; output_buffer+="[\n"; local first=1; counter=0; for msg in "${filtered_messages[@]}"; do ((counter++)); if ! parse_daten_zeile "$msg"; then log_warn "[JSON] Überspringe Zeile $counter"; continue; fi; if [[ $first -eq 0 ]]; then output_buffer+=",\n"; fi; output_buffer+=$(printf "  {\n"); output_buffer+=$(printf "    \"index\": %s,\n" "$(jq -n --arg s "$G_IDX" '$s')"); output_buffer+=$(printf "    \"neu\": %s,\n" "$( [[ "$G_NEU" == "Ja" ]] && echo true || echo false )"); output_buffer+=$(printf "    \"bekannt\": %s,\n" "$( [[ "$G_BEKANNT" == "Ja" ]] && echo true || echo false )"); output_buffer+=$(printf "    \"datum\": %s,\n" "$(jq -n --arg s "$G_DATUM" '$s')"); output_buffer+=$(printf "    \"anrufer_name\": %s,\n" "$(jq -n --arg s "$G_NAME_NR" '$s')"); output_buffer+=$(printf "    \"eigene_nr\": %s,\n" "$(jq -n --arg s "$G_EIGENE_NR" '$s')"); output_buffer+=$(printf "    \"dauer\": %s,\n" "$(jq -n --arg s "$G_DAUER" '$s')"); output_buffer+=$(printf "    \"pfad\": %s\n" "$(jq -n --arg s "$G_PFAD" '$s')"); output_buffer+=$(printf "  }"); first=0; done; output_buffer+="\n]"; formatted_output="$output_buffer"; log_debug "[JSON] Ende." ;;
        simple) log_debug "[Simple] Generiere..."; counter=0; output_buffer=""; for msg in "${filtered_messages[@]}"; do ((counter++)); if ! parse_daten_zeile "$msg"; then log_warn "[Simple] Überspringe Zeile $counter"; continue; fi; output_buffer+=$(printf "%s: Neu=%s Bekannt=%s Datum=%s Von=%s EigeneNr=%s Dauer=%s Pfad=%s\n" "$G_IDX" "$G_NEU" "$G_BEKANNT" "$G_DATUM" "${G_NAME_NR:-N/A}" "$G_EIGENE_NR" "$G_DAUER" "$G_PFAD"); done; formatted_output="$output_buffer"; log_debug "[Simple] Ende." ;;
        csv) log_debug "[CSV] Generiere..."; local csv_header="Index;Neu;Bekannt;Datum;AnruferNameNummer;EigeneNr;Dauer;Pfad"; output_buffer=""; if [[ $pure_output -eq 0 ]]; then output_buffer+="${csv_header}"; output_buffer+=$'\n'; fi; counter=0; for msg in "${filtered_messages[@]}"; do ((counter++)); if ! parse_daten_zeile "$msg"; then log_warn "[CSV] Überspringe Zeile $counter"; continue; fi; local escaped_name_nr="\"${G_NAME_NR//\"/\"\"}\""; local csv_line=$(printf "%s;%s;%s;%s;%s;%s;%s;%s" "$G_IDX" "$G_NEU" "$G_BEKANNT" "$G_DATUM" "$escaped_name_nr" "$G_EIGENE_NR" "$G_DAUER" "$G_PFAD"); output_buffer+="${csv_line}"; output_buffer+=$'\n'; done; formatted_output="$output_buffer"; log_debug "[CSV] Ende." ;;
        *) log_error "Interner Fehler: Format '$list_format'."; return 1 ;;
    esac
    if [[ -n "$output_file" ]]; then log_ts "Schreibe -> $output_file"; if ! printf "%s\n" "$formatted_output" > "$output_file"; then log_error "Fehler beim Schreiben: '$output_file'."; if [[ $is_redirected -eq 0 ]]; then echo "Fehler, gebe hier aus:" >&2; printf "%s\n" "$formatted_output"; fi; return 1; fi; else printf "%s\n" "$formatted_output"; fi
    return 0
}

# Lädt eine oder alle Voicemail-Dateien herunter und konvertiert sie optional
function download_voicemail() {
    local sid="$1"; local tam_idx="$2"; local msg_idx_filter="$3"; local output_target="$4"
    local audio_format_param="$AUDIO_FORMAT"; local download_script_path="/lua/photo.lua"
    local messages_data=(); local final_filenames=(); local all_successful=true
    local total_files=0; local i=0; local final_ext="wav"; local convert_to_format=""
    declare G_IDX G_NEU G_BEKANNT G_DATUM G_NAME_NR G_EIGENE_NR G_DAUER G_PFAD # Für parse_daten_zeile

    # --- Schritt 1: Nachrichtenliste holen ---
    log_ts "Rufe Nachrichtenliste (Rohdaten) vom Parser ab..."
    local response_html; response_html=$(curl --connect-timeout 10 --max-time 20 -s -H "Content-Type: application/x-www-form-urlencoded" --data "sid=${sid}&page=tam&xhr=1&tamidx=${tam_idx}&useajax=1&no_sidrenew=1" "${FRITZBOX_URL}/data.lua"); local curl_rc=$?
    if [[ $curl_rc -ne 0 ]] || ! echo "$response_html" | grep -q 'id="uiTamCalls"'; then log_error "HTML nicht abrufbar (RC: $curl_rc)."; return 1; fi
    mapfile -t messages_data < <(echo "$response_html" | "$PARSER_SCRIPT"); local parse_rc=$?; if [[ $parse_rc -ne 0 ]] || [[ ${#messages_data[@]} -eq 0 ]]; then log_error "Keine Daten vom Parser (RC: $parse_rc)."; return 1; fi
    log_ts "${#messages_data[@]} Nachrichten-Rohdaten erhalten."

    # --- Schritt 2: Konvertierungsformat bestimmen ---
    if [[ -n "$audio_format_param" ]]; then final_ext="$audio_format_param"; if [[ "$final_ext" == "ogg" || "$final_ext" == "mp3" ]]; then convert_to_format="$final_ext"; log_debug "Zielformat explizit: '$final_ext'"; else convert_to_format=""; final_ext="wav"; log_debug "Zielformat explizit: '$final_ext', keine Konv."; fi
    elif [[ "$msg_idx_filter" != "all" ]] && ! [[ -d "$output_target" ]]; then local target_ext_lower=$(echo "${output_target##*.}" | tr '[:upper:]' '[:lower:]'); if [[ "$target_ext_lower" == "ogg" || "$target_ext_lower" == "mp3" ]]; then final_ext="$target_ext_lower"; convert_to_format="$final_ext"; log_debug "Zielformat aus Endung: '$final_ext'"; else final_ext="wav"; convert_to_format=""; if [[ "$output_target" != *.* ]]; then output_target+=".wav"; elif [[ "$target_ext_lower" != "wav" ]]; then log_warn "Unbekannte Endung '.$target_ext_lower', -> WAV."; output_target="${output_target%.*}.wav"; fi; log_debug "Zielformat: wav"; fi
    else if [[ -z "$audio_format_param" ]]; then final_ext="wav"; convert_to_format=""; log_debug "Zielformat: wav (Standard für Verzeichnis/all)"; fi; fi
    if [[ -n "$convert_to_format" ]] && ! command -v ffmpeg &> /dev/null; then log_error "'ffmpeg' benötigt für '$convert_to_format'."; return 1; fi

    # --- Schritt 3: Zu bearbeitende Nachrichten filtern und Dateinamen generieren ---
    local target_messages=(); final_filenames=()
    log_debug "Filtere Nachrichten und generiere Dateinamen (Filter: '$msg_idx_filter')..."; counter=0
    for msg_line in "${messages_data[@]}"; do
        if ! parse_daten_zeile "$msg_line"; then log_warn "Überspringe Zeile (Filter/Name): $msg_line"; continue; fi; local current_idx_filter="$G_IDX"
        local match=0; case "$msg_idx_filter" in all) match=1 ;; latest) if [[ ${#target_messages[@]} -eq 0 ]]; then match=1; fi ;; *) if [[ "$current_idx_filter" == "$msg_idx_filter" ]]; then match=1; fi ;; esac
        if [[ $match -eq 1 ]]; then
            target_messages+=("$msg_line")
            local current_target_filename=""
            if [[ "$msg_idx_filter" == "all" ]] || [[ -d "$output_target" ]]; then
                 local date_part=$(echo "$G_DATUM" | grep -oP '^\d{2}\.\d{2}\.\d{2}'); local time_part=$(echo "$G_DATUM" | grep -oP '\d{2}:\d{2}$')
                 local year="20${date_part:6:2}"; local month="${date_part:3:2}"; local day="${date_part:0:2}"; local hour="${time_part:0:2}"; local minute="${time_part:3:2}"; local timestamp="${year}${month}${day}_${hour}${minute}"
                 local safe_caller=$(sanitize_filename "${G_NAME_NR:-Unbekannt_$G_IDX}"); local base_filename="${timestamp}_${safe_caller}"
                 current_target_filename="${output_target%/}/${base_filename}.${final_ext}"
            else current_target_filename="$output_target"; fi # Expliziter Name
            final_filenames+=("$current_target_filename")
            if [[ "$msg_idx_filter" != "all" ]]; then break; fi
        fi
    done
    total_files=${#target_messages[@]}
    if [[ $total_files -eq 0 || ${#final_filenames[@]} -ne $total_files ]]; then log_error "Fehler: Dateianzahl stimmt nicht (${#final_filenames[@]} vs ${total_files}). Filter: '$msg_idx_filter'."; return 1; fi
    log_ts "Verarbeite ${total_files} Nachrichten..."; log_debug "Finale Dateinamen (${#final_filenames[@]}):"; if [[ $VERBOSE -eq 1 ]]; then printf "  %s\n" "${final_filenames[@]}" >&2; fi

    # --- Schritt 4: Download-Schleife ---
    TMP_DOWNLOAD_FILE=""; i=0
    log_debug "Vor der Download-Schleife: Iteriere über ${#target_messages[@]} Nachrichten..."

    for current_msg_line in "${target_messages[@]}"; do
        # Parse die aktuelle Zeile, um G_PFAD und G_IDX für diese Iteration zu setzen
        if ! parse_daten_zeile "$current_msg_line"; then
             log_warn "Überspringe Download für ungültige Zeile: $current_msg_line"
             ((i++)); all_successful=false; continue # Wichtig: i erhöhen!
        fi
        local current_idx="$G_IDX"
        local file_path_raw="$G_PFAD"
        local final_filename="${final_filenames[$i]}"
        local initial_wav_filename="${final_filename%.*}.wav"

        log_debug "--- Beginn DL Schleife: Index=$current_idx ---"
        log_debug "Initial WAV: $initial_wav_filename"
        log_debug "Final Ziel:  $final_filename"
        log_debug "Interner Pfad: $file_path_raw"

        # Prüfung auf leere Variablen
        if [[ -z "$final_filename" || -z "$file_path_raw" || -z "$current_idx" ]]; then
            log_error "Interner Fehler: Infos unvollständig (Index '$current_idx', Pfad '$file_path_raw', Ziel '$final_filename'). Überspringe."
            all_successful=false; ((i++)); continue # Wichtig: i erhöhen!
        fi
        ((i++)) # Zähler erhöhen

        echo ""; log_ts "Verarbeite DL Index $current_idx -> '$final_filename' ($i/$total_files)..."

        # URL bauen & kodieren
        local file_path_encoded; if ! command -v jq &> /dev/null; then log_error "'jq' fehlt."; return 1; fi
        file_path_encoded=$(printf %s "$file_path_raw" | jq -sRr @uri)
        local download_url="${FRITZBOX_URL}/cgi-bin/luacgi_notimeout?sid=${sid}&script=${download_script_path}&myabfile=${file_path_encoded}"; log_debug "DL URL: $download_url"

        # Temporäre Datei erstellen & global speichern für Trap
        TMP_DOWNLOAD_FILE=$(mktemp --suffix=.wav); if [[ -z "$TMP_DOWNLOAD_FILE" ]]; then log_error "Temp-Datei nicht erstellt."; all_successful=false; continue; fi; log_debug "Temp-Datei: $TMP_DOWNLOAD_FILE"

        # Download mit curl
        log_ts "Starte Download via curl..."; local http_code
        local curl_opts=(-w "%{http_code}" -o "$TMP_DOWNLOAD_FILE" --connect-timeout 10 --max-time 300 -s --fail -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0" -H "Accept: audio/webm,audio/ogg,audio/wav,audio/*;q=0.9,application/ogg;q=0.7,video/*;q=0.6,*/*;q=0.5" -H "Accept-Language: de,en-US;q=0.7,en;q=0.3" -H "Range: bytes=0-" -H "Sec-Fetch-Dest: audio" -H "Sec-Fetch-Mode: no-cors" -H "Sec-Fetch-Site: same-origin" -H "Referer: ${FRITZBOX_URL}/")
        if [[ "$VERBOSE" -eq 1 ]]; then log_debug "Aktiviere curl -v."; http_code=$(curl "${curl_opts[@]}" -v "$download_url" 2> >(sed 's/^/curl-stderr: /' >&2)); else http_code=$(curl "${curl_opts[@]}" "$download_url"); fi; local curl_rc=$?

        # Download-Prüfung
        if [[ $curl_rc -ne 0 ]] || [[ ! -s "$TMP_DOWNLOAD_FILE" ]]; then log_error "DL Index $current_idx fehlgeschlagen."; if [[ $curl_rc -eq 0 ]]; then log_error "HTTP: $http_code, Size: $(wc -c < "$TMP_DOWNLOAD_FILE" 2>/dev/null||echo 0)."; else log_error "Curl RC: $curl_rc (HTTP: $http_code)."; if [[ $curl_rc -eq 22 ]]; then log_error "HTTP war wahrsch.: $http_code"; fi; fi; if [[ "$VERBOSE" -eq 1 ]]; then log_debug "Datei '$TMP_DOWNLOAD_FILE':"; head -c 100 "$TMP_DOWNLOAD_FILE" >&2; echo "" >&2; fi; all_successful=false; continue; fi

        # Temporäre Datei zum *initialen* WAV-Ziel verschieben
        log_ts "DL Index $current_idx OK (HTTP $http_code)."
        mkdir -p "$(dirname "$initial_wav_filename")"; mv "$TMP_DOWNLOAD_FILE" "$initial_wav_filename"; if [[ $? -ne 0 ]]; then log_error "mv nach '$initial_wav_filename' fehlgeschlagen."; all_successful=false; continue; fi
        TMP_DOWNLOAD_FILE=""; log_ts "Datei '$initial_wav_filename' initial gespeichert."

        # --- Konvertierung (wenn nötig) ---
        if [[ -n "$convert_to_format" ]]; then
             if [[ "$initial_wav_filename" == "$final_filename" ]]; then log_debug "Keine Konvertierung nötig.";
             else log_ts "Konvertiere -> $convert_to_format ('$final_filename')..."; local ffmpeg_cmd=(); local ffmpeg_rc=1; case "$convert_to_format" in ogg) ffmpeg_cmd=(ffmpeg -i "$initial_wav_filename" -c:a libvorbis -q:a 4 -ac 1 -vn -y "$final_filename");; mp3) ffmpeg_cmd=(ffmpeg -i "$initial_wav_filename" -c:a libmp3lame -q:a 7 -ac 1 -vn -y "$final_filename");; esac
                 if [[ ${#ffmpeg_cmd[@]} -gt 0 ]]; then log_debug "Führe aus: ${ffmpeg_cmd[*]}"; if [[ "$VERBOSE" -eq 1 ]]; then "${ffmpeg_cmd[@]}"; ffmpeg_rc=$?; else "${ffmpeg_cmd[@]}" >/dev/null 2>&1; ffmpeg_rc=$?; fi
                     if [[ $ffmpeg_rc -eq 0 ]]; then log_ts "Konvertierung OK: '$final_filename'."; log_debug "Lösche '$initial_wav_filename'"; rm -f "$initial_wav_filename"; else log_error "ffmpeg fehlgeschlagen (RC: $ffmpeg_rc)."; log_warn "Original WAV '$initial_wav_filename' bleibt."; all_successful=false; fi
                 fi; fi
        else log_debug "Keine Konvertierung angefordert."; fi
        log_debug "--- Ende DL Schleife: Index=$current_idx ---"
    done # Ende Download-Schleife

    # --- Schritt 5: Ergebnis melden ---
    echo ""; if [[ "$all_successful" == true ]]; then log_ts "Alle Downloads/Konvertierungen erfolgreich."; return 0; else log_warn "Einige Downloads/Konvertierungen fehlgeschlagen."; return 1; fi
}
# ==========================

# === Skriptstart ===
log_ts "Skript gestartet."

# --- Argumentenverarbeitung ---
if [[ $# -eq 0 ]]; then usage; exit 1; fi
ACTION=""; TAM_INDEX=$DEFAULT_TAM_INDEX; MESSAGE_INDEX=""; OUTPUT_FILENAME=""
LIST_FORMAT=$DEFAULT_LIST_FORMAT; LIST_FILTER="all"; VERBOSE=0; LIST_OUTPUT_FILE=""; AUDIO_FORMAT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            ACTION="list"; shift
            if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then LIST_FILTER="$1"; shift; fi
            ;;
        --download)
            ACTION="download"; shift
            if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--download: Index fehlt."; usage; exit 1; fi
            MESSAGE_INDEX="$1"; shift
            ;;
        --output)
            shift
            if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--output: Wert fehlt."; usage; exit 1; fi
            OUTPUT_FILENAME="$1"; shift
            ;;
        --output-file)
            shift
            if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--output-file: Dateiname fehlt."; usage; exit 1; fi
            LIST_OUTPUT_FILE="$1"; shift
            ;;
        --format)
            shift
            if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--format: Wert fehlt."; usage; exit 1; fi
            if [[ "$1" != "table" && "$1" != "json" && "$1" != "simple" && "$1" != "csv" && "$1" != "pipe" ]]; then log_error "Ungültiges Format '$1'."; usage; exit 1; fi
            LIST_FORMAT="$1"; shift
            ;;
        --tam)
            shift
            if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--tam: Index fehlt."; usage; exit 1; fi
            if ! [[ "$1" =~ ^[0-9]+$ ]]; then log_error "--tam: Index '$1' muss Zahl sein."; usage; exit 1; fi
            TAM_INDEX="$1"; shift
            ;;
        --audio-format)
            shift
            if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--audio-format: Format fehlt."; usage; exit 1; fi
            if [[ "$1" != "wav" && "$1" != "ogg" && "$1" != "mp3" ]]; then log_error "Ungültiges Format für --audio-format: '$1'."; usage; exit 1; fi
            AUDIO_FORMAT="$1"; shift
            ;;
        -v|--verbose)
            VERBOSE=1; shift
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            log_error "Unbekannte Option '$1'."
            usage; exit 1
            ;;
    esac
done

# --- Validierung der Argumente ---
if [[ -z "$ACTION" ]]; then log_error "Aktion fehlt."; usage; exit 1; fi
if [[ "$ACTION" == "download" && -n "$LIST_OUTPUT_FILE" ]]; then log_error "--output-file nicht mit --download."; usage; exit 1; fi
if [[ "$ACTION" == "list" && -n "$AUDIO_FORMAT" ]]; then log_error "--audio-format nicht mit --list."; usage; exit 1; fi

if [[ "$ACTION" == "download" ]]; then
    if [[ -z "$MESSAGE_INDEX" ]]; then log_error "--download: Index fehlt."; usage; exit 1; fi
    if [[ -z "$OUTPUT_FILENAME" ]]; then log_error "--download: --output fehlt."; usage; exit 1; fi
    if ! command -v jq &> /dev/null; then log_error "'jq' fehlt."; exit 1; fi
    if [[ "$MESSAGE_INDEX" == "all" && -e "$OUTPUT_FILENAME" && ! -d "$OUTPUT_FILENAME" ]]; then log_error "--output muss Verzeichnis sein für 'all'."; exit 1; fi
    # Prüfung für Einzeldownload Verzeichnis entfernt -> erlaubt
elif [[ "$ACTION" == "list" ]]; then
    if [[ "$LIST_FORMAT" == "json" && ! -x "$(command -v jq)" ]]; then log_error "'jq' fehlt für '--format json'."; exit 1; fi
    if [[ "$LIST_FORMAT" == "table" && ! -x "$(command -v column)" ]]; then log_warn "'column' nicht gefunden."; fi
fi
log_ts "Aktion: '$ACTION', TAM: '$TAM_INDEX', Filter: '$LIST_FILTER', Format: '$LIST_FORMAT', DL Index: '$MESSAGE_INDEX', DL Output: '$OUTPUT_FILENAME', List Output File: '$LIST_OUTPUT_FILE', Audio Format: '${AUDIO_FORMAT:-automatisch/wav}', Verbose: $VERBOSE"

# --- Abhängigkeitsprüfung ---
log_ts "Prüfe Kernwerkzeuge..."; for cmd in curl md5sum iconv awk sed grep file; do if ! command -v $cmd &> /dev/null; then log_error "Werkzeug '$cmd' fehlt."; exit 1; fi; done; if ! grep -V | grep -q "GNU grep"; then log_warn "Kein GNU grep gefunden."; fi; log_ts "Kernwerkzeuge vorhanden."
# ========================

# === Hauptlogik ===
export VERBOSE
creds_data=$(load_credentials "$CREDENTIALS_FILE"); if [[ $? -ne 0 ]]; then exit 1; fi
IFS='|' read -r FRITZBOX_URL FRITZBOX_USER FRITZBOX_PASSWORD <<< "$creds_data"

log_ts "Hole Session ID..."
SID=$(get_sid "$FRITZBOX_URL" "$FRITZBOX_USER" "$FRITZBOX_PASSWORD")
if [[ $? -ne 0 ]]; then log_error "Fehler beim Holen der SID."; exit 1; fi

log_ts "Führe Aktion '$ACTION' aus..."
case "$ACTION" in
    list)
        if ! list_voicemails_main "$SID" "$TAM_INDEX" "$LIST_FILTER" "$LIST_FORMAT"; then log_error "Fehler beim Auflisten."; exit 1; fi
        ;;
    download)
        if ! download_voicemail "$SID" "$TAM_INDEX" "$MESSAGE_INDEX" "$OUTPUT_FILENAME"; then log_error "Fehler beim Download."; exit 1; fi
        ;;
    *)
        log_error "Interner Fehler: Aktion '$ACTION'."
        exit 1
        ;;
esac

log_ts "Skript erfolgreich beendet."
exit 0