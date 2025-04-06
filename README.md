# Fritz!Box Voicemail Tools (Web Scraper)

Dieses Skript ermöglicht das Auflisten und Herunterladen von Voicemail-Nachrichten von einer AVM Fritz!Box über die Weboberfläche (Web-Scraping).

**Language:** [English](#english) | [Deutsch](#deutsch)

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
    *   **Konvertierung:**
        *   **Automatisch (für `latest`/`<index>`):** Wenn `--output` auf `.ogg` oder `.mp3` endet, wird `ffmpeg` zur Konvertierung verwendet.
        *   **Explizit (`--audio-format <format>`):** Erzwingt das Zielformat (`wav`, `ogg`, `mp3`). Nötig für Konvertierung bei `--download all`. Hat Vorrang vor der Dateiendung.
        *   **Standard:** `.wav`, wenn keine Konvertierung angefordert wird.
*   **Anrufbeantworter-Auswahl (`--tam <index>`):** Wählt den gewünschten Anrufbeantworter aus (Standard: 0).
*   **Ausführliches Logging (`-v`, `--verbose`):** Zeigt detaillierte Debug-Informationen auf Stderr (inklusive `curl -v` beim Download).
*   **Sauberes Beenden:** Korrekte Handhabung von Strg+C (SIGINT) inklusive Abmeldung von der Fritz!Box.
*   **Modulare Struktur:** Aufgeteilt in Bibliothek (`fb_lib.sh`), Parser (`_parse_voicemail_html.sh`) und Hauptskript (`fb-voicemailtools.sh`).

### Voraussetzungen

*   **Bash:** Version 4+ wird empfohlen (wegen `mapfile`).
*   **Kernwerkzeuge:** `curl`, `md5sum`, `iconv`, `awk`, `grep` (GNU-Version mit `-P` Support empfohlen), `sed`, `file`. Diese sind auf den meisten Linux-Systemen Standard.
*   **Optional:**
    *   `jq`: Benötigt für `--format json` und intern für den Download (URL-Kodierung). **Stark empfohlen.**
    *   `column`: Benötigt für schön formatierte `--format table` Ausgabe.
    *   `ffmpeg`: Benötigt für die Audio-Konvertierung zu `.ogg` oder `.mp3`.
*   **Konfigurationsdatei:** Eine Datei namens `fb-credentials` im selben Verzeichnis wie die Skripte.

### Installation

1.  **Klonen oder Herunterladen:**
    ```bash
    # Ersetze <repository_url> mit der tatsächlichen URL deines GitHub Repos
    git clone <repository_url>
    cd fb-voicemailtools # Oder wie auch immer das Verzeichnis heißt
    ```
    *(Alternativ: Lade die `.sh`-Dateien manuell herunter und lege sie in ein Verzeichnis)*
2.  **Ausführbar machen:**
    ```bash
    chmod +x fb_lib.sh _parse_voicemail_html.sh fb-voicemailtools.sh
    ```
3.  **Konfigurationsdatei erstellen:**
    *   Erstelle eine neue Datei `fb-credentials`.
    *   ```bash
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
```
*Ersetze `http://fritz.box`, `mein_benutzer` und `mein_super_sicheres_passwort` mit deinen tatsächlichen Daten.*

### Verwendung

**Grundlegende Syntax:**

```bash
./fb-voicemailtools.sh <Aktion> [Optionen]
```

**Beispiele:**

*   **Alle Nachrichten auflisten (Tabelle):**
    ```bash
    ./fb-voicemailtools.sh --list
    ```
*   **Neueste Nachricht im Simple-Format anzeigen:**
    ```bash
    ./fb-voicemailtools.sh --list latest --format simple
    ```
*   **Nachrichten von unbekannten Anrufern als CSV speichern (nur Daten):**
    ```bash
    ./fb-voicemailtools.sh --list unknown --format csv > unbekannt.csv
    ```
    *(Oder: `./fb-voicemailtools.sh --list unknown --format csv --output-file unbekannt.csv`)*
*   **Nachricht mit Index 5 herunterladen und als OGG speichern (automatische Konvertierung):**
    ```bash
    ./fb-voicemailtools.sh --download 5 --output nachricht_5.ogg
    ```
*   **Alle Nachrichten von TAM 1 als MP3 herunterladen (explizite Konvertierung nötig):**
    ```bash
    mkdir ./tam1_mp3
    ./fb-voicemailtools.sh --download all --tam 1 --output ./tam1_mp3/ --audio-format mp3
    ```
*   **Download mit ausführlichem Debugging (inkl. curl -v):**
    ```bash
    ./fb-voicemailtools.sh --download latest --output test.wav -v
    ```

### Bekannte Probleme / Einschränkungen

*   **Fehlerhaftes HTML:** Das Skript verwendet Regex zum Parsen, da das von `data.lua` gelieferte HTML strukturelle Fehler enthalten kann, die Standard-Parser zum Scheitern bringen. Zukünftige Änderungen am Fritz!OS-Webinterface könnten den Regex-Parser unbrauchbar machen.
*   **"Bekannt?"-Status:** Die Anzeige, ob ein Anrufer im Telefonbuch "bekannt" ist, basiert darauf, ob der entsprechende Button im Webinterface aktiv ist. Es gibt Berichte, dass diese Anzeige auf der Fritz!Box selbst nicht immer 100% korrekt ist. Das Skript spiegelt den Zustand des Webinterfaces wider.
*   **Download `all` + Konvertierung:** Für `--download all` muss das Zielformat explizit mit `--audio-format <ogg|mp3>` angegeben werden, wenn eine Konvertierung gewünscht ist. Eine automatische Erkennung über `--output` ist hier nicht möglich, da es ein Verzeichnis ist.

### Lizenz

Dieses Projekt steht unter der [MIT Lizenz](LICENSE). (Füge ggf. eine LICENSE-Datei hinzu)

---

## <a name="english"></a>English 🇬🇧

### Introduction

This script allows listing and downloading voicemail messages from an AVM Fritz!Box using its web interface (Web Scraping). It serves as an alternative in cases where the TR-064 interface is unreliable or not desired.

This set of bash scripts interacts with your Fritz!Box's web interface to access voicemail messages stored on a connected USB drive or internal memory. It logs in, retrieves the message list from an internal Lua page (`data.lua`), and parses it to display the list or download the corresponding audio files. As the HTML provided by the Fritz!Box can sometimes be malformed, robust regex methods (awk, grep) are used for parsing.

### Features

*   **List (`--list`):** Displays voicemail messages.
    *   **Filters:** `all` (default), `latest`, `<index>` (specific message), `known` (caller in phonebook), `unknown` (caller not in phonebook).
    *   **Formats (`--format`):**
        *   `table`: Human-readable table (requires `column`).
        *   `simple`: One line per message with key-value pairs.
        *   `json`: Output in JSON format (requires `jq`).
        *   `csv`: Semicolon-separated values, suitable for spreadsheets.
    *   **Clean Output:** Output to file (`--output-file`) or via pipe (`|`)/redirection (`>`) contains only the raw data (no headers/logs).
*   **Download (`--download`):** Downloads voice messages.
    *   **Selection:** `latest`, `<index>`, `all` (all messages on the selected answering machine).
    *   **Target:** Single file or directory (`--output`).
    *   **Conversion:**
        *   **Automatic (for `latest`/`<index>`):** If `--output` ends with `.ogg` or `.mp3`, `ffmpeg` is used for conversion.
        *   **Explicit (`--audio-format <format>`):** Forces the target format (`wav`, `ogg`, `mp3`). Necessary for conversion with `--download all`. Takes precedence over the file extension.
        *   **Default:** `.wav` if no conversion is requested.
*   **Answering Machine Selection (`--tam <index>`):** Selects the desired answering machine (default: 0).
*   **Verbose Logging (`-v`, `--verbose`):** Shows detailed debug information on Stderr (including `curl -v` during download).
*   **Clean Exit:** Correct handling of Ctrl+C (SIGINT) including Fritz!Box logout.
*   **Modular Structure:** Divided into a library (`fb_lib.sh`), parser (`_parse_voicemail_html.sh`), and main script (`fb-voicemailtools.sh`).

### Prerequisites

*   **Bash:** Version 4+ recommended (due to `mapfile`).
*   **Core Tools:** `curl`, `md5sum`, `iconv`, `awk`, `grep` (GNU version with `-P` support recommended), `sed`, `file`. These are standard on most Linux systems.
*   **Optional:**
    *   `jq`: Required for `--format json` and internally for downloads (URL encoding). **Highly recommended.**
    *   `column`: Required for nicely formatted `--format table` output.
    *   `ffmpeg`: Required for audio conversion to `.ogg` or `.mp3`.
*   **Configuration File:** A file named `fb-credentials` in the same directory as the scripts.

### Installation

1.  **Clone or Download:**
    ```bash
    # Replace <repository_url> with the actual URL of your GitHub repo
    git clone <repository_url>
    cd fb-voicemailtools # Or whatever the directory is called
    ```
    *(Alternatively: Download the `.sh` files manually and place them in a directory)*
2.  **Make Executable:**
    ```bash
    chmod +x fb_lib.sh _parse_voicemail_html.sh fb-voicemailtools.sh
    ```
3.  **Create Configuration File:**
    *   Create a new file named `fb-credentials`.
    *   ```bash
      nano fb-credentials
      ```
    *   Add your Fritz!Box details (see next section).
4.  **Set Permissions for Config File (Recommended):**
    ```bash
    chmod 600 fb-credentials
    ```

### Configuration (`fb-credentials`)

The `fb-credentials` file must contain the following lines:

```ini
# URL of your Fritz!Box (including http:// or https://)
FRITZBOX_URL="http://fritz.box"

# Username for Fritz!Box login.
# Leave the value empty if you only use a password to log in.
# Important: The user needs the "Fritz!Box Settings" permission.
FRITZBOX_USER="my_user"

# Password for Fritz!Box login.
FRITZBOX_PASSWORD="my_super_secret_password"
```
*Replace `http://fritz.box`, `my_user`, and `my_super_secret_password` with your actual details.*

### Usage

**Basic Syntax:**

```bash
./fb-voicemailtools.sh <action> [options]
```

**Examples:**

*   **List all messages (table format):**
    ```bash
    ./fb-voicemailtools.sh --list
    ```
*   **Show latest message in simple format:**
    ```bash
    ./fb-voicemailtools.sh --list latest --format simple
    ```
*   **Save messages from unknown callers as CSV (data only):**
    ```bash
    ./fb-voicemailtools.sh --list unknown --format csv > unknown.csv
    ```
    *(Or: `./fb-voicemailtools.sh --list unknown --format csv --output-file unknown.csv`)*
*   **Download message with index 5 and save as OGG (automatic conversion):**
    ```bash
    ./fb-voicemailtools.sh --download 5 --output message_5.ogg
    ```
*   **Download all messages from TAM 1 as MP3 (explicit conversion required):**
    ```bash
    mkdir ./tam1_mp3
    ./fb-voicemailtools.sh --download all --tam 1 --output ./tam1_mp3/ --audio-format mp3
    ```
*   **Download with verbose debugging (incl. curl -v):**
    ```bash
    ./fb-voicemailtools.sh --download latest --output test.wav -v
    ```

### Known Issues / Limitations

*   **Malformed HTML:** The script uses regex for parsing because the HTML provided by `data.lua` can contain structural errors that cause standard parsers to fail. Future changes to the Fritz!OS web interface might break the regex parser.
*   **"Known?" Status:** The indication of whether a caller is "known" in the phonebook is based on whether the corresponding button is active in the web interface. There are reports that this indication on the Fritz!Box itself is not always 100% accurate. The script reflects the state shown in the web interface.
*   **Download `all` + Conversion:** For `--download all`, the target format must be specified explicitly using `--audio-format <ogg|mp3>` if conversion is desired. Automatic detection via the `--output` argument is not possible here, as it's a directory.

### License

This project is licensed under the [MIT License](LICENSE). (Consider adding a LICENSE file)
