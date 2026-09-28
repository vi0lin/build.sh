#!/usr/bin/env bash
# publish_release.sh <build-ordner>
#     -- Regelfall: der Release-Name ist der NAME DES ORDNERS.
#            publish_release.sh builds/deb-asan    ->  "deb-asan"
#        Die App sucht unter demselben Namen (CMake baut den Namen des
#        Bauordners als XBM_RELEASE_NAME ein), beide passen also von selbst.
#
# publish_release.sh <name> <build-ordner> [version]
#     -- Name ausdruecklich:
#            publish_release.sh linux-debug builds/deb-asan  ->  "linux-debug"
#        Die App muss dann mit  -DXBM_RELEASE_NAME=linux-debug  gebaut sein.
#
# Paketiert ein fertiges Release (Programmdatei + benoetigte data/) und
# veroeffentlicht es ueber ein EIGENES, kleines Releases-Git-Repository --
# derselbe Roh-Datei-Weg, der fuer den Quellcode-Sync schon nachweislich
# funktioniert (git_pull_host in build.sh), nur fuer Binaerdateien in einem
# SEPARATEN Repository, damit sie nicht die Quellcode-Historie aufblaehen.
#
# [Warum ein eigenes Repo statt Binaerdateien im Quellcode-Repo: jede
#  neue .apk/.exe bliebe sonst FUER IMMER in der Git-Historie liegen, auch
#  nach dem naechsten Release -- das Repo wuerde mit jeder Version weiter
#  wachsen. Hier wird stattdessen bei jeder Veroeffentlichung derselbe EINE
#  Commit ueberschrieben (git commit --amend + --force push) -- das
#  Releases-Repo waechst dadurch praktisch nicht, nur der JEWEILS AKTUELLE
#  Stand zaehlt, alte Versionen braucht die App-Update-Pruefung ohnehin
#  nicht.]
#
# VORAUSSETZUNG: config/release.conf mit
#   RELEASE_GIT_URL="http://192.168.1.69:3000/releases.git"
#   RELEASE_NOTES="Kurzbeschreibung dieser Version"      (optional)
set -euo pipefail

if (( $# == 1 )); then
  # NUR DER BAU-ORDNER -- der Release-Name ist sein Name.
  # [Vorher kam er aus RELEASE_NAME[] in config/targets.conf (deb ->
  #  "linux", exe -> "windows" ...). Der Ordnername ist eindeutig, steht
  #  schon im Aufruf und passt zu dem, was die App sucht.]
  quelle=${1%/}
  version=""
  schluessel=$(basename -- "$quelle")
  if [[ -z $schluessel || $schluessel == . || $schluessel == / ]]; then
    echo "Aus '$1' laesst sich kein Release-Name ableiten -- Ordner angeben" >&2
    echo "(z.B. builds/deb) oder den Namen ausdruecklich:" >&2
    echo "    publish_release.sh <name> <build-ordner>" >&2
    exit 1
  fi
elif (( $# >= 2 )); then
  # NAME UND PFAD AUSDRUECKLICH.
  schluessel=$1
  quelle=${2%/}
  version=${3:-}
else
  echo "Nutzung: publish_release.sh <build-ordner>" >&2
  echo "     oder publish_release.sh <name> <build-ordner> [version]" >&2
  exit 1
fi

# PAKETART AUS DEM INHALT DES BAU-ORDNERS ABLEITEN, NICHT AUS DEM NAMEN.
# [Genau deshalb bleibt das Skript projektunabhaengig -- es fragt "was
#  liegt da tatsaechlich drin", nicht "wie hast du es genannt". Eine .apk
#  im Ordner -> Android-Paket; eine .exe -> Windows-Zip; sonst wird eine
#  einzelne Programmdatei im obersten Ordner erwartet (Linux/Mac-Binary).]
shopt -s nullglob
# ZWISCHENSTAENDE DES APK-BAUS NICHT MITZAEHLEN. [build_apk.sh legt in
#  denselben Ordner auch <name>-unaligned.apk und <name>-aligned.apk --
#  beide UNSIGNIERT. Nach einem Bau, der zwischen Ausrichten und Signieren
#  abbrach, liegen sie noch da, und alphabetisch kommt "-aligned" VOR dem
#  fertigen "<name>.apk": veroeffentlicht worden waere ein unsigniertes
#  Paket, das kein Android installiert.]
apks=()
for _a in "$quelle"/*.apk; do
  case $_a in *-unaligned.apk|*-aligned.apk) continue ;; esac
  apks+=("$_a")
done
exes=("$quelle"/*.exe)
shopt -u nullglob
if (( ${#apks[@]} > 1 )); then
  echo "  Mehrere .apk in $quelle -- nicht eindeutig, welche gemeint ist:" >&2
  printf '    %s\n' "${apks[@]}" >&2
  exit 1
fi
if (( ${#apks[@]} > 0 )); then
  paketart=apk
elif (( ${#exes[@]} > 0 )); then
  paketart=zip
else
  paketart=tar
fi

# FRISCHE-PRUEFUNG: NICHTS VEROEFFENTLICHEN, WAS GAR NICHT NEU IST.
#
# [Genau das ist passiert: build_apk.sh brach intern mit "Configuring
#  incomplete, errors occurred!" ab, gab aber trotzdem 0 zurueck.
#  build.sh hielt den Bau daher fuer erfolgreich -- und veroeffentlichte
#  klaglos die ALTE .apk, die noch von einem frueheren Lauf in
#  builds/android lag. Im Protokoll stand "Veroeffentlicht", auf dem
#  Geraet landete wochenlang dieselbe Fassung, und der Zeitstempel in
#  der App blieb auf dem alten Stand stehen. Ein Fehlschlag, der wie ein
#  Erfolg aussieht -- die unangenehmste Sorte.
#
#  Deshalb: build.sh reicht den Zeitpunkt UNMITTELBAR VOR dem Bau als
#  XBM_BAU_BEGINN herein. Ist die zu verpackende Datei AELTER als
#  dieser Zeitpunkt, kann sie unmoeglich aus diesem Lauf stammen --
#  dann wird abgebrochen statt veroeffentlicht.
#
#  Von Hand aufgerufen (ohne XBM_BAU_BEGINN) entfaellt die Pruefung --
#  dort will man ja bewusst auch einen aelteren Stand hochladen
#  koennen.]
if [[ -n ${XBM_BAU_BEGINN:-} ]] && [[ ${XBM_BAU_BEGINN} != 0 ]]; then
  neueste=""
  case $paketart in
    apk) neueste=${apks[0]} ;;
    zip) neueste=${exes[0]} ;;
    tar) neueste="$quelle/x_bookmark_manager" ;;
  esac
  if [[ -f $neueste ]]; then
    # Aenderungszeit portabel ermitteln (GNU stat, sonst BSD stat).
    dateizeit=$(stat -c %Y "$neueste" 2>/dev/null || stat -f %m "$neueste" 2>/dev/null || echo 0)
    if [[ -n $dateizeit ]] && (( dateizeit > 0 )) && (( dateizeit < XBM_BAU_BEGINN )); then
      echo "  ABBRUCH: '$neueste' ist AELTER als der Beginn dieses Baus." >&2
      echo "    Datei:     $(date -d "@$dateizeit" 2>/dev/null || date -r "$dateizeit" 2>/dev/null || echo "$dateizeit")" >&2
      echo "    Baubeginn: $(date -d "@$XBM_BAU_BEGINN" 2>/dev/null || date -r "$XBM_BAU_BEGINN" 2>/dev/null || echo "$XBM_BAU_BEGINN")" >&2
      echo "    Der Bau hat also gar kein neues Paket erzeugt -- vermutlich ist er" >&2
      echo "    fehlgeschlagen, ohne das zu melden (Rueckgabewert 0 trotz Fehler)." >&2
      echo "    Es wird NICHTS veroeffentlicht, damit nicht erneut ein alter Stand" >&2
      echo "    aufgespielt wird." >&2
      exit 1
    fi
  fi
fi

# VERSION = ZEITSTEMPEL DES LETZTEN COMMITS -- derselbe Wert, den CMake in
# das Programm einbaut (siehe CMakeLists.txt, XBM_VERSION_GEN). Beide
# Seiten muessen uebereinstimmen, sonst vergleicht die App Aepfel mit
# Birnen. [Vorher wurde die feste "1" aus xbm_version.h gelesen -- damit
#  war jedes Release "Version 1" und die App sah nie etwas Neues.]
if [[ -z $version ]]; then
  version=$(git log -1 --format=%ct 2>/dev/null || true)
  if [[ -z $version || ! $version =~ ^[0-9]+$ ]]; then
    echo "Version weder angegeben noch aus Git ermittelbar (kein Repository?)" >&2
    exit 1
  fi
fi

# KONFIGURATION: Abschnitt [release] aus build.sh.conf im Projektstamm
# (dieselbe Datei wie fuer build.sh); ohne sie weiterhin config/release.conf.
konfdatei=${XBM_KONF_DATEI:-build.sh.conf}
# .unreleased bevorzugen -- dieselbe Regel wie in build.sh.
[[ -f "$konfdatei.unreleased" ]] && konfdatei="$konfdatei.unreleased"
if [[ -f $konfdatei ]]; then
  konfig="$konfdatei [release]"
  # Nur den Abschnitt [release] als Bash ausfuehren -- nichts anderes aus
  # der Datei (die Host-Tabelle etwa waere kein gueltiges Bash).
  eval "$(awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*\[[A-Za-z_-]+\][[:space:]]*$/ { s=$0; gsub(/[][ \t]/,"",s); im = (tolower(s)=="release"); next }
    im { print }' "$konfdatei")"
else
  konfig=config/release.conf
  [[ -f $konfig ]] || { echo "Fehlt: $konfdatei mit [release] (oder $konfig) -- RELEASE_GIT_URL=... setzen" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$konfig"
fi
[[ -n ${RELEASE_GIT_URL:-} ]] || { echo "RELEASE_GIT_URL fehlt in $konfig" >&2; exit 1; }

arbeitsordner=$(mktemp -d)

# ZIP-ARCHIV AUCH OHNE DAS PROGRAMM 'zip'.
# [Auf 'windows' (WSL) fehlte zip -- der Bau lief 4 Minuten durch und
#  scheiterte erst hier. python3 ist dort praktisch immer vorhanden und
#  kann ZIP selbst schreiben; 7z ist die dritte Wahl.]
xbm_zip() {                        # xbm_zip <ziel.zip> <datei|ordner>...
  local ziel=$1; shift
  if command -v zip >/dev/null 2>&1; then
    zip -qr "$ziel" "$@"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$ziel" "$@" <<'PY'
import os, sys, zipfile
ziel, eintraege = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(ziel, 'w', zipfile.ZIP_DEFLATED) as z:
    for e in eintraege:
        if os.path.isdir(e):
            for wurzel, _, dateien in os.walk(e):
                for d in sorted(dateien):
                    p = os.path.join(wurzel, d)
                    z.write(p, os.path.normpath(p))
        else:
            z.write(e, os.path.normpath(e))
PY
  elif command -v 7z >/dev/null 2>&1; then
    7z a -tzip -bso0 -bsp0 "$ziel" "$@"
  else
    echo "  weder zip noch python3 noch 7z vorhanden (apt install zip)" >&2
    return 1
  fi
}
trap 'rm -rf "$arbeitsordner"' EXIT

paket=""
case $paketart in
  tar)
    [[ -f "$quelle/x_bookmark_manager" ]] || { echo "  $quelle/x_bookmark_manager fehlt" >&2; exit 1; }
    paket="xbm-${schluessel}-${version}.tar.gz"
    ( cd "$quelle" && tar -czf "$arbeitsordner/$paket" \
        x_bookmark_manager $( [[ -d data ]] && echo data ) )
    ;;
  zip)
    shopt -s nullglob
    exes=("$quelle"/*.exe)
    shopt -u nullglob
    (( ${#exes[@]} > 0 )) || { echo "  keine .exe in $quelle gefunden" >&2; exit 1; }
    paket="xbm-${schluessel}-${version}.zip"
    # [Vorher: "... 2>/dev/null || true" -- das verschluckte jeden echten
    #  Packfehler. Jetzt nur vorhandene Teile, und Fehler zaehlen.]
    ( cd "$quelle"
      shopt -s nullglob
      teile=(./*.exe ./*.dll)
      [[ -d data ]] && teile+=(./data)
      xbm_zip "$arbeitsordner/$paket" "${teile[@]}" ) \
      || { echo "  Packen fehlgeschlagen: $paket" >&2; exit 1; }
    [[ -s "$arbeitsordner/$paket" ]] \
      || { echo "  Paket $paket ist leer oder fehlt" >&2; exit 1; }
    ;;
  apk)
    # Dieselbe, oben bereinigte Liste -- NICHT neu globben (sonst waeren
    # die unsignierten Zwischenstaende wieder dabei).
    (( ${#apks[@]} > 0 )) || { echo "  keine .apk in $quelle gefunden" >&2; exit 1; }
    paket="xbm-${schluessel}-${version}.apk"
    cp "${apks[0]}" "$arbeitsordner/$paket"
    ;;
  *) echo "Unbekannte Paketart: $paketart" >&2; exit 1 ;;
esac

pruefsumme=$(sha256sum "$arbeitsordner/$paket" | cut -d' ' -f1)
echo "  Paket:   $paket  ($(du -h "$arbeitsordner/$paket" | cut -f1))"
echo "  sha256:  $pruefsumme"

# RELEASES-REPO HOLEN. [--depth 1: es zaehlt nur der aktuelle Stand, keine
#  Historie noetig. "main" EXPLIZIT anfordern statt sich auf den Standard-
#  Branch (HEAD) des Servers zu verlassen -- bei einem frisch angelegten
#  Repo zeigt HEAD dort oft noch auf einen nie befuellten "master", der
#  Klon braeche dann still ohne jede Datei ab. Existiert das Repo auf dem
#  Server noch nicht oder hat noch keinen "main"-Branch, legt der Clone
#  nichts an -- dann hier frisch initialisieren.]
repo="$arbeitsordner/releases"
if ! git clone --depth 1 --branch main "$RELEASE_GIT_URL" "$repo" -q 2>/dev/null; then
  mkdir -p "$repo"
  # ORIGIN FEHLTE HIER -- das war der Fehler. [Ohne diese Zeile blieb das
  #  frisch initialisierte Repo ganz ohne Fernverweis, und der Push weiter
  #  unten scheiterte mit "'origin' does not appear to be a git
  #  repository" -- kein Netzwerkproblem, schlicht ein vergessenes
  #  "git remote add".]
  ( cd "$repo" && git init -q && git remote add origin "$RELEASE_GIT_URL" )
fi
cd "$repo"
git config user.email "release@bookmarks.local"
git config user.name "xbm-release"

eintragen() {
# Paket + Pruefsumme ins Arbeitsverzeichnis, release.json fuer
# DIESES Ziel aktualisieren, als den einen Commit festhalten.
# [Als Funktion, weil es bei einem Push-Wettlauf auf dem
#  frisch geholten Stand WIEDERHOLT werden muss -- siehe unten.]
# AELTERE PAKETE DIESES ZIELS ENTFERNEN -- nur eines je Ziel behalten.
# [Bisher blieb JEDES jemals veroeffentlichte Paket im Repository liegen:
#  nach fuenf Veroeffentlichungen war ein frischer Klon fuenfmal so gross.
#  Geklont wird es von jeder Veroeffentlichung auf jedem Bauhost und von
#  jedem --run-only -- und der Rechner mit dem Git-Server muss dafuer
#  jedes Mal ALLES packen. Bei flachen Klonen (--depth 1) rechnet Git die
#  Kompression dabei neu: gemessen 362 % + 173 % CPU auf dem Laptop.
#  release.json zeigt ohnehin nur auf das jeweils neueste Paket; aeltere
#  sind fuer die App unerreichbar. Nur Pakete DIESES Ziels ("xbm-<ziel>-")
#  werden angefasst, die anderer Ziele bleiben.]
for _alt in xbm-"${schluessel}"-*; do
  [[ -e $_alt ]] || continue
  [[ $_alt == "$paket" || $_alt == "$paket.sha256" ]] && continue
  # Nur "xbm-<ziel>-<ZAHL>.": sonst traefe "deb" auch "xbm-deb-asan-...".
  _rest=${_alt#xbm-"$schluessel"-}
  [[ $_rest =~ ^[0-9]+\. ]] || continue
  git rm -q -f -- "$_alt" 2>/dev/null || rm -f -- "$_alt"
done
cp "$arbeitsordner/$paket" ./
echo "$pruefsumme  $paket" > "${paket}.sha256"

# release.json PFLEGEN -- bestehende Eintraege ANDERER Ziele bleiben
# erhalten (aus dem gerade geklonten Stand gelesen), nur der Eintrag fuer
# DIESES Ziel wird ersetzt.
#
# MIT awk STATT python3. [Auf FreeBSD (buildserver) gibt es haeufig kein
#  "python3" im PATH -- der Aufruf scheiterte dort mit "python3: command
#  not found", und damit die ganze Veroeffentlichung. awk gehoert zum
#  POSIX-Grundbestand und ist auf Linux, FreeBSD und in Git-Bash
#  gleichermassen vorhanden. Die erzeugte Datei ist Zeichen fuer Zeichen
#  dieselbe wie zuvor (dasselbe Einrueckformat), die App merkt keinen
#  Unterschied.]

# Roh-Datei-URL nach demselben Muster, das fuer den Quellcode-Sync schon
# nachweislich funktioniert: <server>/<repo ohne .git>/raw/branch/main/<datei>
basis=${RELEASE_GIT_URL%/}
case $basis in *.git) basis=${basis%.git} ;; esac
url="${basis}/raw/branch/main/${paket}"

[ -f release.json ] || : > release.json
awk -v schluessel="$schluessel" -v url="$url" -v sha="$pruefsumme" \
    -v version="$version" -v notes="${RELEASE_NOTES:-}" '
BEGIN { n = 0; inobj = 0; hatte_notes = 0 }
/^[ \t]*"[^"]+"[ \t]*:[ \t]*\{/ {
    zeile = $0
    sub(/^[ \t]*"/, "", zeile)
    sub(/"[ \t]*:[ \t]*\{.*$/, "", zeile)
    aktuell = zeile
    if (!(aktuell in gesehen)) { gesehen[aktuell] = 1; reihe[n++] = aktuell }
    inobj = 1
    next
}
inobj && /"url"[ \t]*:/ {
    zeile = $0; sub(/^.*"url"[ \t]*:[ \t]*"/, "", zeile); sub(/".*$/, "", zeile)
    urls[aktuell] = zeile; next
}
inobj && /"sha256"[ \t]*:/ {
    zeile = $0; sub(/^.*"sha256"[ \t]*:[ \t]*"/, "", zeile); sub(/".*$/, "", zeile)
    shas[aktuell] = zeile; next
}
inobj && /"version"[ \t]*:/ {
    zeile = $0; sub(/^.*"version"[ \t]*:[ \t]*/, "", zeile); sub(/[^0-9].*$/, "", zeile)
    vers[aktuell] = zeile; next
}
/^[ \t]*\}/ { inobj = 0; next }
!inobj && /^[ \t]*"notes"[ \t]*:/ {
    zeile = $0; sub(/^[ \t]*"notes"[ \t]*:[ \t]*"/, "", zeile); sub(/",?[ \t]*$/, "", zeile)
    alte_notes = zeile; hatte_notes = 1; next
}
END {
    if (!(schluessel in gesehen)) { gesehen[schluessel] = 1; reihe[n++] = schluessel }
    urls[schluessel] = url; shas[schluessel] = sha; vers[schluessel] = version
    ausgabe_notes = notes
    if (ausgabe_notes == "" && hatte_notes) ausgabe_notes = alte_notes
    printf "{\n"
    printf "  \"version\": %s", version
    if (ausgabe_notes != "") printf ",\n  \"notes\": \"%s\"", ausgabe_notes
    for (i = 0; i < n; i++) {
        k = reihe[i]
        if (urls[k] == "") continue
        printf ",\n  \"%s\": {\n", k
        # VERSION JE PLATTFORM. [Die Plattformen werden getrennt und zu
        #  verschiedenen Zeiten veroeffentlicht -- eine einzige globale
        #  Version passte nie zu allen. Die App liest zuerst die Version
        #  IHRES Eintrags; die globale bleibt als Rueckfall.]
        if (vers[k] != "") printf "    \"version\": %s,\n", vers[k]
        printf "    \"url\": \"%s\",\n", urls[k]
        printf "    \"sha256\": \"%s\"\n", shas[k]
        printf "  }"
    }
    printf "\n}\n"
}' release.json > release.json.neu && mv release.json.neu release.json

git add -A
# NIE ANHAEUFEN: immer denselben einen Commit ueberschreiben, siehe
# Begruendung ganz oben.
if git rev-parse HEAD >/dev/null 2>&1; then
  git commit -q --amend -m "Release ${version}" --allow-empty
else
  git commit -q -m "Release ${version}"
fi
}
# http.postBuffer HOCHSETZEN. [Git puffert einen HTTP-Push standardmaessig
#  nur bis 1 MB im Speicher, bevor es auf "Chunked Transfer Encoding"
#  umschaltet -- viele kleine/eigene Git-Server (im Unterschied zu
#  GitHub/Gitea in ausgereifter Konfiguration) kommen mit dieser
#  Uebertragungsart nicht zuverlaessig klar und brechen mitten in der
#  Uebertragung ab: "RPC failed; curl 56 Recv failure: Connection reset
#  by peer" / "unexpected disconnect while reading sideband packet".
#  Ein hoeherer Puffer (hier 500 MB) laesst Git die GESAMTE Anfrage in
#  einem Stueck senden, ohne Chunked Encoding -- behebt das bei genau
#  dieser Fehlerklasse zuverlaessig, kostet aber entsprechend mehr
#  Arbeitsspeicher waehrend des Pushs.]
# GLEICHZEITIGES VEROEFFENTLICHEN OHNE DATENVERLUST.
# [Vorher: klonen -> release.json aendern -> push --FORCE. Veroeffentlichten
#  zwei Ziele gleichzeitig (deb, exe und apk laufen parallel), las jedes
#  release.json beim Klonen, fuegte SEINEN Eintrag hinzu und ueberschrieb
#  dann per --force, was der andere inzwischen gepusht hatte. Dessen
#  Eintrag verschwand ohne jede Meldung -- so kannte release.json
#  "windows" nicht, obwohl exe@windows veroeffentlicht hatte.
#
#  Jetzt: --force-with-lease. Git ueberschreibt nur, wenn der Server noch
#  auf GENAU dem Stand ist, den wir geholt haben. Hat inzwischen ein
#  anderer gepusht, wird der Push abgelehnt; dann holen wir dessen Stand,
#  tragen unseren Eintrag ERNEUT ein (release.json enthaelt danach beide)
#  und versuchen es noch einmal. Das --amend/Ueberschreiben bleibt, damit
#  das Repo nicht waechst -- nur eben nicht mehr blind.]
eintragen
git branch -M main
versuch=1
while :; do
  # Stand, auf dem unser Commit aufbaut -- leer, wenn der Server noch
  # nichts hatte (dann ist "main muss leer sein" die Bedingung).
  erwartet=$(git rev-parse -q --verify refs/remotes/origin/main 2>/dev/null || true)
  if git -c http.postBuffer=524288000 push -q \
       --force-with-lease="main:${erwartet}" origin main 2>/dev/null; then
    break
  fi
  if (( versuch >= 6 )); then
    echo "  FEHLER: release.json konnte nach $versuch Versuchen nicht geschrieben" >&2
    echo "          werden -- veroeffentlicht gerade ein anderes Ziel ohne Ende?" >&2
    exit 1
  fi
  echo "  Server hat inzwischen einen neueren Stand (anderes Ziel veroeffentlicht)" \
       "-- trage erneut ein, Versuch $((versuch + 1))"
  # Zufaellige kurze Pause, damit zwei Wartende nicht wieder gleichzeitig
  # kommen.
  sleep $(( (RANDOM % 3) + 1 ))
  git fetch -q --depth 1 origin main
  git reset -q --hard FETCH_HEAD
  git update-ref refs/remotes/origin/main FETCH_HEAD
  eintragen
  versuch=$((versuch + 1))
done

echo "  Veroeffentlicht: $paket"
echo "  release.json aktualisiert (Version ${version}, Ziel ${schluessel})."
