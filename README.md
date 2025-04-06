# Fritz!Box Voicemail Tools (Web Scraper)

Dieses Skript ermöglicht das Auflisten und Herunterladen von Voicemail-Nachrichten von einer AVM Fritz!Box über die Weboberfläche (Web-Scraping). Es ist eine Alternative für Fälle, in denen die TR-064 Schnittstelle nicht zuverlässig funktioniert oder gewünscht ist.

**Sprache:** [English](#english) | [Deutsch](#deutsch)

---

## <a name="deutsch"></a>Deutsch 🇩🇪

### Einleitung

Dieses Set aus Bash-Skripten interagiert mit dem Webinterface Ihrer Fritz!Box, um auf Voicemail-Nachrichten zuzugreifen, die auf einem angeschlossenen USB-Speicher oder dem internen Speicher abgelegt sind. Es meldet sich an, holt die Liste der Nachrichten von einer internen Lua-Seite (`data.lua`) und parst diese, um sie anzuzeigen oder die zugehörigen Audiodateien herunterzuladen. Da das von der Fritz!Box gelieferte HTML teilweise fehlerhaft sein kann, wird für das Parsing auf robuste Regex-Methoden (awk, grep) zurückgegriffen.

### Features

*   **Auflisten (`--list`):** Zeigt Voicemail-Nachrichten an.
    *   **Filter:** `all` (Standard), `latest` (neueste), `<index>` (spezifische Nachricht), `known` (Anrufer im Telefonbuch), `unknown` (Anrufer nicht im Telefonbuch).
    *   **Formate (`--format`):**
        *   `table`: Gut lesbare Tabelle (benötigt `column`).
        *   `simple`: Eine Zeile pro Nachricht mit Schlüssel-Wert-Paaren.
        *   `json`: Ausgabe im JSON-Format (benötigt `jq`).
        *   `csv`: Semikolon-getrennte Werte, geeignet für Tabellenkalkulationen.
    *   **Reine Ausgabe:** Ausgabe in Datei (`--output-file`) oder via Pipe (`|`)/Umleitung (`>`) enthält nur die reinen Daten (keine Header/Logs).
*   **Herunterladen (`--download`):** Lädt Sprachnachrichten herunter.
    *   **Auswahl:** `latest` (neueste), `<index>` (spezifische Nachricht), `all` (alle Nachrichten auf dem ausgewählten AB).
    *   **Ziel:** Einzelne Datei oder Verzeichnis (`--output`).
    *   **Audio-Format (`--audio-format`):** Explizite Auswahl des Zielformats (`wav`, `ogg`, `mp3`). Benötigt `ffmpeg` für `ogg`/`mp3`.
    *   **Automatische Konvertierung:** Bei `--download latest|index` wird das Zielformat auch aus der Dateiendung von `--output` erkannt (z.B. `--output anruf.mp3`). `--audio-format` hat Vorrang. Bei `--download all` ist `wav` Standard, außer `--audio-format` wird gesetzt.
*   **Anrufbeantworter-Auswahl (`--tam <index>`):** Wählt den gewünschten Anrufbeantworter aus (Standard: 0).
*   **Ausführliches Logging (`-v`, `--verbose`):** Zeigt detaillierte Debug-Informationen auf Stderr.
*   **Sauberes Beenden:** Korrekte Handhabung von Strg+C (SIGINT) inklusive Abmeldung von der Fritz!Box.
*   **Modulare Struktur:** Aufgeteilt in Bibliothek (`fb_lib.sh`), Parser (`_parse_voicemail_html.sh`) und Hauptskript (`fb-voicemailtools.sh`).

### Voraussetzungen

*   **Bash:** Version 4+ wird empfohlen (wegen `mapfile`).
*   **Kernwerkzeuge:** `curl`, `md5sum`, `iconv`, `awk`, `grep` (GNU-Version mit `-P` Support empfohlen), `sed`, `file`. Diese sind auf den meisten Linux-Systemen Standard.
*   **Optional:**
    *   `jq`: Benötigt für `--format json` und intern für den Download (`jq` wird zur URL-Kodierung verwendet). **Praktisch obligatorisch für Download.**
    *   `column`: Benötigt für schön formatierte `--format table` Ausgabe.
    *   `ffmpeg`: Benötigt für die Audio-Konvertierung zu `.ogg` oder `.mp3`.
*   **Konfigurationsdatei:** Eine Datei namens `fb-credentials` im selben Verzeichnis wie die Skripte.

### Installation

1.  **Klonen oder Herunterladen:**
    ```bash
    git clone <repository_url> # Oder lade die .sh Dateien herunter
    cd <repository_verzeichnis>
    ```
2.  **Ausführbar machen:**
    ```bash
    chmod +x fb_lib.sh _parse_voicemail_html.sh fb-voicemailtools.sh
    ```
3.  **Konfigurationsdatei erstellen:**
    *   Kopiere die Beispiel-Datei (falls vorhanden) oder erstelle eine neue Datei `fb-credentials`.
    *   ```bash
      # Beispiel: cp fb-credentials.example fb-credentials
      nano fb-credentials
      ```
    *   Füge deine Fritz!Box-Daten hinzu (siehe nächster Abschnitt).
4.  **Berechtigungen für Konfigurationsdatei setzen (Empfohlen):**
    ```bash
    chmod 600 fb-credentials
    ```

### Konfiguration (`fb-credentials`)

Die Datei `fb-credentials` muss folgende Zeilen enthalten:

```ini
# URL Ihrer Fritz!Box (mit http:// oder https://)
FRITZBOX_URL="http://fritz.box"

# Benutzername für die Fritz!Box Anmeldung.
# Lassen Sie den Wert leer, wenn Sie sich nur mit Passwort anmelden.
# Wichtig: Der Benutzer benötigt die Berechtigung "Fritz!Box Einstellungen".
FRITZBOX_USER="mein_benutzer"

# Passwort für die Fritz!Box Anmeldung.
FRITZBOX_PASSWORD="mein_super_sicheres_passwort"