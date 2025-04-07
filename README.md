# Fritz!Box Voicemail Tools (TR-064/XML)

Ein Kommandozeilen-Skript (`fritzbox-voicemail-tools.sh`), um Voicemail-Nachrichten von einer AVM Fritz!Box über das TR-064 Protokoll aufzulisten und herunterzuladen.

This is a command-line script (`fritzbox-voicemail-tools.sh`) to list and download voicemail messages from an AVM Fritz!Box using the TR-064 protocol.

**Sprache:** [English](#english) | [Deutsch](#deutsch)

## <a name="deutsch"></a>Deutsch 🇩🇪
---

## Features

*   **Nachrichten auflisten (`--list`)**
    *   Filter: `all` (Standard), `latest`, `index <nr>`, `known` (Name vorhanden), `unknown` (kein Name).
    *   Ausgabeformate (`--format`): `table` (Standard), `json`, `simple`, `csv`, `xml`.
    *   Ausgabe in Datei (`--output-file`).
    *   Auswahl des Anrufbeantworters (`--tam <index>`).
*   **Nachrichten herunterladen (`--download`)**
    *   Ziele: `latest`, `all` oder spezifischer `index <nr>`.
    *   Zielangabe (`--output`): Dateiname (für einzelne) oder Verzeichnis (für `all`/`latest`).
    *   Automatische Dateinamengenerierung (Format: `JJJJMMTT_HHMM_AnruferName.wav/.ogg/.mp3`).
    *   **Optionale Audiokonvertierung** (`--audio-format`): `wav` (Standard, keine Konvertierung), `ogg`, `mp3` (benötigt `ffmpeg`).
    *   Konvertierung wird auch aktiviert, wenn die `--output`-Dateiendung `.ogg` oder `.mp3` ist (bei Einzeldownloads).
*   **Debugging:** Gestufte Ausführlichkeit (`-v`, `-vv`, `-vvv`) zur Fehleranalyse. Standardmäßig nur Fehler-/Warnmeldungen.
*   **Robustheit:** Nutzt `awk` für stabiles Parsen der von der Fritz!Box gelieferten XML-Daten.
*   **Benutzerfreundlichkeit:** Standardkonform (`--long-option`, `-s`), saubere Fehlerbehandlung, Strg+C-Abbruch.

## Voraussetzungen

*   **System:** Linux/macOS/WSL mit Bash v4+ und Standard-Tools:
    *   `curl`
    *   `awk` (GNU Awk / `gawk` empfohlen)
    *   `sed`, `grep` (GNU-Versionen empfohlen)
    *   `file`, `date`, `od`, `mktemp`, `dirname`, `basename`, `wc`, `cut`, `tr`, `head`, `paste`
*   **Optional:**
    *   `jq`: Für `--format json` und robustere URL-Kodierung beim Download.
    *   `column`: Für schönere Tabellenausgabe (`--format table`).
    *   `ffmpeg`: Für Audiokonvertierung (`--audio-format ogg` oder `mp3`).
*   **Fritz!Box:**
    *   TR-064 Protokoll muss in der Fritz!Box-Oberfläche aktiviert sein (Heimnetz > Netzwerk > Netzwerkeinstellungen > Heimnetzfreigaben > Zugriff für Anwendungen zulassen).
    *   Ein Fritz!Box-Benutzer mit Kennwort und der Berechtigung "Sprachnachrichten, Faxnachrichten, E-Mails und Smarthome-Geräte". **Wichtig:** Der Standardbenutzer `fritz****` reicht oft nicht aus, es muss ein explizit angelegter Benutzer sein.

## Installation & Setup

1.  **Skript herunterladen:**
    Lade die `fritzbox-voicemail-tools.sh`-Datei aus diesem Repository herunter oder klone das Repository:
    ```bash
    git clone https://github.com/HerrGuhr/fritzbox-voicemail-tools.git
    cd fritzbox-voicemail-tools
    ```
2.  **Ausführbar machen:**
    ```bash
    chmod +x fritzbox-voicemail-tools.sh
    ```
3.  **Anmeldedatei erstellen:**
    Erstelle im selben Verzeichnis wie das Skript eine Datei namens `fb-credentials` mit folgendem Inhalt (ersetze die Platzhalter):
    ```ini
    # Anmeldedaten für Fritz!Box TR-064 Zugriff
    # URL oder IP-Adresse der Fritz!Box (ohne http://)
    FRITZBOX_URL="fritz.box"
    # Benutzername (muss TR-064 Berechtigung haben)
    FRITZBOX_USER="mein_tr064_benutzer"
    # Passwort für den Benutzer
    FRITZBOX_PASSWORD="mein_sicheres_passwort"
    ```
    **Wichtig:** Schütze diese Datei vor unbefugtem Zugriff (`chmod 600 fb-credentials`).

## Benutzung

Das Skript wird über die Kommandozeile aufgerufen.

```bash
./fritzbox-voicemail-tools.sh <AKTION> [OPTIONEN]
```

**Beispiele:**

*   **Alle Nachrichten auflisten (Standard: Tabelle):**
    ```bash
    ./fritzbox-voicemail-tools.sh --list
    ```
*   **Neueste Nachricht im einfachen Format anzeigen:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list latest --format simple
    ```
*   **Nachricht mit Index 42 als JSON ausgeben:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list 42 --format json
    ```
*   **Alle unbekannten Nachrichten als CSV in eine Datei schreiben:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list unknown --format csv --output-file unbekannt.csv
    ```
*   **Neueste Nachricht herunterladen und als MP3 speichern:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download latest --output neueste_nachricht.mp3
    ```
    *(Benötigt `ffmpeg`)*
*   **Alle Nachrichten herunterladen und als OGG im Verzeichnis `~/voicemails` speichern:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download all --output ~/voicemails/ --audio-format ogg
    ```
    *(Benötigt `ffmpeg`)*
*   **Nachricht Nr. 10 vom zweiten Anrufbeantworter (Index 1) herunterladen:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download 10 --tam 1 --output nachricht_10_ab1.wav
    ```
*   **Liste mit Basis-Debugging anzeigen:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list -v
    ```
*   **Download mit sehr detailliertem Debugging:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download latest --output temp.wav -vvv
    ```

## Konfiguration

Die einzige Konfiguration erfolgt über die `fb-credentials`-Datei (siehe "Installation & Setup").

## Lizenz

Dieses Projekt steht unter der MIT-Lizenz..

## Kontakt

Bei Fragen oder Problemen erstelle bitte ein Issue im GitHub Repository.

---

## English Version

### Fritz!Box Voicemail Tools (TR-064/XML)

Version: 2.00
Author: Marc Guhr (<marc.guhr@gmail.com>)
Repository: <https://github.com/HerrGuhr/fritzbox-voicemail-tools>
License: MIT

A command-line script (`fritzbox-voicemail-tools.sh`) to list and download voicemail messages from an AVM Fritz!Box using the TR-064 protocol.

---
## <a name="english"></a>English 🇩🇪
### Features

*   **List Messages (`--list`)**
    *   Filters: `all` (default), `latest`, `index <nr>`, `known` (name present), `unknown` (no name).
    *   Output Formats (`--format`): `table` (default), `json`, `simple`, `csv`, `xml`.
    *   Output to file (`--output-file`).
    *   Select Answering Machine (`--tam <index>`).
*   **Download Messages (`--download`)**
    *   Targets: `latest`, `all`, or specific `index <nr>`.
    *   Output Target (`--output`): Filename (for single) or Directory (for `all`/`latest`).
    *   Automatic filename generation (Format: `YYYYMMDD_HHMM_CallerName.wav/.ogg/.mp3`).
    *   **Optional Audio Conversion** (`--audio-format`): `wav` (default, no conversion), `ogg`, `mp3` (requires `ffmpeg`).
    *   Conversion is also activated if the `--output` filename ends with `.ogg` or `.mp3` (for single downloads).
*   **Debugging:** Stepped verbosity levels (`-v`, `-vv`, `-vvv`) for troubleshooting. Default is quiet (only errors/warnings).
*   **Robustness:** Uses `awk` for stable parsing of the XML data provided by the Fritz!Box.
*   **Usability:** Standard-compliant options (`--long-option`, `-s`), clean error handling, Ctrl+C trapping.

### Requirements

*   **System:** Linux/macOS/WSL with Bash v4+ and standard tools:
    *   `curl`
    *   `awk` (GNU Awk / `gawk` recommended)
    *   `sed`, `grep` (GNU versions recommended)
    *   `file`, `date`, `od`, `mktemp`, `dirname`, `basename`, `wc`, `cut`, `tr`, `head`, `paste`
*   **Optional:**
    *   `jq`: For `--format json` and more robust URL encoding during download.
    *   `column`: For nicer table output (`--format table`).
    *   `ffmpeg`: For audio conversion (`--audio-format ogg` or `mp3`).
*   **Fritz!Box:**
    *   TR-064 protocol must be enabled in the Fritz!Box web interface (Heimnetz > Netzwerk > Netzwerkeinstellungen > Heimnetzfreigaben > Zugriff für Anwendungen zulassen / Home Network > Network > Network Settings > Home Network Sharing > Allow access for applications).
    *   A Fritz!Box user with a password and the permission "Sprachnachrichten, Faxnachrichten, E-Mails und Smarthome-Geräte" (Voice messages, fax messages, e-mails and smarthome devices). **Important:** The default user `fritz****` might not be sufficient; an explicitly created user is often required.

### Installation & Setup

1.  **Download the Script:**
    Download the `fritzbox-voicemail-tools.sh` file from this repository or clone the repository:
    ```bash
    git clone https://github.com/HerrGuhr/fritzbox-voicemail-tools.git
    cd fritzbox-voicemail-tools
    ```
2.  **Make it Executable:**
    ```bash
    chmod +x fritzbox-voicemail-tools.sh
    ```
3.  **Create Credentials File:**
    In the same directory as the script, create a file named `fb-credentials` with the following content (replace placeholders):
    ```ini
    # Credentials for Fritz!Box TR-064 Access
    # URL or IP Address of the Fritz!Box (without http://)
    FRITZBOX_URL="fritz.box"
    # Username (must have TR-064 permission)
    FRITZBOX_USER="my_tr064_user"
    # Password for the user
    FRITZBOX_PASSWORD="my_secure_password"
    ```
    **Important:** Protect this file from unauthorized access (`chmod 600 fb-credentials`).

### Usage

The script is called via the command line.

```bash
./fritzbox-voicemail-tools.sh <ACTION> [OPTIONS]
```

**Examples:**

*   **List all messages (default: table):**
    ```bash
    ./fritzbox-voicemail-tools.sh --list
    ```
*   **List the latest message in simple format:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list latest --format simple
    ```
*   **Output message with index 42 as JSON:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list 42 --format json
    ```
*   **Write all unknown messages as CSV to a file:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list unknown --format csv --output-file unknown.csv
    ```
*   **Download the latest message and save as MP3:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download latest --output latest_message.mp3
    ```
    *(Requires `ffmpeg`)*
*   **Download all messages and save as OGG in the `~/voicemails` directory:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download all --output ~/voicemails/ --audio-format ogg
    ```
    *(Requires `ffmpeg`)*
*   **Download message #10 from the second answering machine (index 1):**
    ```bash
    ./fritzbox-voicemail-tools.sh --download 10 --tam 1 --output message_10_tam1.wav
    ```
*   **List messages with basic debugging:**
    ```bash
    ./fritzbox-voicemail-tools.sh --list -v
    ```
*   **Download with very detailed debugging:**
    ```bash
    ./fritzbox-voicemail-tools.sh --download latest --output temp.wav -vvv
    ```

### Configuration

The only configuration happens via the `fb-credentials` file (see "Installation & Setup").

### License

This project is licensed under the MIT License.

### Contact

For questions or issues, please create an Issue in the GitHub repository.
