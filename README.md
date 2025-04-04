# fritzbox_voicemail_downloader
Fritz!Box OS8 Voicemail Downloader (Bash Script)

Beispiel:
download_voicemail_de.sh 123 ausgabe.wav
Wobei 123 der Nummer im rec Ordner entspricht.

(vorausgesetzt der pfad ist per smb gemountet) kann man z.b. mit dem befehl
ls -t /pfad/zum/mount/zur/fritzbox/rec.* | head -n1 | awk -F '.' '{printf "%s", $NF}'
die "id" der letzten Nachricht erhalten

hier als onliner der die aktuellste nachricht in das aktuelle verzeichnis schreibt (vorausgesetzt das script ist in diesem pfad)

id=$(ls -t /pfad/zum/mount/zur/fritzbox/rec.* | head -n1 | awk -F '.' '{printf "%s", $NF}');./download_voicemail_de.sh $id $id.wav
