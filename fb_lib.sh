#!/bin/bash

# fb_lib.sh
# Version: 1.5
# Zweck: Bibliothek mit Hilfsfunktionen für Fritz!Box Web GUI Skripte.
#        - Anmeldedaten laden
#        - Session ID (SID) holen via Challenge-Response
#        - SID abmelden
#        - Logging-Funktionen (inkl. optionaler Debug-Ausgabe via VERBOSE=1)
# Autor: Marc Guhr
# Datum: 2025-04-07

# === Logging Funktionen ===

# Gibt eine formatierte Zeitstempel-Nachricht auf Stderr aus.
# Verwendung: log_ts "Meine Nachricht"
function log_ts() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $@" >&2
}

# Gibt eine formatierte Warnung auf Stderr aus.
# Verwendung: log_warn "Etwas ist seltsam"
function log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: $@" >&2
}

# Gibt eine formatierte Fehlermeldung auf Stderr aus.
# Verwendung: log_error "Das ist schiefgelaufen"
function log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: $@" >&2
}

# Gibt eine formatierte Debug-Nachricht auf Stderr aus,
# aber NUR, wenn die Umgebungsvariable VERBOSE=1 gesetzt ist.
# Wird vom Hauptskript via 'export VERBOSE' gesteuert.
# Verwendung: log_debug "Detailinformation"
function log_debug() {
    # Prüfe, ob VERBOSE gesetzt und gleich "1" ist
    [[ -n "$VERBOSE" && "$VERBOSE" == "1" ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $@" >&2
}


# === Funktionsdefinitionen ===

# Lädt Anmeldedaten aus einer Datei.
# Erwartet Dateipfad als Argument $1.
# Datei sollte Zeilen enthalten wie:
#   FRITZBOX_URL="http://fritz.box"
#   FRITZBOX_USER="user" # Optional
#   FRITZBOX_PASSWORD="password"
# Gibt URL, User (leer wenn nicht gesetzt) und Passwort zurück, getrennt durch |.
# Gibt bei Fehlern 1 zurück und loggt eine Fehlermeldung.
function load_credentials() {
    local cred_file="$1"
    local url user pass

    if [[ ! -r "$cred_file" ]]; then
        log_error "Datei '$cred_file' nicht gefunden oder nicht lesbar."
        return 1
    fi

    # Lese Werte, entferne führende/folgende Anführungszeichen (einfach & doppelt) und Leerzeichen
    url=$(grep '^FRITZBOX_URL=' "$cred_file" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
    user=$(grep '^FRITZBOX_USER=' "$cred_file" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')
    pass=$(grep '^FRITZBOX_PASSWORD=' "$cred_file" | cut -d'=' -f2- | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Validierung
    if [[ -z "$url" || -z "$pass" ]]; then
        log_error "URL oder Passwort fehlt oder ist leer in '$cred_file'."
        return 1
    fi

    # URL-Format prüfen und ggf. korrigieren/warnen
    if [[ ! "$url" =~ ^https?:// ]]; then
        if [[ ! "$url" =~ :// ]]; then
           log_warn "URL '$url' hat kein Protokoll (http/https), füge 'http://' hinzu."
           url="http://${url}"
        else
           # Hat ein anderes Protokoll, nur warnen
           log_warn "URL-Format ('$url') sieht ungewöhnlich aus (kein http/https am Anfang)."
        fi
    fi

    log_debug "Anmeldedaten geladen: URL=$url, User=${user:-<keiner>}"
    # Gebe Werte zur Verwendung durch den Aufrufer zurück (Pipe-getrennt)
    echo "${url}|${user}|${pass}"
    return 0
}

# Holt eine gültige Session ID (SID) von der Fritz!Box.
# Argument $1: FRITZBOX_URL
# Argument $2: FRITZBOX_USER (kann leer sein für Passwort-only Login)
# Argument $3: FRITZBOX_PASSWORD
# Gibt bei Erfolg die SID auf Stdout zurück.
# Gibt bei Fehlern 1 zurück und loggt eine Fehlermeldung.
function get_sid() {
    local url="$1"
    local user="$2"
    local pass="$3"
    local login_url="${url}/login_sid.lua"
    local challenge_xml challenge sid_check challenge_password response_hash response login_response_xml sid_value

    log_ts "Fordere Challenge oder bestehende SID von $login_url an..."
    # Timeout für Verbindungsaufbau (5s) und Gesamtdauer (10s)
    challenge_xml=$(curl --connect-timeout 5 --max-time 10 -s "$login_url")
    local curl_rc=$?
    if [[ $curl_rc -ne 0 ]]; then
        log_error "Verbindungsfehler zu curl '$login_url' (Code: $curl_rc)."
        return 1
    fi

    # Prüfe, ob wir direkt eine gültige SID bekommen (selten, aber möglich)
    sid_check=$(echo "$challenge_xml" | grep -oP '<SID>\K[a-f0-9]{16}(?=</SID>)')

    if [[ "$sid_check" == "0000000000000000" ]]; then
        log_debug "Antwort enthält SID=0, Challenge wird benötigt."
        # Extrahiere Challenge (8 Hex-Zeichen)
        challenge=$(echo "$challenge_xml" | grep -oP '<Challenge>\K[a-f0-9]{8}(?=</Challenge>)')
        if [[ -z "$challenge" ]]; then
            log_error "Konnte Challenge nicht aus der Antwort extrahieren:"
            log_debug "$challenge_xml" # Zeige die Antwort im Debug-Modus
            return 1
        fi
        log_ts "Challenge erhalten: $challenge"

        # Response berechnen: challenge-md5(challenge-password in UTF16-LE)
        log_debug "Berechne MD5-Hash für die Response..."
        challenge_password="${challenge}-${pass}"
        # Wichtig: iconv für korrekte UTF-16LE Kodierung des Challenge-Passworts
        # md5sum erwartet den Hash als einzigen Output auf stdout
        response_hash=$(printf "%s" "$challenge_password" | iconv -f UTF-8 -t UTF-16LE | md5sum | cut -d' ' -f1)
        if [[ -z "$response_hash" ]]; then
             log_error "MD5 Hash konnte nicht berechnet werden."
             return 1
        fi
        response="${challenge}-${response_hash}"
        log_debug "Response Hash berechnet: $response_hash"

        # SID mit Response anfordern
        log_ts "Fordere SID mit Challenge-Response an..."
        local curl_data_array=() # Array für curl Daten
        curl_data_array+=("--data-urlencode" "response=${response}")
        # Füge Benutzername hinzu, falls vorhanden
        if [[ -n "$user" ]]; then
             curl_data_array+=("--data-urlencode" "username=${user}")
        fi

        login_response_xml=$(curl --connect-timeout 5 --max-time 10 -s "${curl_data_array[@]}" "$login_url")
        curl_rc=$?
        if [[ $curl_rc -ne 0 ]]; then
            log_error "Verbindungsfehler beim Anfordern der SID mit Response (Code: $curl_rc)."
            return 1
        fi

    elif [[ -n "$sid_check" && "$sid_check" != "0000000000000000" ]]; then
        # Fall: Direkt eine gültige SID erhalten (z.B. wenn schon angemeldet)
        log_warn "Gültige SID ($sid_check) ohne erneute Challenge erhalten. Verwende diese."
        echo "$sid_check"
        return 0
    else
        log_error "Ungültige Antwort von login_sid.lua (weder SID=0 noch gültige SID):"
        log_debug "$challenge_xml"
        return 1
    fi

    # Extrahiere SID aus der zweiten Antwort (nach der Response)
    sid_value=$(echo "$login_response_xml" | grep -oP '<SID>\K[a-f0-9]{16}(?=</SID>)')
    if [[ -z "$sid_value" || "$sid_value" == "0000000000000000" ]]; then
        log_error "Anmeldung fehlgeschlagen. SID ist ungültig oder null."
        log_error "Mögliche Ursachen: Falscher Benutzername/Passwort, fehlende Berechtigungen ('Fritz!Box Einstellungen')."
        log_debug "Antwort auf SID-Anfrage:"
        log_debug "$login_response_xml"
        return 1
    fi

    log_ts "SID erfolgreich erhalten: $sid_value"
    echo "$sid_value" # SID auf Stdout ausgeben
    return 0
}

# Meldet eine Session ID (SID) bei der Fritz!Box ab.
# Argument $1: FRITZBOX_URL
# Argument $2: SID
# Gibt nichts zurück. Schlägt fehl, wenn die SID ungültig ist, was aber ignoriert wird.
function logout_sid() {
    local url="$1"
    local sid="$2"
    local login_url="${url}/login_sid.lua"

    if [[ -n "$sid" && "$sid" != "0000000000000000" ]]; then
        log_ts "Melde SID $sid ab..."
        # Einfacher GET-Request zum Abmelden. Keine Antwortprüfung nötig.
        curl --connect-timeout 2 --max-time 5 -s "${login_url}?logout=1&sid=${sid}" > /dev/null
        log_debug "Abmeldung für SID $sid gesendet."
    else
        log_debug "Keine gültige SID zum Abmelden vorhanden oder SID war bereits 0."
    fi
    # Kein Return-Code, da Abmeldung "fire and forget" ist.
}
# ========================
