#!/bin/bash

# ==============================================================================
# fritzbox-voicemail-tools.sh - Voicemails von AVM Fritz!Box auflisten/herunterladen
#
# Version:      2.00
# Author:       Marc Guhr <marc.guhr@gmail.com>
# Repository:   https://github.com/HerrGuhr/fritzbox-voicemail-tools
# Lizenz:       MIT License
# Datum:        2025-04-09
#
# Beschreibung: Dieses Skript interagiert mit einer AVM Fritz!Box über das
#               TR-064 Protokoll (via SOAP und nachfolgendem XML-Abruf),
#               um Voicemail-Nachrichten aufzulisten und herunterzuladen.
#               Es nutzt Standard-Linux-Tools und ist für die Kommandozeile
#               konzipiert.
#
# ==============================================================================

# --- Globale Einstellungen ---
# Setzt die Locale auf UTF-8, um Probleme mit Sonderzeichen zu vermeiden.
# Dies ist wichtig für die korrekte Verarbeitung von Anrufernamen etc.
export LC_ALL=C.UTF-8

# === Standard-Konfiguration ===
# Diese Werte werden verwendet, wenn keine entsprechenden Optionen übergeben werden.
DEFAULT_TAM_INDEX=0        # Standard-Index des Anrufbeantworters (0 = erster AB)
DEFAULT_LIST_FORMAT="table" # Standard-Ausgabeformat für --list
SCRIPT_VERSION="2.00"      # Aktuelle Skriptversion

# === Globale Variablen ===
# Diese Variablen speichern den Skript-Zustand und Konfigurationswerte.
SCRIPT_NAME=$(basename "$0")    # Name des Skripts (z.B. "fritzbox-voicemail-tools.sh")
SCRIPT_DIR=$(dirname "$0")      # Verzeichnis, in dem das Skript liegt
CREDENTIALS_FILE="${SCRIPT_DIR}/fb-credentials" # Pfad zur Anmeldedatei

# Fritz!Box Verbindungsdaten (werden aus CREDENTIALS_FILE geladen)
FRITZBOX_URL=""
FRITZBOX_TR064_USER=""
FRITZBOX_TR064_PASS=""
VOICEMAIL_LIST_URL="" # URL zur XML-Liste (wird dynamisch per TR-064 geholt)

# Skript-Optionen / Statusvariablen (werden durch Argumentenverarbeitung gesetzt)
VERBOSE=0               # Verbosity Level: 0=Silent(Warn/Err), 1=Info/Debug, 2=Detail, 3=Silly
TMP_DOWNLOAD_FILE=""    # Pfad zur temporären Download-Datei (für Cleanup)
ACTION=""               # Hauptaktion (--list oder --download)
TAM_INDEX=$DEFAULT_TAM_INDEX # Zu verwendender AB-Index
MESSAGE_INDEX=""        # Index für Download (Zahl, 'all', 'latest')
OUTPUT_FILENAME=""      # Ziel für Download (--output)
LIST_OUTPUT_FILE=""     # Zieldatei für reine Listenausgabe (--output-file)
LIST_FORMAT=$DEFAULT_LIST_FORMAT # Ausgabeformat für --list
LIST_FILTER="all"       # Filter für --list
AUDIO_FORMAT=""         # Ziel-Audioformat für Konvertierung (--audio-format)

# ========================
# === Logging Funktionen ===
# ========================
# Diese Funktionen steuern die Ausgabe von Meldungen auf stderr,
# abhängig vom eingestellten Verbosity-Level (-v, -vv, -vvv).
# WARN und ERROR werden immer angezeigt.

# Gibt INFO-Meldungen aus. Erfordert Level >= 1 (-v).
# $@: Die Nachricht
log_ts() {
    [[ $VERBOSE -ge 1 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $@" >&2
}

# Gibt WARN-Meldungen aus. Wird immer angezeigt.
# $@: Die Warnmeldung
log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: $@" >&2
}

# Gibt FEHLER-Meldungen aus. Wird immer angezeigt.
# $@: Die Fehlermeldung
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: $@" >&2
}

# Gibt Basis-DEBUG-Meldungen aus. Erfordert Level >= 1 (-v).
# $@: Die Debug-Nachricht
log_debug() {
    [[ $VERBOSE -ge 1 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $@" >&2
}

# Gibt detailliertere DEBUG-Meldungen aus. Erfordert Level >= 2 (-vv).
# $@: Die Detail-Debug-Nachricht
log_debug_detail() {
    [[ $VERBOSE -ge 2 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DETAIL: $@" >&2
}

# Gibt sehr detaillierte ("Silly") DEBUG-Meldungen aus. Erfordert Level >= 3 (-vvv).
# $@: Die Silly-Debug-Nachricht
log_debug_silly() {
    [[ $VERBOSE -ge 3 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SILLY: $@" >&2
}

# Gibt den Inhalt einer Variablen als Bytedump (od -c) aus. Erfordert Level >= 3 (-vvv).
# Wird verwendet, um nicht-druckbare Zeichen sichtbar zu machen.
# $1: Titel für die Ausgabe
# $2: Der String/die Variable, deren Inhalt angezeigt werden soll
log_debug_od() {
    [[ $VERBOSE -ge 3 ]] || return 0 # Nur bei -vvv
    local title="$1"
    shift # Restliche Argumente sind der String
    log_debug_silly "$title"
    echo "--- START od -c ---" >&2
    echo -nE "$@" | od -c >&2 # -n: kein Newline, -E: keine Backslash-Interpretation
    echo "--- END od -c ---" >&2
}

# ===================================
# === Trap- und Cleanup-Funktionen ===
# ===================================

# Wird bei Skriptende (normal oder Fehler) via 'trap cleanup EXIT' aufgerufen.
# Räumt temporäre Dateien auf.
cleanup() {
    local exit_code=$? # Exit-Code des Skripts speichern
    # Nur loggen, wenn es kein Abbruch durch Benutzer war (Exit Code 130)
    if [[ $exit_code -ne 130 ]]
    then
        log_debug "Cleanup wird ausgeführt (Exit Code: $exit_code)..." # Level 1
    fi
    # Prüfen, ob eine temporäre Datei existiert und sie entfernen
    if [[ -n "$TMP_DOWNLOAD_FILE" && -f "$TMP_DOWNLOAD_FILE" ]]
    then
        log_debug "Entferne temporäre Datei: $TMP_DOWNLOAD_FILE" # Level 1
        rm -f "$TMP_DOWNLOAD_FILE"
    fi
    # Skript mit dem ursprünglichen Exit-Code beenden (wichtig für Fehlererkennung)
    # Außer wenn der Exit-Code 130 ist (Abbruch durch Benutzer), dann wurde schon beendet.
    if [[ $exit_code -ne 130 ]]
    then
        exit $exit_code
    fi
}

# Wird bei Strg+C (SIGINT) via 'trap cleanup_on_interrupt INT' aufgerufen.
# Gibt eine Meldung aus und beendet das Skript mit Exit Code 130.
cleanup_on_interrupt() {
    # Versuche, die Meldung auf das Terminal zu schreiben, sonst auf stderr
    local terminal="/dev/tty"
    if [ ! -w "$terminal" ]
    then
        terminal="/dev/stderr"
    fi
    # \e[?25h: Cursor wieder anzeigen (falls er mal versteckt wurde)
    # \e[0m: Textattribute zurücksetzen (falls Farbe/Fett etc. aktiv war)
    printf "\e[?25h\e[0m\n" > "$terminal" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: Abbruch durch Benutzer (Strg+C)..." > "$terminal"
    # Beenden mit speziellem Exit-Code für Interrupt
    exit 130
}

# Registriert die Cleanup-Funktionen für die Signale EXIT (jedes Skriptende) und INT (Strg+C).
trap cleanup_on_interrupt INT
trap cleanup EXIT

# =========================
# === Funktionsdefinitionen ===
# =========================

# Zeigt die Hilfe / Bedienungsanleitung an und beendet das Skript.
usage() {
    # Verwendung von `cat << EOF` für einen leicht editierbaren Here-Document Block.
    cat << EOF
Verwendung: $SCRIPT_NAME <Aktion> [Optionen]

Beschreibung:
  Listet Voicemail-Nachrichten von einer AVM Fritz!Box auf oder lädt sie herunter.
  Nutzt TR-064 (SOAP/XML), um direkt mit der Fritz!Box zu kommunizieren.

Aktionen:
  --list [Filter]          Listet Voicemails auf.
                           Filter: all (Standard), latest, index <nr>, known, unknown.
                           'known' basiert darauf, ob ein Name (<Name>) im XML vorhanden ist.
  --download <Index|all|latest>
                         Lädt Voicemails herunter.
                           Index: Nummer der Nachricht, 'all' oder 'latest'.

Optionen:
  --output <Datei|Verz.>   Zieldatei (für einzelne DL) oder Zielverzeichnis (für all/latest).
                           Endung (.ogg/.mp3) bei Einzel-DL aktiviert Konvertierung.
                           Bei Verzeichnis wird Dateiname automatisch generiert.
  --output-file <Datei>    Schreibt die reine Listenausgabe (--list) in diese Datei
                           (statt auf stdout).
  --audio-format <FMT>   Format für Konvertierung beim Download: wav (Standard, keine Konv.), ogg, mp3.
                           Nötig bei '--download all', wenn Konvertierung gewünscht.
                           Überschreibt Endung bei '--output <Datei>'.
  --tam <index>            Index des zu verwendenden Anrufbeantworters (Standard: ${DEFAULT_TAM_INDEX}).
  --format <format>        Ausgabeformat für --list (Standard: ${DEFAULT_LIST_FORMAT}).
                           Verfügbar: table, json, simple, csv, xml.
  -v                       Aktiviert INFO und Basis-DEBUG Ausgaben auf stderr.
  -vv                      Aktiviert detailliertere DEBUG Ausgaben auf stderr.
  -vvv                     Aktiviert alle DEBUG Ausgaben (inkl. od, curl -v) auf stderr.
  -h, --help               Zeigt diese Hilfe an.

Voraussetzungen:
  - bash v4 oder neuer
  - Standard Linux Tools: curl, awk (gawk empfohlen), sed, grep (GNU), file, date
                          od, mktemp, dirname, basename, wc, cut, tr, head, paste
  - Optional: jq (für --format json, robustere URL-Kodierung),
              column (für --format table),
              ffmpeg (für --audio-format ogg/mp3)
  - Anmeldedatei: '${CREDENTIALS_FILE}' im selben Verzeichnis wie das Skript,
                   enthaltend FRITZBOX_URL, FRITZBOX_USER, FRITZBOX_PASSWORD.
  - Fritz!Box: TR-064 Protokoll muss aktiviert sein.
               Der verwendete Benutzer benötigt die Berechtigung für
               'Sprachnachrichten, Faxnachrichten, E-Mails und Smarthome-Geräte'.

Beispiele:
  # Liste alle Nachrichten im Standardformat (Tabelle)
  $SCRIPT_NAME --list
  # Liste die neueste Nachricht im einfachen Textformat
  $SCRIPT_NAME --list latest --format simple
  # Lade Nachricht mit Index 5 als MP3 herunter
  $SCRIPT_NAME --download 5 --output nachricht_5.mp3
  # Lade alle neuen Nachrichten als OGG in ein Verzeichnis (Filter nicht implementiert, aber 'all')
  $SCRIPT_NAME --download all --output ./voicemails/ --audio-format ogg
  # Liste Nachrichten von AB 1 (zweiter AB) als JSON mit viel Debugging
  $SCRIPT_NAME --list --tam 1 --format json -vvv

Autor:        Marc Guhr <marc.guhr@gmail.com>
Repository:   https://github.com/HerrGuhr/fritzbox-voicemail-tools
Version:      ${SCRIPT_VERSION}
EOF
    exit 0 # Erfolgreich beenden nach Hilfeanzeige
}

# Lädt die Anmeldedaten (URL, Benutzer, Passwort) aus der Credentials-Datei.
# Argument $1: Pfad zur Credentials-Datei.
# Setzt globale Variablen: FRITZBOX_URL, FRITZBOX_TR064_USER, FRITZBOX_TR064_PASS.
# Gibt 0 bei Erfolg zurück, 1 bei Fehlern.
load_credentials() {
    local cred_file="$1"
    local url user pass # Lokale Variablen zum Einlesen

    # Prüfen, ob Datei lesbar ist
    if [[ ! -r "$cred_file" ]]
    then
        log_error "Anmeldedatei '$cred_file' nicht gefunden oder nicht lesbar."
        return 1
    fi

    log_debug "Lese Anmeldedaten aus '$cred_file'..." # Level 1

    # Extrahiere Werte und entferne führende/trailing Leerzeichen und Anführungszeichen
    url=$(grep '^FRITZBOX_URL=' "$cred_file" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
    user=$(grep '^FRITZBOX_USER=' "$cred_file" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
    pass=$(grep '^FRITZBOX_PASSWORD=' "$cred_file" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Prüfen, ob alle Werte vorhanden sind
    if [[ -z "$url" || -z "$user" || -z "$pass" ]]
    then
        log_error "Mindestens einer der Werte (FRITZBOX_URL, FRITZBOX_USER, FRITZBOX_PASSWORD) fehlt in '$cred_file'."
        return 1
    fi

    # Füge 'http://' hinzu, falls kein Protokoll angegeben ist
    if [[ ! "$url" =~ :// ]]
    then
        log_warn "URL '$url' hat kein Protokoll, füge 'http://' hinzu."
        url="http://${url}"
    fi

    # Setze globale Variablen
    FRITZBOX_URL="$url"
    FRITZBOX_TR064_USER="$user"
    FRITZBOX_TR064_PASS="$pass"

    log_debug "Credentials geladen: URL=${FRITZBOX_URL} User=${FRITZBOX_TR064_USER}" # Level 1
    return 0
}

# Holt die dynamische URL zur XML-Voicemail-Liste via TR-064 (SOAP Call 'GetMessageList').
# Argument $1: Der Index des Anrufbeantworters (TAM).
# Setzt globale Variable: VOICEMAIL_LIST_URL.
# Gibt 0 bei Erfolg zurück, 1 bei Fehlern.
get_voicemail_list_url() {
    local tam_idx="$1"
    local base_url control_url soap_action soap_body user_pass soap_response curl_rc
    base_url=$(echo "$FRITZBOX_URL" | sed 's/:[0-9]*$//')
    control_url="${base_url}:49000/upnp/control/x_tam"
    soap_action="urn:dslforum-org:service:X_AVM-DE_TAM:1#GetMessageList"
    # SOAP Body als einzelne Variable für Lesbarkeit
    soap_body="<?xml version='1.0' encoding='utf-8'?>
<s:Envelope s:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/' xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'>
<s:Body>
<u:GetMessageList xmlns:u='urn:dslforum-org:service:X_AVM-DE_TAM:1'>
<NewIndex>${tam_idx}</NewIndex>
</u:GetMessageList>
</s:Body>
</s:Envelope>"

    user_pass="${FRITZBOX_TR064_USER}:${FRITZBOX_TR064_PASS}"
    soap_response=""
    curl_rc=0

    log_ts "Rufe TR-064 GetMessageList für TAM ${tam_idx}..." # Level 1

    # curl Optionen als Array für bessere Lesbarkeit
    local curl_cmd_array=(
        curl
        -s # Silent
        -k # Allow insecure SSL
        -m 15 # Timeout 15s
        --anyauth # Auto-negotiate auth
        -u "$user_pass" # Credentials
        "$control_url" # Target URL
        -H 'Content-Type: text/xml; charset="utf-8"' # Header
        -H "SoapAction:$soap_action" # Header
        -d "$soap_body" # Data (SOAP Body)
    )

    log_debug "Führe TR-064 curl aus..." # Level 1
    # Curl Debugging (-v) nur bei Level 3 (-vvv)
    if [[ "$VERBOSE" -ge 3 ]]
    then
        log_debug_silly "Aktiviere curl -v für TR-064." # Level 3
        # Leite stderr von curl um, um es als SILLY Log auszugeben
        soap_response=$("${curl_cmd_array[@]}" -v 2> >(sed 's/^/curl-silly: /' >&2))
        curl_rc=$?
    else
        # Normale Ausführung ohne -v
        soap_response=$("${curl_cmd_array[@]}")
        curl_rc=$?
    fi
    log_debug "TR-064 curl beendet (RC: $curl_rc)." # Level 1

    # Prüfe curl Ergebnis
    if [[ $curl_rc -ne 0 ]]
    then
        log_error "TR-064 SOAP Aufruf fehlgeschlagen (curl RC: $curl_rc)."
        return 1
    fi

    # Extrahiere URL aus der Antwort
    VOICEMAIL_LIST_URL=$(echo "$soap_response" | grep -oP '<NewURL>\K[^<]+' | sed 's/&amp;/\&/g')
    if [[ -z "$VOICEMAIL_LIST_URL" ]]
    then
        log_error "Konnte <NewURL> nicht aus SOAP-Antwort extrahieren."
        log_debug_od "SOAP-Antwort:" "$soap_response" # Level 3
        return 1
    fi

    log_ts "URL zur XML-Liste erhalten." # Level 1
    log_debug "XML Listen URL: $VOICEMAIL_LIST_URL" # Level 1
    return 0
}

# Holt den Inhalt der XML-Voicemail-Liste von der zuvor ermittelten URL.
# Nutzt globale Variable: VOICEMAIL_LIST_URL.
# Gibt den XML-Inhalt auf stdout aus bei Erfolg oder leeren String wenn Liste leer.
# Gibt 0 bei Erfolg zurück, 1 bei Fehlern.
get_voicemail_list_xml() {
    if [[ -z "$VOICEMAIL_LIST_URL" ]]
    then
        log_error "Keine URL für die XML-Liste vorhanden (get_voicemail_list_url vorher ausführen)."
        return 1
    fi

    log_ts "Rufe XML-Liste von URL ab..." # Level 1
    local xml_content curl_rc

    # Führe curl aus, um die XML-Datei herunterzuladen
    xml_content=$(curl -s -k -m 10 --fail --show-error "$VOICEMAIL_LIST_URL")
    curl_rc=$?
    log_debug "XML Abruf curl beendet (RC: $curl_rc)." # Level 1

    # Prüfe curl Ergebnis
    if [[ $curl_rc -ne 0 ]]
    then
        log_error "Fehler beim Abrufen der XML-Liste von der URL (curl RC: $curl_rc)."
        # curl gibt dank --show-error schon eine Meldung aus
        return 1
    fi

    # Prüfe, ob die Liste leer ist
    if [[ -z "$xml_content" ]] || ! echo "$xml_content" | grep -q "<Message>"
    then
        log_warn "XML-Liste ist leer oder enthält keine Nachrichten."
        echo "" # Leeren String ausgeben
        return 0 # Kein Fehler
    fi

    # XML Inhalt bei Level 3 (-vvv) loggen
    log_debug_od "Empfangener XML-Inhalt:" "$xml_content" # Level 3

    # XML Inhalt auf stdout ausgeben
    echo "$xml_content"
    return 0
}

# Parst den Voicemail-XML-Inhalt mit AWK (Record-basiert).
# Argument $1: Der XML-Inhalt als String.
# Gibt die geparsten Daten Pipe-separiert auf stdout aus (9 Felder pro Zeile).
# Reihenfolge: Index|Neu|Bekannt|Datum|Nummer|AnruferName|EigeneNr|DauerMinuten|Pfad
# Gibt 0 bei Erfolg zurück, 1 bei Fehlern.
parse_voicemail_xml_awk() {
    local xml_content="$1"
    log_debug "Parse XML ($(echo "$xml_content" | wc -c) Bytes) mit AWK..." # Level 1

    # AWK Skript zur Verarbeitung jeder <Message>
    local awk_script='
    # --- Initialisierung ---
    BEGIN {
        RS="</Message>"; # Jede Nachricht ist ein Record
        FS="<|>";       # Felder sind durch < oder > getrennt
        OFS="|";        # Ausgabe-Felder mit Pipe trennen
    }
    # --- Verarbeitung pro Nachricht ---
    /<Message>/ { # Nur Records mit <Message> verarbeiten
        # Variablen für die Felder zurücksetzen
        idx=neu_val=datum=name=nummer=called=duration_str=pfad="";
        neu="Nein"; bekannt="Nein"; dauer_min=0; anrufer_name="Unbekannt";

        # Felder extrahieren
        for(i=1; i<=NF; ++i) {
            if($i == "Index")       idx=$(i+1);
            else if($i == "New")    neu_val=$(i+1);
            else if($i == "Date")   datum=$(i+1);
            else if($i == "Name")   name=$(i+1); # Kann leer sein
            else if($i == "Number") nummer=$(i+1);
            else if($i == "Called") called=$(i+1);
            else if($i == "Duration") duration_str=$(i+1); # Format SS:MM
            else if($i == "Path")   pfad=$(i+1);
        }

        # Validierung: Index muss vorhanden sein
        if (idx == "") { print "WARN: Überspringe Nachricht ohne Index..." > "/dev/stderr"; next; }

        # Feld "Neu?" aufbereiten
        if (neu_val == "1") neu="Ja";

        # Feld "Bekannt?" + "AnruferName" aufbereiten
        if (name != "") { # Name ist vorhanden
            bekannt="Ja";
            anrufer_name = name;
        } else { # Kein Name vorhanden
            bekannt="Nein";
            if (nummer != "") { # Nummer als Fallback für Name
                anrufer_name = nummer;
            } else { # Weder Name noch Nummer
                anrufer_name = "Unbekannt";
            }
        }

        # Feld "DauerMinuten" aufbereiten (aus SS:MM)
        dauer_min = 0;
        if (duration_str != "") {
            # match() prüft Format und extrahiert Teile in Array d
            if (match(duration_str, /^[0-9]{1,2}:([0-9]+)$/, d)) {
                # d[1] sind die Minuten
                dauer_min = d[1] + 0; # Explizit numerisch
            }
            # Dauer Debugging nur bei Level >= 2 (-vv)
            if (ENVIRON["VERBOSE"] >= 2) {
                # Nur loggen wenn Dauer > 0 oder Formatfehler vorlag
                if (dauer_min > 0 || duration_str !~ /^[0-9]{1,2}:([0-9]+)$/) {
                     printf "[AWK Dauer Idx:%s] Str:\047%s\047 -> Min:%d\n", idx, duration_str, dauer_min > "/dev/stderr";
                }
            }
        } else {
            # Leeres Duration Tag -> Nur bei Level >= 2 loggen
            if (ENVIRON["VERBOSE"] >= 2) { printf "[AWK Dauer Idx:%s] WARN: Leere Duration -> Min:0\n", idx > "/dev/stderr"; }
        }
        dauer_min = dauer_min + 0; # Sicherstellen, dass es Zahl ist

        # Feld "Pfad" bereinigen
        sub(/.*path=/, "", pfad);

        # --- Ausgabe der 9 Felder ---
        print idx, neu, bekannt, datum, nummer, anrufer_name, called, dauer_min, pfad;
    }
    ' # Ende AWK Skript

    local parsed_output
    # Führe AWK aus, übergib VERBOSE Level
    parsed_output=$(echo "$xml_content" | awk -v VERBOSE="$VERBOSE" "$awk_script")
    local awk_rc=${PIPESTATUS[1]} # Prüfe AWK Exit Code

    if [[ $awk_rc -ne 0 ]]
    then
        log_error "AWK XML Parser fehlgeschlagen (RC: $awk_rc)."
        return 1
    fi

    log_debug "AWK XML Parsing abgeschlossen." # Level 1
    echo "$parsed_output" # Gib das Ergebnis (Pipe-separierte Zeilen) aus
    return 0
}


# Bereinigt einen String für die Verwendung in Dateinamen.
# Ersetzt Umlaute, ß und ungültige Zeichen.
# Argument $1: Der zu bereinigende String.
# Gibt den bereinigten String auf stdout aus.
sanitize_filename() {
    local filename="$1"
    # Umlaute ersetzen
    filename=${filename//ä/ae}; filename=${filename//Ä/Ae}
    filename=${filename//ö/oe}; filename=${filename//Ö/Oe}
    filename=${filename//ü/ue}; filename=${filename//Ü/Ue}
    filename=${filename//ß/ss}
    # Ungültige Zeichen ersetzen und bereinigen
    filename=$(echo "$filename" | sed \
        -e 's/[^A-Za-z0-9._-]/_/g' `# Ersetze alles außer A-Z,a-z,0-9,._- durch _` \
        -e 's/__*/_/g'             `# Reduziere mehrere _ zu einem _` \
        -e 's/^[._]*//'            `# Entferne führende . oder _` \
        -e 's/[._]*$//')           `# Entferne folgende . oder _`
    # Fallback, falls Name leer ist
    if [[ -z "$filename" ]]; then filename="Unbekannt"; fi
    echo "$filename"
}

# Escaped XML-Sonderzeichen (&, <, >, ", ') für die sichere Einbettung in XML.
# Argument $1: Der zu escapende String.
# Gibt den escapeden String auf stdout aus.
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"  # & muss zuerst ersetzt werden!
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    echo "$s"
}

# Verarbeitet die geparste Liste (Ausgabe von parse_voicemail_xml_awk)
# und formatiert sie gemäß den Optionen für die Ausgabe (--format).
# Argument $1: Die geparsten Daten (mehrere Zeilen, Pipe-separiert).
# Argument $2: Der verwendete TAM-Index (für Titel/Metadaten).
# Argument $3: Der angewendete Filter (für Titel/Metadaten).
# Argument $4: Das gewünschte Ausgabeformat (table, json, simple, csv, xml).
# Nutzt globale Variable LIST_OUTPUT_FILE für Dateiausgabe.
# Gibt 0 bei Erfolg zurück, 1 bei Fehlern.
process_and_format_list() {
    # Erwarteter Input pro Zeile ($1):
    # Index|Neu|Bekannt|Datum|Nummer|AnruferName|EigeneNr|DauerMinuten|Pfad
    local parsed_output="$1"; local tam_idx="$2"; local list_filter="$3"; local list_format="$4"
    local output_file="$LIST_OUTPUT_FILE"; local is_redirected=0; if ! [ -t 1 ]; then is_redirected=1; fi; local pure_output=0; if [[ -n "$output_file" || $is_redirected -eq 1 ]]; then pure_output=1; fi
    local messages=(); local filtered_messages=(); local formatted_output=""; local output_buffer=""; local counter=0
    # Diese Variablen werden von parse_line() gefüllt
    local idx neu bekannt datum nummer anrufer_name eigene_nr dauer_min pfad

    # --- Hilfsfunktion: Liest eine Pipe-separierte Zeile sicher in Variablen ---
    parse_line() {
        local line="$1"; local awk_output; local read_rc
        awk_output=$(echo "$line" | awk 'BEGIN{FS="|"; OFS="\x03"} {print $1,$2,$3,$4,$5,$6,$7,$8,$9}'); awk_rc=$?
        if [[ $awk_rc -ne 0 ]]; then log_warn "parse_line: AWK Trennung fehlgeschlagen (RC: $awk_rc)"; return 1; fi
        IFS=$'\x03' read -r idx neu bekannt datum nummer anrufer_name eigene_nr dauer_min pfad <<< "$awk_output"; read_rc=$?
        if [[ $read_rc -ne 0 ]] || [[ -z "$idx" ]]; then log_warn "parse_line: read fehlgeschlagen (RC: $read_rc) oder Index leer."; idx=""; neu=""; bekannt=""; datum=""; nummer=""; anrufer_name=""; eigene_nr=""; dauer_min=""; pfad=""; return 1; fi; return 0
    }
    # --- Ende Hilfsfunktion ---

    log_debug "process_and_format_list: Verarbeite Daten für Format '$list_format'..." # Level 1
    # Prüfe, ob Input leer ist
    if [[ -z "$parsed_output" ]] || ! echo "$parsed_output" | grep -q "|"; then if [[ $pure_output -eq 0 ]]; then echo "Keine Voicemail-Nachrichten gefunden."; fi; return 0; fi

    # Lese Zeilen in Array
    mapfile -t messages < <(echo "$parsed_output"); mapfile_rc=$?
    log_debug "mapfile RC: $mapfile_rc. ${#messages[@]} Nachrichten eingelesen." # Level 1
    if [[ $mapfile_rc -ne 0 ]]; then log_error "Fehler mapfile."; return 1; fi

    # --- Filter anwenden ---
    log_debug "Wende Filter '$list_filter' an..."; filtered_messages=() # Level 1
    case "$list_filter" in
        latest)  if [[ ${#messages[@]} -gt 0 ]]; then filtered_messages+=("${messages[0]}"); fi ;;
        all)     filtered_messages=("${messages[@]}") ;;
        known)   for msg in "${messages[@]}"; do if [[ "$(echo "$msg" | cut -d'|' -f3)" == "Ja" ]]; then filtered_messages+=("$msg"); fi; done ;;
        unknown) for msg in "${messages[@]}"; do if [[ "$(echo "$msg" | cut -d'|' -f3)" == "Nein" ]]; then filtered_messages+=("$msg"); fi; done ;;
        *)       if [[ "$list_filter" =~ ^[0-9]+$ ]]; then local found=0; for msg in "${messages[@]}"; do if [[ "$(echo "$msg" | cut -d'|' -f1)" == "$list_filter" ]]; then filtered_messages+=("$msg"); found=1; break; fi; done; if [[ $found -eq 0 ]]; then log_error "Index '$list_filter' nicht gefunden."; return 1; fi; else log_error "Ungültiger Filter '$list_filter'."; return 1; fi ;;
    esac
    log_debug "${#filtered_messages[@]} Nachrichten entsprechen dem Filter." # Level 1
    if [[ ${#filtered_messages[@]} -eq 0 ]]; then if [[ $pure_output -eq 0 ]]; then echo "Keine Nachrichten entsprechen Filter '$list_filter'."; fi; return 0; fi

    # --- Ausgabe formatieren ---
    output_buffer=""; formatted_output=""
    log_debug_detail "Generiere Ausgabe im Format: $list_format" # Level 2
    case "$list_format" in
        table)
            local header="Index|Neu?|Bekannt?|Datum/Zeit|Nummer|Anrufer/Name|Eigene Nr.|Dauer(m)|Pfad"
            local table_data=""
            for msg in "${filtered_messages[@]}"
            do
                if parse_line "$msg"
                then
                    local line
                    line=$(printf "%s|%s|%s|%s|%s|%s|%s|%s|%s" "$idx" "$neu" "$bekannt" "$datum" "$nummer" "$anrufer_name" "$eigene_nr" "$dauer_min" "$pfad")
                    table_data+="${line}"$'\n'
                else
                    log_warn "[Table] Überspringe Zeile wegen Parsing-Fehler."
                fi
            done
            local full_table_content=$(printf "%s\n%b" "$header" "${table_data%$'\n'}")
            if command -v column &>/dev/null
            then
                 output_buffer=$(echo -e "$full_table_content" | column -t -s '|')
            else
                 if [[ $pure_output -eq 0 ]]; then log_warn "'column' nicht gefunden, Tabellenformatierung einfach."; fi
                 output_buffer="$full_table_content"
            fi
            if [[ $pure_output -eq 1 ]]
            then
                 formatted_output="$output_buffer"
            else
                 local title="--- Voicemail-Liste (TAM ${tam_idx}, Filter: ${list_filter}) ---"
                 local summary="--- Ende Liste (Anzahl: ${#filtered_messages[@]}) ---"
                 formatted_output=$(printf "%s\n%s\n%s" "$title" "$output_buffer" "$summary")
            fi
            ;;
        json)
            if ! command -v jq &>/dev/null; then log_error "'jq' fehlt für --format json."; return 1; fi
            output_buffer="" # Sammelt JSON Lines
            counter=0
            for msg in "${filtered_messages[@]}"
            do
                ((counter++))
                if ! parse_line "$msg"
                then
                     log_warn "[JSON] Überspringe Nachricht $counter wegen Parsing-Fehler."
                     continue
                fi
                # Erzeuge ein JSON-Objekt pro Zeile mit einem jq Aufruf
                local json_line
                json_line=$(jq -cn \
                    --argjson idx "$idx" \
                    --argjson neu "$( [[ "$neu" == "Ja" ]] && echo true || echo false )" \
                    --argjson bekannt "$( [[ "$bekannt" == "Ja" ]] && echo true || echo false )" \
                    --arg datum "$datum" \
                    --arg nummer "$nummer" \
                    --arg anrufer_name "$anrufer_name" \
                    --arg eigene_nr "$eigene_nr" \
                    --argjson dauer_min "$dauer_min" \
                    --arg pfad "$pfad" \
                    '{index: $idx, neu: $neu, bekannt: $bekannt, datum: $datum, nummer: $nummer, anrufer_name: $anrufer_name, eigene_nr: $eigene_nr, dauer_min: $dauer_min, pfad: $pfad}')
                 output_buffer+="${json_line}"$'\n'
            done
            # Füge die JSON Lines zu einem Array zusammen
            if [[ -n "$output_buffer" ]]
            then
                formatted_output=$(printf "%s" "${output_buffer%$'\n'}" | jq -sc '.')
            else
                formatted_output="[]" # Leeres Array
            fi
            log_debug "[JSON] JSON-Generierung abgeschlossen." # Level 1
            ;;
        simple)
            output_buffer=""
            counter=0
            for msg in "${filtered_messages[@]}"
            do
                ((counter++))
                if ! parse_line "$msg"
                then
                     log_warn "[Simple] Überspringe Nachricht $counter wegen Parsing-Fehler."
                     continue
                fi
                local line_content
                line_content=$(printf "%s: Neu=%s Bekannt=%s Datum=%s Nummer=%s Von=%s EigeneNr=%s Dauer=%sm Pfad=%s" \
                    "$idx" "$neu" "$bekannt" "$datum" "$nummer" "$anrufer_name" "$eigene_nr" "$dauer_min" "$pfad")
                output_buffer+="${line_content}"$'\n'
            done
            # Letztes Newline entfernen
            if [[ "$output_buffer" == *$'\n' ]]; then formatted_output="${output_buffer%$'\n'}"; else formatted_output="$output_buffer"; fi
            ;;
        csv)
            local csv_header="Index;Neu;Bekannt;Datum;Nummer;AnruferName;EigeneNr;DauerMinuten;Pfad"
            output_buffer=""
            if [[ $pure_output -eq 0 ]]; then output_buffer+="${csv_header}"$'\n'; fi
            counter=0
            for msg in "${filtered_messages[@]}"
            do
                ((counter++))
                if ! parse_line "$msg"
                then
                     log_warn "[CSV] Überspringe Nachricht $counter wegen Parsing-Fehler."
                     continue
                fi
                # Anführungszeichen im Namen escapen (" -> "")
                local escaped_name="\"${anrufer_name//\"/\"\"}\""
                local csv_line
                csv_line=$(printf "%s;%s;%s;%s;%s;%s;%s;%s;%s" \
                    "$idx" "$neu" "$bekannt" "$datum" "$nummer" "$escaped_name" "$eigene_nr" "$dauer_min" "$pfad")
                output_buffer+="${csv_line}"$'\n'
            done
            # Letztes Newline entfernen
            if [[ "$output_buffer" == *$'\n' ]]; then formatted_output="${output_buffer%$'\n'}"; else formatted_output="$output_buffer"; fi
            ;;
        xml)
            log_debug_detail "[XML] Generiere XML-Ausgabe..." # Level 2
            # XML Header und Root-Element
            output_buffer="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            output_buffer+="<VoicemailList tam_index=\"${tam_idx}\" filter=\"$(xml_escape "$list_filter")\">\n"
            counter=0
            for msg in "${filtered_messages[@]}"
            do
                ((counter++))
                if ! parse_line "$msg"
                then
                     log_warn "[XML] Überspringe Nachricht $counter wegen Parsing-Fehler."
                     continue
                fi
                # XML-Element für die Nachricht (Werte escapen)
                output_buffer+="  <Voicemail>\n"
                output_buffer+="    <Index>$(xml_escape "$idx")</Index>\n"
                output_buffer+="    <Neu>$(xml_escape "$neu")</Neu>\n"
                output_buffer+="    <Bekannt>$(xml_escape "$bekannt")</Bekannt>\n"
                output_buffer+="    <Datum>$(xml_escape "$datum")</Datum>\n"
                output_buffer+="    <Nummer>$(xml_escape "$nummer")</Nummer>\n"
                output_buffer+="    <AnruferName>$(xml_escape "$anrufer_name")</AnruferName>\n"
                output_buffer+="    <EigeneNr>$(xml_escape "$eigene_nr")</EigeneNr>\n"
                output_buffer+="    <DauerMinuten>$(xml_escape "$dauer_min")</DauerMinuten>\n"
                output_buffer+="    <Pfad>$(xml_escape "$pfad")</Pfad>\n"
                output_buffer+="  </Voicemail>\n"
            done
            output_buffer+="</VoicemailList>" # Schließe Root-Element
            formatted_output="$output_buffer"
            log_debug "[XML] XML-Generierung abgeschlossen." # Level 1
            ;;
        *)
            log_error "Interner Fehler: Unbekanntes Ausgabeformat '$list_format'."
            return 1
            ;;
    esac

    # --- Finale Ausgabe ---
    # Gib den formatierten Output entweder in eine Datei oder auf stdout aus.
    if [[ -n "$output_file" ]]
    then
        log_ts "Schreibe formatierte Liste nach '$output_file'..." # Level 1
        # printf "%s\n": Stellt sicher, dass genau ein Newline am Ende steht
        if ! printf "%s\n" "$formatted_output" > "$output_file"
        then
            log_error "Fehler beim Schreiben der Liste in die Datei '$output_file'."
            # Wenn nicht umgeleitet, trotzdem auf stdout ausgeben
            if [[ $is_redirected -eq 0 ]]; then echo "Fehler beim Schreiben. Ausgabe erfolgt stattdessen hier:" >&2; printf "%s\n" "$formatted_output"; fi
            return 1
        fi
    else
        # Ausgabe auf stdout
        printf "%s\n" "$formatted_output"
    fi
    return 0
}

# Lädt eine oder alle Voicemail-Dateien herunter.
# Argument $1: TAM-Index.
# Argument $2: Zu ladender Nachrichten-Index ('all', 'latest' oder Nummer).
# Argument $3: Zieldatei oder Zielverzeichnis (--output).
# Nutzt globale Variablen: AUDIO_FORMAT, VERBOSE, FRITZBOX_URL, VOICEMAIL_LIST_URL.
# Gibt 0 bei Erfolg zurück, 1 bei Fehlern (auch Teilfehlern bei 'all').
download_voicemail() {
    local tam_idx="$1"; local msg_idx_filter="$2"; local output_target="$3"
    local audio_format_param="$AUDIO_FORMAT"; local download_script_path="/download.lua"
    local messages_xml=""; local target_msg_indices=(); declare -A msg_details; local final_filenames=()
    local all_successful=true; local total_files=0; local i=0; local final_ext="wav"; local convert_to_format=""

    # --- Schritt 1: Aktuelle XML Liste holen ---
    log_ts "Rufe XML für Download ab..."; if ! get_voicemail_list_url "$tam_idx"; then return 1; fi # Level 1
    messages_xml=$(get_voicemail_list_xml); if [[ $? -ne 0 ]] || [[ -z "$messages_xml" ]]; then log_error "XML für Download nicht abrufbar/leer."; return 1; fi; log_ts "XML erfolgreich abgerufen." # Level 1

    # --- Schritt 2: Zielformat bestimmen ---
    log_debug "Bestimme Zieldateiformat..."; # Level 1
    if [[ -n "$audio_format_param" ]]; then final_ext="$audio_format_param"; if [[ "$final_ext" == "ogg" || "$final_ext" == "mp3" ]]; then convert_to_format="$final_ext"; log_debug "Format explizit: '$final_ext' (Konv.)"; else convert_to_format=""; final_ext="wav"; log_debug "Format explizit: '$final_ext' (Keine Konv.)"; fi
    elif [[ "$msg_idx_filter" != "all" ]] && [[ -n "$output_target" && "$output_target" != */ ]]; then local target_ext_lower=$(echo "${output_target##*.}" | tr '[:upper:]' '[:lower:]'); if [[ "$target_ext_lower" == "ogg" || "$target_ext_lower" == "mp3" ]]; then final_ext="$target_ext_lower"; convert_to_format="$final_ext"; log_debug "Format aus Endung: '$final_ext' (Konv.)"; else final_ext="wav"; convert_to_format=""; if [[ "$output_target" != *.* ]]; then output_target+=".wav"; elif [[ "$target_ext_lower" != "wav" ]]; then log_warn "Endung '.$target_ext_lower', -> WAV."; output_target="${output_target%.*}.wav"; fi; log_debug "Format: WAV (aus Dateiname/Standard)"; fi
    else final_ext="wav"; convert_to_format=""; log_debug "Format: WAV (Standard für 'all'/Verz.)"; fi
    if [[ -n "$convert_to_format" ]] && ! command -v ffmpeg &>/dev/null; then log_error "'ffmpeg' benötigt für '$convert_to_format'."; return 1; fi

    # --- Schritt 3: Filtern, Details, Dateinamen ---
    target_msg_indices=(); final_filenames=(); declare -A msg_details; log_debug "Filtere XML für Download (Filter: '$msg_idx_filter')..." # Level 1
    local awk_filter_cmd='BEGIN { RS="</Message>"; FS="<|>"; OFS="|"; } /<Message>/ { idx=dt=nm=num=pth=""; for(i=1; i<=NF; ++i) { if($i == "Index") idx=$(i+1); else if($i == "Date") dt=$(i+1); else if($i == "Name") nm=$(i+1); else if($i == "Number") num=$(i+1); else if($i == "Path") pth=$(i+1); } sub(/.*path=/, "", pth); if(idx != "" && pth != "") print idx, dt, nm, num, pth; }'
    # Prozesssubstitution verwenden, um Subshell zu vermeiden!
    while IFS='|' read -r current_idx msg_date msg_name msg_number msg_path; do
        if [[ -z "$current_idx" || -z "$msg_path" ]]; then log_warn "Überspringe ungültige DL-Zeile."; continue; fi; local match=0; case "$msg_idx_filter" in all) match=1 ;; latest) if [[ ${#target_msg_indices[@]} -eq 0 ]]; then match=1; fi ;; *) if [[ "$current_idx" == "$msg_idx_filter" ]]; then match=1; fi ;; esac
        if [[ $match -eq 1 ]]; then
            log_debug "Index $current_idx passt zum DL-Filter '$msg_idx_filter'." # Level 1
            target_msg_indices+=("$current_idx"); msg_details["$current_idx,Datum"]="$msg_date"; msg_details["$current_idx,Name"]="$msg_name"; msg_details["$current_idx,Nummer"]="$msg_number"; msg_details["$current_idx,Pfad"]="$msg_path"
            local current_target_filename=""; if [[ "$msg_idx_filter" == "all" ]] || [[ -d "$output_target" ]]; then local date_part=$(echo "$msg_date" | grep -oP '^\d{2}\.\d{2}\.\d{2}'); local time_part=$(echo "$msg_date" | grep -oP '\d{2}:\d{2}$'); local year="20${date_part:6:2}"; local month="${date_part:3:2}"; local day="${date_part:0:2}"; local hour="${time_part:0:2}"; local minute="${time_part:3:2}"; local timestamp="${year}${month}${day}_${hour}${minute}"; local caller_info="${msg_name:-${msg_number:-Unbekannt}}"; local safe_caller=$(sanitize_filename "${caller_info}"); if [[ -z "$safe_caller" ]]; then safe_caller="Unbekannt_Idx${current_idx}"; fi; local base_filename="${timestamp}_${safe_caller}"; current_target_filename="${output_target%/}/${base_filename}.${final_ext}"; log_debug_detail "Generierter Dateiname: '$current_target_filename'"; else current_target_filename="$output_target"; log_debug_detail "Verwende spezifischen Zieldateinamen: '$current_target_filename'"; fi; final_filenames+=("$current_target_filename") # Level 2
            if [[ "$msg_idx_filter" != "all" ]]; then log_debug "DL-Filter: Breche Schleife nach erstem Match ab."; break; fi # Level 1
        fi
    done < <(echo "$messages_xml" | awk "$awk_filter_cmd") # Prozesssubstitution

    total_files=${#target_msg_indices[@]}; if [[ $total_files -eq 0 ]]; then log_error "Keine Nachrichten für DL-Filter '$msg_idx_filter' gefunden."; return 1; fi
    if [[ ${#final_filenames[@]} -ne $total_files ]]; then log_error "Interner Fehler: Anzahl DL-Dateinamen (${#final_filenames[@]}) != Anzahl DL-Indizes ($total_files)."; return 1; fi
    log_ts "Verarbeite ${total_files} Nachrichten für Download (Filter: '$msg_idx_filter')..." # Level 1
    if [[ $VERBOSE -ge 1 ]]; then log_debug "Zu verarbeitende Indizes (${#target_msg_indices[@]}): ${target_msg_indices[*]}"; log_debug "Zugehörige Zieldateinamen (${#final_filenames[@]}):"; for (( idx=0; idx<total_files; idx++ )); do log_debug "  Index ${target_msg_indices[$idx]} -> ${final_filenames[$idx]}"; done; fi # Level 1

    # --- Schritt 4: Download-Schleife ---
    i=0; log_debug "Beginne Download-Schleife..." # Level 1
    for current_idx in "${target_msg_indices[@]}"
    do
        ((i++)); local final_filename="${final_filenames[$((i-1))]}"; local file_path_raw="${msg_details[$current_idx,Pfad]}"; local initial_save_filename="${final_filename%.*}.wav";
        log_debug_detail "--- Beginn DL Iteration $i: Index=$current_idx ---" # Level 2
        log_debug_detail "Ziel (Final): '$final_filename'" # Level 2
        if [[ -z "$final_filename" || -z "$file_path_raw" ]]; then log_error "Interner Fehler: Infos DL-Index $current_idx."; all_successful=false; continue; fi

        # Standardmäßig still, Info nur bei -v
        if [[ $VERBOSE -ge 1 ]]; then echo ""; log_ts "Download Index $current_idx -> '$final_filename' ($i/$total_files)..."; fi # Level 1

        # URL Bauen
        local file_path_encoded base_url sid_from_url download_url
        if command -v jq &>/dev/null; then file_path_encoded=$(printf %s "$file_path_raw" | jq -sRr @uri); else log_warn "'jq' fehlt, nutze Alt-Kodierung."; file_path_encoded=$(printf %s "$file_path_raw" | od -tx1 -An | tr ' ' % | tr -d '\n'); fi
        base_url=$(echo "$VOICEMAIL_LIST_URL" | sed -n 's~\(https\?://[^/]*\).*~\1~p'); sid_from_url=$(echo "$VOICEMAIL_LIST_URL" | grep -oP 'sid=[a-f0-9]+' | cut -d= -f2)
        if [[ -z "$base_url" || -z "$sid_from_url" ]]; then log_error "Basis-URL/SID nicht extrahierbar."; all_successful=false; continue; fi
        download_url="${base_url}${download_script_path}?sid=${sid_from_url}&path=${file_path_encoded}"; log_debug "Download URL: $download_url" # Level 1

        # Temp Datei
        TMP_DOWNLOAD_FILE=$(mktemp --suffix=.download); if [[ -z "$TMP_DOWNLOAD_FILE" ]]; then log_error "Temp-Datei nicht erstellt."; all_successful=false; continue; fi; log_debug "Temp-Datei: $TMP_DOWNLOAD_FILE" # Level 1

        # Curl Download
        log_debug "Starte Download mit curl..."; local http_code curl_rc # Level 1
        # curl Optionen und Header als Arrays
        local curl_opts=(-L --output "$TMP_DOWNLOAD_FILE" --connect-timeout 15 --max-time 300 --fail --silent --show-error --write-out "%{http_code}")
        local curl_headers=(-H "User-Agent: fb-voicemailtools/$SCRIPT_VERSION" -H "Accept: audio/wav,audio/*;q=0.8,*/*;q=0.5" -H "Referer: ${FRITZBOX_URL}/")
        # Curl Debugging (-v) nur bei Level 3 (-vvv)
        if [[ "$VERBOSE" -ge 3 ]]; then log_debug_silly "Aktiviere curl -v für Download."; http_code=$(curl "${curl_opts[@]}" "${curl_headers[@]}" -v "$download_url" 2> >(sed 's/^/curl-silly: /' >&2)); else http_code=$(curl "${curl_opts[@]}" "${curl_headers[@]}" "$download_url"); fi; curl_rc=$?
        log_debug "curl RC: $curl_rc, HTTP: $http_code" # Level 1

        # Prüfung
        if [[ $curl_rc -ne 0 ]] || ! [[ -s "$TMP_DOWNLOAD_FILE" ]]; then log_error "DL Index $current_idx fehlgeschlagen."; if [[ $curl_rc -eq 0 ]]; then log_error "HTTP: $http_code, Size: $(wc -c < "$TMP_DOWNLOAD_FILE" 2>/dev/null||echo 0)."; else log_error "Curl RC: $curl_rc (HTTP: $http_code)."; if [[ $curl_rc -eq 22 && "$http_code" =~ ^[45] ]]; then log_error "-> HTTP $http_code."; fi; fi; if [[ -f "$TMP_DOWNLOAD_FILE" ]]; then rm "$TMP_DOWNLOAD_FILE"; fi; all_successful=false; continue; fi
        local mime_type=$(file -b --mime-type "$TMP_DOWNLOAD_FILE"); log_debug "MIME: $mime_type"; if [[ "$mime_type" != "audio/x-wav" && "$mime_type" != "audio/wav" ]]; then log_warn "Unerwarteter MIME '$mime_type'."; fi # Level 1
        log_debug "DL Index $current_idx OK (HTTP $http_code, $(wc -c < "$TMP_DOWNLOAD_FILE") Bytes)." # Level 1

        # Verschieben
        mkdir -p "$(dirname "$initial_save_filename")" || { log_error "Konnte Zielverzeichnis für '$initial_save_filename' nicht erstellen."; all_successful=false; continue; }
        if ! mv "$TMP_DOWNLOAD_FILE" "$initial_save_filename"; then log_error "mv '$initial_save_filename' fehlgeschlagen."; all_successful=false; rm -f "$TMP_DOWNLOAD_FILE"; continue; fi
        TMP_DOWNLOAD_FILE=""; log_debug "'$initial_save_filename' gespeichert." # Level 1

        # Konvertieren
        if [[ -n "$convert_to_format" ]] && [[ "$initial_save_filename" != "$final_filename" ]]; then
             if [[ $VERBOSE -ge 1 ]]; then log_ts "Konvertiere '$initial_save_filename' -> $convert_to_format ('$final_filename')..."; fi # Level 1
             local ffmpeg_cmd=(); local ffmpeg_rc=1
             case "$convert_to_format" in ogg) ffmpeg_cmd=(ffmpeg -i "$initial_save_filename" -c:a libvorbis -q:a 4 -ac 1 -vn -y "$final_filename");; mp3) ffmpeg_cmd=(ffmpeg -i "$initial_save_filename" -c:a libmp3lame -q:a 6 -ac 1 -vn -y "$final_filename");; *) log_warn "Konv.-Format '$convert_to_format' nicht unterstützt."; ffmpeg_cmd=();; esac
             if [[ ${#ffmpeg_cmd[@]} -gt 0 ]]; then
                 log_debug "Führe aus: ${ffmpeg_cmd[*]}"; # Level 1
                 # ffmpeg Debugging (-vv oder höher)
                 if [[ "$VERBOSE" -ge 2 ]]; then "${ffmpeg_cmd[@]}"; ffmpeg_rc=$?; else "${ffmpeg_cmd[@]}" >/dev/null 2>&1; ffmpeg_rc=$?; fi; log_debug "ffmpeg RC: $ffmpeg_rc" # Level 1
                 if [[ $ffmpeg_rc -eq 0 ]]; then if [[ $VERBOSE -ge 1 ]]; then log_ts "Konvertierung OK: '$final_filename'."; fi; log_debug "Lösche '$initial_save_filename'"; rm -f "$initial_save_filename"; # Level 1
                 else log_error "ffmpeg fehlgeschlagen (RC: $ffmpeg_rc)."; log_warn "Original WAV '$initial_save_filename' bleibt."; all_successful=false; fi
             fi; else log_debug "Keine Konvertierung."; fi # Level 1
        log_debug_detail "--- Ende DL Iteration $i: Index=$current_idx ---" # Level 2
    done

    # --- Ergebnis melden ---
    # Keine Leerzeile mehr hier, Download ist jetzt standardmäßig still.
    if [[ "$all_successful" == true ]]; then log_ts "Alle Downloads/Konvertierungen erfolgreich."; return 0; else log_warn "Einige Downloads/Konvertierungen fehlgeschlagen."; return 1; fi # Level 1 (außer Warn)
}
# ==========================

# === Skriptstart ===
log_ts "Skript gestartet (Version ${SCRIPT_VERSION})." # Level 1

# --- Argumentenverarbeitung ---
log_debug "Verarbeite Kommandozeilenargumente..." # Level 1
VERBOSE=0; ACTION=""; TAM_INDEX=$DEFAULT_TAM_INDEX; MESSAGE_INDEX=""; OUTPUT_FILENAME=""; LIST_FORMAT=$DEFAULT_LIST_FORMAT; LIST_FILTER="all"; LIST_OUTPUT_FILE=""; AUDIO_FORMAT=""
# Beachte die Konvention: --long-option, -s (short)
while [[ $# -gt 0 ]]; do key="$1"; case "$key" in -h|--help) usage; exit 0 ;; -v) ((VERBOSE=VERBOSE<3?VERBOSE+1:3)); shift ;; -vv) VERBOSE=2; shift ;; -vvv) VERBOSE=3; shift ;; --list) ACTION="list"; shift; if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then LIST_FILTER="$1"; shift; else LIST_FILTER="all"; fi ;; --download) ACTION="download"; shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--download: Index fehlt."; usage; exit 1; fi; MESSAGE_INDEX="$1"; shift ;; --output) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--output: Wert fehlt."; usage; exit 1; fi; OUTPUT_FILENAME="$1"; shift ;; --output-file) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--output-file: Name fehlt."; usage; exit 1; fi; LIST_OUTPUT_FILE="$1"; shift ;; --format) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--format: Wert fehlt."; usage; exit 1; fi; if [[ "$1" != "table" && "$1" != "json" && "$1" != "simple" && "$1" != "csv" && "$1" != "xml" ]]; then log_error "Ungültiges Format '$1'."; usage; exit 1; fi; LIST_FORMAT="$1"; shift ;; --tam) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--tam: Index fehlt."; usage; exit 1; fi; if ! [[ "$1" =~ ^[0-9]+$ ]]; then log_error "--tam: Index '$1' muss Zahl sein."; usage; exit 1; fi; TAM_INDEX="$1"; shift ;; --audio-format) shift; if [[ $# -eq 0 || "$1" == --* || "$1" == -* ]]; then log_error "--audio-format: Format fehlt."; usage; exit 1; fi; if [[ "$1" != "wav" && "$1" != "ogg" && "$1" != "mp3" ]]; then log_error "Ungültiges Format '$1'."; usage; exit 1; fi; AUDIO_FORMAT="$1"; shift ;; *) log_error "Unbekannte Option '$1'."; usage; exit 1 ;; esac; done
if [[ $VERBOSE -gt 3 ]]; then VERBOSE=3; fi # Sicherstellen, dass max Level 3 ist

# --- Validierung der Argumente ---
log_debug "Validiere Argumente..." # Level 1
if [[ -z "$ACTION" ]]; then log_error "Aktion fehlt."; usage; exit 1; fi; if [[ "$ACTION" == "download" && -n "$LIST_OUTPUT_FILE" ]]; then log_error "--output-file nicht mit --download."; usage; exit 1; fi; if [[ "$ACTION" == "download" && ("$LIST_FORMAT" != "$DEFAULT_LIST_FORMAT" || "$LIST_FILTER" != "all") ]]; then log_warn "--format/Filter ignoriert bei --download."; fi; if [[ "$ACTION" == "list" && -n "$AUDIO_FORMAT" ]]; then log_error "--audio-format nicht mit --list."; usage; exit 1; fi; if [[ "$ACTION" == "list" && -n "$OUTPUT_FILENAME" ]]; then log_error "--output nicht mit --list."; usage; exit 1; fi; if [[ "$ACTION" == "download" ]]; then if [[ -z "$MESSAGE_INDEX" ]]; then log_error "--download: Index fehlt."; usage; exit 1; fi; if [[ -z "$OUTPUT_FILENAME" ]]; then log_error "--download: --output fehlt."; usage; exit 1; fi; if [[ "$MESSAGE_INDEX" == "all" && -e "$OUTPUT_FILENAME" && ! -d "$OUTPUT_FILENAME" ]]; then log_error "--output muss Verz. sein für 'all'."; exit 1; fi; if [[ "$MESSAGE_INDEX" == "all" ]] || [[ "$OUTPUT_FILENAME" == */ ]]; then mkdir -p "$OUTPUT_FILENAME" || { log_error "Zielverz. '$OUTPUT_FILENAME' nicht erstellt."; exit 1; } ; fi; fi; if [[ "$ACTION" == "list" ]]; then if [[ "$LIST_FORMAT" == "json" && ! -x "$(command -v jq)" ]]; then log_error "'jq' fehlt für '--format json'."; exit 1; fi; if [[ "$LIST_FORMAT" == "table" && ! -x "$(command -v column)" ]]; then log_warn "'column' nicht gefunden."; fi; fi;
# Logge Parameter nur wenn -v oder höher aktiv ist
log_debug "Parameter validiert: Aktion='$ACTION', TAM='$TAM_INDEX', Verbose=$VERBOSE, Filter='$LIST_FILTER', Format='$LIST_FORMAT', DL-Index='$MESSAGE_INDEX', DL-Output='$OUTPUT_FILENAME', List-Outfile='$LIST_OUTPUT_FILE', Audio-Fmt='${AUDIO_FORMAT:-auto/wav}'" # Level 1

# --- Abhängigkeitsprüfung ---
log_ts "Prüfe Kernabhängigkeiten..." # Level 1
core_tools=(curl awk sed grep file paste mktemp date dirname basename wc cut tr head od)
missing_tool=false
for cmd in "${core_tools[@]}"; do if ! command -v "$cmd" &> /dev/null; then log_error "Werkzeug '$cmd' fehlt."; missing_tool=true; fi; done
if [[ "$missing_tool" == true ]]; then exit 1; fi
# Optionale Prüfungen
if [[ ("$ACTION" == "list" && "$LIST_FORMAT" == "json") || "$ACTION" == "download" ]]; then if ! command -v jq &>/dev/null; then log_warn "'jq' für json/download nicht gefunden."; fi; fi
if [[ "$ACTION" == "list" && "$LIST_FORMAT" == "table" ]] && ! command -v column &>/dev/null; then log_warn "'column' für '--format table' nicht gefunden."; fi
log_ts "Abhängigkeitsprüfung abgeschlossen." # Level 1
# ========================

# === Hauptlogik ===
# Exportiere VERBOSE, damit Subprozesse (wie AWK) das Level kennen
export VERBOSE

# Lade Anmeldedaten (Fehler wird dort behandelt)
if ! load_credentials "$CREDENTIALS_FILE"; then exit 1; fi

log_ts "Führe Aktion '$ACTION' aus..." # Level 1
action_rc=0 # Gesamtergebnis der Aktion (0 = Erfolg)

case "$ACTION" in
    list)
        # Variablen sind implizit lokal für diesen Block
        xml_content=""
        parsed_content=""

        # Führe die Schritte sequentiell aus, prüfe nach jedem auf Fehler
        if ! get_voicemail_list_url "$TAM_INDEX"; then action_rc=1; fi
        if [[ $action_rc -eq 0 ]]; then xml_content=$(get_voicemail_list_xml); if [[ $? -ne 0 ]]; then log_error "Fehler Holen XML."; action_rc=1; fi; fi
        if [[ $action_rc -eq 0 ]]; then if [[ -n "$xml_content" ]]; then parsed_content=$(parse_voicemail_xml_awk "$xml_content"); if [[ $? -ne 0 ]]; then log_error "Fehler Parsen XML."; action_rc=1; fi; else log_debug "XML war leer."; parsed_content=""; fi; fi
        if [[ $action_rc -eq 0 ]]; then if ! process_and_format_list "$parsed_content" "$TAM_INDEX" "$LIST_FILTER" "$LIST_FORMAT"; then log_error "Fehler Aufbereiten Liste."; action_rc=1; fi; fi
        ;;
    download)
        # Download-Funktion hat ihre eigene Fehlerbehandlung
        if ! download_voicemail "$TAM_INDEX" "$MESSAGE_INDEX" "$OUTPUT_FILENAME"; then log_error "Fehler während Download."; action_rc=1; fi
        ;;
    *)
        log_error "Interner Fehler: Unbekannte Aktion '$ACTION'."
        action_rc=1
        ;;
esac

# --- Skriptende ---
# Gib abschließende Meldung basierend auf dem Erfolg aus (nur bei -v)
if [[ $action_rc -eq 0 ]]
then
    log_ts "Aktion '$ACTION' erfolgreich beendet." # Level 1
    exit 0 # Erfolg signalisieren
else
    log_error "Aktion '$ACTION' mit Fehlern beendet." # Wird immer angezeigt
    exit 1 # Fehler signalisieren
fi