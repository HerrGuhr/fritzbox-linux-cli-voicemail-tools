#!/bin/bash
# fb_voice_download.sh
# Version 0.1
# Script um Anrufbeantworternachrichten einer Fritzbox als wav Datei herunterzuladen
# (c) 2025-04-04 Marc Guhr


# === Konfiguration ===
FRITZBOX_URL="http://fritz.box" # Oder IP-Adresse wie http://192.168.178.1
FRITZBOX_USER="BENUTZERHIER" # Ersetzen durch Ihren Benutzernamen (oft leer, wenn keiner gesetzt ist)
FRITZBOX_PASSWORD="PASSWORTHIER" # Ersetzen durch Ihr Passwort
TAM_INDEX=0 # Index des Anrufbeantworters (normalerweise 0 für den ersten)
# ===================

# === Skript-Konstanten ===
LOGIN_URL="${FRITZBOX_URL}/login_sid.lua"
DOWNLOAD_SCRIPT_PATH="/lua/photo.lua" # Wie aus Ihrem fetch-Befehl ermittelt
# ======================

# === Funktionsdefinitionen ===
function get_sid() {
    local CHALLENGE_XML
    local CHALLENGE
    local SID_CHECK
    local CHALLENGE_PASSWORD
    local RESPONSE_HASH
    local RESPONSE
    local LOGIN_RESPONSE_XML

    echo "Versuche, Challenge zu erhalten..."
    CHALLENGE_XML=$(curl -s "$LOGIN_URL")
    SID_CHECK=$(echo "$CHALLENGE_XML" | grep -o '<SID>[a-z0-9]\{16\}</SID>' | sed 's/<[^>]*>//g')

    if [[ "$SID_CHECK" == "0000000000000000" ]]; then
        # Bereits angemeldet oder Anmeldung deaktiviert
        CHALLENGE=$(echo "$CHALLENGE_XML" | grep -o '<Challenge>[a-z0-9]\{8\}</Challenge>' | sed 's/<[^>]*>//g')
        if [[ -z "$CHALLENGE" ]]; then
            echo "Fehler: Konnte Challenge nicht erhalten, aber SID ist 0000000000000000. FritzOS-Version benötigt hier möglicherweise keine Challenge/Response?" >&2
            # Fortfahren mit SID 000... - könnte funktionieren, wenn Anmeldung für das Download-Skript nicht zwingend erforderlich ist
             SID="0000000000000000"
             echo "Fahre fort mit SID 0000000000000000."
             return 0
        fi
        echo "Challenge erhalten: $CHALLENGE"
    elif [[ -n "$SID_CHECK" && "$SID_CHECK" != "0000000000000000" ]]; then
         # Möglicherweise bereits mit einer gültigen SID aus einer früheren Sitzung angemeldet? Unwahrscheinlich für Skript.
         echo "Warnung: Eine Nicht-Null-SID ($SID_CHECK) ohne Anmeldung erhalten. Versuche trotzdem anzumelden." >&2
         # Weiter unten Challenge holen
    fi

    CHALLENGE=$(echo "$CHALLENGE_XML" | grep -o '<Challenge>[a-z0-9]\{8\}</Challenge>' | sed 's/<[^>]*>//g')
    if [[ -z "$CHALLENGE" ]]; then
        echo "Fehler: Konnte Challenge nicht aus der Fritz!Box-Antwort extrahieren." >&2
        echo "Antwort war: $CHALLENGE_XML" >&2
        return 1
    fi
     echo "Challenge erhalten: $CHALLENGE"

    echo "Berechne Response..."
    CHALLENGE_PASSWORD="${CHALLENGE}-${FRITZBOX_PASSWORD}"
    RESPONSE_HASH=$(printf "%s" "$CHALLENGE_PASSWORD" | iconv -f UTF-8 -t UTF-16LE | md5sum | cut -d' ' -f1)
    RESPONSE="${CHALLENGE}-${RESPONSE_HASH}"

    echo "Fordere SID an..."
    if [[ -z "$FRITZBOX_USER" ]]; then
        # Anmeldung ohne Benutzernamen
        LOGIN_RESPONSE_XML=$(curl -s "${LOGIN_URL}" --data-urlencode "response=${RESPONSE}")
    else
        # Anmeldung mit Benutzernamen
        LOGIN_RESPONSE_XML=$(curl -s "${LOGIN_URL}" --data-urlencode "response=${RESPONSE}" --data-urlencode "username=${FRITZBOX_USER}")
    fi

    SID=$(echo "$LOGIN_RESPONSE_XML" | grep -o '<SID>[a-z0-9]\{16\}</SID>' | sed 's/<[^>]*>//g')

    if [[ -z "$SID" || "$SID" == "0000000000000000" ]]; then
        echo "Fehler: Anmeldung fehlgeschlagen. SID ist ungültig oder null." >&2
        echo "Überprüfen Sie Benutzername/Passwort und stellen Sie sicher, dass der Benutzer ausreichende Berechtigungen hat (inkl. Fritz!Box-Einstellungen)." >&2
        echo "Antwort war: $LOGIN_RESPONSE_XML" >&2
        return 1
    fi

    echo "Anmeldung erfolgreich. SID erhalten: $SID"
    return 0
}

function logout_sid() {
    local LOGOUT_SID=$1
    if [[ -n "$LOGOUT_SID" && "$LOGOUT_SID" != "0000000000000000" ]]; then
        echo "Melde ab..."
        curl -s "${LOGIN_URL}?logout=1&sid=${LOGOUT_SID}" > /dev/null
        echo "Abmeldeanforderung gesendet."
    fi
}
# ==========================

# === Argumentenverarbeitung ===
if [[ $# -ne 2 ]]; then
    echo "Verwendung: $0 <nachrichten_index> <ausgabedateiname>" >&2
    echo "Beispiel: $0 112 meine_sprachnachricht.wav" >&2
    exit 1
fi

MESSAGE_INDEX="$1"
OUTPUT_FILENAME="$2"

# Validieren, dass der Nachrichtenindex eine Zahl ist
if ! [[ "$MESSAGE_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Fehler: <nachrichten_index> muss eine positive ganze Zahl sein." >&2
    exit 1
fi
# ========================

# === Abhängigkeitsprüfung ===
for cmd in curl md5sum iconv jq file; do
    if ! command -v $cmd &> /dev/null; then
        echo "Fehler: Benötigter Befehl '$cmd' nicht gefunden. Bitte installieren." >&2
        exit 1
    fi
done
# ========================

# === Hauptlogik ===
SID=""
# Setze Trap, um Abmeldung auch bei Skriptende/Fehler sicherzustellen
trap 'logout_sid "$SID"' EXIT

if ! get_sid; then
    echo "Fehler beim Holen der SID. Beende." >&2
    exit 1
fi

# Konstruiere den internen Dateipfad
FILE_PATH_RAW="/data/tam/rec/rec.${TAM_INDEX}.${MESSAGE_INDEX}"

# URL-kodiere den Dateipfad-Parameterwert
FILE_PATH_ENCODED=$(printf %s "$FILE_PATH_RAW" | jq -sRr @uri)

# Konstruiere die vollständige Download-URL
DOWNLOAD_URL="${FRITZBOX_URL}/cgi-bin/luacgi_notimeout?sid=${SID}&script=${DOWNLOAD_SCRIPT_PATH}&myabfile=${FILE_PATH_ENCODED}"

echo "Lade Nachricht mit Index ${MESSAGE_INDEX} von TAM ${TAM_INDEX} herunter..."
echo "URL: ${DOWNLOAD_URL}" # Vorsicht beim Loggen von URLs mit SIDs, wenn Logs öffentlich sind

# Temporäre Datei für den Download vor der Typprüfung
TMP_OUTPUT_FILE=$(mktemp --suffix=.data)
trap 'rm -f "$TMP_OUTPUT_FILE"; logout_sid "$SID"' EXIT # Sicherstellen, dass temporäre Datei aufgeräumt wird

HTTP_CODE=$(curl -w "%{http_code}" -o "$TMP_OUTPUT_FILE" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0" \
  -H "Accept: audio/webm,audio/ogg,audio/wav,audio/*;q=0.9,application/ogg;q=0.7,video/*;q=0.6,*/*;q=0.5" \
  -H "Accept-Language: de,en-US;q=0.7,en;q=0.3" \
  -H "Range: bytes=0-" \
  -H "Sec-Fetch-Dest: audio" \
  -H "Sec-Fetch-Mode: no-cors" \
  -H "Sec-Fetch-Site: same-origin" \
  -H "Referer: ${FRITZBOX_URL}/" \
  "$DOWNLOAD_URL")

# Prüfe den Download-Erfolg
if [[ "$HTTP_CODE" -ne 200 ]]; then
     echo "Fehler: Download fehlgeschlagen. HTTP-Statuscode: $HTTP_CODE" >&2
     # Optional: Zeige Anfang der möglicherweise kleinen Fehlerdatei
     if [[ -s "$TMP_OUTPUT_FILE" ]]; then
         echo "Antwortinhalt (erste 100 Bytes):" >&2
         head -c 100 "$TMP_OUTPUT_FILE" >&2
         echo "" >&2
     fi
     exit 1
fi

if [[ ! -s "$TMP_OUTPUT_FILE" ]]; then
    echo "Fehler: Download erfolgreich (HTTP 200), resultierte aber in einer leeren Datei." >&2
    exit 1
fi

echo "Download erfolgreich (HTTP $HTTP_CODE). Datei temporär gespeichert."

# Identifiziere den tatsächlichen Dateityp
DETECTED_TYPE=$(file -b "$TMP_OUTPUT_FILE") # -b für kurze Ausgabe

echo "Erkannter Dateityp: $DETECTED_TYPE"

# Benenne die temporäre Datei in den vom Benutzer gewünschten Namen um
mv "$TMP_OUTPUT_FILE" "$OUTPUT_FILENAME"
if [[ $? -ne 0 ]]; then
     echo "Fehler: Konnte temporäre Datei nicht nach $OUTPUT_FILENAME umbenennen" >&2
     # Temp-Datei zur Inspektion behalten? Oder erneut löschen versuchen? Trap kümmert sich darum.
     exit 1
fi
# Entferne TMP_OUTPUT_FILE aus Trap, da sie erfolgreich verschoben wurde
trap 'logout_sid "$SID"' EXIT

echo "Sprachnachricht gespeichert als: $OUTPUT_FILENAME"

# Warne den Benutzer, wenn der erkannte Typ nicht mit der angeforderten Erweiterung übereinstimmt (einfache Prüfung)
USER_EXT="${OUTPUT_FILENAME##*.}"
USER_EXT_LOWER=$(echo "$USER_EXT" | tr '[:upper:]' '[:lower:]')

if echo "$DETECTED_TYPE" | grep -qE "MPEG ADTS.*layer III|MP3"; then
    if [[ "$USER_EXT_LOWER" != "mp3" ]]; then
        echo "Warnung: Erkannter Typ scheint MP3 zu sein, wurde aber mit der Erweiterung .$USER_EXT gespeichert"
    fi
elif echo "$DETECTED_TYPE" | grep -qE "RIFF.*WAVE audio"; then
     if [[ "$USER_EXT_LOWER" != "wav" ]]; then
        echo "Warnung: Erkannter Typ scheint WAV zu sein, wurde aber mit der Erweiterung .$USER_EXT gespeichert"
    fi
elif echo "$DETECTED_TYPE" | grep -q "Speex audio"; then
     if [[ "$USER_EXT_LOWER" != "speex" ]]; then
        echo "Warnung: Erkannter Typ scheint Speex zu sein, wurde aber mit der Erweiterung .$USER_EXT gespeichert"
        echo "Hinweis: Standard-Audioplayer können Speex-Dateien möglicherweise nicht direkt abspielen."
    fi
else
     echo "Warnung: Konnte erkannten Typ ($DETECTED_TYPE) nicht sicher einer gängigen Audio-Erweiterung (.mp3, .wav, .speex) zuordnen."
fi

echo "Skript beendet."
# Abmeldung wird durch den Trap EXIT gehandhabt

exit 0
