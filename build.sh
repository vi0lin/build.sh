#!/usr/bin/env bash
# cleanup() {
#   echo -ne '\e[?25h'
#   tput cnorm
#   exit
# }
# trap cleanup INT TERM EXIT
# echo -ne '\e[?25l'
# tput civis
# set -x
# FASSUNG -- muss auf beiden Seiten uebereinstimmen.
# [build.sh steuert die Gegenseite und wurde bisher behandelt wie jede
#  andere Quelldatei: ueber die Zeitmarke. Blieb eine Uebertragung
#  unbemerkt aus, lief drueben eine alte Fassung weiter -- und meldete
#  "unbekannte Option: --chdir", ohne die Ursache zu nennen.]
XBM_BUILD_PROTO=3
# ---------------------------------------------------------------------------
# build.sh -- lokal und auf Zielmaschinen bauen.
#
#   ./build.sh deb@local win@windows apk@buildserver
#
# WAS AN DER ALTEN FASSUNG NICHT FUNKTIONIERTE
#
# 1. DAS PASSWORT BEKAM ANFUEHRUNGSZEICHEN MIT.
#    In hosts.conf stand   sshpass -p "1234"   als EIN Feld. Beim
#    unquotierten $sshpass zerlegt bash an Leerzeichen, entfernt aber
#    KEINE Anfuehrungszeichen -- sshpass erhielt als Passwort die sechs
#    Zeichen  "1234"  statt der vier. Deshalb schlug die Anmeldung fehl.
#    Nachgemessen: die Argumente sind [sshpass] [-p] ["1234"].
#
# 2. rsync -e $sshpass ssh   WAR VOELLIG ZERLEGT.
#    -e nimmt EIN Argument. Aus  -e $sshpass ssh  wurde
#       -e sshpass   -p   "1234"   ssh   ./   ziel:/pfad/
#    also -e mit dem Wert "sshpass", danach -p als rsync-Schalter und
#    zwei zusaetzliche Quellpfade. Richtig ist  -e "sshpass -p 1234 ssh".
#
# 3. mkdir -p / test -d GIBT ES AUF WINDOWS NICHT.
#    Die alte Zeile rief pauschal powershell auf -- das schlaegt auf
#    POSIX-Zielen fehl. Jetzt entscheidet ein OS-Feld je Host.
#
# 4. rsync IST AUF WINDOWS SELTEN VORHANDEN.
#    Es wird geprueft; fehlt es, wird ueber tar via ssh uebertragen.
#    Windows 10 ab 1803 bringt tar.exe mit, das genuegt.
#
# 5. set -x FLUTETE DIE AUSGABE und machte den Fortschritt unlesbar.
#    Raus; stattdessen je Auftrag eine Logdatei und eine Zusammenfassung.
# ---------------------------------------------------------------------------
set -uo pipefail
# JOBSTEUERUNG EIN.
# [Damit legt bash jeden Hintergrundauftrag in eine EIGENE
#  Prozessgruppe. Nur so laesst er sich mitsamt seinen Kindern beenden,
#  ohne die aufrufende Shell mitzunehmen.]
set -m

DEFAULT_HOST="local"
JOBS=$(nproc 2>/dev/null || echo 4)
CONFIGURE_ONLY=0
BUILD_ONLY=0
DRY_RUN=0
HOOKS_ONLY_MODE=""   # "", "success" oder "fail" -- fuer die ERFOLG/FEHLSCHLAG-Logik
HOOKS_ONLY_FLAG=""    # die WORTGLEICHE Formulierung von der Kommandozeile
# AKTUELLE_PARALLELITAET: gilt NUR fuer mehrere Auftraege auf DEMSELBEN
# Host -- verschiedene Hosts laufen immer unabhaengig und gleichzeitig,
# darauf hat dieser Wert keinen Einfluss. Aendert sich per --parallel N /
# --unparallel WAEHREND des Einlesens der Kommandozeile und gilt ab dann
# fuer jedes NEU hinzugefuegte Ziel -- so laesst sich je Zielgruppe eine
# eigene Grenze setzen:
#     --parallel 4 test@gut --unparallel deb@local --parallel 2 test@schlecht
# Vorgabe 1 -- entspricht --unparallel, bis irgendwo auf der Zeile ein
# --parallel/--unparallel etwas anderes bestimmt.
AKTUELLE_PARALLELITAET=1
# DASSELBE PRINZIP fuer --run/--run-only/--publish: "aktuell gueltige"
# Einstellung, die add_target() bei jedem Ziel einfriert (siehe dort) --
# POSITIONAL, nicht mehr global fuer den gesamten Aufruf. Vorgabe: alle
# drei aus, bis ein --run/--run-only/--publish auf der Kommandozeile
# etwas anderes bestimmt.
AKTUELLE_RUN=0
AKTUELLE_RUN_ONLY=0
AKTUELLE_PUBLISH=0
RUN_JE_ZIEL=()
RUN_ONLY_JE_ZIEL=()
PUBLISH_JE_ZIEL=()
MOVE_TO_MODE=0
MOVE_TO_HOST=""
MOVE_TO_DATEI=""
CLEAN=0
CLEANDEEP=0
VERBOSE=0
AS_HOST=""
FULL_SYNC=0
FORCE_GIT_URL=""; FORCE_GIT=0; NO_GIT=0
SYNC_REPORT=0
SKIP_TOOLCHECK=0
NO_LOG=0
LOG_STDOUT=0
AUSZUG=0
AUSZUG_N=25
AUTO_INSTALL=1
EXEC_MODE=0
XBM_NUR_STEUERDATEIEN=0
XBM_KEIN_MUX=${XBM_KEIN_MUX:-0}
EXEC_CMD=""
XBM_EXEC_DATEI=".xbm-exec.sh"
EXEC_VORHANDEN=0
LIST_MODE=0
SHOW_LAST_MODE=0
SHOW_MODE=0
SYNC_ONLY=0
TIMING=${XBM_TIMING:-0}
XBM_TIMING_DATEI=""
XBM_WARM_PID=""
CMD_NAME=""
CMD_ARGS=()
PROJEKT_DIR=""
XBM_PROJECT_ARG=""
MUTTER_HOST=""
MUTTER_PFAD=""
ERLAUBE_SUDO=0
SYNC_DIR=".xbm-sync"

TARGETS=()
HOSTS=()
# Je Auftrag: war der Zielname leer? [Dann ist es ein exec-Auftrag.
#  --exec galt vorher fuer den GANZEN Lauf -- damit fuehrte auch
#  "exe@windows" nur den Befehl aus statt zu bauen: keine
#  Prozentanzeige, verdaechtig schnell fertig.]
OHNE_ZIEL=()
# Je Auftrag: die Parallelitaetsgrenze, die zum Zeitpunkt seines
# Hinzufuegens auf der Kommandozeile galt (siehe add_target).
PARALLEL_JE_ZIEL=()

log()  { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# ===========================================================================
# --add-to-path / --remove-from-path / --wsl-keep-warm / --no-wsl-keep-warm
# ===========================================================================
# [Ersetzt pfad-eintragen.ps1 und wsl-warmhalten.ps1 -- der PowerShell-Teil
#  steht jetzt hier im Skript und wird ueber powershell.exe ausgefuehrt, es
#  liegen keine .ps1-Dateien mehr im Projekt. Dieselbe build.sh funktioniert
#  so auf Linux, FreeBSD, macOS, in WSL und in Git-Bash.]

XBM_PFAD_MARKE_A='# >>> build.sh --add-to-path >>>'
XBM_PFAD_MARKE_E='# <<< build.sh --add-to-path <<<'

# Ordner, in dem DIESE build.sh wirklich liegt (Symlinks aufgeloest).
xbm_selbst_ordner() {
  local p=${BASH_SOURCE[0]}
  if command -v realpath >/dev/null 2>&1; then
    p=$(realpath "$p") || return 1
  elif readlink -f / >/dev/null 2>&1; then
    p=$(readlink -f "$p") || return 1
  fi
  ( cd -P "$(dirname "$p")" && pwd -P )
}

# WERKZEUGE NEBEN build.sh IMMER FINDEN.
# [targets.conf ruft publish_release.sh jetzt OHNE ./ auf, also ueber den
#  PATH. Auf den anderen Rechnern startet build.sh aber ueber ssh als
#  nicht-interaktive Shell -- die liest ~/.profile und ~/.bashrc NICHT,
#  der Eintrag von --add-to-path greift dort also nicht. Deshalb nimmt
#  build.sh seinen eigenen Ordner selbst vorne in den PATH: was neben ihm
#  liegt, wird immer gefunden, und zwar genau die Fassung, die zu diesem
#  build.sh gehoert.]
if _xbm_eigen=$(xbm_selbst_ordner 2>/dev/null) && [[ -n $_xbm_eigen ]]; then
  case ":$PATH:" in
    *":$_xbm_eigen:"*) ;;
    *) PATH="$_xbm_eigen:$PATH"; export PATH ;;
  esac
fi
unset _xbm_eigen

xbm_umgebung() {                  # -> windows | wsl | posix
  case $(uname -s 2>/dev/null) in
    MINGW*|MSYS*|CYGWIN*) echo windows; return ;;
  esac
  if [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/version 2>/dev/null
  then echo wsl; else echo posix; fi
}

# PowerShell-Code ausfuehren. -EncodedCommand (UTF-16LE, base64) statt
# -Command: kein Anfuehrungszeichen-Problem zwischen bash, wsl und
# powershell -- der Text kommt Byte fuer Byte so an, wie er hier steht.
xbm_powershell() {                # xbm_powershell <skripttext>
  local ps
  ps=$(command -v powershell.exe 2>/dev/null || command -v pwsh.exe 2>/dev/null) \
    || { err "  powershell.exe nicht gefunden"; return 1; }
  command -v iconv >/dev/null 2>&1 \
    || { err "  iconv fehlt (wird fuer den PowerShell-Aufruf gebraucht)"; return 1; }
  local enc
  enc=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n\r')
  "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$enc" \
    | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

xbm_ps_text() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }   # PowerShell-Zeichenkette

# posix-Pfad -> Windows-Pfad; scheitert, wenn Windows ihn nicht sinnvoll sieht
xbm_windows_pfad() {
  case $(xbm_umgebung) in
    wsl)     [[ $1 == /mnt/[a-zA-Z]/* ]] || return 1; wslpath -w "$1" ;;
    windows) cygpath -w "$1" ;;
    *)       return 1 ;;
  esac
}

# --- Windows: Benutzer- oder System-PATH -------------------------------------
# [Aus pfad-eintragen.ps1 uebernommen, an zwei Stellen verbessert:
#  1. Der PATH wird ROH aus der Registry gelesen und als REG_EXPAND_SZ
#     zurueckgeschrieben. [Environment]::Get/SetEnvironmentVariable liefert
#     ihn AUFGELOEST und schreibt REG_SZ -- dabei werden aus Eintraegen wie
#     %USERPROFILE%\bin still feste Pfade.
#  2. Austragen ist moeglich (--remove-from-path).
#  Nicht setx: das kuerzt den PATH bei 1024 Zeichen und zerstoert ihn.]
xbm_windows_pfad_setzen() {       # add|remove <windows-ordner> User|Machine
  local skript
  skript=$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$d = __ORDNER__; $modus = '__MODUS__'; $bereich = '__BEREICH__'
$key = if ($bereich -eq 'Machine') {
  'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
} else { 'HKCU:\Environment' }
try {
  $roh = (Get-Item -Path $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
  $alle = @(($roh -split ';') | Where-Object { $_ -ne '' })
  $rest = @($alle | Where-Object { $_.TrimEnd('\') -ine $d.TrimEnd('\') })
  $war_drin = $rest.Count -ne $alle.Count
  if ($modus -eq 'add') {
    if ($war_drin) { "Windows: bereits im $bereich-PATH: $d" }
    else {
      Set-ItemProperty -Path $key -Name 'Path' -Value (($rest + $d) -join ';') -Type ExpandString
      "Windows: eingetragen in den $bereich-PATH: $d"
    }
    # setzt XBM_BUILD_HOME und meldet die Aenderung an Windows
    # (WM_SETTINGCHANGE) -- neue Fenster sehen den PATH dann sofort
    [Environment]::SetEnvironmentVariable('XBM_BUILD_HOME', $d, $bereich)
  } else {
    if ($war_drin) {
      Set-ItemProperty -Path $key -Name 'Path' -Value ($rest -join ';') -Type ExpandString
      "Windows: aus dem $bereich-PATH entfernt: $d"
    } else { "Windows: war nicht im $bereich-PATH: $d" }
    [Environment]::SetEnvironmentVariable('XBM_BUILD_HOME', $null, $bereich)
  }
  if ($bereich -eq 'Machine') { "Fuer den SSH-Dienst noch (als Admin):  Restart-Service sshd" }
} catch [System.UnauthorizedAccessException], [System.Security.SecurityException] {
  "FEHLER: keine Berechtigung fuer den $bereich-PATH -- Terminal als Administrator starten"
  exit 1
}
PS
)
  skript=${skript//__ORDNER__/$(xbm_ps_text "$2")}
  skript=${skript//__MODUS__/$1}
  skript=${skript//__BEREICH__/$3}
  xbm_powershell "$skript"
}

# --- Linux/FreeBSD/macOS/WSL: Startdateien der Shells ------------------------
# Ein markierter Block. Erneutes --add-to-path ERSETZT ihn (z.B. nachdem das
# Skript verschoben wurde), --remove-from-path entfernt ihn spurlos.
xbm_profil_dateien() {
  local f=("$HOME/.profile")          # sh/dash/FreeBSD-sh, bash als Login-Shell
  [[ -f $HOME/.bash_profile ]] && f+=("$HOME/.bash_profile")   # verdeckt .profile!
  [[ ! -f $HOME/.bash_profile && -f $HOME/.bash_login ]] && f+=("$HOME/.bash_login")
  [[ -f $HOME/.bashrc ]] && f+=("$HOME/.bashrc")   # Terminalfenster (keine Login-Shell)
  [[ -f $HOME/.zshrc ]]  && f+=("$HOME/.zshrc")
  [[ -f $HOME/.shrc ]]   && f+=("$HOME/.shrc")     # FreeBSD sh, interaktiv
  printf '%s\n' "${f[@]}"
}

xbm_block_entfernen() {           # xbm_block_entfernen <datei>
  local f=$1 tmp
  [[ -f $f ]] && grep -qxF "$XBM_PFAD_MARKE_A" "$f" && grep -qxF "$XBM_PFAD_MARKE_E" "$f" \
    || return 0
  tmp=$(mktemp) || return 1
  awk -v a="$XBM_PFAD_MARKE_A" -v e="$XBM_PFAD_MARKE_E" \
      '$0==a{weg=1;next} $0==e{weg=0;next} !weg' "$f" > "$tmp" \
    && cat "$tmp" > "$f"          # cat statt mv: Rechte/Eigentuemer bleiben
  rm -f "$tmp"
}

xbm_profil_setzen() {             # add|remove <ordner>
  local modus=$1 d=$2 q f
  q=${d//\'/\'\\\'\'}
  while IFS= read -r f; do
    xbm_block_entfernen "$f" || { err "  konnte $f nicht aendern"; return 1; }
    if [[ $modus == add ]]; then
      { [[ -s $f && -n $(tail -c1 "$f") ]] && echo    # fehlender Zeilenumbruch am Ende
        printf '%s\n' "$XBM_PFAD_MARKE_A" \
          "# eingetragen von build.sh --add-to-path; entfernen: build.sh --remove-from-path" \
          "case \":\$PATH:\" in *:'$q':*) ;; *) PATH=\"\$PATH:\"'$q'; export PATH ;; esac" \
          "XBM_BUILD_HOME='$q'; export XBM_BUILD_HOME" \
          "$XBM_PFAD_MARKE_E"
      } >> "$f" || { err "  konnte $f nicht schreiben"; return 1; }
      log "  eingetragen: $f"
    else
      log "  bereinigt:   $f"
    fi
  done < <(xbm_profil_dateien)
}

xbm_pfad_befehl() {               # add|remove [User|Machine]
  local modus=$1 bereich=${2:-User} d umg w rc=0
  d=$(xbm_selbst_ordner) || { err "Ordner von build.sh nicht ermittelbar"; return 1; }
  umg=$(xbm_umgebung)
  log "build.sh liegt in: $d   (Umgebung: $umg)"
  [[ $modus == add && ! -x $d/build.sh ]] && chmod +x "$d/build.sh" 2>/dev/null
  if [[ $umg != windows ]]; then
    xbm_profil_setzen "$modus" "$d" || rc=1
  fi
  if [[ $umg != posix ]]; then
    if w=$(xbm_windows_pfad "$d"); then
      xbm_windows_pfad_setzen "$modus" "$w" "$bereich" || rc=1
    else
      log "  Windows-PATH: uebersprungen (Ordner liegt nicht auf einem Windows-Laufwerk)"
    fi
  fi
  if (( rc == 0 )) && [[ $modus == add ]]; then
    log ""
    if [[ $umg == windows ]]; then
      log "Fertig. In einem NEUEN Terminal geht jetzt in jedem Projektordner:"
    else
      log "Fertig. In einem NEUEN Terminal (oder nach  source ~/.profile)"
      log "geht jetzt in jedem Projektordner:"
    fi
    log "    build.sh --help"
  fi
  return $rc
}

# --- WSL warmhalten ------------------------------------------------------------
# [Aus wsl-warmhalten.ps1 uebernommen. Windows faehrt die WSL-VM herunter,
#  sobald kein Prozess mehr darin laeuft; jeder Lauf zahlt dann den
#  Kaltstart. Eine geplante Aufgabe startet bei der Anmeldung einen
#  schlafenden Prozess, zusaetzlich vmIdleTimeout=-1 in .wslconfig.
#  Geaendert gegenueber dem .ps1:
#  - Aus WSL heraus wird die Distribution genommen, in der build.sh gerade
#    laeuft, statt der ersten aus der Liste.
#  - Der Prozess startet ueber ein VERSTECKTES powershell.exe. [-Hidden
#    bei der Aufgabe versteckt nur die Aufgabe in der Aufgabenplanung,
#    nicht das Fenster -- sonst stand nach jeder Anmeldung ein leeres
#    Konsolenfenster da, und wer es schloss, beendete das Warmhalten.]
#  - .wslconfig wird ohne BOM geschrieben (Windows PowerShell 5 setzt bei
#    -Encoding UTF8 eines davor).]
xbm_wsl_warm() {                  # on|off
  local umg distro skript
  umg=$(xbm_umgebung)
  [[ $umg == posix ]] && { err "--wsl-keep-warm geht nur unter Windows (WSL oder Git-Bash)"; return 1; }
  distro=${WSL_DISTRO_NAME:-}
  skript=$(cat <<'PS'
$ErrorActionPreference = 'Stop'
$modus = '__MODUS__'; $Distro = __DISTRO__
$Name = 'WSL-warmhalten'
if ($modus -eq 'off') {
  Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
  "Aufgabe '$Name' entfernt. Der schlafende Prozess laeuft bis zum naechsten  wsl --shutdown  weiter."
  exit 0
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { "FEHLER: wsl.exe nicht gefunden"; exit 1 }
if ($Distro -eq '') {
  $alt = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
  $Distro = (wsl.exe -l -q | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
  [Console]::OutputEncoding = $alt
  if ($Distro) { $Distro = $Distro.Trim() }
}
if (-not $Distro) { "FEHLER: keine WSL-Distribution gefunden"; exit 1 }
"Distribution: $Distro"

$cfg = Join-Path $env:USERPROFILE '.wslconfig'
$inhalt = if (Test-Path $cfg) { [IO.File]::ReadAllText($cfg) } else { '' }
if ($inhalt -notmatch 'vmIdleTimeout') {
  if ($inhalt -notmatch '\[experimental\]') { $inhalt += "`r`n[experimental]`r`n" }
  $inhalt = $inhalt -replace '\[experimental\]', "[experimental]`r`nvmIdleTimeout=-1"
  [IO.File]::WriteAllText($cfg, $inhalt, (New-Object System.Text.UTF8Encoding($false)))
  "vmIdleTimeout=-1 in $cfg eingetragen (wirksam nach  wsl --shutdown)."
} else { "vmIdleTimeout steht bereits in $cfg -- unveraendert." }

$wslAufruf = "wsl.exe -d '" + $Distro.Replace("'", "''") + "' --exec sleep infinity"
$Aktion = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -WindowStyle Hidden -Command "' + $wslAufruf + '"')
$Ausloeser = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$Einstellungen = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $Name -Action $Aktion -Trigger $Ausloeser `
  -Settings $Einstellungen `
  -Description 'Haelt WSL warm, damit build.sh nicht bei jedem Aufruf den Kaltstart zahlt.' | Out-Null
Start-ScheduledTask -TaskName $Name
"Aufgabe '$Name' angelegt und gestartet (startet kuenftig bei der Anmeldung)."
"Pruefen:  wsl.exe -d $Distro --exec ps -e   (sollte 'sleep' zeigen)"
PS
)
  skript=${skript//__MODUS__/$1}
  skript=${skript//__DISTRO__/$(xbm_ps_text "$distro")}
  xbm_powershell "$skript"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
add_target() {
  local item=$1
  if [[ $item == *@* ]]; then
    # "@windows" ohne Ziel ist erlaubt und kennzeichnet einen
    # exec-Auftrag.
    TARGETS+=("${item%%@*}"); HOSTS+=("${item##*@}")
    [[ -z ${item%%@*} ]] && OHNE_ZIEL+=(1) || OHNE_ZIEL+=(0)
  else
    TARGETS+=("$item");       HOSTS+=("$DEFAULT_HOST")
    OHNE_ZIEL+=(0)
  fi
  # Die GERADE GUELTIGE Parallelitaet einfrieren -- ein spaeteres
  # --parallel/--unparallel auf der Kommandozeile darf dieses bereits
  # hinzugefuegte Ziel nicht mehr aendern.
  PARALLEL_JE_ZIEL+=("$AKTUELLE_PARALLELITAET")
  # DASSELBE fuer --run/--run-only/--publish -- POSITIONAL, genau wie
  # --parallel: gilt fuer ALLE ab hier folgenden Ziele, bis ein
  # spaeteres --run/--publish auf der Kommandozeile es aendert. So kann
  # in EINEM Aufruf gemischt werden, z.B.
  #   --publish deb@local exe@windows --run apk@windows
  # (die ersten beiden werden veroeffentlicht, das letzte stattdessen
  # ausgefuehrt) -- vorher galten --run/--publish global fuer den
  # GESAMTEN Aufruf, unabhaengig von der Position.
  RUN_JE_ZIEL+=("$AKTUELLE_RUN")
  RUN_ONLY_JE_ZIEL+=("$AKTUELLE_RUN_ONLY")
  PUBLISH_JE_ZIEL+=("$AKTUELLE_PUBLISH")
}

# ERSTES ARGUMENT: EIN VERZEICHNIS?
# [Damit laesst sich  build.sh /pfad/zum/projekt exe@windows  schreiben
#  und build.sh aus dem PATH heraus aufrufen. Ohne Angabe gilt das
#  aktuelle Verzeichnis. Erkannt wird es daran, dass es ein Verzeichnis
#  IST -- nicht an der Schreibweise: ein Ziel heisst "exe" oder
#  "exe@host" und ist nie ein Ordner.]
if [[ $# -gt 0 && $1 != -* && $1 != *@* ]] && [[ -d $1 ]]; then
  PROJEKT_DIR=$1; shift
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --clean)          CLEAN=1; shift ;;
    --clean-deep)      CLEANDEEP=1; shift ;;
    -t|--target)
      IFS=',' read -ra items <<< "$2"
      for item in "${items[@]}"; do add_target "$item"; done
      shift 2 ;;
    -o|--on)          DEFAULT_HOST="$2"; shift 2 ;;
    -j|--jobs)        JOBS="$2"; shift 2 ;;
    -p|--parallel)    AKTUELLE_PARALLELITAET="$2"; shift 2 ;;
    --unparallel)
      # KURZFORM FUER --parallel 1. [Gilt, wie --parallel, ab hier fuer
      #  jedes NEU hinzugefuegte Ziel -- nicht rueckwirkend fuer bereits
      #  hinzugefuegte.]
      AKTUELLE_PARALLELITAET=1; shift ;;
    --configure-only) CONFIGURE_ONLY=1; shift ;;
    --build-only)     BUILD_ONLY=1; shift ;;
    --run)
      # NACH ERFOLGREICHEM BAU RUN_CMD[ziel] AUSFUEHREN (config/targets.conf).
      # POSITIONAL, wie --parallel: gilt fuer alle AB HIER folgenden
      # Ziele, bis --no-run/--no-run-only es wieder abschaltet oder ein
      # weiteres --run/--run-only es aendert. [Gedacht z.B. fuer
      # ./build.sh --run deb-asan@local: baut UND startet danach gleich
      # mit den passenden ASAN_OPTIONS. Laeuft NICHT, wenn der Bau
      # fehlschlaegt oder --hooks-only aktiv ist (dort wurde ja gar
      # nicht wirklich gebaut -- ein "erfolgreicher" Testlauf wuerde
      # sonst eine moeglicherweise gar nicht vorhandene oder veraltete
      # Datei starten).]
      AKTUELLE_RUN=1; AKTUELLE_RUN_ONLY=0; shift ;;
    --run-only)
      # WIE --run, aber OHNE zu bauen -- konfigurieren/bauen werden fuer
      # dieses Ziel komplett uebersprungen. [Gedacht fuer den Fall "apk
      # wurde auf dem Bauserver gebaut und schon veroeffentlicht (siehe
      # --publish) -- jetzt soll nur noch das FERTIGE Release auf einem
      # ANDEREN Rechner (z.B. windows, wo Handy+adb angeschlossen sind)
      # heruntergeladen und installiert/gestartet werden". Ein Bauversuch
      # von "apk" auf windows waere ohnehin sinnlos (./build_apk.sh gibt
      # es dort nicht).]
      AKTUELLE_RUN=1; AKTUELLE_RUN_ONLY=1; shift ;;
    --no-run)
      # --run/--run-only fuer alle AB HIER folgenden Ziele wieder
      # abschalten -- das Gegenstueck zu --unparallel, nur fuer diese
      # beiden Flags.
      AKTUELLE_RUN=0; AKTUELLE_RUN_ONLY=0; shift ;;
    --publish)
      # NACH ERFOLGREICHEM BAU PUBLISH_CMD[ziel] AUSFUEHREN -- SEPARAT von
      # --run/RUN_CMD. POSITIONAL, wie --parallel: gilt fuer alle AB HIER
      # folgenden Ziele, bis --no-publish es abschaltet. [Bewusst ein
      # EIGENES Flag statt automatisch bei jedem Bau: Veroeffentlichen
      # aufs Releases-Repo soll ein bewusster Schritt bleiben, nicht bei
      # jedem beilaeufigen Testbau nebenbei passieren.]
      AKTUELLE_PUBLISH=1; shift ;;
    --no-publish)
      # --publish fuer alle AB HIER folgenden Ziele wieder abschalten.
      AKTUELLE_PUBLISH=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --hooks-only|--hooks-only-success)
      # NUR DIE HOOKS PRUEFEN -- statt zu konfigurieren/zu bauen, laeuft
      # bei JEDEM Auftrag ein Beispielbefehl, der meldet, fuer welches
      # Ziel@Host er steht und durch welchen Schalter er ausgeloest
      # wurde -- und dann ERFOLGREICH endet. So laesst sich die gesamte
      # Hook-Kette (pre-job, pre-action, post-action, post-job, post-run)
      # in Sekunden durchspielen, ohne auf einen echten Bau zu warten.
      HOOKS_ONLY_MODE=success
      # DIE GENAUE FORMULIERUNG MERKEN, nicht nur "success"/"fail".
      # [Bisher wurde beim Weiterreichen an eine Zielmaschine IMMER neu
      #  aus HOOKS_ONLY_MODE zusammengesetzt -- "--hooks-only" und
      #  "--hooks-only-success" landen beide auf demselben MODE=success,
      #  wurden also beide zu "--hooks-only-success" umgeschrieben. Wer
      #  ausdruecklich "--hooks-only" eingab, sah drueben aber
      #  "--hooks-only-success" -- das war nicht dieselbe Formulierung,
      #  auch wenn die WIRKUNG gleich ist. Jetzt wird die Zielmaschine
      #  wortgleich mit dem gefuettert, was hier auf der Kommandozeile
      #  stand.]
      HOOKS_ONLY_FLAG=$1
      shift ;;
    --hooks-only-fail)
      # DASSELBE, aber der Beispielbefehl schlaegt absichtlich fehl --
      # damit laesst sich pruefen, ob die *-fail-Hooks (z.B.
      # post-job-fail.sh) tatsaechlich greifen, ohne einen echten
      # Bau-Fehler herbeifuehren zu muessen.
      HOOKS_ONLY_MODE=fail
      HOOKS_ONLY_FLAG=$1
      shift ;;
    --sync-report)
      # Nur zeigen, was uebertragen wuerde -- nichts tun.
      SYNC_REPORT=1; DRY_RUN=1; shift ;;
    --skip-toolcheck) SKIP_TOOLCHECK=1; shift ;;
    --project)
      # --project [@host:]/pfad
      # [Bisher war das Projektverzeichnis immer das erste Argument und
      #  immer oertlich. Mit --project laesst es sich benennen -- und
      #  ein @host davor bedeutet: das MUTTERPROJEKT liegt dort. Von da
      #  wird geholt, bevor zu den Zielen verteilt wird.]
      XBM_PROJECT_ARG="$2"; shift 2 ;;
    --sync-only)
      # NUR UEBERTRAGEN -- nicht bauen, nicht ausfuehren, nichts holen.
      # [Nuetzlich, um mehrere Maschinen auf denselben Stand zu bringen,
      #  bevor man dort von Hand arbeitet -- und um zu sehen, WAS
      #  eigentlich hinuebergeht, ohne dass ein Bau die Ausgabe
      #  zudeckt.]
      SYNC_ONLY=1; shift ;;
    --list)
      LIST_MODE=1; shift ;;
    --move-to)
      # EIGENSTAENDIGER BEFEHL, kein Ziel-Auftrag: ./build.sh --move-to
      # <host> <datei> -- ersetzt build_wrapper.sh:mv_to_laptop. Braucht
      # ZWEI Argumente, deshalb eigens abgefangen statt ueber add_target.
      [[ -n ${2:-} && -n ${3:-} ]] || {
        err "--move-to braucht Host UND Datei:  build.sh --move-to windows builds/apk/x_bookmark_manager.apk"
        exit 2; }
      MOVE_TO_MODE=1; MOVE_TO_HOST=$2; MOVE_TO_DATEI=$3
      shift 3 ;;
    --show-last)
      # NUR DIE UEBERSICHT DES LETZTEN LAUFS ZEIGEN -- kein Bau, keine
      # Uebertragung, gar nichts weiter. [Praktisch, um im Nachhinein
      #  nachzusehen, welche Auftraege/Hooks/Uebertragungen beim letzten
      #  Aufruf gelaufen sind, ohne das Terminal von damals noch offen
      #  zu haben.]
      SHOW_LAST_MODE=1; shift ;;
    --show)
      # ZUSAETZLICH ZUM NORMALEN LAUF: am Ende dieselbe Uebersicht
      # ausgeben, die --show-last spaeter anzeigen wuerde -- fuer den
      # DIESEN Lauf, direkt im Anschluss.
      SHOW_MODE=1; shift ;;
    --exec)
      # ALLES DAHINTER IST DER BEFEHL.
      # [Sonst muesste man jede Option davor erraten. Steht nichts
      #  dahinter, wird von der Standardeingabe gelesen -- damit
      #  funktionieren  --exec << EOF ... EOF  und
      #  --exec < <(echo ...) ohne Sonderbehandlung.]
      EXEC_MODE=1; shift
      if [[ $# -gt 0 ]]; then
        EXEC_CMD="$*"; shift $#
      else
        EXEC_CMD=$(cat)
      fi
      ;;
    --install)
      # Auch auf Linux nachinstallieren (fragt nach dem sudo-Passwort).
      # [Hier stand vorher eine Kopie der Startwerte von oben (EXEC_MODE=0 ...
      #  PROJEKT_DIR="" ... MUTTER_PFAD=""). Sie setzte alles zurueck, was VOR
      #  --install auf der Befehlszeile stand: Projektordner, --timing,
      #  --exec, --list, --project ...]
      ERLAUBE_SUDO=1; AUTO_INSTALL=1; shift ;;
    --timing)
      TIMING=1; shift ;;
    --timing-file)
      TIMING=1; XBM_TIMING_DATEI="$2"; shift 2 ;;
    --no-mux)
      # Buendelung abschalten, falls die Gegenseite sie nicht mag.
      XBM_KEIN_MUX=1; shift ;;
    --no-install)
      AUTO_INSTALL=0; shift ;;
    --add-to-path|--remove-from-path)
      # build.sh dauerhaft in den PATH (Linux/FreeBSD/macOS: Startdateien der
      # Shells; Windows/WSL/Git-Bash: Benutzer-PATH + XBM_BUILD_HOME).
      # Optional danach --machine: System-PATH unter Windows (Admin noetig,
      # damit auch ueber ssh gestartete Laeufe ihn sehen).
      [[ $1 == --add-to-path ]] && _xbm_m=add || _xbm_m=remove
      [[ ${2:-} == --machine ]] && _xbm_b=Machine || _xbm_b=User
      xbm_pfad_befehl "$_xbm_m" "$_xbm_b"; exit $? ;;
    --wsl-keep-warm)
      xbm_wsl_warm on; exit $? ;;
    --no-wsl-keep-warm)
      xbm_wsl_warm off; exit $? ;;
    --no-log)
      # Keine Logdateien schreiben. [Normalerweise geht die VOLLE
      #  Ausgabe ins Log -- das ist der Zweck. Abschalten kann man es
      #  trotzdem, etwa bei sehr grossen Baeumen oder wenn man nur
      #  schnell etwas ausprobiert.]
      NO_LOG=1; shift ;;
    --excerpt)
      # Bei Fehlschlag die letzten Zeilen des Logs zeigen (auf stderr).
      AUSZUG=1
      if [[ ${2:-} =~ ^[0-9]+$ ]]; then AUSZUG_N=$2; shift; fi
      shift ;;
    --log-stdout)
      # GENAU DAS, WAS INS LOG GEHT -- auch auf den Bildschirm.
      # [Unterschied zu --show-output: dort laeuft der ROHE Strom ueber
      #  den Bildschirm, ohne Zeitstempel. Hier ist die Ausgabe Zeile
      #  fuer Zeile identisch mit der Logdatei -- das zaehlt, wenn man
      #  sie vergleicht oder an ein anderes Werkzeug weiterreicht.]
      LOG_STDOUT=1; shift ;;
    --show-output|--output)
      # Volle Ausgabe AUCH auf dem Bildschirm. Ohne das zeigt der
      # Bildschirm nur den Fortschritt.
      VERBOSE=1; shift ;;
    --full-sync)
      # Alles neu uebertragen -- noetig, wenn drueben Dateien fehlen oder
      # etwas geloescht wurde. [Die Zeitmarke erkennt GEAENDERTE Dateien,
      #  aber keine GELOESCHTEN: die bleiben drueben liegen.]
      FULL_SYNC=1; shift ;;
    --git|--git-repo)
      # Git-URL fuer ALLE Hosts dieses Laufs erzwingen -- unabhaengig
      # davon, was (falls ueberhaupt etwas) in hosts.conf steht. Praktisch
      # zum Ausprobieren, ohne die Konfiguration anzufassen.
      FORCE_GIT_URL=$2; shift 2 ;;
    --force-git)
      # Git benutzen, auch wenn hosts.conf KEINE URL eingetragen hat --
      # dann muss die URL ueber --git mitkommen, sonst Fehlermeldung
      # beim ersten betroffenen Host.
      FORCE_GIT=1; shift ;;
    --no-git)
      # Git-Weg abschalten, selbst wenn hosts.conf eine URL eintraegt --
      # etwa wenn das Netz zum Git-Server gerade nicht steht.
      NO_GIT=1; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    --proto)
      if [[ ${2:-} != "$XBM_BUILD_PROTO" ]]; then
        printf '\033[31m%s\033[0m\n' \
          "build.sh auf dieser Maschine ist Fassung $XBM_BUILD_PROTO," >&2
        printf '\033[31m%s\033[0m\n' \
          "die steuernde Seite erwartet ${2:-?}." >&2
        printf '\033[31m%s\033[0m\n' \
          "Die Uebertragung hat build.sh nicht erneuert. Abhilfe:" >&2
        printf '\033[31m%s\033[0m\n' \
          "    ./build.sh --full-sync <ziel>@<host>" >&2
        exit 1
      fi
      shift 2 ;;
    --exec-file)
      # INTERN. [Damit die Gegenseite ihre eigenen pre-/post-action-Hooks
      #  ausfuehrt, wird auch bei --exec drueben build.sh gerufen -- nur
      #  mit dem Skript statt mit Bau-Befehlen. Sonst liefen die Hooks,
      #  die ausdruecklich AUF DER ZIELMASCHINE greifen sollen, nirgends.]
      EXEC_MODE=1; EXEC_CMD=""; XBM_EXEC_DATEI="$2"
      EXEC_VORHANDEN=1
      shift 2 ;;
    --chdir)
      # Arbeitsverzeichnis wechseln, BEVOR irgendetwas passiert.
      # [Damit entfaellt im Fernbefehl das  cd ... &&  -- und genau
      #  dessen Anfuehrungszeichen zerlegt cmd.exe falsch.]
      cd "$2" || { echo "kann nicht wechseln nach: $2" >&2; exit 1; }
      shift 2 ;;
    --run-id)
      # Kennung dieses Laufs -- steht in der Prozessliste und macht den
      # Prozess auf der Gegenseite auffindbar.
      # [Vorher wurde sie als  VAR=wert  vorangestellt. Das ist
      #  POSIX-Schreibweise; cmd.exe kennt sie nicht und meldete
      #      Der Befehl "XBM_LAUF_ID" ist entweder falsch geschrieben...
      #  Ein Argument steht ebenso in der Prozessliste, funktioniert
      #  aber in JEDER Shell.]
      XBM_LAUF_ID="$2"; shift 2 ;;
    --as-host)
      # INTERN. [Der Fernaufruf lautet  --target ziel@local , weil auf der
      #  Zielmaschine oertlich gebaut wird. Damit ging der urspruengliche
      #  Hostname verloren: Hooks der Form  post-action.ziel@windows.sh
      #  wurden drueben nie gefunden (gesucht wurde @local), und XBM_HOST
      #  meldete "local" statt "windows". Diese Option reicht den echten
      #  Namen mit.]
      AS_HOST="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Aufruf:
  build.sh [ziel@host ...] [-t ziel@host,...] [-o vorgabe-host] [-j N]
           [-p N] [--configure-only] [--build-only] [--dry-run] [-v]

--clean
--clean-deep
--target
--on
--jobs
--parallel      (gilt NUR pro Host, ab hier fuer neu hinzugefuegte Ziele --
                 verschiedene Hosts laufen immer gleichzeitig, unabhaengig
                 davon. Vorgabe: 1, siehe --unparallel)
--unparallel    (== --parallel 1 -- Auftraege auf demselben Host streng
                 nacheinander; ab hier fuer neu hinzugefuegte Ziele)
--run           (POSITIONAL wie --parallel: RUN_CMD[ziel] nach
                 erfolgreichem Bau starten, ab hier fuer neu hinzugefuegte
                 Ziele -- siehe config/targets.conf)
--run-only      (POSITIONAL: NICHT bauen -- nur das veroeffentlichte
                 Release von releases.git herunterladen und RUN_CMD
                 ausfuehren, ab hier fuer neu hinzugefuegte Ziele)
--no-run        (== weder --run noch --run-only -- ab hier fuer neu
                 hinzugefuegte Ziele)
--publish       (POSITIONAL: PUBLISH_CMD[ziel] nach erfolgreichem Bau
                 ausfuehren, ab hier fuer neu hinzugefuegte Ziele --
                 SEPARAT von --run, siehe config/targets.conf)
--no-publish    (== kein --publish -- ab hier fuer neu hinzugefuegte
                 Ziele)
--move-to       (build.sh --move-to <host> <datei> -- ueberträgt eine
                 einzelne Datei zu einem Host, Ordnerstruktur bleibt
                 erhalten; ersetzt build_wrapper.sh:mv_to_laptop)

--configure-only
--build-only
--dry-run
--hooks-only / --hooks-only-success
--hooks-only-fail
--list
--show          (am Ende dieses Laufs die Uebersicht zeigen)
--show-last     (nur die Uebersicht des letzten Laufs zeigen, sonst nichts)
--sync-report
--skip-toolcheck
--project
--sync-only
--full-sync
--verbose
--proto
--chdir
--as-host
--help
--no-log
--show-output --output
--install
--no-install
--add-to-path [--machine]
                (build.sh dauerhaft in den PATH; Windows: Benutzer-PATH,
                 mit --machine System-PATH)
--remove-from-path [--machine]
--wsl-keep-warm     (Windows: WSL-VM dauerhaft warm halten)
--no-wsl-keep-warm
--no-log
--show-output --output
--exec
--install
--timing
--timing-file
--no-mux
--no-install
--excerpt
--log-stdout
--show-output|--output
--full-sync
--git|--git-repo
--force-git
--no-git
--verbose
--proto
--exec-file
--chdir
--run-id
--as-host
--help

Beispiele:
  build.sh deb@local win@windows apk@buildserver
  build.sh apk@buildserver
  build.sh -t deb,exe -o local

config/hosts.conf   name | os | benutzer@host | pfad | passwort
                    os ist "posix" oder "windows"; Passwort leer lassen,
                    wenn ein SSH-Schluessel benutzt wird.
config/targets.conf declare -A CONF_CMD BUILD_CMD RUN_CMD PUBLISH_CMD DOWNLOAD
                    Release-Name = Name des Bauordners (builds/deb -> "deb").
                    Vorlage: config/ im Repository von build.sh.
EOF
      exit 0 ;;
    -*) err "unbekannte Option: $1"; exit 2 ;;
    *)
      # BEFEHL AUS DER BIBLIOTHEK? [Dann ist alles dahinter sein
      #  Parameter -- wie bei --exec.]
      if [[ -z $CMD_NAME && -d "${PROJEKT_DIR:-.}/cmds/$1" ]]; then
        CMD_NAME=$1; shift
        CMD_ARGS=("$@"); shift $#
      else
        add_target "$1"; shift
      fi ;;
  esac
done

if (( ${#TARGETS[@]} == 0 )); then
  if (( SHOW_MODE )); then
    # --show OHNE Ziele: es gibt nichts zu bauen, also einfach dasselbe
    # zeigen wie --show-last und beenden. [Sonst wuerde gleich darunter
    # der leere Aufruf auf das Standardziel "linux" umgebogen und ein
    # ECHTER Bau angestossen -- fuer "ich will nur die Uebersicht sehen"
    # waere das ein unerwuenschter Nebeneffekt.]
    SHOW_LAST_MODE=1; SHOW_MODE=0
  elif (( SYNC_ONLY )); then
    err "--sync-only braucht mindestens einen Host:  build.sh --sync-only @windows"
    exit 2
  elif (( EXEC_MODE )); then
    # Ohne Angabe: auf dieser Maschine.
    TARGETS=("ausfuehren"); HOSTS=("$DEFAULT_HOST")
  else
    TARGETS=("linux"); HOSTS=("$DEFAULT_HOST")
  fi
fi
# Bei --exec sind Ziele bedeutungslos -- ein leerer Name aus "@windows"
# wird zu "exec", damit Meldungen und Hook-Auswahl etwas zu nennen haben.
# Ein Bibliotheksbefehl ist ein exec-Auftrag.
if [[ -n $CMD_NAME ]]; then EXEC_MODE=1; fi

# Bei --sync-only braucht es keine Ziele -- nur Maschinen.
if (( SYNC_ONLY )); then
  for _i in "${!TARGETS[@]}"; do
    [[ -z ${TARGETS[$_i]} ]] && TARGETS[$_i]="sync"
  done
fi

EXEC_JOB=()
for _i in "${!TARGETS[@]}"; do EXEC_JOB+=(0); done
if (( EXEC_MODE )); then
  # Gibt es Auftraege OHNE Zielnamen? Dann sind genau die gemeint.
  # Sonst gilt --exec fuer alle -- das ist der Fall
  #     build.sh --exec "ls"        (ganz ohne Auftrag)
  _mit_bare=0
  for _i in "${!TARGETS[@]}"; do
    (( ${OHNE_ZIEL[$_i]:-0} )) && _mit_bare=1
  done
  for _i in "${!TARGETS[@]}"; do
    if (( _mit_bare )); then
      (( ${OHNE_ZIEL[$_i]:-0} )) && EXEC_JOB[$_i]=1
    else
      EXEC_JOB[$_i]=1
    fi
    (( ${EXEC_JOB[$_i]} )) && [[ -z ${TARGETS[$_i]} ]] && TARGETS[$_i]="ausfuehren"
  done
fi

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
# --project auswerten.
# [Drei Schreibweisen:
#      --project .                     hier
#      --project /home/user/projekt    dort, oertlich
#      --project @linux:/home/u/proj   auf einem anderen Rechner
#  Bei der dritten wird das Projekt von dort GEHOLT, bevor es zu den
#  Zielen verteilt wird -- dieser Rechner ist dann nur Durchgangsstation.]
if [[ -n $XBM_PROJECT_ARG ]]; then
  if [[ $XBM_PROJECT_ARG == @*:* ]]; then
    MUTTER_HOST=${XBM_PROJECT_ARG%%:*}; MUTTER_HOST=${MUTTER_HOST#@}
    MUTTER_PFAD=${XBM_PROJECT_ARG#*:}
  elif [[ $XBM_PROJECT_ARG == @* ]]; then
    err "--project @host braucht einen Pfad:  --project @host:/pfad"
    exit 2
  else
    PROJEKT_DIR=$XBM_PROJECT_ARG
  fi
fi

# INS PROJEKTVERZEICHNIS WECHSELN, bevor irgendetwas gelesen wird.
# [config/, hooks/ und die Bauordner sind alle relativ. Der Wechsel muss
#  also vor dem Einlesen passieren -- danach waere die halbe
#  Konfiguration aus dem falschen Ordner.]
if [[ -n $PROJEKT_DIR ]]; then
  cd "$PROJEKT_DIR" || { err "kann nicht wechseln nach: $PROJEKT_DIR"; exit 1; }
fi

# --- GLOBALE HOSTS -----------------------------------------------------
# [Damit build.sh aus dem PATH heraus ueberall dieselben Maschinen
#  kennt. Die Datei im Projekt ergaenzt sie und ueberschreibt
#  gleichnamige Eintraege -- das Projekt hat also das letzte Wort.]
XBM_HOSTS_GLOBAL=()
[[ -n ${XBM_HOSTS:-} ]] && XBM_HOSTS_GLOBAL+=("$XBM_HOSTS")
XBM_HOSTS_GLOBAL+=("$HOME/.config/xbm/hosts.conf" "/etc/xbm/hosts.conf")

# Bei --exec braucht es keine Bau-Ziele.
if (( ! EXEC_MODE )) && (( ! LIST_MODE )); then
  [[ -f config/targets.conf ]] || { err "config/targets.conf fehlt"; exit 1; }
fi
[[ -f config/targets.conf ]] || : 
# shellcheck disable=SC1091
# IMMER DEKLARIEREN, auch ohne targets.conf.
# [Ohne die Deklaration bricht  ${#CONF_CMD[@]}  unter  set -u  mit
#  "unbound variable" ab -- und bei --exec und --list gibt es die Datei
#  ja voellig zu Recht nicht.]
declare -A CONF_CMD BUILD_CMD RUN_CMD PUBLISH_CMD REQUIRE DOWNLOAD RELEASE_NAME
[[ -f config/targets.conf ]] && source config/targets.conf

declare -A HOST_OS HOST_SSH HOST_PATH HOST_PASS HOST_XFER HOST_GIT
HOST_SSH=() HOST_OS=() HOST_PATH=() HOST_PASS=() HOST_XFER=()
# Leerzeichen an BEIDEN Enden entfernen.
# [${v%% } streift nur EIN Zeichen ab. In einer ausgerichteten Tabelle
#  stehen aber mehrere, und der Schluesselname hiess dann
#  "windows       " -- der Nachschlag ging ins Leere und meldete
#  "unbekannter Host".]
trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }

entquote() {   # umschliessende Anfuehrungszeichen entfernen
  local v=$1
  v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
  printf '%s' "$v"
}

# BEIDE FORMATE VERSTEHEN.
# [Dein hosts.conf hatte noch vier Felder:
#     name | sshpass -p "1234" | benutzer@host | pfad
#  Mein neuer Parser erwartete fuenf mit dem Betriebssystem an zweiter
#  Stelle. Dadurch landete der Pfad im falschen Feld -- und der Fernaufruf
#  wurde  mkdir -p ''  , was GNU-mkdir mit "missing operand" quittiert.
#  Genau die Zeile steht in deinem Log.
#
#  Statt dich zum Umschreiben zu zwingen, wird das Format jetzt ERKANNT:
#  steht an zweiter Stelle ein Betriebssystem-Wort, gilt das neue Format,
#  sonst das alte -- und das Passwort wird aus dem sshpass-Aufruf
#  herausgeloest.]
hosts_einlesen() {               # hosts_einlesen <datei>
  [[ -f $1 ]] || return 0
  # SIEBTES FELD: GIT-REPOSITORY.
  #     name | os | benutzer@host | pfad | passwort | xfer | git-url
  # [Steht dort eine URL, wird auf dem Host NICHT mehr getar't/gersynct
  #  -- statt dessen clont bzw. zieht build.sh dort per "git pull" den
  #  aktuellen Stand. Leer = wie gehabt (ssh-Uebertragung).]
  while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 || [[ -n ${c1:-} ]]; do
    local_name=$(trim "${c1:-}")
    [[ $local_name == \#* || -z $local_name ]] && continue
    c2=$(trim "${c2:-}"); c3=$(trim "${c3:-}"); c4=$(trim "${c4:-}")
    c5=$(trim "${c5:-}"); c6=$(trim "${c6:-}"); c7=$(trim "${c7:-}")

    # ROH-DIAGNOSE JEDES FELDES. [Nach zwei Korrekturen, die die
    #  eigentliche Ursache bei dir noch nicht getroffen haben: hier steht
    #  JEDES einzelne Feld genau so, wie es beim Einlesen ankommt -- das
    #  Passwort maskiert. Zaehl die Pipe-Zeichen in der Datei nach: sind
    #  es fuer eine Git-Zeile weniger als 6, fehlt ein Feld (meist das
    #  leere "xfer"-Feld zwischen Passwort und Git-URL) und ALLES ab
    #  dort verschiebt sich um eine Spalte nach links -- die URL landet
    #  dann in c6 statt in c7, und c7 bleibt leer.]
    # log "  [Host-Diagnose] '$1' Zeile fuer '$local_name': c2='$c2' c3='$c3' c4='$c4' c5='***' c6='$c6' c7='$c7'"

    local_os="" local_ssh="" local_path="" local_pass="" local_xfer="" local_git=""
    case ${c2,,} in
      posix|linux|unix|mac|macos|darwin|windows|win|cmd|gitbash|msys|wsl)
        local_os=${c2,,}; local_ssh=$c3; local_path=$c4
        local_pass=$(entquote "$c5"); local_xfer=${c6,,} ;;
      *)
        # ALTES FORMAT: name | sshpass -p "..." | benutzer@host | pfad
        local_ssh=$c3; local_path=$c4
        if [[ $c2 == *sshpass* ]]; then
          # Passwort hinter -p herausloesen, Anfuehrungszeichen weg.
          local_pass=$(entquote "$(printf '%s' "$c2" | sed -n 's/.*-p[[:space:]]*//p')")
        fi
        # Betriebssystem aus dem Pfad raten: Laufwerksbuchstabe = Windows.
        if [[ $local_path =~ ^[A-Za-z]: ]]; then local_os=windows
        else local_os=posix; fi
        ;;
    esac
    # GIT-URL IMMER AUS FELD 7 -- UNABHAENGIG VOM OBEN GEWAEHLTEN ZWEIG.
    # [Vorher stand "local_git=$c7" NUR im "neuen Format"-Zweig (bekanntes
    #  Betriebssystem-Wort in Feld 2). Ein Eintrag, der aus irgendeinem
    #  Grund in den "alten Format"-Zweig fiel -- z.B. ein Tippfehler im
    #  Betriebssystem-Feld, oder ein Host, der noch die uralte sshpass-
    #  Schreibweise nutzt -- verlor damit seine Git-URL STILLSCHWEIGEND,
    #  ganz gleich, was dort tatsaechlich in der Datei stand. Jetzt wird
    #  Feld 7 immer gelesen, egal welcher Zweig fuer Betriebssystem/
    #  Zugang gegriffen hat -- eine Git-URL ist unabhaengig davon.]
    local_git=$c7
    # VERRUTSCHTES FELD ABFANGEN: eine Git-URL SIEHT MAN ihr an (beginnt
    # mit einem Schema wie http(s):// oder git@/ssh://) -- ganz im
    # Unterschied zu "xfer", das nur "tar"/"rsync"/leer sein darf. Fehlt
    # das leere xfer-Feld zwischen Passwort und Git-URL (die Zeile hat
    # dann nur 6 statt 7 Felder), landet die URL in c6 statt in c7 --
    # GENAU DAS war bei mehreren Hosts gleichzeitig der Fall: kein
    # Einzeltippfehler, sondern ein durchgehend falsches Format in der
    # ganzen Datei. Statt das viermal von Hand zu korrigieren, erkennt
    # der Parser das jetzt selbst und verschiebt es zurecht.
    if [[ -z $local_git && $local_xfer =~ ^(https?|git|ssh)://|^[A-Za-z0-9_.-]+@.*: ]]; then
      local_git=$c6
      local_xfer=""
    fi
    # DREI ARTEN VON WINDOWS-ZUGANG -- sie brauchen verschiedene Syntax.
    # [Bisher gab es nur "windows", und das hiess "schick alles durch
    #  bash -lc". Das setzt voraus, dass die ANMELDE-Shell eine
    #  POSIX-Shell ist. Ist es cmd.exe, greift die Klammerung nicht:
    #  cmd kennt keine einfachen Anfuehrungszeichen und will
    #  Backslashes. Genau daher kamen "Syntaxfehler." und "Die Syntax
    #  fuer den Dateinamen ... ist falsch".]
    #   cmd      Anmelde-Shell ist cmd.exe  -> cmd-Syntax
    #   gitbash  Anmelde-Shell ist bash     -> bash -lc
    #   wsl      -> posix, das IST Linux
    [[ $local_os == win  ]] && local_os=cmd
    [[ $local_os == windows ]] && local_os=cmd
    [[ $local_os == msys ]] && local_os=gitbash
    # wsl BLEIBT eigenstaendig.
    # [Bisher wurde es auf posix abgebildet -- das stimmt nur, wenn die
    #  ANMELDE-Shell schon in WSL liegt. Bei dir landet ssh in cmd.exe;
    #  ein  mkdir -p '/home/...'  ging dann an cmd und ergab
    #  "Syntaxfehler." und "Das System kann den angegebenen Pfad nicht
    #  finden." WSL erreicht man von cmd aus nur ueber wsl.exe.]
    [[ $local_os == linux || $local_os == unix || $local_os == mac \
       || $local_os == macos || $local_os == darwin ]] && local_os=posix

    # Doppelte Schraegstriche glaetten (C://Users -> C:/Users).
    local_path=${local_path//\/\//\/}
    # BEQUEMLICHKEITEN IM PFAD aufloesen.
    # [$(pwd) im Konfigurationsfile wird als TEXT gelesen, nicht
    #  ausgefuehrt -- daraus wuerde ein Ordner namens "$(pwd)". Statt die
    #  Datei per eval auszufuehren (was jede Zeile zu ausfuehrbarem Code
    #  machte), werden genau die drei ueblichen Faelle ersetzt.]
    local_path=${local_path//\$\(pwd\)/$PWD}
    local_path=${local_path//\$\{PWD\}/$PWD}
    local_path=${local_path//\$PWD/$PWD}
    local_path=${local_path//\$HOME/$HOME}
    local_path=${local_path//\$\{HOME\}/$HOME}
    [[ $local_path == "~"* ]] && local_path="$HOME${local_path#\~}"

    # ÖRTLICHER HOST -- kein benutzer@host noetig.
    # [Meine Pruefung verlangte beides. Ein Eintrag wie
    #     local | posix | | $(pwd) |
    #  ist aber voellig sinnvoll: man will den oertlichen Bau in
    #  derselben Tabelle stehen haben. Fehlt benutzer@host, ist der Host
    #  eben oertlich -- dann braucht es weder ssh noch einen Pfad, denn
    #  gebaut wird im Projektordner selbst.]
    if [[ -z $local_ssh ]]; then
      HOST_OS[$local_name]=${local_os:-posix}
      HOST_SSH[$local_name]=""
      HOST_PATH[$local_name]=${local_path:-.}
      HOST_PASS[$local_name]=""
      HOST_XFER[$local_name]=""
      # AUCH HIER Feld 7 uebernehmen statt hart zu leeren. [Dieser Zweig
      #  gilt fuer Hosts OHNE benutzer@host (typischerweise "local") --
      #  bisher wurde HOST_GIT dort bedingungslos geleert, selbst wenn
      #  in Feld 7 tatsaechlich eine URL stand. Ein oertlicher Host
      #  braucht zwar meist kein Git, aber "hart leeren, egal was
      #  dasteht" ist genau dieselbe Art von stillschweigendem
      #  Datenverlust wie beim frueheren Fehler im "alten Format"-Zweig.]
      HOST_GIT[$local_name]=$local_git
      continue
    fi
    if [[ -z $local_path ]]; then
      err "config/hosts.conf: Host '$local_name' ohne Pfad"
      err "  benutzer@host = '${local_ssh}'"
      err "  Erwartet:  name | os | benutzer@host | pfad | passwort"
      err "  (Fuer einen oertlichen Host benutzer@host leer lassen.)"
      exit 1
    fi
    HOST_OS[$local_name]=$local_os;   HOST_SSH[$local_name]=$local_ssh
    HOST_PATH[$local_name]=$local_path; HOST_PASS[$local_name]=$local_pass
    HOST_XFER[$local_name]=$local_xfer; HOST_GIT[$local_name]=$local_git
  done < "$1"
}

# Erst die globalen, dann die des Projekts -- gleichnamige werden dabei
# ueberschrieben, neue kommen hinzu.
for _hf in "${XBM_HOSTS_GLOBAL[@]}"; do
  [[ -f $_hf ]] && { hosts_einlesen "$_hf"; HOST_QUELLE_GLOBAL="$_hf"; }
done
hosts_einlesen "config/hosts.conf"

# ---------------------------------------------------------------------------
# SSH-Aufruf als ARRAY zusammensetzen -- nie als Zeichenkette.
# [Eine Zeichenkette muesste erneut zerlegt werden, und genau dabei gehen
#  Leerzeichen und Anfuehrungszeichen verloren. Ein Array behaelt jedes
#  Argument so, wie es gemeint war.]
# ---------------------------------------------------------------------------
ssh_cmd() {                      # $1 = hostname -> setzt SSH_ARGV
  local h=$1
  SSH_ARGV=()
  local pw=${HOST_PASS[$h]:-}
  [[ -n $pw ]] && SSH_ARGV+=(sshpass -p "$pw")
  # ZEITGRENZEN. [Ohne sie haengt ssh bei einer toten Gegenstelle
  #  unbegrenzt -- und weil waehrend der Uebertragung nichts ausgegeben
  #  wird, sieht "haengt" genauso aus wie "arbeitet". ConnectTimeout
  #  begrenzt den Verbindungsaufbau, ServerAlive erkennt eine Leitung,
  #  die mitten in der Uebertragung stirbt.]
  # EINE VERBINDUNG FUER ALLE BEFEHLE.
  # [Gemessen: ein einziges  --exec "echo hallo"  baute SECHS
  #  ssh-Verbindungen auf (Ordner anlegen, Werkzeuge pruefen, Fassung
  #  lesen, uebertragen, aufrufen, Nachkontrolle). Windows-OpenSSH
  #  braucht je Verbindung ein bis zwei Sekunden -- daher deine 10 bis
  #  20 Sekunden.
  #
  #  ControlMaster haelt die ERSTE Verbindung offen; alle weiteren
  #  laufen als zusaetzliche Kanaele darin und kosten fast nichts. Auch
  #  die Passwortpruefung faellt nur einmal an.
  #  ControlPath nutzt %C (ein kurzer Hash) -- ein langer Pfad sprengt
  #  sonst die Laengengrenze von Unix-Sockets.]
  local cpfad="${TMPDIR:-/tmp}/xbm-%C"
  SSH_ARGV+=(ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new
             -o ConnectTimeout=20
             -o ServerAliveInterval=15 -o ServerAliveCountMax=8)
  if (( ! XBM_KEIN_MUX )); then
    SSH_ARGV+=(-o ControlMaster=auto -o "ControlPath=$cpfad"
               -o ControlPersist=120)
  fi
  SSH_ARGV+=("${HOST_SSH[$h]}")
}

# Fuer rsync -e: EIN Wort mit dem Transportbefehl.
rsh_string() {
  # [Zwei getrennte local-Zeilen: bei "local h=$1 pw=${HOST_PASS[$h]}"
  #  expandiert Bash ALLE Woerter vor der ersten Zuweisung -- $h war dann
  #  noch das h des AUFRUFERS (dynamischer Geltungsbereich). Je nach
  #  Aufrufer kam so das Passwort eines ANDEREN Hosts oder gar keins.]
  local h=$1
  local pw=${HOST_PASS[$h]:-}
  if [[ -n $pw ]]; then printf 'sshpass -p %s ssh' "$pw"
  else                  printf 'ssh'; fi
}

# ALLES DURCH EINE POSIX-SHELL SCHICKEN -- auch auf Windows.
# [Der eigentliche Grund, warum "mkdir -p" auf Windows scheiterte: die
#  Vorgabe-Shell von OpenSSH ist dort cmd.exe, und die kennt weder
#  mkdir -p noch test -d noch &&. Der naheliegende Ausweg waere, alles in
#  cmd- bzw. PowerShell-Syntax zu doppeln -- zwei Sprachen fuer dieselbe
#  Sache, mit eigenem Zitier-Regelwerk.
#
#  Es gibt einen einfacheren: auf dem Windows-Ziel muss ohnehin eine
#  POSIX-Shell vorhanden sein, denn dort laeuft ./build.sh weiter. Also
#  wird JEDER Befehl durch  bash -lc  geschickt. Damit gilt ueberall
#  dieselbe Syntax, und mkdir -p, test -d und Pipes funktionieren.
#
#  Voraussetzung auf dem Windows-Rechner: Git Bash oder MSYS2, und bash
#  muss im PATH des SSH-Dienstes liegen.]

# Pfad in die Form, die cmd.exe versteht: Backslashes.
# [cmd nimmt zwar oft auch Schraegstriche an, aber nicht ueberall --
#  bei "cd /d" und in Anfuehrungszeichen ist der Backslash sicher.]
winpfad() { printf '%s' "${1//\//\\}"; }

# Baut den Fernbefehl als GENAU EIN Argument.
# [Bei getrennter Uebergabe fuegt ssh alles mit Leerzeichen zusammen und
#  die Gegenseite zerlegt erneut -- dabei geht die Zuordnung verloren.
#  Diese Funktion wird von allen Stellen benutzt, damit der Fehler nicht
#  an einer davon wieder auftaucht.]
build_remote_argv() {            # build_remote_argv <host> <befehl>
  # Der Befehl muss GENAU EIN Argument sein: ssh fuegt seine Argumente
  # mit Leerzeichen zusammen, und die Gegenseite zerlegt erneut.
  local h=$1 cmdline=$2
  ssh_cmd "$h"
  case ${HOST_OS[$h]:-posix} in
    gitbash)
      # -c statt -lc.
    # [Das -l laedt bei JEDEM Aufruf das komplette Profil. Auf MSYS2 und
    #  Git Bash sind das schnell mehrere Sekunden -- mal sechs. Wer
    #  seinen PATH nur im Profil setzt, stellt mit
    #      XBM_REMOTE_SHELL="bash -lc"
    #  auf das alte Verhalten zurueck.]
    local rsh=${XBM_REMOTE_SHELL:-bash -c}
      SSH_ARGV+=("$rsh \"${cmdline//\"/\\\"}\"")
      ;;
    cmd)
      # Bei cmd wird NICHT geklammert -- der Aufrufer liefert bereits
      # cmd-Syntax (siehe remote_mkdir / die tar-Zweige).
      SSH_ARGV+=("$cmdline")
      ;;
    wsl)
      # Ueber cmd.exe nach WSL hinein. wsl.exe reicht die restlichen
      # Argumente unveraendert an das Linux-System weiter -- daher OHNE
      # Anfuehrungszeichen, sonst zerlegt cmd sie wieder falsch.
      SSH_ARGV+=("wsl.exe $cmdline")
      ;;
    *)
      SSH_ARGV+=("$cmdline")
      ;;
  esac
}

remote() {                       # remote <host> <befehl als eine zeichenkette>
  local h=$1; shift
  local cmdline="$*"
  build_remote_argv "$h" "$cmdline"
  if (( DRY_RUN )); then
    printf '  [Probelauf] %s\n' "${SSH_ARGV[*]}"
    return 0
  fi
  if (( TIMING )); then
    local t_a t_b rc2
    t_a=$(date +%s%N); "${SSH_ARGV[@]}"; rc2=$?; t_b=$(date +%s%N)
    messpunkt "ssh $(ns_zu_s $(( t_b - t_a )))s: $(printf '%s' "$cmdline" | head -c 55)"
    return $rc2
  fi
  "${SSH_ARGV[@]}"
}

# GIT STATT TAR/RSYNC -- clont bzw. zieht direkt AUF der Gegenseite.
# [Kein Datenstrom von hier zur Gegenseite noetig; die Gegenseite holt
#  sich den Stand selbst vom Git-Server. Setzt auf jeder Plattform
#  voraus, dass dort ein "git" im PATH steht (dieselbe Pruefung wie bei
#  cmake/ninja koennte das bei Bedarf ergaenzen -- hier bewusst schlank
#  gehalten, weil es ein Zusatzweg ist, kein Ersatz fuer den Regelfall).]
git_pull_host() {                # git_pull_host <host> <pfad> <url>
  local h=$1 p=$2 url=$3
  local os=${HOST_OS[$h]:-posix}
  local befehl marke="${SYNC_DIR}/${h}.git-stamp"

  # ZEITSTEMPEL-SCHONEND: "git reset --hard" schreibt beim Auschecken
  # JEDE getrackte Datei neu -- auch wenn sich am INHALT nichts geaendert
  # hat, bekommt sie eine frische mtime (Git kennt keine "unveraendert
  # lassen"-Option beim Checkout). Ninja/CMake stufen eine neuere mtime
  # als "moeglicherweise geaendert" ein: die naechste Konfiguration laeuft
  # neu an, FetchContent fuehrt seine Populate-Schritte erneut aus, und
  # jede Quelldatei wird zumindest an ccache vorbeigeschickt (das dort
  # zwar schnell einen Treffer liefert, aber eben doch angefragt wird)
  # -- in Summe genau der gemeldete "komplette Neustart" nach jedem
  # Git-Abgleich.
  #
  # LOESUNG: vor dem Reset den Namensunterschied zwischen dem alten und
  # dem neuen Stand ermitteln ("git diff --name-only", funktioniert auch
  # mit --depth 1, da der ALTE HEAD-Commit lokal noch vorhanden ist --
  # nur die GESCHICHTE davor ist bei einem flachen Klon nicht da). Nach
  # dem Reset bekommt NUR, was tatsaechlich in dieser Liste steht, seine
  # neue mtime; jede andere Datei wird auf ihren VORHERIGEN Zeitstempel
  # zurueckgesetzt.
  #
  # [Nutzt "find -printf"/"touch -d" (GNU-Erweiterungen) -- auf Linux und
  #  ueber Git-fuer-Windows' mitgelieferte Bash (die GNU-coreutils
  #  mitbringt) verfuegbar. Auf einem reinen macOS-Host (BSD-find/-touch)
  #  wuerde das NICHT greifen -- dort bliebe es beim bisherigen
  #  Verhalten, ohne dass etwas kaputtginge.]
  #
  # FETCH_HEAD statt origin/HEAD -- durchgehend, aus demselben Grund wie
  # unten bei der Erstumstellung: ein per "git init" (statt "git clone")
  # angelegtes Repo kennt refs/remotes/origin/HEAD nie, und JEDER Sync
  # auf so einem Host wuerde sonst mit "ambiguous argument origin/HEAD"
  # scheitern -- nicht nur der allererste.
  local mtime_schonend='
    ALT_STAND=$(git rev-parse HEAD 2>/dev/null)
    # FETCH-FEHLSCHLAG EXPLIZIT ABFANGEN, MIT WIEDERHOLVERSUCHEN. [Vorher
    #  haengte "&&" nur an der NAECHSTEN Zeile (git diff) -- alles danach
    #  (die mtime-Liste, vor allem "git reset --hard FETCH_HEAD") lief
    #  UNBEDINGT weiter, selbst wenn der Fetch gescheitert war.
    #  FETCH_HEAD existierte dann gar nicht, und "git reset" brach mit
    #  der voellig irrefuehrenden Meldung "ambiguous argument
    #  FETCH_HEAD: unknown revision" ab -- sah nach einem GANZ ANDEREN
    #  Fehler aus, war aber nur die Folge des schon vorher gescheiterten
    #  Netzwerkzugriffs.
    #  ZUSAETZLICH mit Wiederholversuchen: "the remote end hung up
    #  unexpectedly" trat wiederholt GENAU dann auf, wenn MEHRERE Hosts
    #  gleichzeitig synchronisierten -- sieht nach einem kleinen/eigenen
    #  Git-Server aus, der mehrere gleichzeitige Verbindungen nicht
    #  vertraegt. Ein einzelner Fehlschlag ist dann kein dauerhaftes
    #  Problem, sondern oft im naechsten Moment schon wieder behoben --
    #  drei Versuche mit steigender Pause, bevor wirklich aufgegeben
    #  wird.]
    fetch_ok=0
    for versuch in 1 2 3; do
      if git fetch --depth 1 origin; then fetch_ok=1; break; fi
      echo "git fetch fehlgeschlagen (Versuch $versuch/3) -- naechster Versuch in $((versuch*3))s" >&2
      sleep $((versuch*3))
    done
    if [ "$fetch_ok" != 1 ]; then
      echo "git fetch fehlgeschlagen -- Server nicht erreichbar oder Verbindung unterbrochen (nach 3 Versuchen)" >&2
      exit 1
    fi
    git diff --no-renames --name-only "$ALT_STAND" FETCH_HEAD \
      > .xbm-git-geaendert.tmp 2>/dev/null
    if find . -maxdepth 0 -printf "" >/dev/null 2>&1; then
      find . -type f -not -path "./.git/*" -printf "%T@|%p\n" \
        > .xbm-git-mtimes.tmp 2>/dev/null
    else
      : > .xbm-git-mtimes.tmp   # kein GNU-find (z.B. macOS) -- Absicherung uebersprungen
    fi
    git reset --hard FETCH_HEAD &&
    # CRLF AN DER WURZEL ABSTELLEN -- ausfuehrliche Begruendung im
    # cmd-Zweig weiter unten. Gilt hier vor allem fuer "gitbash": auch
    # dort ist core.autocrlf=true die Vorgabe von Git fuer Windows und
    # erzeugt bei JEDEM Auschecken neue CRLF-Dateien. Auf Linux/FreeBSD
    # ist die Einstellung ohnehin unbedeutend -- die Merkdatei wird dort
    # einmal angelegt und danach nie wieder angefasst, es kostet also
    # nichts.
    if [ ! -f .xbm-lf.ok ]; then
      git config core.autocrlf false 2>/dev/null
      git config core.eol lf 2>/dev/null
      git rm --cached -r -q . >/dev/null 2>&1 &&
        git reset --hard FETCH_HEAD >/dev/null 2>&1
      echo ok > .xbm-lf.ok 2>/dev/null
    fi
    # SUBMODULE NUR BEI TATSAECHLICHEM BEDARF AKTUALISIEREN. [Vorher lief
    # "git submodule update" bei JEDEM Sync, selbst wenn sich am
    # Submodul-Verweis gar nichts geaendert hatte -- das heisst: bei
    # JEDEM Abgleich ein Netzwerk-Ausflug zu GitHub (curl, hello_imgui
    # UND deren eigene verschachtelte Submodule), unabhaengig davon, ob
    # ueberhaupt etwas Neues da war. Genau das erklaerte die gemeldeten
    # 20-50 Sekunden pro Sync.
    #
    # DIE PRUEFUNG SIEHT DIREKT NACH, OB DIE ORDNER BEFUELLT SIND --
    # sie verlaesst sich NICHT auf "git submodule status".
    # [Auf windows lieferte die alte Bedingung
    #      git submodule status | grep -q "^-"
    #  keinen Treffer, obwohl external/pdf dort nachweislich leer war:
    #  im Protokoll erschien ueberhaupt KEINE Submodul-Zeile, weder
    #  Erfolg noch Fehler noch Warnung -- der ganze Block wurde
    #  uebersprungen, und CMake brach danach jedes Mal mit "does not
    #  contain a CMakeLists.txt file" ab. Warum "git submodule status"
    #  dort schweigt, laesst sich aus der Ferne nicht klaeren -- also
    #  wird jetzt einfach das GEPRUEFT, WORAUF ES ANKOMMT: steht in
    #  .gitmodules ein Pfad, der gar nicht existiert oder leer ist,
    #  muss geholt werden. Das ist unabhaengig von Git-Eigenheiten und
    #  auf jedem System gleich.]
    xbm_submodul_fehlt=0
    if [ -f .gitmodules ]; then
      while IFS= read -r xbm_smpfad; do
        [ -z "$xbm_smpfad" ] && continue
        if [ ! -d "$xbm_smpfad" ] || [ -z "$(ls -A "$xbm_smpfad" 2>/dev/null)" ]; then
          echo "  Submodul-Ordner ist leer: $xbm_smpfad -- wird geholt" >&2
          xbm_submodul_fehlt=1
        fi
      done <<XBMEOF
$(sed -n "s/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p" .gitmodules 2>/dev/null)
XBMEOF
    fi
    if grep -qE "^external/" .xbm-git-geaendert.tmp 2>/dev/null \
       || [ "$xbm_submodul_fehlt" = 1 ]; then
      (git submodule update --init --recursive --depth 1 2>&1 ||
       {
         # SELBSTHEILUNG BEI VERALTETEM VERWEIS. [Der haeufigste Grund
         #  fuer einen Fehlschlag hier: das Hauptprojekt zeigt auf einen
         #  Commit, den es auf dem Submodul-Server gar nicht (mehr) gibt
         #  -- "Server does not allow request for unadvertised object".
         #  Der normale Weg kann das nicht aufloesen und laesst den
         #  Ordner LEER zurueck; CMake bricht dann mit "does not contain
         #  a CMakeLists.txt file" ab, und zwar bei JEDEM Lauf aufs
         #  Neue. "--remote" holt stattdessen den aktuellen Stand des im
         #  .gitmodules eingetragenen Branches -- damit ist der Ordner
         #  wenigstens befuellt und der Bau kann durchlaufen.
         #  ACHTUNG: das ist eine Notbremse, kein Ersatz fuer das
         #  Richtigstellen des Verweises -- deshalb die deutliche
         #  Meldung.]
         echo "WARNUNG: git submodule update fehlgeschlagen -- der im Hauptprojekt eingetragene Commit existiert auf dem Submodul-Server offenbar nicht (mehr)." >&2
         echo "         Versuche Notbremse: aktuellen Branch-Stand holen (git submodule update --remote) ..." >&2
         if git submodule update --init --recursive --remote 2>&1; then
           echo "         Notbremse hat geholfen -- der Baum ist befuellt." >&2
           echo "         BITTE TROTZDEM RICHTIGSTELLEN, sonst passiert das bei jedem Lauf:" >&2
           echo "           cd external/pdf && git fetch origin && git checkout origin/main" >&2
           echo "           cd ../.. && git add external/pdf && git commit -m \"pdf-Verweis\" && git push" >&2
         else
           echo "         Auch die Notbremse schlug fehl -- external/pdf bleibt leer, der Bau wird scheitern." >&2
         fi
       })
    fi
    # NACHKONTROLLE: REPOSITORY DA, ABER ARBEITSBAUM LEER.
    # [Genau dieser Zustand lag auf buildserver vor: external/pdf hatte
    #  ein vollstaendiges .git (git reflog funktionierte dort, HEAD stand
    #  auf 627df9d), aber KEINE Dateien. Grund: Git klont ein Submodul
    #  intern mit "--no-checkout" und checkt DANACH den im Hauptprojekt
    #  eingetragenen Commit aus. Ist dieser Commit im flachen Klon nicht
    #  enthalten (der bekannte Fall "Server does not allow request for
    #  unadvertised object 565c950"), scheitert NUR dieser zweite
    #  Schritt -- der Klon selbst gilt als erfolgreich, der Ordner bleibt
    #  aber leer, und "git submodule update" versucht es beim naechsten
    #  Lauf gar nicht mehr, weil das Repository ja schon da ist. Hier
    #  wird deshalb der fehlende Auscheck-Schritt nachgeholt.]
    if [ -f .gitmodules ]; then
      while IFS= read -r xbm_smpfad; do
        [ -z "$xbm_smpfad" ] && continue
        [ -e "$xbm_smpfad/.git" ] || continue
        if [ -z "$(ls -A "$xbm_smpfad" 2>/dev/null | grep -v "^\.git$")" ]; then
          echo "  $xbm_smpfad: Repository vorhanden, aber Arbeitsbaum LEER -- hole Auschecken nach" >&2
          ( cd "$xbm_smpfad" &&
            { git checkout -f HEAD 2>&1 ||
              git reset --hard 2>&1 ||
              git checkout -f origin/HEAD 2>&1 ||
              git checkout -f main 2>&1 ; } ) || true
          if [ -z "$(ls -A "$xbm_smpfad" 2>/dev/null | grep -v "^\.git$")" ]; then
            echo "  $xbm_smpfad: bleibt leer -- der Bau wird daran scheitern." >&2
          else
            echo "  $xbm_smpfad: Dateien sind jetzt da." >&2
          fi
        fi
      done <<XBMSMEOF
$(sed -n "s/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p" .gitmodules 2>/dev/null)
XBMSMEOF
    fi
    while IFS="|" read -r ts pfad; do
      rel=${pfad#./}
      grep -qxF "$rel" .xbm-git-geaendert.tmp 2>/dev/null && continue
      [ -f "$pfad" ] && touch -d "@${ts%%.*}" "$pfad" 2>/dev/null
    done < .xbm-git-mtimes.tmp
    rm -f .xbm-git-mtimes.tmp .xbm-git-geaendert.tmp
    # CRLF-BEREINIGUNG, UNABHAENGIG VOM REPOSITORY-ZUSTAND. [Trotz
    # .gitattributes und mehrfachem manuellem Nachziehen tauchte das
    # CRLF-Problem (kaputte Shebang-Zeilen, "env: bash\r: No such file
    # or directory") immer wieder auf -- offenbar durch erneutes
    # Bearbeiten auf einem Windows-Rechner. Statt weiter auf saubere
    # Zeilenenden IM REPOSITORY zu vertrauen, wird hier nach JEDEM Sync
    # defensiv nachgesehen und noetigenfalls repariert. Nur Dateien, die
    # WIRKLICH ein \r enthalten, werden ueberhaupt angefasst -- eine
    # bereits saubere Datei behaelt ihre mtime.
    #
    # NUR POSIX-WERKZEUGE, ausdruecklich BSD-tauglich. [buildserver
    #  laeuft FreeBSD. Die naheliegende GNU-Schreibweise
    #      grep -qP "\r" ... && sed -i "s/\r$//" ...
    #  funktioniert dort NICHT: BSD-grep kennt kein -P, und BSD-sed
    #  verlangt bei -i zwingend ein (ggf. leeres) Backup-Argument, sonst
    #  verschluckt es den Ausdruck. Ergebnis waere: auf FreeBSD wird nie
    #  etwas bereinigt. "tr" und "cmp" gibt es dagegen ueberall gleich.
    #  Das Zurueckschreiben laeuft ueber "cat >" statt "mv", weil mv die
    #  Rechte der TEMPORAERDATEI mitbrächte -- die Ausfuehrbarkeit eines
    #  Hook-Skripts ginge dabei verloren.]
    find . -type f \( -name "*.sh" -o -path "./hooks/*" \) \
           -not -path "./.git/*" 2>/dev/null | while read -r datei; do
      if ! tr -d "\r" < "$datei" 2>/dev/null | cmp -s - "$datei" 2>/dev/null; then
        tr -d "\r" < "$datei" > "$datei.xbmtmp" 2>/dev/null &&
          cat "$datei.xbmtmp" > "$datei" 2>/dev/null
        rm -f "$datei.xbmtmp"
      fi
      true   # SCHLEIFE DARF NIE ueber ihren eigenen Rueckgabewert einen
             # "Fehler" melden -- im GUTEN Fall (Datei bereits sauber)
             # liefert die Pruefung sonst 1. Als LETZTER Befehl im ganzen
             # Sync-Skript wuerde GENAU DAS als Sync-Fehlschlag gemeldet,
             # obwohl alles in Ordnung war -- exakt der Fehler, an dem
             # apk@buildserver wiederholt scheiterte.
    done
    true   # dasselbe nochmal fuer den Fall "gar keine Datei gefunden"
  '

  # ERSTUMSTELLUNG: das Zielverzeichnis liegt schon da (von einem
  # frueheren tar/rsync-Sync) und hat Inhalt, ist aber noch KEIN
  # Git-Repo. "git clone" verlangt einen leeren (oder nicht
  # vorhandenen) Zielordner und bricht sonst ab:
  #     fatal: destination path '...' already exists and is not an
  #     empty directory.
  # Genau das ist die gemeldete Fehlermeldung -- kein Netzwerk- oder
  # Erreichbarkeitsproblem, wie die alte Fehlermeldung vermuten liess.
  # Loesung: den VORHANDENEN Ordner per "git init" selbst zum Repo
  # machen, statt ihn per "clone" neu anzulegen -- fetch/reset uebernimmt
  # ihn danach genauso wie bei jedem spaeteren Abgleich.
  #
  # WICHTIG: hier gegen FETCH_HEAD zuruecksetzen, nicht gegen
  # origin/HEAD. [Bei "git clone" legt Git die Referenz
  # refs/remotes/origin/HEAD automatisch an (es fragt dafuer den
  # Standard-Branch der Gegenseite ab) -- bei "git init" + "git fetch"
  # von Hand passiert das NICHT, und "git reset --hard origin/HEAD"
  # scheitert dann mit "ambiguous argument origin/HEAD: unknown
  # revision". FETCH_HEAD zeigt dagegen IMMER auf das, was der letzte
  # "git fetch" tatsaechlich geholt hat -- unabhaengig davon, ob die
  # Referenz vorher schon existierte.]
  local erstumstellung='
    git init -q &&
    (git remote add origin "'"$url"'" 2>/dev/null || git remote set-url origin "'"$url"'") &&
    (fetch_ok=0
     for versuch in 1 2 3; do
       git fetch --depth 1 origin && { fetch_ok=1; break; }
       echo "git fetch fehlgeschlagen (Versuch $versuch/3) -- naechster Versuch in $((versuch*3))s" >&2
       sleep $((versuch*3))
     done
     [ "$fetch_ok" = 1 ]) &&
    git reset --hard FETCH_HEAD &&
    # CRLF AN DER WURZEL ABSTELLEN -- ausfuehrliche Begruendung im
    # cmd-Zweig weiter unten. Gilt hier vor allem fuer "gitbash": auch
    # dort ist core.autocrlf=true die Vorgabe von Git fuer Windows und
    # erzeugt bei JEDEM Auschecken neue CRLF-Dateien. Auf Linux/FreeBSD
    # ist die Einstellung ohnehin unbedeutend -- die Merkdatei wird dort
    # einmal angelegt und danach nie wieder angefasst, es kostet also
    # nichts.
    if [ ! -f .xbm-lf.ok ]; then
      git config core.autocrlf false 2>/dev/null
      git config core.eol lf 2>/dev/null
      git rm --cached -r -q . >/dev/null 2>&1 &&
        git reset --hard FETCH_HEAD >/dev/null 2>&1
      echo ok > .xbm-lf.ok 2>/dev/null
    fi
    (git submodule update --init --recursive --depth 1 2>&1 ||
       {
         # SELBSTHEILUNG BEI VERALTETEM VERWEIS. [Der haeufigste Grund
         #  fuer einen Fehlschlag hier: das Hauptprojekt zeigt auf einen
         #  Commit, den es auf dem Submodul-Server gar nicht (mehr) gibt
         #  -- "Server does not allow request for unadvertised object".
         #  Der normale Weg kann das nicht aufloesen und laesst den
         #  Ordner LEER zurueck; CMake bricht dann mit "does not contain
         #  a CMakeLists.txt file" ab, und zwar bei JEDEM Lauf aufs
         #  Neue. "--remote" holt stattdessen den aktuellen Stand des im
         #  .gitmodules eingetragenen Branches -- damit ist der Ordner
         #  wenigstens befuellt und der Bau kann durchlaufen.
         #  ACHTUNG: das ist eine Notbremse, kein Ersatz fuer das
         #  Richtigstellen des Verweises -- deshalb die deutliche
         #  Meldung.]
         echo "WARNUNG: git submodule update fehlgeschlagen -- der im Hauptprojekt eingetragene Commit existiert auf dem Submodul-Server offenbar nicht (mehr)." >&2
         echo "         Versuche Notbremse: aktuellen Branch-Stand holen (git submodule update --remote) ..." >&2
         if git submodule update --init --recursive --remote 2>&1; then
           echo "         Notbremse hat geholfen -- der Baum ist befuellt." >&2
           echo "         BITTE TROTZDEM RICHTIGSTELLEN, sonst passiert das bei jedem Lauf:" >&2
           echo "           cd external/pdf && git fetch origin && git checkout origin/main" >&2
           echo "           cd ../.. && git add external/pdf && git commit -m \"pdf-Verweis\" && git push" >&2
         else
           echo "         Auch die Notbremse schlug fehl -- external/pdf bleibt leer, der Bau wird scheitern." >&2
         fi
       })
    find . -type f \( -name "*.sh" -o -path "./hooks/*" \) \
           -not -path "./.git/*" 2>/dev/null | while read -r datei; do
      if ! tr -d "\r" < "$datei" 2>/dev/null | cmp -s - "$datei" 2>/dev/null; then
        tr -d "\r" < "$datei" > "$datei.xbmtmp" 2>/dev/null &&
          cat "$datei.xbmtmp" > "$datei" 2>/dev/null
        rm -f "$datei.xbmtmp"
      fi
      true
    done
    true
  '

  case $os in
    cmd)
      local w; w=$(winpfad "$p")
      # CRLF AN DER WURZEL ABSTELLEN. [Git fuer Windows setzt
      #  core.autocrlf=true als Vorgabe -- Git wandelt dann BEIM
      #  AUSCHECKEN jedes LF in CRLF um. Das Repository kann also
      #  vollkommen sauber sein (und war es auch, "git add
      #  --renormalize" fand deshalb nie etwas), und trotzdem liegen auf
      #  der Windows-Platte nach JEDEM reset wieder CRLF-Dateien --
      #  darum "./build_apk.sh: cannot execute" und "env: bash\r: No
      #  such file or directory", immer wieder, nur auf Windows.
      #
      #  autocrlf=false + eol=lf schaltet das fuer KUENFTIGE Auschecks
      #  ab. Bereits vorhandene CRLF-Dateien bleiben aber liegen, weil
      #  Git sie fuer unveraendert haelt -- deshalb EINMALIG erzwingen:
      #  Index leeren ("git rm --cached -r ."), dann erneut "reset
      #  --hard", was jede Datei neu schreibt, diesmal mit LF.
      #
      #  Gesteuert ueber eine MERKDATEI statt ueber eine Abfrage der
      #  Git-Einstellung. [Die naheliegende cmd-Schreibweise dafuer waere
      #  ein "for /f ... in ('git config --get ...')" -- in einer ueber
      #  ssh uebertragenen, mehrfach verschachtelten cmd-Zeile ist das
      #  wegen der %-Zeichen und Anfuehrungszeichen aeusserst fehler-
      #  anfaellig; genau solche Verschachtelungen haben hier schon
      #  mehrfach stillschweigend versagt. "if not exist <datei>" ist
      #  dagegen simpel und robust. Die Merkdatei ueberlebt "git reset
      #  --hard", weil Git unverfolgte Dateien nicht anfasst.]
      # ZWEI GRUPPEN STATT EINER LANGEN &&-KETTE. [In cmd.exe ist ein
      #  "&&" NACH einem "if (...)"-Block unzuverlaessig -- die
      #  Fortsetzung wurde stillschweigend uebersprungen. Im Protokoll
      #  sah man das daran, dass auf Windows ueberhaupt KEINE
      #  Submodul-Zeile auftauchte, weder Erfolg noch Fehler: der Teil
      #  lief schlicht nie. Jetzt: (A) && (B), wobei A der kritische
      #  Teil ist (holen + zuruecksetzen, mit "&&" verkettet, damit ein
      #  Fehlschlag wirklich durchschlaegt) und B die Nacharbeiten
      #  (Zeilenenden, Submodule), deren Schritte mit "&" aneinander
      #  gereiht sind und damit garantiert alle laufen. Der
      #  Rueckgabewert des Ganzen ist der der letzten Anweisung in B --
      #  also der des Submodul-Updates samt Notbremse.]
      local a_kritisch="( if not exist \"$w\\\\.git\" ( if exist \"$w\" ( cd /d \"$w\" && git init -q && ( git remote add origin \"$url\" || git remote set-url origin \"$url\" ) && git fetch --depth 1 origin && git reset --hard FETCH_HEAD ) else ( git clone --depth 1 \"$url\" \"$w\" ) ) else ( cd /d \"$w\" && git fetch --depth 1 origin && git reset --hard FETCH_HEAD ) )"
      # Submodul-Notbremse wie im Bash-Zweig: schlaegt der eingetragene
      # Commit fehl (gibt es auf dem Submodul-Server nicht mehr), wird
      # der aktuelle Branch-Stand geholt, damit external/pdf nicht leer
      # bleibt und CMake nicht abbricht.
      local b_nacharbeit="( cd /d \"$w\" & git config core.autocrlf false & git config core.eol lf & ( if not exist \".xbm-lf.ok\" ( git rm --cached -r -q . & git reset --hard HEAD & echo ok> .xbm-lf.ok ) ) & ( git submodule update --init --recursive --depth 1 || ( echo WARNUNG: Submodul-Verweis zeigt ins Leere -- hole aktuellen Branch-Stand & git submodule update --init --recursive --remote ) ) )"
      befehl="$a_kritisch && $b_nacharbeit"
      ;;
    gitbash|wsl)
      befehl="if [ -d '$p/.git' ]; then cd '$p' && ($mtime_schonend); elif [ -d '$p' ] && [ -n \"\$(ls -A '$p' 2>/dev/null)\" ]; then cd '$p' && ($erstumstellung); else git clone --depth 1 --recurse-submodules --shallow-submodules '$url' '$p'; fi"
      ;;
    *)
      befehl="if [ -d '$p/.git' ]; then cd '$p' && ($mtime_schonend); elif [ -d '$p' ] && [ -n \"\$(ls -A '$p' 2>/dev/null)\" ]; then cd '$p' && ($erstumstellung); else mkdir -p '$p' && git clone --depth 1 --recurse-submodules --shallow-submodules '$url' '$p'; fi"
      ;;
  esac

  log "  git -> $h: $url"
  lauf_notiz "${target}@${h}" sync "git: $url" gestartet
  if (( DRY_RUN )); then
    echo "  [Probelauf] (auf $h) $befehl"; return 0
  fi

  # WAEHREND DES CLONE/PULL SICHTBAR BLEIBEN.
  # [remote() blockiert hier, bis git auf der Gegenseite fertig ist --
  #  bei einem grossen Repo beim ERSTEN Klonen durchaus Minuten. In der
  #  Zwischenzeit rief bisher NICHTS fortschritt()/bau_fortschritt() auf,
  #  also blieb die Statuszeile dieses Auftrags leer bzw. auf dem letzten
  #  Stand stehen -- fuer den Zeichner nicht von einem haengenden oder
  #  nie gestarteten Auftrag zu unterscheiden. Genau das faellt als
  #  "keine Statusausgabe / kein Prozentwert" auf.
  #  Ein kleiner Hintergrund-Herzschlag schreibt hier eine Statuszeile
  #  mit verstrichener Zeit -- kein Prozentwert (den liefert git nicht),
  #  aber ein sichtbares Lebenszeichen statt Stille. Beendet wird er
  #  ueber eine STOP-DATEI, nicht per kill: ein "kill $pid" traf die
  #  Subshell nicht zuverlaessig, wenn disown vorher lief -- ein
  #  Dateitest im laufenden sleep-Zyklus ist unabhaengig davon.]
  local herz_stop="" herz_pid=""
  if [[ -n ${XBM_STATUS_DATEI:-} ]]; then
    herz_stop="${XBM_STATUS_DATEI}.git-stop"
    rm -f "$herz_stop"
    ( local s=0
      while [[ ! -f $herz_stop ]]; do
        fortschritt "$(printf '\r  %-28s sync: git-clone/pull laeuft (%ds)   ' \
                      "${target}@${h}" "$s")"
        sleep 0.3
        [[ -f $herz_stop ]] && break
        sleep 0.3
        [[ -f $herz_stop ]] && break
        sleep 0.4; s=$((s+1))
      done
    ) &
    herz_pid=$!
  fi

  local rc=0
  remote "$h" "$befehl" || rc=1

  if [[ -n $herz_stop ]]; then
    : > "$herz_stop"
    [[ -n $herz_pid ]] && wait "$herz_pid" 2>/dev/null
    rm -f "$herz_stop"
  fi

  if (( rc )); then
    lauf_notiz "${target}@${h}" sync "git: $url" fehlgeschlagen
    err "  git clone/pull auf '$h' fehlgeschlagen -- $url erreichbar?"
    return 1
  fi
  mkdir -p "$SYNC_DIR"
  : > "$marke"
  fortschritt "$(printf '\r  %-28s sync: git fertig   ' "${target}@${h}")"
  lauf_notiz "${target}@${h}" sync "git: $url" ok
  log "  git: '$h' ist auf dem neuesten Stand von $url"
  return 0
}

remote_mkdir() {
  local h=$1 p=$2
  if [[ ${HOST_OS[$h]:-posix} == wsl ]]; then
    # Ohne Anfuehrungszeichen -- cmd wuerde sie mitschicken.
    remote "$h" "mkdir -p $p"
  elif [[ ${HOST_OS[$h]:-posix} == cmd ]]; then
    local w; w=$(winpfad "$p")
    # Ohne Leerzeichen im Pfad OHNE Anfuehrungszeichen -- die inneren
    # sind es, an denen cmd.exe /c scheitert.
    if [[ $w == *" "* ]]; then
      warn "  Pfad enthaelt Leerzeichen: $w"
      warn "  cmd.exe kommt damit ueber ssh schlecht zurecht. Besser einen"
      warn "  Pfad ohne Leerzeichen waehlen (z.B. C:/xbm)."
      remote "$h" "if not exist \"$w\" mkdir \"$w\""
    else
      remote "$h" "if not exist $w mkdir $w"
    fi
  else
    remote "$h" "mkdir -p '$p'"
  fi
}

declare -A RSYNC_BEKANNT DIR_ANGELEGT
remote_has() {                   # gibt es das Programm auf dem Ziel?
  # ANTWORT MERKEN. [Die Frage "gibt es rsync" wird je Lauf mehrfach
  #  gestellt -- einmal beim Hinschieben, einmal beim Zurueckholen. Die
  #  Antwort aendert sich waehrend eines Laufs nicht.]
  if [[ $2 == rsync && -n ${RSYNC_BEKANNT[$1]:-} ]]; then
    [[ ${RSYNC_BEKANNT[$1]} == ja ]]; return
  fi
  if (( DRY_RUN )); then return 1; fi   # im Probelauf den Rueckfall zeigen
  # [rsync wird von der ANMELDE-Shell gestartet -- fuer diese eine Frage
  #  ist "where" in cmd also richtig, nicht die Login-bash.]
  local rc=0
  if [[ ${HOST_OS[$1]:-posix} == wsl ]]; then
    remote "$1" "command -v $2" >/dev/null 2>&1 || rc=1
  elif [[ ${HOST_OS[$1]:-posix} == cmd ]]; then
    remote "$1" "where $2" >/dev/null 2>&1 || rc=1
  else
    remote "$1" "command -v $2 || command -v $2.exe" >/dev/null 2>&1 || rc=1
  fi
  [[ $2 == rsync ]] && { (( rc == 0 )) && RSYNC_BEKANNT[$1]=ja || RSYNC_BEKANNT[$1]=nein; }
  return $rc
}

# ---------------------------------------------------------------------------
# Uebertragung
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# WAS NICHT UEBERTRAGEN WIRD
#
# Feste Listen veralten. Deshalb werden Bauordner ERKANNT: ein Ordner mit
# CMakeCache.txt oder build.ninja darin ist einer -- unabhaengig davon,
# wie er heisst. Damit fallen builds/, linux/, windows/, android/ und
# jeder kuenftige von selbst weg, ohne dass jemand eine Liste pflegt.
#
# Dazu kommen Muster fuer Erzeugnisse, die auch ausserhalb solcher Ordner
# liegen koennen (*.o neben der Quelle etwa), und eine eigene Liste in
# config/exclude.conf -- eine Zeile je Muster, # fuer Kommentare.
# ---------------------------------------------------------------------------
XFER_MUSTER=(
  '*.o' '*.a' '*.so' '*.so.*' '*.dll' '*.dylib' '*.exe' '*.obj' '*.lib'
  '*.apk' '*.aab' '*.dex' '*.class' '*.jar'
  '*.gch' '*.pch' '*.ilk' '*.pdb' '*.idb'
  '*.d' '*.tmp' '*.log' '*.stamp'
  'core' 'core.*'
)
XFER_ORDNER=(
  '.git' '.svn' '.hg' '.cache' '.ccache' '.idea' '.vscode'
  'CMakeFiles' '_deps' 'node_modules' '.deps-cache' '.xbm-sync'
  'builds' '.status'
)

# Alle Bauordner einsammeln -- an CMakeCache.txt / build.ninja erkannt.
xfer_bauordner() {
  find . -maxdepth 4 \( -name CMakeCache.txt -o -name build.ninja \
                       -o -name .ninja_deps \) -printf '%h\n' 2>/dev/null \
    | sed 's|^\./||' | sort -u
}

# Zeigt, WO das Uebertragungsvolumen steckt.
# [Bauordner auszuschliessen hilft nur, wenn sie das Problem sind. Bei
#  20.000 Dateien lohnt es, erst nachzusehen, statt weiter zu raten --
#  meist sind es Fremdquellen unter external/, und da hilft ein ganz
#  anderer Hebel als eine laengere Ausschlussliste.]
xfer_bericht() {
  local liste=$1 n
  n=$(wc -l < "$liste")
  log "  Umfang der Uebertragung: $n Dateien"
  log "  groesste Anteile:"
  # Je Datei den obersten Ordner bestimmen und aufsummieren.
  # Nach ORDNER gruppieren (hoechstens zwei Ebenen), nicht nach Datei.
  # [Ein erster Versuch nahm die ersten zwei Pfadteile -- bei ./src/m9.cpp
  #  ist der zweite aber schon der Dateiname, und die Liste bestand aus
  #  Einzeldateien statt aus Ordnern.]
  awk -F/ '{
      if (NF <= 2) { print "."; next }          # ./datei
      if (NF == 3) { print $2; next }           # ./ordner/datei
      print $2"/"$3                             # ./ordner/unter/...
    }' "$liste" \
    | sort | uniq -c | sort -rn | head -12 \
    | while read -r anzahl ordner; do
        local gr
        gr=$(grep -F "/$ordner/" "$liste" 2>/dev/null | tr '\n' '\0' \
             | du -ch --files0-from=- 2>/dev/null | tail -1 | cut -f1)
        printf '    %7d Dateien  %8s  %s\n' "$anzahl" "${gr:-?}" "$ordner"
      done
}

# Baut den find-Ausdruck fuer die Dateiliste.
xfer_find() {                    # xfer_find [<marke fuer -newer>]
  local marke=${1:-}
  local -a args=(.)
  local d m

  # Ordner ganz abschneiden (-prune) statt jede Datei darin zu pruefen --
  # das spart bei grossen Baeumen spuerbar Zeit.
  args+=('(')
  local erste=1
  for d in "${XFER_ORDNER[@]}"; do
    (( erste )) || args+=(-o); erste=0
    args+=(-name "$d")
  done
  while IFS= read -r d; do
    [[ -z $d || $d == "." ]] && continue
    (( erste )) || args+=(-o); erste=0
    args+=(-path "./$d")
  done < <(xfer_bauordner)
  # config/exclude.conf wird NACHTRAEGLICH angewandt (xfer_filter) --
  # nicht hier. [Nur so lassen sich AUSNAHMEN ausdruecken: "alles unter
  #  external/, aber pdf und miniaudio behalten". In einem find-Ausdruck
  #  waere das kaum lesbar; als Nachfilter sind es drei Zeilen.]
  args+=(')' -prune -o)

  args+=(-type f)
  [[ -n $marke ]] && args+=(-newer "$marke")
  for m in "${XFER_MUSTER[@]}"; do args+=(! -name "$m"); done
  args+=(-print)
  # Die Ausnahme-Ordner ZUSAETZLICH anbieten -- der Filter entscheidet
  # dann in einem Durchlauf, was davon bleibt.
  { find "${args[@]}" 2>/dev/null; xfer_ausnahmen; } | xfer_filter
}

# Wendet config/exclude.conf an. Regeln in der Reihenfolge der Datei,
# die LETZTE passende gewinnt -- damit kann eine Ausnahme eine vorherige
# Ausschlussregel aufheben.
#
#   external/          alles darunter weg
#   !external/pdf/     ... aber das hier doch behalten
#   *.md               Dateien nach Muster
#
# [Ohne Ausnahmen muesste man jeden unerwuenschten Unterordner einzeln
#  auflisten und die Liste bei jeder neuen Abhaengigkeit nachpflegen.
#  Mit Ausnahme schreibt man einmal, was man BEHALTEN will -- und das
#  aendert sich fast nie.]
# Wie xfer_find, aber OHNE den Nachfilter aus exclude.conf.
# [Er ruft ja gerade uns auf -- ihn erneut aufzurufen waere eine
#  Endlosschleife. Die EINGEBAUTEN Regeln (.git, CMakeFiles, *.o,
#  erkannte Bauordner) gelten trotzdem, und genau darum geht es hier.]
xfer_roh() {                     # xfer_roh <startordner>
  local ziel=${1:-.}
  local -a args=("$ziel")
  local d m erste=1
  # DIESELBE ZEITMARKE WIE DER HAUPTLAUF.
  # [Ohne sie lieferte diese Funktion bei JEDEM Lauf alle Dateien der
  #  Ausnahme-Ordner. Bei !external/hello_imgui/ und den drei anderen
  #  waren das jedes Mal rund 15000 Dateien -- auch wenn sich nichts
  #  geaendert hatte. Genau das hast du beobachtet.]
  local marke=${XBM_XFER_MARKE:-}
  args+=('(')
  for d in "${XFER_ORDNER[@]}"; do
    (( erste )) || args+=(-o); erste=0
    args+=(-name "$d")
  done
  while IFS= read -r d; do
    [[ -z $d || $d == "." ]] && continue
    (( erste )) || args+=(-o); erste=0
    args+=(-path "./$d")
  done < <(xfer_bauordner)
  args+=(')' -prune -o -type f)
  for m in "${XFER_MUSTER[@]}"; do args+=(! -name "$m"); done
  [[ -n $marke && -f $marke ]] && args+=(-newer "$marke")
  args+=(-print)
  find "${args[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# DER FILTER -- EIN DURCHLAUF, KEINE ZWISCHENDATEIEN
#
# [Vorher lief das ueber Hilfsdateien und mv. Auf einem vollen
#  Datentraeger schlug das mv fehl:
#      mv: cannot move 'builds/.tmp/xbm.XXXX.n' ... No space left
#  und die Dateiliste war danach unvollstaendig -- OHNE dass das Skript
#  es gemerkt haette. Eine stille Fehlfunktion ist schlimmer als ein
#  Abbruch.
#
#  awk erledigt dasselbe in einem Durchlauf im Speicher: erst die Regeln
#  lesen, dann jeden Pfad dagegen pruefen. Die LETZTE passende Regel
#  gewinnt -- damit gilt die Reihenfolge weiterhin, und es wird nichts
#  mehr geschrieben.]
# ---------------------------------------------------------------------------
xfer_filter() {
  [[ -f config/exclude.conf ]] || { cat; return; }
  awk '
    # --- Glob in einen regulaeren Ausdruck wandeln ---
    function esc(c) {
      # PORTABLE ZEICHENKLASSE.
      # [Vorher stand {} MIT in der Regex-Zeichenklasse:
      #      /[.[\]()+^$?{}|\\]/
      #  gawk akzeptiert das; busybox-awk (Android/Termux) und manche
      #  mawk-Bauten lesen "{}" darin als Wiederholungsoperator und
      #  brechen mit "bad regex ... Invalid contents of {}" ab -- der
      #  Filter lieferte dann 0 Dateien, die Uebertragung schlug fehl.
      #  index() braucht keine Zeichenklasse und ist ueberall gleich.]
      if (index(".[]()+^$?{}|\\", c) > 0) return "\\" c
      return c
    }
    function glob2re(m,   i, c, out) {
      out = ""
      for (i = 1; i <= length(m); i++) {
        c = substr(m, i, 1)
        if      (c == "*") out = out "[^/]*"
        else if (c == "?") out = out "[^/]"
        else               out = out esc(c)
      }
      return out
    }
    function regel2re(m,   ordner, re) {
      ordner = 0
      if (substr(m, length(m), 1) == "/") { ordner = 1; m = substr(m, 1, length(m)-1) }
      re = glob2re(m)
      if (index(m, "/") > 0) {
        # Pfad ab der Projektwurzel
        if (ordner) return "^\\./" re "/"
        else        return "^\\./" re "(/|$)"
      } else {
        # Name, ueberall im Baum
        if (ordner) return "(^\\./|/)" re "/"
        else        return "(^\\./|/)" re "$"
      }
    }
    # --- Regeln einlesen ---
    NR == FNR {
      z = $0
      sub(/^[ \t]+/, "", z); sub(/[ \t]+$/, "", z)
      if (z == "" || substr(z, 1, 1) == "#") next
      n++
      if (substr(z, 1, 1) == "!") { neg[n] = 1; z = substr(z, 2) } else neg[n] = 0
      re[n] = regel2re(z)
      next
    }
    # --- Pfade pruefen ---
    {
      if ($0 in gesehen) next
      gesehen[$0] = 1
      behalten = 1
      for (i = 1; i <= n; i++)
        if ($0 ~ re[i]) behalten = neg[i] ? 1 : 0
      if (behalten) print
    }
  ' config/exclude.conf -
}

# Liefert die Ordner, die durch eine !-Regel wieder hereingeholt werden
# sollen. [Sie muessen zusaetzlich durchsucht werden: in einen
#  ausgeschlossenen Ordner sieht xfer_find gar nicht erst hinein.]
xfer_ausnahmen() {
  [[ -f config/exclude.conf ]] || return 0
  local z m t
  while IFS= read -r z || [[ -n ${z:-} ]]; do
    z=$(trim "${z:-}")
    [[ -z $z || $z == \#* ]] && continue
    [[ $z == '!'* ]] || continue
    m=${z#!}
    if [[ $m == */ ]]; then
      [[ -d ${m%/} ]] && xfer_roh "./${m%/}"
    else
      for t in $m; do
        [[ -f $t ]] && printf './%s\n' "${t#./}"
        [[ -d $t ]] && xfer_roh "./${t#./}"
      done
    fi
  done < config/exclude.conf
}

EXCLUDES=(--exclude '.git/' --exclude 'builds/' --exclude 'build-*/'
          --exclude '*.o' --exclude '*.a' --exclude 'CMakeCache.txt'
          --exclude 'CMakeFiles/' --exclude '.deps-cache/')

push_project() {
  local h=$1
  local path=${HOST_PATH[$h]}   # getrennt -- siehe rsh_string

  # GIT STATT TAR/RSYNC.
  # [Sechstes Feld war "xfer" (rsync/tar); das SIEBTE ist jetzt eine
  #  Git-URL. Ist sie gesetzt (oder --git/--force-git auf der
  #  Befehlszeile), wird nicht mehr uebertragen -- die Gegenseite holt
  #  sich den Stand selbst per "git clone" (erster Lauf) bzw.
  #  "git pull" (jeder weitere). Das ist schneller als tar bei grossen,
  #  kaum geaenderten Baeumen, und es funktioniert unabhaengig von ssh,
  #  wenn das Repo per HTTP erreichbar ist (dein Fall: gitea auf
  #  192.168.1.69).
  #  --no-git schaltet auf ssh zurueck, selbst wenn hosts.conf eine URL
  #  eintraegt -- fuer den Fall, dass das Netz zum Git-Server gerade
  #  nicht steht, das zum Zielrechner aber schon.]
  local git_url=${FORCE_GIT_URL:-${HOST_GIT[$h]:-}}
  if (( NO_GIT )); then git_url=""; fi
  # DIAGNOSE, UNMISSVERSTAENDLICH. [Nach zwei vorigen Korrekturen, die
  #  das Problem noch nicht behoben haben, hier ALLE Grundlagen der
  #  Entscheidung auf einen Blick -- damit sich beim naechsten Lauf aus
  #  dem Log ablesen laesst, ob HOST_GIT[$h] tatsaechlich leer ankommt
  #  (dann liegt es weiter am Einlesen) oder ob es gesetzt ist und
  #  trotzdem nicht gezogen wird (dann liegt es an dieser Stelle oder
  #  danach).]
  # log "  [Git-Diagnose] Host='$h'  FORCE_GIT_URL='${FORCE_GIT_URL:-}'  HOST_GIT[\$h]='${HOST_GIT[$h]:-}'  NO_GIT=$NO_GIT  FORCE_GIT=$FORCE_GIT  -> git_url='$git_url'"
  if (( FORCE_GIT )) && [[ -z $git_url ]]; then
    # --force-git verlangt Git ausdruecklich, aber es gibt weder eine
    # URL in hosts.conf noch --git auf der Befehlszeile. Ein stiller
    # Rueckfall auf ssh waere hier das Gegenteil von "erzwungen".
    err "  --force-git gesetzt, aber '$h' hat keine Git-URL"
    err "  (weder in config/hosts.conf Feld 7 noch per --git <url>)."
    return 1
  fi
  if [[ -n $git_url ]]; then
    git_pull_host "$h" "$path" "$git_url"
    return $?
  fi

  # Ordner nur beim ERSTEN Mal anlegen.
  # [tar -C verlangt ein vorhandenes Verzeichnis, aber einmal je Lauf
  #  genuegt -- danach ist es da.]
  # ORDNER NUR EINMAL ANLEGEN -- ueber Laeufe hinweg.
  # [Gemessen: 0,68 s fuer ein mkdir, das seit dem ersten Lauf nichts
  #  mehr tut. Existiert die Zeitmarke, war schon einmal erfolgreich
  #  uebertragen -- dann gibt es den Ordner.]
  if [[ -z ${DIR_ANGELEGT[$h]:-} ]]; then
    if [[ -f "$SYNC_DIR/${h}.stamp" ]]; then
      DIR_ANGELEGT[$h]=ja           # war schon da
    else
      remote_mkdir "$h" "$path"
      DIR_ANGELEGT[$h]=ja
    fi
  fi

  # WELCHER WEG?
  # [Auf Windows scheitert rsync auch dann, wenn Git Bash es mitbringt:
  #  das lokale rsync startet auf der Gegenseite  rsync --server , und
  #  dafuer benutzt sshd die ANMELDE-Shell -- das ist cmd.exe, und die
  #  findet rsync nicht. Genau die Meldung steht in deinem Log:
  #     Der Befehl "rsync" ist ... nicht gefunden
  #  Meine Pruefung "command -v rsync" lief dagegen durch bash -lc und
  #  sagte faelschlich "vorhanden". Deshalb wird auf Windows gar nicht
  #  erst gefragt, sondern tar benutzt.
  #  Wer rsync dort doch eingerichtet hat, setzt in hosts.conf ein
  #  sechstes Feld auf "rsync".]
  local weg=${HOST_XFER[$h]:-}
  if [[ -z $weg ]]; then
    # NICHT ERST FRAGEN, wo die Antwort feststeht.
    # [Auf cmd, gitbash und wsl scheitert rsync ohnehin -- das haben wir
    #  frueher schon festgestellt. Die Frage kostete einen Umlauf und
    #  konnte nur "nein" ergeben.]
    case ${HOST_OS[$h]:-posix} in
      cmd|gitbash|wsl|windows) weg=tar ;;
      *) remote_has "$h" rsync && weg=rsync || weg=tar ;;
    esac
  fi

  if [[ $weg == rsync ]]; then
    log "  Uebertragung mit rsync"
    lauf_notiz "${target}@${h}" sync rsync gestartet
    if (( DRY_RUN )); then
      printf '  [Probelauf] rsync -az -e %q ./ %q\n' "$(rsh_string "$h")" \
             "${HOST_SSH[$h]}:$path/"
      return 0
    fi
    # WAS WURDE UEBERTRAGEN? -- der tar-Weg sagt es, der rsync-Weg
    # schwieg. [In deinem Log stand nur "Uebertragung mit rsync". Ob
    #  ueberhaupt etwas hinueberging, war nicht zu sehen -- und genau
    #  das ist die Frage, wenn der Bau danach "no work to do" meldet.]
    local rlog; rlog=$(xtmp) || return 1
    # HERZSCHLAG WAEHREND RSYNC LAEUFT -- bisher stumm, blockierend, ohne
    # jede Statuszeile. [Dasselbe Muster wie beim Git-Weg oben: rsync
    #  meldet erst nach seinem Ende etwas, und bei einer laengeren
    #  Uebertragung sah der Zeichner in der Zwischenzeit keinen
    #  Unterschied zwischen "laeuft noch" und "haengt".]
    local rsync_stop="" rsync_pid=""
    if [[ -n ${XBM_STATUS_DATEI:-} ]]; then
      rsync_stop="${XBM_STATUS_DATEI}.rsync-stop"
      rm -f "$rsync_stop"
      ( local s=0
        while [[ ! -f $rsync_stop ]]; do
          fortschritt "$(printf '\r  %-28s sync: rsync laeuft (%ds)   ' \
                        "${target}@${h}" "$s")"
          sleep 0.3
          [[ -f $rsync_stop ]] && break
          sleep 0.3
          [[ -f $rsync_stop ]] && break
          sleep 0.4; s=$((s+1))
        done
      ) &
      rsync_pid=$!
    fi
    if rsync -az --out-format='%n' "${EXCLUDES[@]}" \
             -e "$(rsh_string "$h")" ./ "${HOST_SSH[$h]}:${path}/" > "$rlog" 2>&1
    then
      if [[ -n $rsync_stop ]]; then
        : > "$rsync_stop"
        [[ -n $rsync_pid ]] && wait "$rsync_pid" 2>/dev/null
        rm -f "$rsync_stop"
      fi
      fortschritt "$(printf '\r  %-28s sync: rsync fertig   ' "${target}@${h}")"
      lauf_notiz "${target}@${h}" sync rsync ok
      # [grep -c gibt bei NULL Treffern den Rueckgabewert 1 -- mit
      #  "|| echo 0" stand dann "0\n0" in der Variablen und die
      #  Rechnung darunter brach ab. Ohne || ist die Ausgabe immer eine
      #  Zahl, auch die Null.]
      local n; n=$(grep -cv '/$' "$rlog" 2>/dev/null); n=${n:-0}
      if (( n == 0 )); then
        log "  nichts geaendert -- keine Datei uebertragen"
      else
        log "  $n Datei(en) uebertragen:"
        grep -v '/$' "$rlog" | head -12 | sed 's/^/    /'
        (( n > 12 )) && log "    ... und $(( n - 12 )) weitere"
      fi
      rm -f "$rlog"
    else
      if [[ -n $rsync_stop ]]; then
        : > "$rsync_stop"
        [[ -n $rsync_pid ]] && wait "$rsync_pid" 2>/dev/null
        rm -f "$rsync_stop"
      fi
      err "  rsync fehlgeschlagen:"
      lauf_notiz "${target}@${h}" sync rsync fehlgeschlagen
      tail -5 "$rlog" | sed 's/^/    /' >&2
      rm -f "$rlog"
      return 1
    fi
  else
    # UEBER tar, aber NUR DAS GEAENDERTE.
    # [tar kennt keinen Abgleich -- es packt, was man ihm nennt. Bisher
    #  war das der ganze Baum, bei jedem Lauf: mit vollstaendigem
    #  external/ (hello_imgui, glfw, curl, mbedTLS, whisper, ggml) sind
    #  das schnell mehrere hundert MB, obwohl sich drei Dateien geaendert
    #  haben. Genau diesen Abgleich macht rsync von Haus aus; ohne rsync
    #  muss man ihn selbst nachbilden.
    #
    #  Der Ansatz: eine Zeitmarke je Host. Uebertragen wird, was NEUER
    #  ist als die letzte gelungene Uebertragung. Die Marke wird erst
    #  danach gesetzt -- bricht etwas ab, wird beim naechsten Mal wieder
    #  alles Noetige geschickt.]
    log "  Uebertragung mit tar (kein rsync auf '$h')"
    lauf_notiz "${target}@${h}" sync tar gestartet
    mkdir -p "$SYNC_DIR"
    local marke="$SYNC_DIR/${h}.stamp"
    local liste; liste=$(xtmp) || return 1
    local voll=0
    [[ ! -f $marke ]] && voll=1
    (( FULL_SYNC )) && voll=1

    if (( XBM_NUR_STEUERDATEIEN )); then
      log "  nur Steuerdateien (Ausfuehrung, kein Bau)"
      local sd
      for sd in build.sh config hooks cmds; do
        [[ -e $sd ]] || continue
        find "./$sd" -type f ! -name '*.log' 2>/dev/null
      done > "$liste"
      [[ -f $XBM_EXEC_DATEI ]] && printf '%s\n' "./${XBM_EXEC_DATEI#./}" >> "$liste"
      [[ -f ".xbm-run-${XBM_LAUF_ID}.sh" ]] && \
        printf '%s\n' "./.xbm-run-${XBM_LAUF_ID}.sh" >> "$liste"
      sort -u -o "$liste" "$liste"
    elif (( voll )); then
      log "  vollstaendige Uebertragung (erste oder erzwungen)"
      XBM_XFER_MARKE="" xfer_find > "$liste"
    else
      XBM_XFER_MARKE=$marke xfer_find "$marke" > "$liste"
      # STEUERDATEIEN IMMER MITSCHICKEN -- nie ueber die Zeitmarke
      # auslassen. [build.sh, config/ und hooks/ bestimmen, was drueben
      # passiert. Sind sie dort veraltet, laeuft der Bau nach alten
      # Regeln oder bricht mit einer Meldung ab, die nichts mit der
      # Ursache zu tun hat. Es sind wenige Kilobyte.]
      local st
      for st in build.sh config hooks; do
        [[ -e $st ]] || continue
        # MIT ./ davor -- genau wie xfer_find es liefert.
        # [Ohne das schrieb find hier "build.sh", xfer_find aber
        #  "./build.sh". Fuer sort -u sind das ZWEI verschiedene
        #  Zeichenketten, also blieben beide stehen. tar speichert das
        #  zweite Vorkommen derselben Datei als HARTE VERKNUEPFUNG --
        #  und -U (loeschen vor dem Entpacken) raeumt das Ziel vorher
        #  weg. Ergebnis:
        #      build.sh: Hard-link target './build.sh' does not exist.
        #  Genau die Zeile aus deinem Log. Und weil es immer build.sh
        #  traf, sah es nach einem Windows-Problem aus.]
        find "./$st" -type f 2>/dev/null
      done >> "$liste"
      # Doppelte entfernen -- jetzt greift es, weil beide Seiten
      # dieselbe Schreibweise benutzen.
      sort -u -o "$liste" "$liste"
      local n; n=$(wc -l < "$liste")
      if (( n == 0 )); then
        log "  nichts geaendert -- keine Uebertragung noetig"
        rm -f "$liste"
        return 0
      fi
      log "  $n geaenderte Datei(en)"
    fi

    if (( SYNC_REPORT )); then
      xfer_bericht "$liste"
      rm -f "$liste"; return 0
    fi
    if (( DRY_RUN )); then
      printf '  [Probelauf] tar -czf - -T liste | ssh ... tar -xzf - (%s Dateien)\n' \
             "$(wc -l < "$liste")"
      rm -f "$liste"; return 0
    fi

    # UMFANG NENNEN, BEVOR es losgeht.
    # [Ohne diese Zeile sieht man nur einen stehenden Cursor und weiss
    #  nicht, ob 20 Dateien oder 20.000 unterwegs sind. Genau das war die
    #  Verwirrung: die Zwischendatei mit der DATEILISTE war 1,1 MB gross
    #  -- das sind rund 20.000 Pfade, nicht 1,1 MB Nutzdaten.]
    local anz roh
    anz=$(wc -l < "$liste")
    roh=$(tr '\n' '\0' < "$liste" | du -ch --files0-from=- 2>/dev/null \
          | tail -1 | cut -f1)
    log "  $anz Dateien, ${roh:-?} unkomprimiert -- Uebertragung laeuft"

    if [[ ${HOST_OS[$h]:-posix} == wsl ]]; then
      build_remote_argv "$h" "tar -xzUf - -C $path"
    elif [[ ${HOST_OS[$h]:-posix} == cmd ]]; then
      # OHNE cd und &&: tar kann das Zielverzeichnis selbst waehlen.
      # [cmd.exe /c "..." entfernt das erste und letzte
      #  Anfuehrungszeichen der Zeile und laesst die inneren stehen.
      #  Eine Zeile wie  cd /d "C:\pfad" && tar ...  wird dadurch
      #  zerlegt -- mit Rueckgabewert 0, also unbemerkt. Ein einzelner
      #  Befehl ohne innere Anfuehrungszeichen hat das Problem nicht.]
      # -U loescht jede Datei, BEVOR sie neu angelegt wird.
      # [Windows laesst eine Datei nicht ueberschreiben, wenn sie
      #  schreibgeschuetzt ist oder von einem anderen Vorgang offen
      #  gehalten wird -- dann meldet bsdtar
      #     Can't create \\?\C:\...\build.sh
      #  Loeschen und neu anlegen umgeht beides, solange die Datei nicht
      #  gerade AUSGEFUEHRT wird.]
      build_remote_argv "$h" "tar -xzUf - -C $(winpfad "$path")"
    else
      build_remote_argv "$h" "cd '$path' && tar -xzUf -"
    fi
    # Schwache Verdichtung: ueber LAN ist die CPU der Engpass, nicht die
    # Leitung. Stufe 1 packt Quelltext fast so gut wie Stufe 6, aber um
    # ein Vielfaches schneller.
    #
    # FORTSCHRITT: tar nennt mit -v jede Datei auf stderr; die werden
    # gezaehlt und als Zeile ausgegeben. [Sonst laesst sich "langsam"
    # nicht von "haengt" unterscheiden -- und genau das war die Frage.]
    # Merker fuer die Nachkontrolle -- eine Datei, die es drueben danach
    # geben MUSS.
    # build.sh AUSDRUECKLICH pruefen -- es ist die Datei, von der alles
    # abhaengt. [Vorher wurde die erste beliebige Datei der Liste
    #  geprueft. Die kam an, build.sh aber nicht -- und die Kontrolle
    #  meldete Erfolg.]
    local pruefdatei=build.sh
    grep -qx './build.sh' "$liste" || pruefdatei=$(head -1 "$liste")
    pruefdatei=${pruefdatei#./}

    # FORTSCHRITT NUR AUF DEN BILDSCHIRM.
    # [Vorher ging er nach stderr und damit ins Log -- dort stand
    #  anschliessend eine einzige, endlos lange Zeile mit allen
    #  Zwischenstaenden. Ins Log gehoert eine Zeile, nicht fuenfzig.]
    # Meldungen der GEGENSEITE (tar drueben) mitschneiden -- nur so laesst
    # sich "Could not unlink" hinterher benennen.
    local xferlog; xferlog=$(xtmp) || return 1
    if GZIP=-1 tar -czvf - -T "$liste" 2> >(
         i=0
         while IFS= read -r _; do
           i=$((i+1))
           (( i > anz )) && i=$anz
           (( i % 200 == 0 )) && \
             fortschritt "$(printf '\r  %-28s sync: tar %d/%d   ' "${target}@${h}" "$i" "$anz")"
         done
         fortschritt "$(printf '\r%*s\r' 40 '')"
       ) | "${SSH_ARGV[@]}" 2> >(tee "$xferlog" >&2); then
      log "  uebertragen: $anz/$anz"
      # NACHSEHEN, ob wirklich etwas ankam.
      # [ssh gibt 0 zurueck, wenn die Fernzeile 0 zurueckgab -- das sagt
      #  nichts darueber, ob tar auch entpackt hat. Genau so blieb eine
      #  fehlgeschlagene Uebertragung unbemerkt: gemeldet wurde Erfolg,
      #  auf der Platte lag nichts.]
      # Bei --exec ist build.sh drueben nicht das Entscheidende -- die
      # Ausfuehrung selbst meldet ohnehin, wenn etwas fehlt.
      if [[ -n $pruefdatei ]] && (( ! EXEC_MODE )); then
        local dapruef
        if [[ ${HOST_OS[$h]:-posix} == wsl ]]; then
          # Ohne Anfuehrungszeichen und ohne && -- beides ueberlebt den
          # Weg durch cmd.exe nicht.
          dapruef="test -f $path/$pruefdatei"
        elif [[ ${HOST_OS[$h]:-posix} == cmd ]]; then
          dapruef="if exist $(winpfad "$path/$pruefdatei") echo DA"
        else
          dapruef="test -f '$path/$pruefdatei' && echo DA"
        fi
        local gefunden=0
        if [[ ${HOST_OS[$h]:-posix} == wsl ]]; then
          remote "$h" "$dapruef" >/dev/null 2>&1 && gefunden=1
        else
          remote "$h" "$dapruef" 2>/dev/null | grep -q DA && gefunden=1
        fi
        if (( ! gefunden )); then
          lauf_notiz "${target}@${h}" sync tar "Pruefdatei fehlt drueben" fehlgeschlagen
          err "  Uebertragung meldete Erfolg, aber '$pruefdatei' ist"
          err "  drueben nicht auffindbar. Ziel: $path"
          err "  Pruef von Hand:"
          if [[ ${HOST_OS[$h]:-posix} == wsl ]]; then
            err "      ssh ${HOST_SSH[$h]} \"wsl.exe ls -la $path\""
          elif [[ ${HOST_OS[$h]:-posix} == cmd ]]; then
            err "      ssh ${HOST_SSH[$h]} \"dir $(winpfad "$path")\""
          else
            err "      ssh ${HOST_SSH[$h]} \"ls -la '$path'\""
          fi
          rm -f "$liste"
          return 1
        fi
      fi
      touch "$marke"          # erst NACH Erfolg UND Nachkontrolle
      lauf_notiz "${target}@${h}" sync tar ok
      rm -f "$liste" "$xferlog"
    else
      rm -f "$liste"
      lauf_notiz "${target}@${h}" sync tar fehlgeschlagen
      err "  Uebertragung fehlgeschlagen"
      if [[ ${HOST_OS[$h]:-posix} == cmd || ${HOST_OS[$h]:-posix} == gitbash ]]; then
        # LAUFENDE DATEI AUF DER GEGENSEITE?
        # [Aus dem Log: "./builds/exe/x_bookmark_manager.exe: Could not
        #  unlink". Windows kann eine laufende exe nicht ersetzen. Sie war nur
        #  unterwegs, weil eine Ausnahme in exclude.conf sie mitnahm -- dabei
        #  wird sie DORT gebaut und muss nie hin.]
        if grep -q "Could not unlink" "$xferlog" 2>/dev/null; then
          err "  Windows kann eine LAUFENDE Datei nicht ersetzen:"
          grep "Could not unlink" "$xferlog" | head -3 | sed 's/^/      /' >&2
          err "  Entweder die App drueben schliessen -- oder die Ausnahme in"
          err "  config/exclude.conf auf Ergebnisse beschraenken, die die"
          err "  Gegenseite NICHT selbst baut (apk, deb -- nicht die exe)."
        fi
        rm -f "$xferlog"
        err "  Meldet tar \"Can't create ...\", laesst Windows die Datei"
        err "  nicht ersetzen. Haeufige Gruende:"
        err "    * der Ordner liegt unter Desktop/Dokumente und wird von"
        err "      OneDrive synchronisiert -- das sperrt Dateien zeitweise."
        err "      Abhilfe: einen Pfad ausserhalb waehlen, etwa C:/xbm"
        err "    * eine alte bash-Sitzung haelt build.sh noch offen:"
        err "      ssh ${HOST_SSH[$h]} \"taskkill /IM bash.exe /F\""
        err "    * Schreibschutz gesetzt:"
        err "      ssh ${HOST_SSH[$h]} \"attrib -R $(winpfad "$path")\\*.* /S\""
        err "    * ein Virenwaechter prueft .sh-Dateien"
      fi
      return 1
    fi
    return 0
    local tarexc=()
    for e in .git builds build-android build-linux CMakeFiles .deps-cache; do
      tarexc+=(--exclude="$e")
    done
    if (( DRY_RUN )); then
      printf '  [Probelauf] tar c ... | ssh ... tar x -C %q\n' "$path"
      return 0
    fi
  fi
}

# Was soll nach dem Bau zurueckgeholt werden?
# [Bisher wurde der GANZE Ordner builds/<ziel> geholt. Bei apk sind das
#  Zwischenstaende, Objektdateien und ein paar hundert MB -- gebraucht
#  wird eine Datei. Deshalb je Ziel eine Liste in config/targets.conf:
#
#      DOWNLOAD[apk]='builds/apk/x_bookmark_manager.apk'
#      DOWNLOAD[exe]='builds/exe/*.exe builds/exe/*.dll'
#      DOWNLOAD[deb]='builds/deb/x_bookmark_manager, data/erzeugt/'
#
#  Pfade sind RELATIV ZUR PROJEKTWURZEL auf der Gegenseite und landen
#  hier an derselben Stelle -- so muss man nicht zweimal nachdenken.
#  Trennen mit Leerzeichen, Kommas oder Zeilenumbruechen; Ordner mit
#  oder ohne / am Ende; * und ? sind erlaubt.]
download_muster() {              # download_muster <ziel>
  local t=$1
  local roh=${DOWNLOAD[$t]-}     # getrennt -- siehe rsh_string
  [[ -z $roh ]] && return 1
  printf '%s' "$roh" | tr ',\n\t' '   '
}

pull_artifacts() {
  local h=$1 target=$2
  local path=${HOST_PATH[$h]}   # getrennt -- siehe rsh_string
  local muster
  if muster=$(download_muster "$target"); then
    # --- gezielt einzelne Dateien und Ordner ---------------------------
    (( DRY_RUN )) && { log "  [Probelauf] holen: $muster"; return 0; }
    log "  hole zurueck: $muster"

    # Das Packen laeuft auf der Gegenseite in einer SHELL, damit * und ?
    # dort aufgeloest werden. Der Auftrag reist base64-verpackt -- so
    # gibt es nichts zu zitieren, egal ob cmd.exe, WSL oder Git Bash den
    # Empfang macht.
    local skript
    skript="cd '$path' || exit 1"$'\n'
    skript+="fehlt=\"\""$'\n'
    skript+="for m in $muster; do"$'\n'
    skript+="  set -- \$m"$'\n'
    skript+="  [ -e \"\$1\" ] || fehlt=\"\$fehlt \$m\""$'\n'
    skript+="done"$'\n'
    # Fehlende NENNEN statt still weglassen.
    # [Sonst sucht man hinterher, warum die Datei nicht da ist -- und
    #  die Antwort waere gewesen: sie war drueben auch nicht da.]
    skript+="[ -n \"\$fehlt\" ] && echo \"nicht gefunden:\$fehlt\" >&2"$'\n'
    skript+="tar -czf - $muster 2>/dev/null"$'\n'

    local b64; b64=$(printf '%s' "$skript" | base64 | tr -d '\n')
    local innen="echo $b64 | base64 -d | bash"
    case ${HOST_OS[$h]:-posix} in
      cmd|gitbash) build_remote_argv "$h" "bash -c \"$innen\"" ;;
      wsl)         build_remote_argv "$h" "bash -c \"$innen\"" ;;
      *)           build_remote_argv "$h" "$innen" ;;
    esac
    # Hier an DERSELBEN Stelle auspacken.
    if "${SSH_ARGV[@]}" | tar -xzf - -C . 2>/dev/null; then
      local n=0 m
      for m in $muster; do
        for f in $m; do [[ -e $f ]] && ((n++)); done
      done
      log "  zurueckgeholt: $n Eintraege"
    else
      err "  Zurueckholen fehlgeschlagen"
      return 1
    fi
    return 0
  fi

  # --- kein DOWNLOAD gesetzt: wie bisher der ganze Ordner -------------
  log "  kein DOWNLOAD[$target] in targets.conf -- hole builds/$target"

  # GIBT ES DEN ORDNER DRUEBEN UEBERHAUPT?
  # [Dein apk-Lauf lief genau hier ins Leere: das Ziel heisst "apk",
  #  build_apk.sh legt das Ergebnis aber unter builds/android/ ab. Der
  #  Rueckfall holte builds/apk -- den es nicht gibt -- und schwieg
  #  dazu. Jetzt wird nachgesehen und aufgezaehlt, was WIRKLICH da ist.
  #  Dann muss niemand raten, was in DOWNLOAD gehoert.]
  local schau="ls -d '$path/builds/'*/ 2>/dev/null | sed 's#.*/builds/##'"
  local vorhanden
  case ${HOST_OS[$h]:-posix} in
    cmd|gitbash|wsl) vorhanden=$(remote "$h" "bash -c \"$schau\"" 2>/dev/null) ;;
    *)               vorhanden=$(remote "$h" "$schau" 2>/dev/null) ;;
  esac
  if [[ -n $vorhanden ]] && ! printf '%s\n' "$vorhanden" | grep -qx "${target}/"
  then
    err "  Auf '$h' gibt es kein builds/$target."
    err "  Vorhanden sind:"
    printf '%s\n' "$vorhanden" | sed 's/^/         /' >&2
    err "  Trag in config/targets.conf ein, was du brauchst, z.B.:"
    local ersterOrdner
    ersterOrdner=$(printf '%s\n' "$vorhanden" | head -1 | tr -d '/')
    err "      DOWNLOAD[$target]='builds/${ersterOrdner}/dein_ergebnis'"
    return 1
  fi
  log "  (eine Liste dort spart Zeit und Platz)"
  mkdir -p "builds/${target}"
  local weg=${HOST_XFER[$h]:-}
  if [[ -z $weg ]]; then
    case ${HOST_OS[$h]:-posix} in
      cmd|gitbash|wsl|windows) weg=tar ;;
      *) remote_has "$h" rsync && weg=rsync || weg=tar ;;
    esac
  fi
  if [[ $weg == rsync ]]; then
    (( DRY_RUN )) && { printf '  [Probelauf] rsync zurueck: %s\n' "$target"; return 0; }
    rsync -az -e "$(rsh_string "$h")" \
          "${HOST_SSH[$h]}:${path}/builds/${target}/" "builds/${target}/" \
      || log "  (noch keine Artefakte fuer $target)"
  else
    (( DRY_RUN )) && { printf '  [Probelauf] tar zurueck: %s\n' "$target"; return 0; }
    if [[ ${HOST_OS[$h]:-posix} == cmd ]]; then
      build_remote_argv "$h" \
        "tar -czf - -C $(winpfad "$path/builds/${target}") ."
    else
      build_remote_argv "$h" "tar -czf - -C $path/builds/${target} ."
    fi
    "${SSH_ARGV[@]}" \
      | tar -xzf - -C "builds/${target}" \
      || log "  (noch keine Artefakte fuer $target)"
  fi
}

# --move-to <host> <datei> -- ERSETZT das fruehere, fragile mv_to_laptop
# aus build_wrapper.sh (scp mit halb-hardcodiertem Zielordner, kopierte
# manchmal ins falsche Verzeichnis statt die Ordnerstruktur zu erhalten).
#
# [Genau wie pull_artifacts oben, nur in die andere Richtung: die Datei
#  wird lokal MIT ihrem relativen Pfad eingepackt (tar kennt "datei" als
#  z.B. "builds/android/x_bookmark_manager.apk") und drueben unter
#  HOST_PATH[$h] wieder ausgepackt. tar legt dabei die noetigen
#  Zwischenordner selbst an -- das war GENAU der Fehler bei scp: ein
#  Zielordner, der drueben noch nicht existierte, fuehrte zu einer
#  Kopie mit falschem/verkuerztem Namen im falschen (meist obersten)
#  Verzeichnis, statt zu einem sauberen Fehler oder einer korrekten
#  Ordnerstruktur.]
move_to_host() {                 # move_to_host <host> <datei>
  local h=$1 datei=$2
  local path=${HOST_PATH[$h]:-} # getrennt -- siehe rsh_string
  if [[ -z $path ]]; then
    err "  Host '$h' unbekannt -- siehe config/hosts.conf"
    return 1
  fi
  if [[ ! -e $datei ]]; then
    err "  '$datei' gibt es hier nicht"
    return 1
  fi
  log "  --move-to: '$datei' -> ${h}:${path}/${datei}"
  if (( DRY_RUN )); then
    log "  [Probelauf] wuerde uebertragen: $datei"
    return 0
  fi

  # AUSPACKEN MIT VORHERIGEM mkdir -p FUER DEN BASISORDNER SELBST -- der
  # existiert bei einem frischen Host manchmal noch gar nicht, waehrend
  # die UNTERORDNER der Datei ja von tar selbst angelegt werden.
  local innen="mkdir -p '$path' 2>/dev/null; cd '$path' || exit 1; tar -xzf -"
  case ${HOST_OS[$h]:-posix} in
    cmd|gitbash)
      local w; w=$(winpfad "$path")
      innen="mkdir \"$w\" 2>nul & cd /d \"$w\" && tar -xzf -"
      build_remote_argv "$h" "$innen" ;;
    wsl)         build_remote_argv "$h" "bash -c \"$innen\"" ;;
    *)           build_remote_argv "$h" "$innen" ;;
  esac

  if tar -czf - "$datei" | "${SSH_ARGV[@]}"; then
    log "  uebertragen: $datei"
    return 0
  else
    err "  --move-to fehlgeschlagen (Host erreichbar? Pfad korrekt?)"
    return 1
  fi
}


# ---------------------------------------------------------------------------
# HOOKS -- optionale Skripte vor und nach dem Bau
#
# Kein Eintrag in einer Konfigurationsdatei noetig: es genuegt, eine Datei
# anzulegen und ausfuehrbar zu machen. Fehlt sie, passiert nichts.
#
#   hooks/pre-action.<ziel>.sh     auf der BAUMASCHINE, vor konfigurieren
#   hooks/post-action.<ziel>.sh    auf der BAUMASCHINE, nach dem Bauen
#   hooks/pre-job.<ziel>.sh       auf DEINEM Rechner, vor dem Uebertragen
#   hooks/post-job.<ziel>.sh      auf DEINEM Rechner, nach dem Zurueckholen
#
# Feiner geht auch -- gewinnt vor der allgemeinen Fassung:
#   hooks/post-action.<ziel>@<host>.sh
#
# WARUM ZWEI EBENEN
# [Bei  exe@windows  gibt es zwei Orte, an denen "nach dem Bau" gelten
#  kann: auf der Zielmaschine (Dateien umbenennen, Version einstempeln)
#  und auf deinem Rechner, nachdem die Artefakte angekommen sind
#  (signieren, aufs Geraet spielen, Bescheid geben). Eine einzige Ebene
#  waere fuer die Haelfte der Faelle am falschen Ort.]
#
# Umgebung, die jeder Hook bekommt:
#   XBM_TARGET  XBM_HOST  XBM_JOBS  XBM_BUILD_DIR  XBM_PROJECT_DIR
#   XBM_PHASE   XBM_STATUS (nur bei post-*: ok|fail)
#
# FEHLERVERHALTEN
#   pre-*  schlaegt fehl -> der Auftrag wird abgebrochen, es wird NICHT
#          gebaut. [Ein Vorbereitungsschritt, der scheitert, macht den
#          folgenden Bau bestenfalls unbrauchbar.]
#   post-* schlaegt fehl -> der Auftrag gilt als fehlgeschlagen, die
#          bereits gebauten Artefakte bleiben aber liegen. Sie sind ja in
#          Ordnung; nur die Nachbereitung nicht.
# ---------------------------------------------------------------------------
# Passt eine Liste? Leere Liste heisst "alle".
# [Die Liste steht in der Datei, der Wert kommt vom Auftrag. Leerzeichen
#  um die Kommas werden geduldet -- man schreibt sie beim Ausrichten
#  schnell hin.]
hook_liste_passt() {             # hook_liste_passt <liste> <wert>
  local liste=$1 wert=$2
  [[ -z $liste ]] && return 0
  local alt=$IFS eintrag
  IFS=','
  for eintrag in $liste; do
    eintrag=$(trim "$eintrag")
    [[ $eintrag == "$wert" ]] && { IFS=$alt; return 0; }
  done
  IFS=$alt
  return 1
}

run_hook() {                     # run_hook <phase> <ziel> <host> [status]
  local phase=$1 target=$2 host=$3 status=${4:-}
  # Auf einer Zielmaschine heisst der Host "local" -- fuer die Auswahl
  # und fuer XBM_HOST gilt der Name, unter dem der Auftrag lief.
  [[ -n ${AS_HOST:-} ]] && host=$AS_HOST

  # ORDNER DURCHSEHEN statt Namen aufzuzaehlen.
  # [Mit Kommalisten gibt es zu jeder Phase beliebig viele gueltige
  #  Dateinamen -- man kann sie nicht mehr vorher hinschreiben. Also
  #  andersherum: jede Datei wird gelesen und gefragt, ob sie auf diesen
  #  Auftrag passt.]
  #
  # AUFBAU DES NAMENS
  #   <phase>[.<ziele>][@<hosts>].sh
  # Beide Listen kommagetrennt; FEHLEND oder LEER heisst "alle".
  #   post-action.sh                       alle Ziele, alle Hosts
  #   post-action@windows.sh               alle Ziele, Host windows
  #   post-action.exe.sh                   Ziel exe, alle Hosts
  #   post-action.exe@.sh                  dasselbe, Liste leer
  #   post-action.exe,apk@windows,server.sh  zwei Ziele, zwei Hosts
  #   post-action.@windows,local.sh        alle Ziele, zwei Hosts
  local -a treffer=()
  local f
  shopt -s nullglob
  for f in hooks/*.sh; do
    local basis=${f##*/}; basis=${basis%.sh}
    # Muss mit der Phase beginnen, gefolgt von Ende, '.' oder '@'.
    # [Ohne diese Pruefung wuerde "pre-job" auch auf "pre-jobber"
    #  passen.]
    # AUFBAU:  <phase>[-success|-fail][.<ziele>][@<hosts>]
    # [Die Stelle fuer success/fail steht direkt hinter der Phase --
    #  dort ist sie eindeutig, denn Ziele und Hosts folgen erst nach
    #  '.' bzw. '@'. Ein Ziel namens "success" waere damit kein Problem:
    #  post-action.success.sh meint das ZIEL success, post-action-success.sh
    #  die Bedingung.]
    local wann=""
    local kopf=$basis
    if   [[ $kopf == "$phase"-success* ]]; then wann=ok;   kopf=${kopf/-success/}
    elif [[ $kopf == "$phase"-fail*    ]]; then wann=fail; kopf=${kopf/-fail/}
    fi
    [[ $kopf == "$phase" || $kopf == "$phase".* || $kopf == "$phase"@* ]] \
      || continue

    # Bedingung pruefen. [Bei pre-* gibt es noch keinen Ausgang -- ein
    #  success/fail waere dort sinnlos, also wird der Hook uebergangen
    #  und einmal darauf hingewiesen.]
    if [[ -n $wann ]]; then
      if [[ $phase == pre-* ]]; then
        warn "  $f: success/fail ist bei '$phase' ohne Bedeutung"
        continue
      fi
      [[ $wann == "$status" ]] || continue
    fi

    local rest=${kopf#"$phase"}
    local ziele="" hosts=""
    if [[ $rest == @* ]]; then
      hosts=${rest#@}
    elif [[ $rest == .* ]]; then
      rest=${rest#.}
      if [[ $rest == *@* ]]; then ziele=${rest%%@*}; hosts=${rest#*@}
      else                        ziele=$rest; fi
    fi
    hook_liste_passt "$ziele" "$target" || continue
    hook_liste_passt "$hosts" "$host"   || continue

    # Reihenfolge: erst allgemein, dann genau. Schluessel = Anzahl der
    # gesetzten Einschraenkungen, danach der Name (damit es bei
    # Gleichstand berechenbar bleibt).
    # Reihenfolge: allgemein vor genau. Eine BEDINGUNG (success/fail)
    # macht einen Hook ebenfalls genauer -- also zaehlt sie mit.
    local rang=0
    [[ -n $wann  ]] && ((rang++))
    [[ -n $ziele ]] && ((rang++))
    [[ -n $hosts ]] && ((rang++))
    treffer+=("${rang}|${f}")
  done
  shopt -u nullglob
  (( ${#treffer[@]} == 0 )) && return 0

  local eintrag skript
  while IFS= read -r eintrag; do
    skript=${eintrag#*|}
    # KEIN chmod +x noetig -- gestartet wird ohnehin mit bash.
    log "  Hook: $skript"
    # LIVE IN DER STATUSFLAECHE ZEIGEN, WELCHER HOOK GERADE LAEUFT.
    # [Bisher stand in der parallelen Uebersicht waehrend eines Hooks
    #  gar nichts -- der Job schien kurz "haengenzubleiben", ohne dass
    #  zu sehen war, woran es lag.]
    fortschritt "$(printf '\r  %-28s hook: %s   ' "${target}@${host}" "$skript")"
    if (( DRY_RUN )); then
      printf '  [Probelauf] %s\n' "$skript"
      continue
    fi
    if ! XBM_TARGET=$target XBM_HOST=$host XBM_JOBS=$JOBS \
         XBM_BUILD_DIR="builds/${target}" XBM_PROJECT_DIR="$PWD" \
         XBM_PHASE=$phase XBM_STATUS=$status XBM_HOOK="$skript" \
         XBM_HOOKS_ONLY="${HOOKS_ONLY_MODE:-}" \
         bash "$skript"; then
      lauf_notiz "${target}@${host}" hook "$skript" fehlgeschlagen
      err "  Hook $skript fehlgeschlagen"
      return 1
    fi
    lauf_notiz "${target}@${host}" hook "$skript" ok
  done < <(printf '%s\n' "${treffer[@]}" | sort -t'|' -k1,1n -k2,2)
  return 0
}


# ---------------------------------------------------------------------------
# WERKZEUGE PRUEFEN
#
# [Bisher fiel ein fehlendes cmake erst NACH der Uebertragung auf -- bei
#  83 MB und zehntausend Dateien eine teure Art, es zu erfahren. Und die
#  Meldung war
#      ./build.sh: line 795: cmake: command not found
#  also eine Zeilennummer aus dem Skript statt einer Aussage darueber,
#  WAS auf WELCHER Maschine fehlt.
#
#  Geprueft wird das erste Wort jedes Befehls aus targets.conf -- das ist
#  das Programm, das aufgerufen wird.]
# ---------------------------------------------------------------------------
XBM_HOST_JETZT=""
werkzeuge_von() {                # werkzeuge_von <ziel>
  local t=$1 c w
  for c in "${CONF_CMD[$t]-}" "${BUILD_CMD[$t]-}"; do
    [[ -z $c ]] && continue
    # Erstes Wort, ./skript.sh ausgenommen (die pruefen wir per Datei)
    w=${c%% *}
    # Shell-Schluesselwoerter und Eingebautes sind keine Programme.
    # [Ohne das meldete ein Befehl wie  for i in ...; do ...  ein
    #  fehlendes Programm namens "for".]
    case $w in
      ./*|true|:|for|if|while|until|case|do|then|else|{|\(|env|cd|export|\
      set|unset|echo|test|exec|source|.|eval|local|read) continue ;;
    esac
    printf '%s\n' "$w"
  done
  # AUSDRUECKLICH ANGEMELDETER BEDARF.
  # [Bisher wurde nur das erste Wort der Bau-Befehle geprueft. Alles,
  #  was ein HOOK braucht -- mpv fuer einen Klang, adb zum Installieren,
  #  zip zum Packen -- war unsichtbar und wurde nie nachinstalliert.
  #  Zwei Wege, es anzumelden:
  #    1. in config/targets.conf:   REQUIRE[exe]='mpv zip'
  #    2. im Hook selbst, als Kommentarzeile:
  #           # xbm-requires: mpv adb
  #       Das ist die bessere Stelle -- die Abhaengigkeit steht dort,
  #       wo sie gebraucht wird, und zieht beim Kopieren des Hooks mit.]
  [[ -n ${REQUIRE[$t]:-} ]] && printf '%s\n' ${REQUIRE[$t]}

  # BEDARF DER HOOKS.
  # [Hooks sind benutzerspezifisch und werden nicht mitgeliefert -- sie
  #  bringen ihren Bedarf selbst mit, als Kommentarzeile:
  #      # xbm-requires: mpv
  #      # xbm-requires: winget::mpv = mpv-player.mpv-CI.MSVC
  #      # xbm-requires: apt::mpv = mpv
  #  Die erste Form nennt nur das Werkzeug; der Paketname kommt dann aus
  #  config/packages.conf oder der eingebauten Tabelle. Die zweite Form
  #  nennt beides und gilt VOR packages.conf -- so steht die Begruendung
  #  dort, wo sie hingehoert, und zieht beim Kopieren des Hooks mit.
  #
  #  Hier wird nur der WERKZEUGNAME herausgezogen; die Paketnamen sammelt
  #  hook_pakete_laden ein (das muss in der Hauptshell laufen, damit die
  #  Zuordnung nicht in einer Unter-Shell verlorengeht).]
  local hf
  shopt -s nullglob
  for hf in hooks/*.sh; do
    hook_gilt_fuer "$hf" "$t" "$XBM_HOST_JETZT" || continue
    sed -n 's/^[[:space:]]*#[[:space:]]*xbm-requires:[[:space:]]*//p' "$hf" \
      | while IFS= read -r zeile; do
          if [[ $zeile == *::*=* ]]; then
            # verwalter::werkzeug = paket  ->  nur das werkzeug
            local vw=${zeile%%=*}
            printf '%s\n' "$(trim "${vw#*::}")"
          else
            printf '%s\n' $zeile
          fi
        done
  done
  shopt -u nullglob
}

# Sammelt die Paketnamen aus den Hooks ein.
# [MUSS in der Hauptshell laufen -- in einer Befehlsersetzung waere das
#  gefuellte Feld danach wieder weg. Genau dieser Fehler hat mich beim
#  winget-Pfad schon einmal erwischt.]
declare -A PAKET_AUS_HOOK
hook_pakete_laden() {            # hook_pakete_laden <ziel> <host>
  local t=$1 h=$2 hf zeile vw paket verw werkz
  PAKET_AUS_HOOK=()
  shopt -s nullglob
  for hf in hooks/*.sh; do
    hook_gilt_fuer "$hf" "$t" "$h" || continue
    while IFS= read -r zeile; do
      [[ $zeile == *::*=* ]] || continue
      vw=$(trim "${zeile%%=*}")
      paket=$(trim "${zeile#*=}")
      verw=${vw%%::*}
      werkz=${vw#*::}
      [[ -z $verw || -z $werkz || -z $paket ]] && continue
      PAKET_AUS_HOOK["$verw:$werkz"]=$paket
    done < <(sed -n 's/^[[:space:]]*#[[:space:]]*xbm-requires:[[:space:]]*//p' "$hf")
  done
  shopt -u nullglob
}

# Passt dieser Hook ueberhaupt auf Ziel und Host?
# [Damit wird nur installiert, was der jeweilige Auftrag wirklich
#  braucht -- "pro Hook", wie gewuenscht. Phase und success/fail
#  spielen hier keine Rolle: ob ein Hook spaeter WIRKLICH laeuft, haengt
#  vom Ausgang ab, den man vorher nicht kennt. Im Zweifel lieber
#  installieren als mitten im Lauf scheitern.]
hook_gilt_fuer() {               # hook_gilt_fuer <datei> <ziel> <host>
  local basis=${1##*/}; basis=${basis%.sh}
  local t=$2 h=$3
  basis=${basis/-success/}; basis=${basis/-fail/}
  local rest=${basis#*[.@]}
  [[ $basis == "$rest" ]] && return 0        # weder . noch @ -> gilt fuer alles
  local ziele="" hosts=""
  case $basis in
    *@*) hosts=${basis#*@}
         local vorn=${basis%%@*}
         [[ $vorn == *.* ]] && ziele=${vorn#*.} ;;
    *.*) ziele=${basis#*.} ;;
  esac
  hook_liste_passt "$ziele" "$t" || return 1
  hook_liste_passt "$hosts" "$h" || return 1
  return 0
}

# Gibt es das Programm -- auch als .exe?
# [In WSL und Git Bash liegen Windows-Programme als cmake.exe vor. Ein
#  blosses  command -v cmake  findet dort NICHTS, obwohl CMake einsatz-
#  bereit im PATH steht. Genau das ist bei dir passiert: der PATH enthielt
#  /mnt/c/Program Files/CMake/bin, meine Pruefung meldete trotzdem
#  "cmake fehlt".]
werkzeug_da() {                  # werkzeug_da <name>  -> gibt Fundnamen aus
  local w=$1
  if command -v "$w" >/dev/null 2>&1; then printf '%s' "$w"; return 0; fi
  if command -v "$w.exe" >/dev/null 2>&1; then printf '%s' "$w.exe"; return 0; fi
  return 1
}


# Paketverwalter auf DIESER Maschine.
# [Bisher konnte nur die Fernstrecke installieren. Die Pruefung, die auf
#  der BAUMASCHINE laeuft (werkzeuge_pruefen), hat nur gemeldet -- und
#  genau dort faellt ein fehlendes mpv auf, weil dort die Hooks laufen.]
LOKAL_VERWALTER=""
LOKAL_WINGET=""

# Laufen wir gerade IN WSL?
# [Entscheidend, denn dort gibt es ZWEI Welten. winget legt ein
#  WINDOWS-Programm ab; ein Hook, der in WSL  mpv  aufruft, braucht aber
#  ein LINUX-mpv. Erkennbar an /proc/version oder am Ordner /mnt/c.]
ist_wsl() {
  [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version && return 0
  [[ -d /mnt/c/Windows ]] && return 0
  return 1
}

lokal_verwalter() {
  LOKAL_VERWALTER=""; LOKAL_WINGET=""
  # IN WSL ZUERST apt.
  # [Sonst wird ueber die Interop-Bruecke winget gefunden und ein
  #  Windows-Programm installiert -- das der Hook in WSL nie zu sehen
  #  bekommt. Genau das ist bei deinem mpv passiert.]
  if ist_wsl && command -v apt-get >/dev/null 2>&1; then
    LOKAL_VERWALTER=apt; return 0
  fi
  if command -v winget.exe >/dev/null 2>&1; then
    LOKAL_WINGET=winget.exe; LOKAL_VERWALTER=winget; return 0
  fi
  if command -v winget >/dev/null 2>&1; then
    LOKAL_WINGET=winget; LOKAL_VERWALTER=winget; return 0
  fi
  # [LOCALAPPDATA gibt es nur auf Windows. Unter set -u bricht der
  #  Zugriff ohne Vorgabewert ab -- und zwar mitten im Auftrag, mit einer
  #  Meldung, die nichts mit der Ursache zu tun hat.]
  local wp="${LOCALAPPDATA:-}/Microsoft/WindowsApps/winget.exe"
  [[ -n ${LOCALAPPDATA:-} && -x "$wp" ]] && {
    LOKAL_WINGET=$wp; LOKAL_VERWALTER=winget; return 0; }
  command -v apt-get >/dev/null 2>&1 && { LOKAL_VERWALTER=apt; return 0; }
  return 1
}

lokal_installieren() {           # lokal_installieren <werkzeug>
  local w=$1 id
  lokal_verwalter || return 1
  id=$(paket_id "$w" "$LOKAL_VERWALTER")
  [[ -z $id ]] && id=$w
  case $LOKAL_VERWALTER in
    winget)
      log "  installiere $w ($id) mit winget..."
      local o="--silent --accept-source-agreements"
      o="$o --accept-package-agreements --disable-interactivity"
      # AUSGABE NICHT VERSCHLUCKEN.
      # [Vorher ging sie nach /dev/null. Man sah "installiere mpv ..."
      #  und danach, dass es immer noch fehlt -- ohne den Grund. Der
      #  steht in winges Ausgabe.]
      "$LOKAL_WINGET" install --id "$id" -e --scope user $o 2>&1 \
        || "$LOKAL_WINGET" install --id "$id" -e $o 2>&1 \
        || "$LOKAL_WINGET" install "$id" $o 2>&1 \
        || { err "  winget konnte '$id' nicht installieren (Ausgabe oben)"
             return 1; }
      ;;
    apt)
      (( ERLAUBE_SUDO )) || {
        err "  '$w' fehlt. Mit --install erlauben (braucht sudo), oder:"
        err "      sudo apt install $id"
        return 1; }
      log "  installiere $w ($id) mit apt..."
      sudo -n apt-get install -y "$id" 2>&1 \
        || { err "  apt konnte $id nicht installieren (Ausgabe oben)"
             err "  Ohne Passwort geht es nur mit einer sudoers-Regel."
             return 1; }
      ;;
  esac
  return 0
}

werkzeuge_pruefen() {            # werkzeuge_pruefen <ziel> <host>
  local t=$1 h=$2 w fehlt=() nurexe=()
  # UNTER WELCHEM NAMEN LAEUFT DIESER AUFTRAG WIRKLICH?
  # [Auf der Zielmaschine heisst der Host "local" -- build.sh wird dort
  #  mit --target exe@local gerufen. Ein Hook namens
  #      pre-action.@windows.sh
  #  galt damit als nicht zutreffend, und sein Bedarf (mpv) wurde nie
  #  verlangt -- obwohl der Hook GENAU DORT laeuft. Der Name des
  #  Auftraggebers steht in AS_HOST; der zaehlt.]
  local hname=${AS_HOST:-$h}
  hook_pakete_laden "$t" "$hname"
  while IFS= read -r w; do
    [[ -z $w ]] && continue
    local fund
    if fund=$(werkzeug_da "$w"); then
      [[ $fund == *.exe ]] && nurexe+=("$w")
    else
      fehlt+=("$w")
    fi
  done < <(XBM_HOST_JETZT=$hname werkzeuge_von "$t" | grep -v '^$' | sort -u)

  if (( ${#nurexe[@]} > 0 )); then
    # BRUECKE FUER DIE .exe-NAMEN.
    # [Die Bau-Befehle aus targets.conf kann ich umschreiben --
    #  cmake wird zu cmake.exe. In deinen HOOKS kann ich das nicht: das
    #  sind deine Dateien, und ein Skript, das fremden Code umschreibt,
    #  waere ein schlechter Tausch. Stattdessen wird fuer jedes nur als
    #  .exe vorhandene Werkzeug ein kleines Skript unter dem
    #  ENDUNGSLOSEN Namen angelegt und dessen Ordner dem PATH
    #  vorangestellt. Dann laeuft  mpv --no-video ...  im Hook
    #  unveraendert.
    #
    #  Warum das ueberhaupt noetig ist: Git Bash und MSYS2 haengen von
    #  sich aus ".exe" an, wenn ein Befehl sonst nicht gefunden wird --
    #  dort waere mpv nie ein Problem. WSL tut das NICHT. Dass in deinem
    #  Log "nur als .exe vorhanden" steht UND der Aufruf scheitert,
    #  heisst also: die Shell dort ist WSLs bash, nicht Git Bash.
    #  Die Bruecke hilft in beiden Faellen.]
    local bruecke="$PWD/builds/.werkzeuge"
    mkdir -p "$bruecke"
    local we2
    for we2 in "${nurexe[@]}"; do
      if [[ ! -x "$bruecke/$we2" ]]; then
        printf '#!/usr/bin/env bash
exec %s.exe "$@"
' "$we2" > "$bruecke/$we2"
        chmod +x "$bruecke/$we2"
      fi
    done
    case ":$PATH:" in
      *":$bruecke:"*) ;;
      *) export PATH="$bruecke:$PATH" ;;
    esac
    # Jedes Werkzeug einzeln nennen -- "${nurexe[*]} -> ${nurexe[0]}.exe"
    # las sich so, als zeigten alle auf dasselbe Programm.
    local liste=""
    for we2 in "${nurexe[@]}"; do liste+=" $we2->$we2.exe"; done
    log "  Bruecke angelegt:$liste"
    log "  (${bruecke} steht jetzt im PATH -- Hooks koennen die Namen"
    log "   ohne Endung benutzen)"
  fi

  # COMPILER PRUEFEN, wenn cmake im Spiel ist.
  # [Bisher wurde nur das erste Wort des Befehls geprueft -- also cmake.
  #  Das war vorhanden, und erst cmake selbst meldete dann
  #      No CMAKE_C_COMPILER could be found.
  #  Nach Uebertragung und Konfigurationslauf. Ein Compiler ist aber
  #  genauso eine Voraussetzung wie cmake.]
  if [[ "${CONF_CMD[$t]-}${BUILD_CMD[$t]-}" == *cmake* ]]; then
    local cc gefunden_cc=""
    for cc in cc gcc clang cl x86_64-w64-mingw32-gcc; do
      if werkzeug_da "$cc" >/dev/null; then gefunden_cc=$cc; break; fi
    done
    if [[ -z $gefunden_cc ]]; then
      err "Auf '$h' ist kein C/C++-Compiler auffindbar."
      err "  cmake kann ohne einen nichts konfigurieren:"
      err "      No CMAKE_C_COMPILER could be found."
      err "  Gesucht wurde nach: cc gcc clang cl x86_64-w64-mingw32-gcc"
      err "  (jeweils auch als .exe)"
      err ""
      err "  AUF WINDOWS am einfachsten -- ein Compiler, der in JEDER"
      err "  Shell im PATH steht:"
      err "      winget install BrechtSanders.WinLibs.POSIX.UCRT"
      err "      winget install Ninja-build.Ninja"
      err "  Danach den System-PATH ergaenzen und sshd neu starten."
      err ""
      err "  MIT MSVC geht es auch, ist aber unbequemer: cl.exe steht nur"
      err "  in einer Developer-Eingabeaufforderung im PATH. Dann muss"
      err "  vcvars64.bat vor cmake aufgerufen werden, etwa in"
      err "  config/targets.conf:"
      err "      CONF_CMD[exe]='cmd /c \"call vcvars64.bat && cmake ...\"'"
      err ""
      err "  ODER GANZ OHNE WINDOWS-MASCHINE -- Cross-Compile auf Linux:"
      err "      apt install mingw-w64 cmake ninja-build"
      err "      ./build.sh exe@local"
      err "  mit der Toolchain-Datei, die du schon hast:"
      err "      cmake/toolchain-mingw-clang.cmake"
      err ""
      err "  Pruefung ueberspringen: --skip-toolcheck"
      return 1
    fi
    log "  Compiler auf '$hname': $gefunden_cc"
  fi

  # NACHINSTALLIEREN, dann erneut pruefen.
  if (( ${#fehlt[@]} > 0 )) && (( AUTO_INSTALL )); then
    local rest=()
    for w in "${fehlt[@]}"; do
      lokal_installieren "$w" || { rest+=("$w"); continue; }
      werkzeug_da "$w" >/dev/null || rest+=("$w")
    done
    fehlt=("${rest[@]}")
    if (( ${#fehlt[@]} == 0 )); then
      log "  alle fehlenden Programme installiert."
    elif ist_wsl; then
      err "  Hinweis: hier laeuft WSL (Linux), nicht Windows."
      err "  Ein per winget installiertes Windows-Programm ist von hier"
      err "  aus NICHT als '${fehlt[0]}' aufrufbar -- es hiesse"
      err "  '${fehlt[0]}.exe' und braeuchte eine neue Sitzung."
      err "  Richtig ist hier:  sudo apt install ${fehlt[0]}"
    fi
  fi

  (( ${#fehlt[@]} == 0 )) && return 0

  err "Auf '$hname' fehlen Programme fuer das Ziel '$t': ${fehlt[*]}"
  err "  PATH dort: $PATH"
  local w2
  for w2 in "${fehlt[@]}"; do
    case $w2 in
      cmake)  err "  cmake:  winget install Kitware.CMake" ;;
      ninja)  err "  ninja:  winget install Ninja-build.Ninja" ;;
      git)    err "  git:    winget install Git.Git" ;;
      *)      err "  $w2: nicht im PATH der SSH-Sitzung" ;;
    esac
  done
  err "  Wichtig: nach der Installation den PATH der SSH-Sitzung pruefen --"
  err "  eine Login-Shell sieht nicht immer denselben PATH wie dein Fenster:"
  err "      ssh $h 'bash -lc \"command -v cmake ninja\"'"
  return 1
}


# Prueft ein Programm auf der Gegenseite -- IN DER SHELL, IN DER AUCH
# GEBAUT WIRD.
# [Das war vorher falsch: bei os=cmd ging  command -v  an cmd.exe, das
#  diesen Befehl gar nicht kennt -- die Pruefung war also wirkungslos.
#  Und where/command -v sehen ohnehin VERSCHIEDENE PATHs: cmd.exe hat
#  einen anderen als die Login-bash. Gebaut wird aber mit  bash
#  build.sh , also zaehlt allein, was BASH findet.]
fern_hat_werkzeug() {            # fern_hat_werkzeug <host> <programm>
  local h=$1 w=$2
  case ${HOST_OS[$h]:-posix} in
    cmd|gitbash)
      # Durch die Login-bash fragen -- dort laeuft spaeter der Bau.
      remote "$h" "bash -lc \"command -v $w || command -v $w.exe\"" \
        >/dev/null 2>&1 ;;
    wsl)
      remote "$h" "command -v $w" >/dev/null 2>&1 ;;
    *)
      remote "$h" "command -v $w || command -v $w.exe" >/dev/null 2>&1 ;;
  esac
}




# ---------------------------------------------------------------------------
# BEFEHLSBIBLIOTHEK -- ein Name, je Plattform eine Fassung
#
#     cmds/<name>/posix.sh      Linux, macOS, WSL   (bash, bekommt "$@")
#     cmds/<name>/windows.ps1   Windows             (powershell -NoProfile)
#     cmds/<name>/windows.sh    Windows, falls bash lieber ist
#     cmds/<name>/default.sh    wenn nichts Genaueres da ist
#
# Aufruf:   build.sh @windows d 1
#           build.sh @local   d 1
#
# [Der Sinn: ein Befehl, ein Name, und die Uebersetzung auf die jeweilige
#  Maschine passiert an EINER Stelle -- in der Datei, die dorthin gehoert.
#  Die Umrechnung von Parametern (bei dir 1-10 gegen 5-100) steht damit
#  dort, wo sie hingehoert, statt im Aufrufer.]
# ---------------------------------------------------------------------------
plattform_von() {                # plattform_von <host>
  case ${HOST_OS[$1]:-posix} in
    cmd|gitbash) printf 'windows' ;;
    *)           printf 'posix' ;;
  esac
}

cmd_datei() {                    # cmd_datei <name> <host> -> Pfad oder leer
  local name=$1 h=$2 pl
  pl=$(plattform_von "$h")
  local k
  for k in "cmds/$name/$pl.sh" "cmds/$name/$pl.ps1" \
           "cmds/$name/default.sh" "cmds/$name/default.ps1"; do
    [[ -f $k ]] && { printf '%s' "$k"; return 0; }
  done
  return 1
}

# Baut aus der gewaehlten Fassung das Skript, das drueben laeuft.
cmd_skript_bauen() {             # cmd_skript_bauen <datei> <ziel> <args...>
  local quelle=$1 ziel=$2; shift 2
  if [[ $quelle == *.ps1 ]]; then
    # -NoProfile spart das Laden des PowerShell-Profils -- das kostet
    # sonst je Aufruf spuerbar Zeit.
    {
      printf '#!/usr/bin/env bash\n'
      printf 'exec powershell.exe -NoProfile -ExecutionPolicy Bypass \\\n'
      printf '  -File "%s"' "${quelle##*/}"
      local a
      for a in "$@"; do printf ' %q' "$a"; done
      printf '\n'
    } > "$ziel"
  else
    {
      printf '#!/usr/bin/env bash\n'
      printf 'set -- '
      local a
      for a in "$@"; do printf '%q ' "$a"; done
      printf '\n'
      cat "$quelle"
    } > "$ziel"
  fi
}


# ---------------------------------------------------------------------------
# ZEITMESSUNG
# [Der Log deckt nur ab, was NACH dem ersten log-Aufruf passiert. Die
#  Pruefungen davor -- Werkzeuge, Compiler, Verbindungsaufbau -- geben
#  im Erfolgsfall nichts aus und sind damit unsichtbar. Genau dort steckt
#  aber die Wartezeit. Mit --timing wird jeder Fernaufruf gemessen.]
# ---------------------------------------------------------------------------
XBM_T0=$(date +%s%N 2>/dev/null || echo 0)
# Sekunden mit zwei Nachkommastellen, OHNE awk und ohne printf %f.
# [awk richtet sich nach der Spracheinstellung und liefert in deutscher
#  Umgebung "3,00" mit Komma. Bashs printf %.2f kann damit nichts
#  anfangen:  printf: 3,00: invalid number  -- genau die Meldung aus
#  deinem Log. Ganzzahlrechnung kennt das Problem nicht.]
ns_zu_s() {                      # ns_zu_s <nanosekunden>
  local ns=$1
  (( ns < 0 )) && ns=0
  printf '%d.%02d' $(( ns / 1000000000 )) $(( (ns / 10000000) % 100 ))
}
zeit_seit_start() {
  local jetzt; jetzt=$(date +%s%N 2>/dev/null || echo 0)
  ns_zu_s $(( jetzt - XBM_T0 ))
}
messpunkt() {                    # messpunkt <text>
  (( TIMING )) || return 0
  # Auf den BILDSCHIRM, nicht ins Log. [stderr ist innerhalb eines
  #  Auftrags in die Logdatei umgeleitet -- dort haette man die Messung
  #  erst hinterher gesehen, und genau das will man nicht.]
  local z; z=$(printf '  [%6ss] %s' "$(zeit_seit_start)" "$*")
  # AUCH IN EINE DATEI. [Du hast die Ausgabe bisher von Hand
  #  umgeleitet -- das macht das Skript jetzt selbst.]
  if [[ -n ${XBM_TIMING_DATEI:-} ]]; then
    printf '%s\n' "$z" >> "$XBM_TIMING_DATEI" 2>/dev/null || true
  fi
  if { true >&3; } 2>/dev/null; then printf '%s\n' "$z" >&3
  else printf '%s\n' "$z" >&2; fi
}


# ---------------------------------------------------------------------------
# QUELLEN, DIE AELTER SIND ALS IHRE OBJEKTDATEI, ANFASSEN.
# [Der Grund fuer "erfolgreiche" Bauten mit altem Baustempel: unzip
#  stellt die im Archiv GESPEICHERTEN Zeiten wieder her, nicht die
#  aktuelle Uhrzeit. Liegt eine Quelle damit vor ihrer .o-Datei, haelt
#  ninja sie fuer alt und uebersetzt sie NICHT -- das Log zeigte dann nur
#  [3/3] und band die ALTEN Objektdateien. Das gehoert hierher und nicht
#  in ein Hilfsskript, das man vergessen kann. Angefasst wird nur, was
#  wirklich aelter ist; ein normaler inkrementeller Bau bleibt unberuehrt.]
# ---------------------------------------------------------------------------
quellen_auffrischen() {          # quellen_auffrischen <bauordner>
  local bdir=$1
  [[ -d $bdir ]] || return 0
  local n=0 q o ts
  while IFS= read -r o; do
    q=${o#*.dir/}; q=${q%.o}; q=${q%.obj}
    [[ -f $q ]] || continue
    [[ $q -nt $o ]] && continue
    touch "$q" 2>/dev/null
    if [[ ! $q -nt $o ]]; then
      # Uhr des Bauwirts laeuft vor: eine Minute NACH der Objektdatei.
      ts=$(date -d "@$(( $(date -r "$o" +%s 2>/dev/null || echo 0) + 60 ))" \
           '+%Y%m%d%H%M.%S' 2>/dev/null) && touch -t "$ts" "$q" 2>/dev/null
    fi
    [[ $q -nt $o ]] && n=$((n+1))
  done < <(find "$bdir" \( -name '*.o' -o -name '*.obj' \) 2>/dev/null)
  if (( n > 0 )); then
    log "  $n Quelldatei(en) waren aelter als ihre Objektdatei -- aufgefrischt"
    log "  (sonst uebersprungen ninja sie und band alte Objekte)"
  fi
}

# ---------------------------------------------------------------------------
# ZWISCHENDATEIEN
#
# [Fehler von einer Parrot-Maschine:
#      mv: cannot move ... no space left on device
#  /tmp ist auf vielen Systemen eine RAM-Platte (tmpfs), oft nur halb so
#  gross wie der Arbeitsspeicher. Das Skript legte dort unter anderem den
#  VOLLSTAENDIGEN Bauausgang ab -- bei einem grossen Bau mit set -x
#  schnell hunderte MB.
#
#  Zwei Aenderungen: die Zwischendateien liegen jetzt im Projekt
#  (builds/.tmp), also auf derselben Platte wie das Projekt selbst. Und
#  der Bauausgang wird nicht mehr ganz mitgeschrieben -- gebraucht
#  werden nur die letzten Zeilen.
#
#  Mit XBM_TMPDIR laesst sich der Ort verlegen, falls das Projekt auf
#  einem knappen Datentraeger liegt.]
# ---------------------------------------------------------------------------
XBM_TMP=""
tmp_bereit() {
  [[ -n $XBM_TMP ]] && return 0
  XBM_TMP=${XBM_TMPDIR:-builds/.tmp}
  if ! mkdir -p "$XBM_TMP" 2>/dev/null; then
    XBM_TMP=${TMPDIR:-/tmp}
  fi
}

# Ersetzt mktemp -- gleiche Benutzung, anderer Ort.
xtmp() {
  tmp_bereit
  local f
  if ! f=$(mktemp "$XBM_TMP/xbm.XXXXXX" 2>/dev/null); then
    err "kann keine Zwischendatei anlegen in '$XBM_TMP'"
    err "  Platz frei?   df -h $XBM_TMP"
    err "  Anderer Ort:  XBM_TMPDIR=/pfad/mit/platz ./build.sh ..."
    return 1
  fi
  printf '%s' "$f"
}

# ---------------------------------------------------------------------------
# ZEITSTEMPEL FUER DIE LOGDATEI
#
# [Das Log wird nicht von einer Funktion geschrieben, sondern durch
#  Umleitung gefuellt -- es gibt also keine einzelne Stelle, an der man
#  eine Uhrzeit anhaengen koennte. Der richtige Ort ist die Umleitung
#  selbst: die Ausgabe laeuft durch diesen Filter.
#
#  ts aus moreutils kann das; fehlt es, springt awk ein, und ohne awk
#  eine bash-Schleife. So funktioniert es auf jeder Maschine, auch auf
#  einem frisch aufgesetzten Windows mit Git Bash.
#
#  Format ueber XBM_TS_FORMAT aenderbar, leer schaltet es ab.]
# ---------------------------------------------------------------------------
# XBM_TS_FORMAT=${XBM_TS_FORMAT-"{%H:%M:%S}"}
# XBM_TS_FORMAT=${XBM_TS_FORMAT-"{%H:%M:%S %.S}"}
XBM_TS_FORMAT=${XBM_TS_FORMAT-"{%.T}"}

zeitstempel() {
  if [[ -z $XBM_TS_FORMAT ]]; then cat; return; fi

  # 1. ts aus moreutils, falls vorhanden.
  if command -v ts >/dev/null 2>&1; then
    ts "$XBM_TS_FORMAT"
    return
  fi

  # 2. bash selbst -- printf '%()T' kann strftime, ohne einen einzigen
  #    Fremdprozess.
  #    [awk schied aus: mawk (die Vorgabe auf Debian und Ubuntu) merkt
  #     sich die Zeit vom Programmstart. Alle Zeilen bekamen dieselbe
  #     Sekunde, auch mit systime() -- nachgemessen an einem Bau, der
  #     drei Sekunden lief. Und ein  date  je Zeile waere unbrauchbar
  #     langsam: 2000 Zeilen in 2,07 s gegenueber 20000 in 0,22 s.]
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) ))
  then
    local z
    while IFS= read -r z; do
      printf "%($XBM_TS_FORMAT)T %s\n" -1 "$z"
    done
    return
  fi

  # 3. Aeltere bash: date je Zeile. Langsam, aber richtig.
  local z2
  while IFS= read -r z2; do
    printf '%s %s\n' "$(date +"$XBM_TS_FORMAT")" "$z2"
  done
}

# ---------------------------------------------------------------------------
# BILDSCHIRM UND LOGDATEI TRENNEN
#
# [Bisher lief die gesamte Ausgabe eines Auftrags in seine Logdatei --
#  einschliesslich der Fortschrittszeilen mit \r. Im Log stand deshalb
#  eine einzige, endlos lange Zeile
#      uebertragen: 200/10179  uebertragen: 400/10179  ...
#  und auf dem Bildschirm war vom Bau selbst gar nichts zu sehen.
#
#  Jetzt gilt:
#    BILDSCHIRM  Fortschritt (Uebertragung und Bau in Prozent).
#                Mit --show-output zusaetzlich die volle Ausgabe.
#    LOGDATEI    die volle Ausgabe, aber KEINE Fortschrittszeilen.
#                Mit --no-log abschaltbar.
#
#  Technisch: vor der Umleitung wird der Bildschirm auf Dateikennung 3
#  gerettet. Alles, was dorthin geht, landet nie im Log.]
# ---------------------------------------------------------------------------
# EIN EREIGNIS IN DER LAUF-UEBERSICHT FESTHALTEN -- fuer --show/--show-last.
# [Mehrere Auftraege schreiben PARALLEL (Hintergrund-Unterschalen) in
#  DIESELBE Datei -- ohne Absicherung koennten sich zwei gleichzeitige
#  Zeilen ineinander verzahnen. flock sperrt kurz, waehrend genau EINE
#  Zeile angehaengt wird; ist flock nicht vorhanden (selten, aber auf
#  manchen Minimal-Systemen), wird ungesichert angehaengt -- eine
#  einzelne kurze Zeile ueberschreitet praktisch nie die Grenze, ab der
#  ein Anhaengen nicht mehr atomar waere, das Risiko ist gering.]
lauf_notiz() {                   # lauf_notiz <ziel@host> <phase> <detail> [status]
  [[ -z ${LAUF_UEBERSICHT:-} ]] && return 0
  local ziel=$1 phase=$2 detail=$3 status=${4:-}
  local zeile
  zeile=$(printf '%s  %-20s %-9s %-38s %s' \
                 "$(date '+%H:%M:%S')" "$ziel" "$phase" "$detail" "$status")
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 201
      printf '%s\n' "$zeile" >> "$LAUF_UEBERSICHT"
    ) 201>>"${LAUF_UEBERSICHT}.lock"
  else
    printf '%s\n' "$zeile" >> "$LAUF_UEBERSICHT"
  fi
}

# Freitext-Zeile fuer die Kopf-/Abschlussuebersicht -- dieselbe
# Absicherung gegen gleichzeitiges Schreiben wie lauf_notiz(), da
# mehrere parallele Auftraege am Ende alle in derselben kurzen Zeitspanne
# ihre OK/FEHLER-Zeile eintragen.
kopf_notiz() {                   # kopf_notiz <text>
  [[ -z ${KOPF_UEBERSICHT:-} ]] && return 0
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 202
      printf '%s\n' "$*" >> "$KOPF_UEBERSICHT"
    ) 202>>"${KOPF_UEBERSICHT}.lock"
  else
    printf '%s\n' "$*" >> "$KOPF_UEBERSICHT"
  fi
}

fortschritt() {                  # nur auf den Bildschirm
  # AUF DER GEGENSEITE GAR NICHTS AUSGEBEN.
  # [Dort ist Kennung 3 kein Bildschirm, sondern der ssh-Kanal. Alles,
  #  was dorthin geht, landet bei der steuernden Seite im LOG -- also
  #  genau da, wo der Balken nicht hingehoert, und nicht dort, wo man
  #  ihn sehen will. Die Gegenseite gibt deshalb nur den vollen
  #  Bauausgang aus; den Prozentsatz bildet die steuernde Seite selbst
  #  daraus.]
  [[ -n ${AS_HOST:-} ]] && return 0
  # BEI --show-output SCHWEIGEN.
  # [Dann laufen ohnehin alle Zeilen durch; ein Balken, der sich mit
  #  \r ueber sie legt, macht beides unlesbar -- die Bauzeilen und den
  #  Balken.]
  # Bei --show-output und --log-stdout schweigen -- dort laufen ohnehin
  # alle Zeilen durch, ein Balken legte sich mit \r darueber.
  (( VERBOSE )) && return 0
  (( LOG_STDOUT )) && return 0

  # INNERHALB EINES AUFTRAGS: in die eigene Statusdatei schreiben,
  # NICHT aufs Terminal.
  # [Bei mehreren Auftraegen schrieben alle ihre \r-Zeile auf dieselbe
  #  Terminalzeile und ueberschrieben sich gegenseitig -- dabei blieb
  #  nichts Lesbares uebrig. Jetzt legt jeder Auftrag seinen Zustand ab,
  #  und EINE Stelle zeichnet daraus die ganze Flaeche. Damit kann nichts
  #  mehr durcheinandergeraten, egal wie viele parallel laufen.]
  if [[ -n ${XBM_STATUS_DATEI:-} ]]; then
    local txt=$*
    txt=${txt//$'\r'/}                 # \r gehoert dem Zeichner
    txt=${txt%"${txt##*[![:space:]]}"}  # Leerzeichen am Ende weg
    if printf '%s\n' "$txt" > "$XBM_STATUS_DATEI".neu 2>/dev/null; then
      mv -f "$XBM_STATUS_DATEI".neu "$XBM_STATUS_DATEI" 2>/dev/null \
        || rm -f "$XBM_STATUS_DATEI".neu 2>/dev/null
    else
      # Kein Platz oder kein Schreibrecht -- die Anzeige ist es nicht
      # wert, deswegen etwas liegenzulassen.
      rm -f "$XBM_STATUS_DATEI".neu 2>/dev/null
    fi
    return 0
  fi

  if { true >&3; } 2>/dev/null; then printf '%s' "$*" >&3
  else printf '%s' "$*"; fi
}

# ---------------------------------------------------------------------------
# DIE STATUSFLAECHE
#
# Eine Zeile je Auftrag, an fester Stelle. Der Zeichner faehrt mit dem
# Cursor hoch und schreibt alle Zeilen neu -- so steht jeder Auftrag
# immer an derselben Position und nichts flackert.
#
# [Ohne Terminal (Ausgabe in eine Datei oder Pipe) darf man den Cursor
#  nicht bewegen -- dort wuerden die Steuerzeichen im Text landen. Dann
#  wird gar nichts gezeichnet; die Zusammenfassung am Ende genuegt.]
# ---------------------------------------------------------------------------
STATUS_DIR=""
CURSOR_VERSTECKT=0
cursor_zurueck() {
  (( CURSOR_VERSTECKT )) || return 0
  CURSOR_VERSTECKT=0
  printf '\033[?25h'
}
zeichner_start() {                # zeichner_start <name...>
  [[ -t 1 ]] || return 0
  (( VERBOSE || LOG_STDOUT )) && return 0
  local -a namen=("$@")
  local n=${#namen[@]}
  (( n == 0 )) && return 0
  local i
  # CURSOR AUSBLENDEN.
  # [Der Zeichner faehrt zehnmal je Sekunde hoch und wieder herunter --
  #  der Cursor springt dabei sichtbar mit. Das ist das Flackern. Er
  #  wird waehrend der Anzeige ausgeblendet und danach zurueckgeholt;
  #  auch bei Abbruch, sonst bliebe er unsichtbar zurueck.]
  printf '\033[?25l'
  CURSOR_VERSTECKT=1
  for ((i=0; i<n; i++)); do printf '\n'; done
  (
    while [[ ! -f "$STATUS_DIR/.stop" ]]; do
      # BREITE DES TERMINALS BEACHTEN.
      # [Eine zu lange Zeile bricht um und belegt ZWEI Zeilen. Der
      #  Zeichner faehrt aber nur um n hoch -- ab da stimmt die Rechnung
      #  nicht mehr, der Block wandert, und stehengebliebene Reste
      #  bleiben fuer immer stehen. Genau so sieht dein "bleibt stehen"
      #  aus.]
      local breite=${COLUMNS:-0}
      if (( breite <= 0 )); then
        breite=$(tput cols 2>/dev/null || echo 80)
      fi
      (( breite < 20 )) && breite=80

      # ALLES IN EINEM STUECK SCHREIBEN.
      # [Vorher waren es n+1 einzelne printf-Aufrufe. Schreibt in der
      #  Zwischenzeit etwas anderes aufs Terminal, landet es MITTEN im
      #  Block und schiebt ihn auseinander. Ein einziger Schreibvorgang
      #  kann nicht unterbrochen werden.]
      local block; block=$(printf '\033[%dA' "$n")
      for ((i=0; i<n; i++)); do
        local z=""
        [[ -f "$STATUS_DIR/$i" ]] && IFS= read -r z < "$STATUS_DIR/$i" 2>/dev/null
        [[ -z $z ]] && z="  ${namen[$i]}"
        z=${z:0:$((breite-1))}
        block+=$(printf '\033[2K%s' "$z")
        block+=$'\n'
      done
      printf '%s' "$block"
      sleep 0.1
    done
  ) &
  ZEICHNER_PID=$!
}

zeichner_stop() {
  [[ -z ${ZEICHNER_PID:-} ]] && return 0
  : > "$STATUS_DIR/.stop"
  wait "$ZEICHNER_PID" 2>/dev/null || true
  ZEICHNER_PID=""

  # EIN LETZTES MAL ZEICHNEN, dann darunter weiterschreiben.
  # [Vorher wurde die Flaeche geleert. Der Endstand -- gerade die 100 --
  #  wurde dabei nie sichtbar: er stand in der Datei, aber der Zeichner
  #  kam nicht mehr dazu. Jetzt bleibt der letzte Stand stehen, und die
  #  Zusammenfassung erscheint darunter.]
  local n=$1 i breite=${COLUMNS:-0}
  (( breite <= 0 )) && breite=$(tput cols 2>/dev/null || echo 80)
  cursor_zurueck
  (( breite < 20 )) && breite=80
  local block; block=$(printf '\033[%dA' "$n")
  for ((i=0; i<n; i++)); do
    local z=""
    [[ -f "$STATUS_DIR/$i" ]] && IFS= read -r z < "$STATUS_DIR/$i" 2>/dev/null
    z=${z:0:$((breite-1))}
    block+=$(printf '\033[2K%s' "$z")
    block+=$'\n'
  done
  printf '%s' "$block"
}

# Liest die Ausgabe eines Baus, reicht sie unveraendert weiter (also ins
# Log) und zeigt nebenbei den Fortschritt an.
# [ninja meldet "[12/345] ...", cmake und make melden "[ 42%]". Beides
#  wird erkannt; findet sich nichts, laeuft nur ein Lebenszeichen mit.]
bau_fortschritt() {              # bau_fortschritt <beschriftung>
  local label=$1 zeile n m proz zaehler=0
  # NACH ZEIT AKTUALISIEREN, NICHT NACH ZEILENZAHL.
  # [Vorher: alle 400 Zeilen ein Lebenszeichen. Ein Konfigurationslauf
  #  hat aber nur wenige Dutzend Zeilen -- da kam nie eines, und die
  #  Statuszeile blieb die ganze Minute leer. Umgekehrt waeren 400
  #  Zeilen bei einem grossen Bau viel zu selten und bei einer Million
  #  Trace-Zeilen zu oft.
  #  Ein Mindestabstand loest beides: hoechstens fuenfmal je Sekunde,
  #  aber eben auch dann, wenn wenig kommt. EPOCHREALTIME kostet keinen
  #  Prozess.]
  local letzte=0 jetzt
  aktuell_genug() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
      jetzt=${EPOCHREALTIME/[.,]/}          # Mikrosekunden
      (( jetzt - letzte < 200000 )) && return 1
      letzte=$jetzt; return 0
    fi
    (( ++zaehler % 25 == 0 ))               # Rueckfall ohne bash 5
  }

  while IFS= read -r zeile; do
    printf '%s\n' "$zeile"              # unveraendert ins Log
    case $zeile in
      \[*|*%*) ;;
      *) ((zaehler++))
         aktuell_genug && \
           fortschritt "$(printf '\r  %-28s %d Zeilen   ' \
                          "$label" "$zaehler")"
         continue ;;
    esac
    if [[ $zeile =~ ^\[([0-9]+)/([0-9]+)\] ]]; then
      n=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
      (( m > 0 )) && proz=$(( n * 100 / m )) || proz=0
      # Bei 100 Prozent und beim ersten Wert immer zeichnen -- sonst
      # bliebe der Endstand womoeglich bei 97 stehen.
      if aktuell_genug || (( n == m )); then
        fortschritt "$(printf '\r  %-28s %3d%%  [%d/%d]   ' \
                       "$label" "$proz" "$n" "$m")"
      fi
    elif [[ $zeile =~ \[[[:space:]]*([0-9]+)%\] ]]; then
      aktuell_genug && \
        fortschritt "$(printf '\r  %-28s %3d%%   ' \
                       "$label" "${BASH_REMATCH[1]}")"
    fi
  done
  # DEN ENDSTAND STEHEN LASSEN.
  # [Hier wurde die Zeile geleert -- damit blitzte die 100 nur kurz auf
  #  und der letzte sichtbare Wert war irgendein Zwischenstand. Die
  #  Flaeche raeumt ohnehin zeichner_stop, wenn alles durch ist.]
  :
}


# ---------------------------------------------------------------------------
# FEHLENDE WERKZEUGE NACHINSTALLIEREN
#
# winget laeuft NICHT von selbst -- es muss aufgerufen werden. Das
# uebernimmt jetzt das Skript.
#
# [Auf Linux ist das heikler: apt braucht sudo, und du wolltest nie ein
#  Passwort eingeben muessen. Deshalb wird dort NUR installiert, wenn du
#  es ausdruecklich verlangst (--install). Auf Windows ist winget ohne
#  erhoehte Rechte benutzbar, solange man --scope user nimmt -- dort
#  wird also von selbst installiert, abschaltbar mit --no-install.]
# ---------------------------------------------------------------------------
paket_id() {                     # paket_id <werkzeug> <verwalter>
  local w=$1 v=$2
  # AUS DEM HOOK ZUERST -- er ist die genaueste Quelle.
  if [[ -n ${PAKET_AUS_HOOK["$v:$w"]:-} ]]; then
    printf '%s' "${PAKET_AUS_HOOK["$v:$w"]}"; return 0
  fi
  # DANN config/packages.conf.
  # [Damit du Paketnamen ergaenzen kannst, ohne build.sh anzufassen.
  #  Aufbau, eine Zeile je Eintrag:
  #      winget:mpv   = mpv-player.mpv-CI.MSVC
  #      apt:mpv      = mpv
  #  Die eingebaute Tabelle unten bleibt als Rueckfall.]
  if [[ -f config/packages.conf ]]; then
    local zeile schl wert
    while IFS='=' read -r schl wert || [[ -n ${schl:-} ]]; do
      schl=$(trim "${schl:-}"); wert=$(trim "${wert:-}")
      [[ -z $schl || $schl == \#* ]] && continue
      # Doppelpunkt ODER doppelter Doppelpunkt erlaubt.
      schl=${schl//::/:}
      if [[ $schl == "$v:$w" ]]; then printf '%s' "$wert"; return 0; fi
    done < config/packages.conf
  fi
  case $v:$w in
    winget:cmake)  echo "Kitware.CMake" ;;
    winget:ninja)  echo "Ninja-build.Ninja" ;;
    winget:git)    echo "Git.Git" ;;
    winget:gcc|winget:g++|winget:cc)
                   echo "BrechtSanders.WinLibs.POSIX.UCRT" ;;
    apt:cmake)     echo "cmake" ;;
    apt:ninja)     echo "ninja-build" ;;
    apt:git)       echo "git" ;;
    apt:gcc|apt:cc) echo "gcc" ;;
    apt:g++)       echo "g++" ;;
    apt:x86_64-w64-mingw32-gcc) echo "mingw-w64" ;;
    *)             echo "" ;;
  esac
}

# Welcher Paketverwalter steht auf der Gegenseite bereit?
# Wo liegt winget? Der Aufruf braucht unter Umstaenden den vollen Pfad.
# [winget ist eine Store-Anwendung und liegt in
#      %LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe
#  Dieser Ordner steht im BENUTZER-PATH. Der SSH-Dienst laeuft aber als
#  Dienst und hat den MASCHINEN-PATH -- dort fehlt er. "where winget"
#  findet dann nichts, und meine Erkennung gab stillschweigend auf.
#  Deshalb wird zusaetzlich am bekannten Ort nachgesehen.]
WINGET_PFAD=""
finde_winget() {                 # finde_winget <host>
  local h=$1
  WINGET_PFAD=""
  if remote "$h" "where winget" >/dev/null 2>&1; then
    WINGET_PFAD="winget"; return 0
  fi
  local kandidat='%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe'
  if remote "$h" "if exist $kandidat echo DA" 2>/dev/null | grep -q DA; then
    WINGET_PFAD="$kandidat"; return 0
  fi
  return 1
}

# Setzt VERWALTER und WINGET_PFAD -- KEINE Befehlsersetzung benutzen!
# [Als  verw=$(fern_verwalter ...)  gerufen, lief die Funktion in einer
#  Unter-Shell. WINGET_PFAD wurde dort gesetzt und war danach wieder
#  weg -- der Aufruf nahm anschliessend das blosse "winget", also genau
#  den Namen, der nicht auffindbar war. Deshalb wird das Ergebnis jetzt
#  ueber eine Variable zurueckgegeben, nicht ueber die Ausgabe.]
VERWALTER=""
fern_verwalter() {               # fern_verwalter <host>
  local h=$1
  VERWALTER=""
  case ${HOST_OS[$h]:-posix} in
    cmd|gitbash)
      # winget wird von cmd aus gerufen, nicht aus der bash.
      finde_winget "$h" && { VERWALTER=winget; return 0; } ;;
  esac
  fern_hat_werkzeug "$h" apt-get && { VERWALTER=apt; return 0; }
  return 1
}

# Versucht, ein Werkzeug nachzuinstallieren. Rueckgabe 0 = versucht.
fern_installieren() {            # fern_installieren <host> <werkzeug> <verwalter>
  local h=$1 w=$2 v=$3 id
  id=$(paket_id "$w" "$v")
  if [[ -z $id ]]; then
    # OHNE ZUORDNUNG TROTZDEM VERSUCHEN.
    # [Eine feste Tabelle kann nie alles kennen -- mpv, adb, zip, was
    #  auch immer ein Hook braucht. winget und apt finden ein Paket
    #  meist schon unter seinem blossen Namen; das zu probieren kostet
    #  nichts und ist besser, als vorschnell aufzugeben.]
    id=$w
    log "  '$w' nicht in der Zuordnungstabelle -- versuche es unter"
    log "  diesem Namen."
  fi
  case $v in
    winget)
      log "  installiere $w ($id) mit winget..."
      # DREI ANLAEUFE, und immer ueber $WINGET_PFAD.
      # [--scope user vermeidet die Rueckfrage nach erhoehten Rechten,
      #  klappt aber nicht bei jedem Paket. Und nicht jeder Name ist
      #  eine Kennung -- "mpv" findet winget nur ueber die Suche.
      #  $WINGET_PFAD ist der volle Pfad, falls winget nicht im PATH
      #  des SSH-Dienstes liegt.]
      local wg=${WINGET_PFAD:-winget}
      local wopt="--silent --accept-source-agreements"
      wopt="$wopt --accept-package-agreements --disable-interactivity"
      remote "$h" "$wg install --id $id -e --scope user $wopt" \
        || remote "$h" "$wg install --id $id -e $wopt" \
        || remote "$h" "$wg install $id $wopt" \
        || { err "  winget konnte '$id' nicht installieren."
             err "  Such selbst nach dem richtigen Namen:"
             err "      ssh ${HOST_SSH[$h]} \"$wg search $w\""
             return 1; }
      ;;
    apt)
      if (( ! ERLAUBE_SUDO )); then
        err "  '$w' fehlt. Auf Linux wird nicht ohne dein Zutun installiert,"
        err "  weil apt sudo braucht. Entweder von Hand:"
        err "      sudo apt install $id"
        err "  oder mit  --install  erlauben (fragt dann nach dem Passwort)."
        return 1
      fi
      log "  installiere $w ($id) mit apt..."
      remote "$h" "sudo -n apt-get install -y $id" \
        || { err "  apt konnte $id nicht installieren (sudo ohne Passwort?)"
             return 1; }
      ;;
    *) return 1 ;;
  esac
  return 0
}


# ---------------------------------------------------------------------------
# STARTSKRIPT FUER DIE GEGENSEITE
#
# [Bisher wurde drueben build.sh aufgerufen -- 113 KB, die dort komplett
#  geparst werden, Konfigurationen lesen, Felder aufbauen. Deine Messung:
#  4,25 s vergingen, bevor build.sh drueben das erste Wort sagte.
#
#  Fuer eine Ausfuehrung braucht die Gegenseite davon nichts. Sie muss
#  nur: die Bruecke fuer .exe-Namen anlegen, die pre-action-Hooks
#  starten, das Skript ausfuehren und die post-action-Hooks starten.
#  Genau das steht jetzt in einem erzeugten Startskript von wenigen
#  Zeilen -- die steuernde Seite weiss ja bereits, welche Hooks passen.]
# ---------------------------------------------------------------------------
startskript_bauen() {            # startskript_bauen <datei> <ziel> <host>
  local aus=$1 t=$2 h=$3 f
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Von build.sh erzeugt -- nicht von Hand aendern.\n'
    printf 'export XBM_TARGET=%q XBM_HOST=%q XBM_JOBS=%q\n' "$t" "$h" "$JOBS"
    printf 'export XBM_PROJECT_DIR="$PWD" XBM_BUILD_DIR=%q\n' "builds/$t"
    printf 'rc=0\n'
    # Bruecke fuer Werkzeuge, die es nur als .exe gibt.
    printf 'br="$PWD/builds/.werkzeuge"; mkdir -p "$br"\n'
    printf 'for w in %s; do\n' "$(XBM_HOST_JETZT=$h werkzeuge_von "$t" \
              | grep -v '^$' | sort -u | tr '\n' ' ')"
    printf '  command -v "$w" >/dev/null 2>&1 && continue\n'
    printf '  command -v "$w.exe" >/dev/null 2>&1 || continue\n'
    printf '  printf "#!/usr/bin/env bash\\nexec %%s.exe \\"\\$@\\"\\n" "$w" > "$br/$w"\n'
    printf '  chmod +x "$br/$w"\n'
    printf 'done\n'
    printf 'case ":$PATH:" in *":$br:"*) ;; *) export PATH="$br:$PATH";; esac\n'

    # pre-action-Hooks
    local bed
    while IFS='|' read -r bed f; do
      [[ -z $f ]] && continue
      [[ -n $bed ]] && continue      # bei pre-* gibt es noch keinen Ausgang
      printf 'export XBM_PHASE=pre-action XBM_HOOK=%q XBM_STATUS=\n' "$f"
      printf 'echo "  Hook: %s"\n' "$f"
      printf 'bash %q || { echo "  Hook %s fehlgeschlagen" >&2; exit 1; }\n' \
             "$f" "$f"
    done < <(hooks_fuer pre-action "$t" "$h")

    printf 'bash %q; rc=$?\n' "$XBM_EXEC_DATEI"

    # post-action-Hooks -- mit dem Ausgang
    printf 'if (( rc == 0 )); then st=ok; else st=fail; fi\n'
    while IFS='|' read -r bed f; do
      [[ -z $f ]] && continue
      printf 'export XBM_PHASE=post-action XBM_HOOK=%q XBM_STATUS=$st\n' "$f"
      if [[ -n $bed ]]; then
        printf 'if [ "$st" = %q ]; then\n' "$bed"
        printf '  echo "  Hook: %s"; bash %q || rc=1\n' "$f" "$f"
        printf 'fi\n'
      else
        printf 'echo "  Hook: %s"\n' "$f"
        printf 'bash %q || rc=1\n' "$f"
      fi
    done < <(hooks_fuer post-action "$t" "$h")
    printf 'exit $rc\n'
  } > "$aus"
}

# Liefert die passenden Hooks einer Phase, in der richtigen Reihenfolge.
# [Dieselbe Auswahl wie run_hook -- nur ohne sie auszufuehren, damit die
#  steuernde Seite sie ins Startskript schreiben kann. Der Status ist
#  vorher nicht bekannt, deshalb kommen -success und -fail beide mit;
#  entschieden wird drueben anhand von $st.]
hooks_fuer() {                   # hooks_fuer <phase> <ziel> <host>
  local phase=$1 t=$2 h=$3 f basis rang
  local -a tr=()
  shopt -s nullglob
  for f in hooks/*.sh; do
    basis=${f##*/}; basis=${basis%.sh}
    local wann=""
    if   [[ $basis == "$phase"-success* ]]; then wann=ok;   basis=${basis/-success/}
    elif [[ $basis == "$phase"-fail*    ]]; then wann=fail; basis=${basis/-fail/}
    fi
    [[ $basis == "$phase" || $basis == "$phase".* || $basis == "$phase"@* ]] \
      || continue
    hook_gilt_fuer "$f" "$t" "$h" || continue
    rang=0; [[ -n $wann ]] && ((rang++))
    tr+=("${rang}|${wann}|${f}")
  done
  shopt -u nullglob
  (( ${#tr[@]} == 0 )) && return 0
  # Ausgabe:  <bedingung>|<datei>   -- die Bedingung entscheidet drueben.
  printf '%s\n' "${tr[@]}" | sort -t'|' -k1,1n -k3,3 \
    | while IFS='|' read -r _ w2 f2; do printf '%s|%s\n' "$w2" "$f2"; done
}


# ---------------------------------------------------------------------------
# ABBRUCH -- auch auf den Zielmaschinen
#
# [Bricht man hier mit Strg-C ab, endet zunaechst nur das oertliche
#  Skript. Der Bau auf der Gegenseite laeuft WEITER: ssh ohne Terminal
#  schickt beim Verbindungsabbruch kein Signal hinueber, und der
#  ferne Prozess merkt erst etwas, wenn er in eine geschlossene Leitung
#  schreibt -- bei einem langen Bau kann das Minuten dauern.
#
#  Deshalb bekommt jeder Lauf eine Kennung, die als Umgebungsvariable
#  im Fernbefehl steht. An ihr laesst sich der Prozess drueben
#  wiederfinden und beenden.]
# ---------------------------------------------------------------------------
XBM_LAUF_ID="xbmrun$$_$(date +%s 2>/dev/null || echo 0)"
declare -A FERNHOSTS_AKTIV
XBM_JOB_PIDS=()

fern_abbrechen() {               # fern_abbrechen -- auf allen benutzten Hosts
  local h
  local -a helfer=()
  for h in "${!FERNHOSTS_AKTIV[@]}"; do
    [[ $h == local || -z ${HOST_SSH[$h]:-} ]] && continue
    # Best effort, mit kurzer Zeitgrenze -- beim Abbruch will niemand
    # noch zwanzig Sekunden auf eine haengende Verbindung warten.
    local toete="pkill -f $XBM_LAUF_ID 2>/dev/null || "
    toete+="kill \$(ps -e -o pid=,args= 2>/dev/null | grep $XBM_LAUF_ID"
    toete+=" | grep -v grep | awk '{print \$1}') 2>/dev/null || true"
    ( ssh_cmd "$h"
      case ${HOST_OS[$h]:-posix} in
        cmd|gitbash) SSH_ARGV+=("bash -c \"$toete\"") ;;
        wsl)         SSH_ARGV+=("wsl.exe bash -c \"$toete\"") ;;
        *)           SSH_ARGV+=("$toete") ;;
      esac
      timeout 5 "${SSH_ARGV[@]}" >/dev/null 2>&1 ) &
    helfer+=($!)
  done
  # NUR AUF DIE ABBRUCHHELFER WARTEN.
  # [Hier stand  jobs -rp  -- das listet ALLE laufenden Jobs, also auch
  #  die Bauauftraege, die man ja gerade beenden will. Der Handler
  #  wartete deshalb erst einmal drei Sekunden auf sich selbst, und die
  #  oertlichen Prozesse starben entsprechend spaeter. Im Test sah es
  #  aus, als wuerde gar nicht beendet.]
  local hp
  for hp in "${helfer[@]:-}"; do
    [[ -z $hp ]] && continue
    wait "$hp" 2>/dev/null || true
  done
}

aufraeumen() {                   # Handler fuer Strg-C und TERM
  trap '' INT TERM              # ein zweites Strg-C soll nicht stoeren
  cursor_zurueck
  printf '\n' >&2
  err "Abbruch -- beende laufende Auftraege..."

  # 1. Zeichner anhalten
  if [[ -n ${ZEICHNER_PID:-} ]]; then
    [[ -n ${STATUS_DIR:-} ]] && : > "$STATUS_DIR/.stop" 2>/dev/null
    kill "$ZEICHNER_PID" 2>/dev/null || true
    ZEICHNER_PID=""
  fi

  # 2. Auf den Zielmaschinen
  fern_abbrechen

  # 3. Oertlich: JEDEN AUFTRAG MIT SEINEN KINDERN.
  #    [Nur die Unterschale zu beenden reicht nicht -- cmake und ninja
  #     sind deren Kinder und liefen weiter.
  #
  #     Ein  kill 0  waere naheliegend, ist aber gefaehrlich: es trifft
  #     die GANZE Prozessgruppe, und wenn build.sh nicht selbst deren
  #     Anfuehrer ist, gehoert die aufrufende Shell dazu. Beim Testen hat
  #     mir das prompt die Sitzung abgeschossen.
  #
  #     Richtig ist: mit  set -m  bekommt jeder Auftrag seine EIGENE
  #     Prozessgruppe, und  kill -TERM -<pid>  trifft genau die.]
  local pp
  for pp in "${XBM_JOB_PIDS[@]:-}"; do
    [[ -z $pp ]] && continue
    # Das  --  ist entscheidend.
    # [Ohne es liest bash "-832" als OPTION und nicht als
    #  Gruppenkennung. Der Aufruf schlaegt still fehl, der Rueckfall
    #  beendet nur die Unterschale -- und cmake, ninja und alles Weitere
    #  laufen munter weiter. Genau das war im Test zu sehen: der Auftrag
    #  meldete "Terminated", der Enkelprozess lebte.]
    kill -TERM -- "-$pp" 2>/dev/null || kill -TERM -- "$pp" 2>/dev/null || true
  done
  sleep 0.4
  for pp in "${XBM_JOB_PIDS[@]:-}"; do
    [[ -z $pp ]] && continue
    kill -KILL -- "-$pp" 2>/dev/null || kill -KILL -- "$pp" 2>/dev/null || true
  done
  err "beendet."
  trap - INT TERM
  exit 130
}
trap aufraeumen INT TERM

# ---------------------------------------------------------------------------
# Ein Auftrag
# ---------------------------------------------------------------------------
# Gibt es action-Hooks, die auf der Gegenseite laufen muessten?
# [Nur ihretwegen wird drueben build.sh gestartet. Ohne sie genuegt ein
#  einziger Fernaufruf -- und genau der macht bei einer WSL-Gegenstelle
#  den Unterschied: jeder bash-Start dort kostet zwei bis drei Sekunden.]
hat_action_hooks() {             # hat_action_hooks <ziel> <host>
  local t=$1 h=$2 f b
  shopt -s nullglob
  for f in hooks/*.sh; do
    b=${f##*/}
    [[ $b == pre-action* || $b == post-action* ]] || continue
    if hook_gilt_fuer "$f" "$t" "$h"; then shopt -u nullglob; return 0; fi
  done
  shopt -u nullglob
  return 1
}

# ZENTRALE AUSFUEHRUNG von Konfigurations-/Bau-Befehlen -- der EINE Punkt,
# durch den JEDER eval-Aufruf von $conf/$build laeuft. Im Hook-Testmodus
# wird HIER, direkt am Ausfuehrungspunkt, durch den Beispielbefehl
# ersetzt -- unabhaengig davon, was $conf/$build gerade enthalten. Das ist
# robuster als eine fruehe Variablen-Ueberschreibung: es kann keine
# Stelle mehr geben, die versehentlich den echten Bau-Befehl doch noch
# ausfuehrt, weil sie an $conf/$build vorbeigreift.
bau_eval() {                      # bau_eval <phase: konfigurieren|bauen> <urspruenglicher-befehl>
  local phase=$1 orig=$2 rc
  lauf_notiz "${target}@${host}" "$phase" "-" gestartet
  if [[ -z ${HOOKS_ONLY_MODE:-} ]]; then
    eval "$orig"; rc=$?
    (( rc == 0 )) && lauf_notiz "${target}@${host}" "$phase" "-" ok \
                  || lauf_notiz "${target}@${host}" "$phase" "-" fehlgeschlagen
    return $rc
  fi
  local hinweis="[--hooks-only${HOOKS_ONLY_MODE:+-$HOOKS_ONLY_MODE}] ${target}@${host} -- Beispielbefehl statt echtem Bau ($phase)"
  if [[ $HOOKS_ONLY_MODE == fail ]]; then
    eval "echo '$hinweis -- absichtlich fehlschlagend'; false"
    lauf_notiz "${target}@${host}" "$phase" "Beispielbefehl (Hook-Testmodus)" fehlgeschlagen
    return 1
  else
    eval "echo '$hinweis -- erfolgreich'; true"
    lauf_notiz "${target}@${host}" "$phase" "Beispielbefehl (Hook-Testmodus)" ok
    return 0
  fi
}

# RELEASE VON releases.git HERUNTERLADEN -- fuer --run-only: das Ziel wird
# NICHT hier gebaut, sondern das zuletzt VEROEFFENTLICHTE Release (siehe
# publish_release.sh/--publish) wird geholt und an die Stelle gelegt, wo
# es normalerweise nach einem Bau laege (builds/<ordner>/) -- danach kann
# RUN_CMD unveraendert darauf zugreifen, egal ob hier je gebaut wurde.
# RELEASE-NAME EINES ZIELS -- dieselbe Regel wie in publish_release.sh.
# DAS WERKZEUG SELBST ZUR GEGENSEITE SCHICKEN.
# [build.sh und publish_release.sh liegen nicht mehr im Projekt, sondern
#  als eigenes Werkzeug daneben (Commit "publish_release.sh outsourced").
#  Die Gegenseite holt sich das Projekt per git -- und "git reset --hard"
#  hat dort das alte build.sh geloescht, weil es nicht mehr im Repo ist.
#  Danach lief jeder Fernbau ins Leere:
#      windows:      /bin/bash: build.sh: No such file or directory
#      buildserver:  sh: ./build.sh: not found
#  Deshalb schickt die steuernde Seite vor jedem Fernbau IHRE Fassung mit.
#  Nebeneffekt: drueben laeuft immer genau dieselbe Fassung wie hier --
#  nie wieder "Fassung 2 drueben, Fassung 3 hier".
#
#  Dabei wird auch das alte Job-Protokoll drueben geloescht. [Sonst zeigte
#  "Protokoll von dort" nach einem Fehlschlag das Protokoll des VORIGEN
#  Laufs -- mit "Veroeffentlicht" am Ende, obwohl diesmal gar nichts lief.]
xbm_werkzeug_senden() {           # xbm_werkzeug_senden <host> <pfad> <ziel>
  local h=$1 p=$2 t=$3 dir befehl f
  dir=$(xbm_selbst_ordner) || { err "  Werkzeugordner nicht ermittelbar"; return 1; }
  local dateien=()
  for f in build.sh publish_release.sh; do
    [[ -f $dir/$f ]] && dateien+=("$f")
  done
  local altlog="builds/logs/${t}@local.log"
  case ${HOST_OS[$h]:-posix} in
    # chmod +x: publish_release.sh wird ueber den PATH aufgerufen und
    # muss dafuer ausfuehrbar sein -- unabhaengig davon, welche Rechte die
    # Dateien hier hatten.
    cmd) befehl="cd /d $(winpfad "$p") && bash -c \"tar -xzf - && chmod +x ${dateien[*]} && rm -f '$altlog'\"" ;;
    wsl) befehl="bash -c \"cd '$p' && tar -xzf - && chmod +x ${dateien[*]} && rm -f '$altlog'\"" ;;
    *)   befehl="cd '$p' && tar -xzf - && chmod +x ${dateien[*]} && rm -f '$altlog'" ;;
  esac
  if (( DRY_RUN )); then
    log "  [Probelauf] Werkzeug (${dateien[*]}) -> ${h}:$p"
    return 0
  fi
  build_remote_argv "$h" "$befehl"
  if ! tar -C "$dir" -czf - "${dateien[@]}" | "${SSH_ARGV[@]}" >/dev/null 2>&1; then
    err "  Werkzeug (${dateien[*]}) liess sich nicht nach '${h}:$p' uebertragen"
    return 1
  fi
  log "  Werkzeug -> $h: ${dateien[*]} (aus $dir)"
}

xbm_release_name() {              # xbm_release_name <ziel> <ersatz-ordner>
  local w=() i args=()
  read -ra w <<< "${PUBLISH_CMD[$1]:-}"
  for (( i = 0; i < ${#w[@]}; i++ )); do
    if [[ ${w[$i]} == publish_release.sh || ${w[$i]} == */publish_release.sh ]]; then
      args=("${w[@]:i+1}")
      break
    fi
  done
  if (( ${#args[@]} >= 2 )); then
    printf '%s\n' "${args[0]}"
  elif (( ${#args[@]} == 1 )); then
    basename -- "${args[0]%/}"
  else
    basename -- "${2%/}"
  fi
}

xbm_release_herunterladen() {     # xbm_release_herunterladen <ziel>
  local target=$1
  local konfig=config/release.conf
  if [[ ! -f $konfig ]]; then
    err "  --run-only: config/release.conf fehlt (RELEASE_GIT_URL=... setzen)"
    return 1
  fi
  local RELEASE_GIT_URL="" RELEASE_NOTES=""
  # shellcheck disable=SC1090
  source "$konfig"
  if [[ -z $RELEASE_GIT_URL ]]; then
    err "  --run-only: RELEASE_GIT_URL fehlt in $konfig"
    return 1
  fi

  # ZIEL -> (Schluessel in release.json, tatsaechlicher Ordnername unter
  # builds/) -- BEIDES aus config/targets.conf, NICHTS davon fest in
  # build.sh verdrahtet. [build.sh soll unveraendert fuer andere Projekte
  # mit anderen Zielnamen nutzbar bleiben -- ein hier hart einprogram-
  # mierter Name wie "deb" oder "apk" wuerde das verhindern.
  #   RELEASE_NAME[ziel]  -- der Schluessel in release.json, den
  #     publish_release.sh beim Veroeffentlichen dieses Ziels verwendet
  #     hat (siehe dort). MUSS in config/targets.conf gepflegt werden.
  #   DOWNLOAD[ziel]      -- existiert dort ohnehin schon (fuer den
  #     umgekehrten Weg, Dateien NACH einem Bau abzuholen); der Ordner-
  #     Anteil daraus (z.B. "builds/android" aus
  #     ".../builds/android/x_bookmark_manager.apk") ist genau der
  #     Ordner, in den ein heruntergeladenes Release ebenso gehoert.]
  # [RELEASE_NAME[] gibt es nicht mehr: der Release-Name ist der Name des
  #  Bauordners, genau wie publish_release.sh ihn vergibt. Er wird deshalb
  #  aus PUBLISH_CMD[ziel] nach derselben Regel bestimmt:
  #      publish_release.sh builds/deb-asan              -> "deb-asan"
  #      publish_release.sh linux-debug builds/deb-asan  -> "linux-debug"
  #  Ohne PUBLISH_CMD: Ordner aus DOWNLOAD[ziel], sonst builds/<ziel>.]
  local ordner
  if [[ -n ${DOWNLOAD[$target]:-} ]]; then
    ordner=$(dirname "${DOWNLOAD[$target]}")
  else
    ordner="builds/$target"   # Ruecksicht: kein DOWNLOAD[] gepflegt -- ueblicher Ort raten
  fi
  local plattform; plattform=$(xbm_release_name "$target" "$ordner")

  local arbeitsordner; arbeitsordner=$(mktemp -d) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$arbeitsordner'" RETURN

  log "  --run-only: hole Release '$plattform' von $RELEASE_GIT_URL"
  if ! git clone --depth 1 --branch main "$RELEASE_GIT_URL" "$arbeitsordner/releases" -q 2>/dev/null
  then
    err "  --run-only: Releases-Repo nicht erreichbar ($RELEASE_GIT_URL)"
    return 1
  fi
  local manifest="$arbeitsordner/releases/release.json"
  if [[ ! -f $manifest ]]; then
    err "  --run-only: release.json fehlt im Releases-Repo -- schon einmal mit --publish veroeffentlicht?"
    return 1
  fi

  # DATEINAMEN AUS release.json HOLEN -- mit awk statt python3. [FreeBSD
  #  (buildserver) hat oft kein "python3" im PATH; der Aufruf scheiterte
  #  dort mit "command not found", und --run-only meldete dann faelsch-
  #  licherweise "kein Eintrag fuer Plattform ... in release.json",
  #  obwohl der Eintrag sehr wohl vorhanden war. awk ist ueberall da.]
  local dateiname
  dateiname=$(awk -v gesucht="$plattform" '
    # Beginn eines Plattform-Blocks:   "linux": {
    /^[ \t]*"[^"]+"[ \t]*:[ \t]*\{/ {
      z = $0
      sub(/^[ \t]*"/, "", z)
      sub(/"[ \t]*:[ \t]*\{.*$/, "", z)
      drin = (z == gesucht)
      next
    }
    drin && /"url"[ \t]*:/ {
      z = $0
      sub(/^.*"url"[ \t]*:[ \t]*"/, "", z)
      sub(/".*$/, "", z)
      sub(/^.*\//, "", z)     # nur den Dateinamen, ohne Pfad
      print z
      gefunden = 1
      exit
    }
    /^[ \t]*\}/ { drin = 0 }
  ' "$manifest" 2>/dev/null)
  if [[ -z $dateiname ]]; then
    err "  --run-only: kein Eintrag fuer Plattform '$plattform' in release.json"
    return 1
  fi
  if [[ ! -f "$arbeitsordner/releases/$dateiname" ]]; then
    err "  --run-only: '$dateiname' fehlt im Releases-Repo"
    return 1
  fi

  # PRUEFSUMME VERIFIZIEREN, bevor irgendetwas ausgepackt wird -- ein
  # unbemerkt beschaedigtes oder unvollstaendig hochgeladenes Release
  # soll NIE angewendet werden.
  if [[ -f "$arbeitsordner/releases/${dateiname}.sha256" ]]; then
    if ! ( cd "$arbeitsordner/releases" && sha256sum -c "${dateiname}.sha256" ) \
         >/dev/null 2>&1; then
      err "  --run-only: Pruefsumme von '$dateiname' stimmt nicht -- abgebrochen"
      return 1
    fi
  fi

  local ziel="$ordner"
  mkdir -p "$ziel"
  case $dateiname in
    *.tar.gz) tar -xzf "$arbeitsordner/releases/$dateiname" -C "$ziel"
              log "  --run-only: '$dateiname' nach '$ziel/' entpackt" ;;
    *.zip)
      command -v unzip >/dev/null 2>&1 || { err "  --run-only: unzip fehlt"; return 1; }
      ( cd "$ziel" && unzip -oq "$arbeitsordner/releases/$dateiname" )
      log "  --run-only: '$dateiname' nach '$ziel/' entpackt" ;;
    *)
      # EINZELDATEI (z.B. .apk) UNTER DEM NAMEN ABLEGEN, DEN DER BAU
      # ERZEUGEN WUERDE -- nicht unter dem Release-Namen.
      # [publish_release.sh benennt das Paket nach Ziel und Version
      #  ("xbm-android-1.apk"), damit im Releases-Repo mehrere
      #  Plattformen nebeneinander liegen koennen. RUN_CMD erwartet aber
      #  genau die Datei, die ein echter Bau hinterlassen haette --
      #  "builds/android/x_bookmark_manager.apk". Sonst scheitert das
      #  Installieren mit "adb.exe: failed to stat ...: No such file or
      #  directory", obwohl das Herunterladen einwandfrei lief.
      #  Den erwarteten Namen liefert DOWNLOAD[ziel] aus
      #  config/targets.conf -- dieselbe Angabe, aus der weiter oben
      #  schon der Zielordner stammt. Fehlt sie, bleibt es beim
      #  Release-Namen.]
      local wunschname=$dateiname
      if [[ -n ${DOWNLOAD[$target]:-} ]]; then
        wunschname=$(basename "${DOWNLOAD[$target]}")
      fi
      cp "$arbeitsordner/releases/$dateiname" "$ziel/$wunschname"
      if [[ $wunschname == "$dateiname" ]]; then
        log "  --run-only: '$dateiname' nach '$ziel/' gelegt"
      else
        log "  --run-only: '$dateiname' nach '$ziel/$wunschname' gelegt (Name aus DOWNLOAD[$target])"
      fi ;;
  esac
  return 0
}

# RUN_CMD AUSFUEHREN, sofern --run/--run-only aktiv ist.
# RUN_CMD[ziel@host] hat VORRANG vor RUN_CMD[ziel] -- so kann derselbe
# Zielname je nach Host unterschiedlich reagieren (z.B. "apk" ganz normal
# auf dem Bauserver bauen, aber auf "windows" stattdessen ueber
# --run-only installieren/starten, ohne dass "apk" dort ueberhaupt
# gebaut werden koennte).
# <mit_download>: 1 bei --run-only (es gibt ja nichts frisch Gebautes,
# also muss das veroeffentlichte Release erst geholt werden), 0 beim
# normalen --run direkt nach einem hier eben erst erfolgten Bau (dort
# soll das GERADE GEBAUTE laufen, nicht versehentlich ein ggf. aelterer
# veroeffentlichter Stand).
xbm_vielleicht_ausfuehren() {     # xbm_vielleicht_ausfuehren <ziel> <host> <mit_download>
  local target=$1 host=$2 mit_download=${3:-0}
  (( ${XBM_TUE_RUN:-0} )) || return 0
  if [[ -n $HOOKS_ONLY_MODE ]]; then
    log "  [Hook-Testmodus] --run uebersprungen -- es wurde ja gar nicht wirklich gebaut"
    return 0
  fi
  # AUF DER ZIELMASCHINE GILT DER URSPRUENGLICHE HOSTNAME. [Der rekursive
  #  Fernaufruf lautet "--target apk@local" -- drueben heisst der Host
  #  also "local", und die Suche ging nach RUN_CMD[apk@local]. In
  #  config/targets.conf steht aber RUN_CMD[apk@windows], unter dem
  #  Namen, unter dem der Auftrag ANGESTOSSEN wurde. Der steht in
  #  AS_HOST; run_hook nutzt ihn aus genau demselben Grund schon so.
  #  Ohne das fand --run-only apk@windows nichts, lud nichts herunter --
  #  und meldete trotzdem "OK", weil ein fehlender Eintrag nur eine
  #  Warnung war.]
  [[ -n ${AS_HOST:-} ]] && host=$AS_HOST
  local befehl=${RUN_CMD["${target}@${host}"]:-${RUN_CMD[$target]:-}}
  if [[ -z $befehl ]]; then
    if (( ${XBM_TUE_RUN_ONLY:-0} )); then
      # Bei --run-only ist das Ausfuehren der EINZIGE Zweck des Auftrags
      # -- ohne RUN_CMD gibt es nichts zu tun, das ist ein Fehler und
      # kein "erledigt".
      err "  --run-only: weder RUN_CMD[${target}@${host}] noch RUN_CMD[$target] ist in config/targets.conf eingetragen"
      return 1
    fi
    warn "  --run gesetzt, aber weder RUN_CMD[${target}@${host}] noch RUN_CMD[$target] ist in config/targets.conf eingetragen"
    return 0
  fi
  if (( mit_download )) && ! xbm_release_herunterladen "$target"; then
    err "  --run: Release konnte nicht heruntergeladen werden -- RUN_CMD wird nicht ausgefuehrt"
    return 1
  fi
  log "  Starte: $befehl"
  lauf_notiz "${target}@${host}" run "-" gestartet
  if eval "$befehl"; then
    lauf_notiz "${target}@${host}" run "-" ok
    return 0
  else
    lauf_notiz "${target}@${host}" run "-" fehlgeschlagen
    return 1
  fi
}

# SUBMODULE NOTFALLS REPARIEREN -- LAEUFT AUF DER MASCHINE, DIE BAUT.
#
# [Bewusst HIER und nicht in der Sync-Befehlszeile. Auf windows wurde die
#  Submodul-Behandlung aus dem Sync-Befehl nachweislich NIE ausgefuehrt:
#  dort erschien ueber mehrere Laeufe hinweg keine einzige Submodul-Zeile
#  im Protokoll, weder Erfolg noch Fehler noch Warnung -- offenbar landet
#  die Sync-Zeile dort in einer anderen Shell als der Bau (der Bau meldet
#  /mnt/c/...-Pfade, laeuft also in WSL). Statt weiter an der
#  Sync-Befehlszeile zu raten, sitzt die Reparatur jetzt an der Stelle,
#  die auf JEDER Maschine garantiert durchlaufen wird: unmittelbar vor
#  dem Konfigurieren, im richtigen Arbeitsverzeichnis, in derselben
#  Shell, die auch baut.
#
#  Zwei Schadensbilder werden behandelt:
#   (a) Der Submodul-Ordner ist LEER oder fehlt -> holen.
#   (b) Der Ordner enthaelt ein .git, aber sonst NICHTS. Das entsteht,
#       weil Git ein Submodul intern mit "--no-checkout" klont und den
#       eingetragenen Commit erst danach auscheckt; fehlt dieser Commit
#       im flachen Klon ("Server does not allow request for unadvertised
#       object"), scheitert NUR der zweite Schritt -- der Klon gilt als
#       erfolgreich, und "git submodule update" ruehrt den Ordner nie
#       wieder an. Dann wird das Auschecken hier nachgeholt.]
xbm_submodule_reparieren() {
  [[ -f .gitmodules ]] || return 0
  command -v git >/dev/null 2>&1 || return 0

  local pfad inhalt
  while IFS= read -r pfad; do
    [[ -z $pfad ]] && continue
    inhalt=$(ls -A "$pfad" 2>/dev/null | grep -v '^\.git$')
    [[ -n $inhalt ]] && continue          # befuellt -- nichts zu tun

    if [[ -e "$pfad/.git" ]]; then
      log "  Submodul '$pfad': Repository da, aber Arbeitsbaum leer -- hole Auschecken nach"
      ( cd "$pfad" && { git checkout -f HEAD ||
                        git reset --hard ||
                        git checkout -f origin/HEAD ||
                        git checkout -f main ; } ) >/dev/null 2>&1 || true
    else
      log "  Submodul '$pfad': fehlt -- wird geholt"
      git submodule update --init --recursive --depth 1 -- "$pfad" >/dev/null 2>&1 ||
        git submodule update --init --recursive --remote -- "$pfad" >/dev/null 2>&1 || true
      # Auch nach dem Holen kann der Arbeitsbaum leer bleiben (Fall b).
      if [[ -e "$pfad/.git" ]] &&
         [[ -z $(ls -A "$pfad" 2>/dev/null | grep -v '^\.git$') ]]; then
        ( cd "$pfad" && { git checkout -f HEAD ||
                          git reset --hard ||
                          git checkout -f origin/HEAD ||
                          git checkout -f main ; } ) >/dev/null 2>&1 || true
      fi
    fi

    if [[ -z $(ls -A "$pfad" 2>/dev/null | grep -v '^\.git$') ]]; then
      # LETZTE STUFE: DIREKT KLONEN. [Steht der Verweis im Hauptprojekt
      #  nicht sauber im Index, tut "git submodule update" schlicht gar
      #  nichts -- kein Fehler, aber auch kein Inhalt. Die URL steht
      #  aber in .gitmodules; damit laesst sich der Ordner direkt
      #  befuellen. Fuer den Bau zaehlt nur, DASS die Quellen da sind.]
      local sm_url
      sm_url=$(git config -f .gitmodules --get "submodule.$pfad.url" 2>/dev/null)
      if [[ -n $sm_url ]]; then
        log "  Submodul '$pfad': letzter Versuch -- klone direkt von $sm_url"
        rm -rf "$pfad"
        git clone --depth 1 "$sm_url" "$pfad" >/dev/null 2>&1 || true
      fi
    fi

    if [[ -z $(ls -A "$pfad" 2>/dev/null | grep -v '^\.git$') ]]; then
      warn "  Submodul '$pfad' ist WEITERHIN leer -- der Bau wird daran scheitern."
      warn "    Dauerhafte Abhilfe (auf dem Rechner mit vollstaendigem $pfad):"
      warn "      cd $pfad && git fetch origin && git checkout origin/main"
      warn "      cd - && git add $pfad && git commit -m 'Verweis' && git push"
    else
      log "  Submodul '$pfad': Dateien sind jetzt vorhanden."
    fi
  done < <(sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' .gitmodules 2>/dev/null)
  return 0
}

do_one() {                       # do_one <ziel> <host> [ist_exec]
  local target=$1 host=$2

  # ABHAENGIGKEIT GESCHEITERT -- GAR NICHT ERST ANFANGEN.
  # [Gesetzt von der Startschleife, wenn dieser --run-only-Auftrag auf
  #  einen Bau/eine Veroeffentlichung DESSELBEN Ziels gewartet hat und
  #  die fehlgeschlagen ist. Weiterzumachen hiesse: das ALTE, noch im
  #  Releases-Repo liegende Paket herunterladen und aufspielen -- mit
  #  "OK" im Protokoll, aber der vorigen Fassung auf dem Geraet.]
  if [[ -n ${XBM_DEP_FEHLER:-} ]]; then
    err "  uebersprungen: '${XBM_DEP_FEHLER}' ist fehlgeschlagen --"
    err "    es gibt keinen frischen Stand zum Aufspielen. (Sonst waere"
    err "    hier klaglos das vorige Release installiert worden.)"
    lauf_notiz "${target}@${host}" job "-" "uebersprungen (${XBM_DEP_FEHLER} fehlgeschlagen)"
    return 1
  fi

  # --run-only: WEDER SYNCHRONISIEREN NOCH BAUEN -- nur das zuletzt
  # veroeffentlichte Release herunterladen und RUN_CMD ausfuehren. [Gedacht
  # fuer einen Rechner, auf dem das Ziel gar nicht gebaut werden KANN oder
  # SOLL (z.B. "apk" auf windows -- ./build_apk.sh gibt es dort nicht),
  # aber wo die fertige Datei installiert/gestartet werden soll -- z.B.
  # das APK vom Bauserver kommt, aber Handy+adb haengen an windows.]
  #
  # NUR AUF DER ZIELMASCHINE SELBST ABKUERZEN. [Hier stand die Abkuerzung
  #  vorher UNBEDINGT, also auch fuer "apk@windows" -- dann lief aber
  #  alles auf der STEUERNDEN Maschine: das Release wurde nach dem
  #  oertlichen builds/android/ entpackt und RUN_CMD dort ausgefuehrt.
  #  Im Protokoll sah man das an "whoami -> user" (der Linux-Benutzer,
  #  nicht "win"), "cd: C:/Users/win/Desktop/x/: No such file or
  #  directory" und "adb: command not found" -- das Handy haengt ja an
  #  windows, nicht hier. Richtig ist: bei einem ENTFERNTEN Host ganz
  #  normal weiterleiten (weiter unten), der Fernaufruf bekommt
  #  --run-only mitgereicht (siehe flags) und kuerzt DORT ab, wo er
  #  sich selbst als "local" sieht. Genau dort liegt dann auch das
  #  heruntergeladene Release.]
  local rs_lokal=0
  [[ $host == local ]] && rs_lokal=1
  [[ -n ${HOST_SSH[$host]+x} && -z ${HOST_SSH[$host]} ]] && rs_lokal=1
  [[ -n ${AS_HOST:-} ]] && rs_lokal=1     # wir SIND bereits die Zielmaschine
  if (( ${XBM_TUE_RUN_ONLY:-0} )) && (( rs_lokal )); then
    lauf_notiz "${target}@${host}" job "-" gestartet
    if xbm_vielleicht_ausfuehren "$target" "$host" 1; then
      lauf_notiz "${target}@${host}" job "-" ok
      return 0
    else
      lauf_notiz "${target}@${host}" job "-" fehlgeschlagen
      return 1
    fi
  fi

  local IST_EXEC=${3:-0}
  local eval_rc=0
  # --exec: DER BEFEHL KOMMT AUS DER BEFEHLSZEILE, nicht aus targets.conf.
  # [Er wird in eine Datei im Projekt geschrieben. Das erspart jede
  #  Zitiererei: die Datei geht mit der normalen Uebertragung hinueber
  #  und wird drueben mit  bash <datei>  gestartet -- kein cd, kein &&,
  #  keine Anfuehrungszeichen, die cmd.exe oder ssh zerlegen koennten.]
  if (( IST_EXEC )) && (( ! EXEC_VORHANDEN )); then
    if [[ -n $CMD_NAME ]]; then
      # DIE ZUM ZIEL PASSENDE FASSUNG WAEHLEN.
      local cq
      if ! cq=$(cmd_datei "$CMD_NAME" "$host"); then
        err "Fuer '$CMD_NAME' gibt es keine Fassung fuer '$host'"
        err "  ($(plattform_von "$host")). Erwartet wird eine dieser Dateien:"
        err "      cmds/$CMD_NAME/$(plattform_von "$host").sh"
        err "      cmds/$CMD_NAME/$(plattform_von "$host").ps1"
        err "      cmds/$CMD_NAME/default.sh"
        return 1
      fi
      log "  Befehl '$CMD_NAME' -> $cq"
      cmd_skript_bauen "$cq" "$XBM_EXEC_DATEI" "${CMD_ARGS[@]}"
      # Die .ps1 muss mit hinueber -- der Wrapper ruft sie beim Namen.
      [[ $cq == *.ps1 ]] && cp -f "$cq" "./${cq##*/}"
    else
      printf '%s\n' "$EXEC_CMD" > "$XBM_EXEC_DATEI"
    fi
    chmod +x "$XBM_EXEC_DATEI" 2>/dev/null || true
  fi
  local conf=${CONF_CMD[$target]-}
  local build=${BUILD_CMD[$target]-}
  # Bei --exec gibt es keine Bau-Befehle -- also auch nichts zu pruefen.
  if (( ! EXEC_MODE )) && (( ! SYNC_ONLY )) && [[ -z $conf || -z $build ]]; then
    err "unbekanntes Ziel '$target' (siehe config/targets.conf)"; return 1
  fi
  # Ein Host ist OERTLICH, wenn er "local" heisst oder kein
  # benutzer@host hat. [Sonst muesste man denselben Rechner je nach
  # Schreibweise unterschiedlich behandeln.]
  local ist_lokal=0
  [[ $host == local ]] && ist_lokal=1
  [[ -n ${HOST_SSH[$host]+x} && -z ${HOST_SSH[$host]} ]] && ist_lokal=1
  if (( ! ist_lokal )) && [[ -z ${HOST_SSH[$host]:-} ]]; then
    err "unbekannter Host '$host' (siehe config/hosts.conf)"; return 1
  fi
  conf=${conf//\$\{JOBS\}/$JOBS}
  build=${build//\$\{JOBS\}/$JOBS}

  # HOOK-TESTMODUS: statt zu konfigurieren/zu bauen, laeuft ein
  # Beispielbefehl, der meldet, fuer welches Ziel@Host er steht und durch
  # welchen Schalter er ausgeloest wurde. [Hier eingesetzt, GLEICH NACH
  # der ${JOBS}-Ersetzung -- das ist der EINE Punkt, durch den sowohl der
  # oertliche als auch der ferne Zweig laufen, bevor sich die beiden
  # Wege trennen. So muss nicht jede einzelne eval-/remote-Stelle
  # weiter unten einzeln abgesichert werden.]
  if [[ -n $HOOKS_ONLY_MODE ]]; then
    local hinweis="[--hooks-only${HOOKS_ONLY_MODE:+-$HOOKS_ONLY_MODE}] ${target}@${host} -- Beispielbefehl statt echtem Bau"
    if [[ $HOOKS_ONLY_MODE == fail ]]; then
      conf="echo '$hinweis (konfigurieren, absichtlich fehlschlagend)'; false"
      build="echo '$hinweis (bauen, absichtlich fehlschlagend)'; false"
    else
      conf="echo '$hinweis (konfigurieren, erfolgreich)'; true"
      build="echo '$hinweis (bauen, erfolgreich)'; true"
    fi
  fi

  local hname_j=${AS_HOST:-$host}
  if (( SYNC_ONLY )) && (( ist_lokal )); then
    # [Ein oertlicher Host ist das Projekt selbst -- da gibt es nichts
    #  zu uebertragen. Das zu sagen ist ehrlicher, als still Erfolg zu
    #  melden.]
    log "  '$host' ist diese Maschine -- nichts zu uebertragen"
    return 0
  fi
  if (( ist_lokal )); then
    # Fuer einen exec-Auftrag gibt es nichts zu bauen -- also auch
    # keinen Bauordner. [Sonst blieb ein leeres builds/ausfuehren/
    # zurueck.]
    (( IST_EXEC )) || mkdir -p "builds/${target}"
    # pre-job/post-job gehoeren auf den STEUERNDEN Rechner.
    # [Auf der Zielmaschine laeuft build.sh ebenfalls im oertlichen Zweig
    #  -- ohne diese Unterscheidung liefen die job-Hooks also ZWEIMAL:
    #  einmal drueben und einmal hier. Ein "APK aufs Geraet spielen"
    #  waere auf dem Bauserver ausgefuehrt worden, wo gar kein Geraet
    #  haengt. AS_HOST ist genau dann gesetzt, wenn wir die Gegenseite
    #  sind.]
    if [[ -z ${AS_HOST:-} ]]; then
      run_hook pre-job "$target" "$host" || {
        err "  pre-job-Hook fehlgeschlagen"; return 1; }
    fi
    # Bei --exec gibt es keine Bau-Befehle -- nur der Bedarf der Hooks
    # zaehlt, und den prueft werkzeuge_pruefen ohnehin mit.
    (( SKIP_TOOLCHECK )) || werkzeuge_pruefen "$target" "$host" || return 1
    # NACH der Pruefung neu einlesen.
    # [werkzeuge_pruefen ersetzt in CONF_CMD/BUILD_CMD gegebenenfalls
    #  "cmake" durch "cmake.exe". conf und build wurden aber schon
    #  VORHER aus den Feldern kopiert -- die Ersetzung waere also
    #  wirkungslos gewesen, und es lief weiter der Name, den es nicht
    #  gibt.]
    conf=${CONF_CMD[$target]-};  conf=${conf//\$\{JOBS\}/$JOBS}
    build=${BUILD_CMD[$target]-}; build=${build//\$\{JOBS\}/$JOBS}
    # SUBMODULE PRUEFEN, BEVOR CMAKE SIE VERMISST. [Ein leeres
    # external/pdf laesst CMake mit "does not contain a CMakeLists.txt
    # file" abbrechen -- hier laesst sich das noch geradeziehen, und
    # zwar auf der Maschine, die gleich baut. Kostet nichts, wenn alles
    # in Ordnung ist: dann wird nur kurz nachgesehen.]
    (( IST_EXEC )) || xbm_submodule_reparieren
    # ZEITPUNKT VOR DEM BAU MERKEN -- fuer die Frische-Pruefung beim
    # Veroeffentlichen (siehe unten und publish_release.sh).
    local bau_beginn; bau_beginn=$(date +%s)
    # Denselben Beispielbefehl HIER ERNEUT einsetzen -- sonst wuerde ihn
    # das Neueinlesen der echten Konfiguration gerade wieder ueberschreiben.
    if [[ -n $HOOKS_ONLY_MODE ]]; then
      local hinweis2="[--hooks-only${HOOKS_ONLY_MODE:+-$HOOKS_ONLY_MODE}] ${target}@${host} -- Beispielbefehl statt echtem Bau"
      if [[ $HOOKS_ONLY_MODE == fail ]]; then
        conf="echo '$hinweis2 (konfigurieren, absichtlich fehlschlagend)'; false"
        build="echo '$hinweis2 (bauen, absichtlich fehlschlagend)'; false"
      else
        conf="echo '$hinweis2 (konfigurieren, erfolgreich)'; true"
        build="echo '$hinweis2 (bauen, erfolgreich)'; true"
      fi
    fi
    run_hook pre-action "$target" "$host" || {
      err "  pre-action-Hook fehlgeschlagen -- Bau nicht gestartet"; return 1; }
    if (( CLEAN )); then
      # [Der alte Aufruf brach unter set -e ab, wenn es noch keinen
      #  CMakeCache gab. Deshalb bedingt und mit || true.]
      [[ -f "builds/${target}/CMakeCache.txt" ]] &&
        cmake --build "builds/${target}" --target clean 2>/dev/null || true
    fi
    (( CLEANDEEP )) && rm -rf "builds/${target}"
    if (( IST_EXEC )); then
      if (( DRY_RUN )); then
        echo "  [Probelauf] bash $XBM_EXEC_DATEI"; eval_rc=0
      else
        bash "$XBM_EXEC_DATEI" 2>&1 | bau_fortschritt "${target}@${hname_j}  ausfuehren"
        eval_rc=${PIPESTATUS[0]}
      fi
    elif (( CONFIGURE_ONLY )); then
      if (( DRY_RUN )); then echo "  [Probelauf] $conf"; eval_rc=0
      else
        bau_eval konfigurieren "$conf" 2>&1 | bau_fortschritt "${target}@${host}  konfigurieren"
        eval_rc=${PIPESTATUS[0]}
      fi
    elif (( BUILD_ONLY )); then
      if (( DRY_RUN )); then echo "  [Probelauf] $build"; eval_rc=0
      else
        quellen_auffrischen "builds/${target}"   # Zeitstempel-Falle
        bau_eval bauen "$build" 2>&1 | bau_fortschritt "${target}@${host}  bauen"
        eval_rc=${PIPESTATUS[0]}
      fi
    else
      # WANN MUSS KONFIGURIERT WERDEN?
      # [Bisher galt: nur wenn CMakeCache.txt fehlt. Das reicht nicht --
      #  ein GESCHEITERTER Konfigurationslauf hinterlaesst die Datei
      #  trotzdem. Nach dem Fehlschlag "No CMAKE_C_COMPILER" lag also
      #  ein CMakeCache.txt da, aber keine build.ninja. Beim naechsten
      #  Lauf wurde die Konfiguration uebersprungen und gleich gebaut:
      #      ninja: error: loading 'build.ninja': GetLastError() = 2
      #  (Fehler 2 = Datei nicht gefunden.)
      #
      #  Deshalb wird zusaetzlich geprueft, ob die Datei des Generators
      #  da ist. Fehlt sie, ist der Ordner halb fertig -- und ein
      #  halber Cache ist schlimmer als keiner: er merkt sich unter
      #  anderem CMAKE_C_COMPILER-NOTFOUND und laesst sich davon auch
      #  durch einen neuen Anlauf nicht abbringen. Also weg damit.]
      local bdir="builds/${target}"
      local muss_konf=0
      [[ -f "$bdir/CMakeCache.txt" ]] || muss_konf=1
      if [[ -f "$bdir/CMakeCache.txt" ]] \
         && [[ ! -f "$bdir/build.ninja" && ! -f "$bdir/Makefile" \
               && ! -f "$bdir/build.xcodeproj" ]]; then
        log "  '$bdir' ist halb konfiguriert (Cache ohne Generatordatei)"
        log "  -- Cache wird verworfen und neu konfiguriert."
        rm -f  "$bdir/CMakeCache.txt"
        rm -rf "$bdir/CMakeFiles"
        muss_konf=1
      fi
      if (( muss_konf )); then
        if (( DRY_RUN )); then echo "  [Probelauf] $conf"
        else
          # ANZEIGE AUCH BEIM KONFIGURIEREN.
          # [In deinem Log dauerte er von 10:47:40 bis 10:48:36 -- fast
          #  eine Minute, in der die Statuszeile leer blieb, weil nur der
          #  BAU durch den Fortschrittsfilter lief. Genau das meintest du
          #  mit "nicht alle Prozentanzeigen".]
          if ! { bau_eval konfigurieren "$conf" 2>&1 \
                   | bau_fortschritt "${target}@${host}  konfigurieren"
                 (( ${PIPESTATUS[0]} == 0 )); }; then
            # NACH EINEM FEHLSCHLAG GLEICH AUFRAEUMEN.
            # [Sonst bleibt ein CMakeCache.txt ohne Generatordatei
            #  liegen. Der naechste Lauf raeumt es zwar auf -- aber erst
            #  nachdem er den halben Cache gefunden hat. Direkt hier zu
            #  loeschen spart diesen Umweg und verhindert, dass sich
            #  Werte wie CURL_LIBRARY-NOTFOUND festsetzen: cmake merkt
            #  sich auch das GESCHEITERTE Suchen und probiert es beim
            #  naechsten Mal gar nicht erneut.]
            log "  Konfiguration fehlgeschlagen -- '$bdir' wird geraeumt,"
            log "  damit der naechste Lauf frisch beginnt."
            rm -f  "$bdir/CMakeCache.txt"
            rm -rf "$bdir/CMakeFiles"
            run_hook post-action "$target" "$host" fail || true
            return 1
          fi
        fi
      fi
      if (( DRY_RUN )); then echo "  [Probelauf] $build"; eval_rc=0
      else
        local baulog; baulog=$(xtmp) || return 1
        # NUR DIE LETZTEN ZEILEN AUFHEBEN.
        # [Gebraucht wird der Ausgang nur, um "unknown build rule" und
        #  Aehnliches zu erkennen -- und das steht am Ende. Vorher lief
        #  der GANZE Bauausgang in die Datei; auf einer RAM-Platte ist
        #  das der sichere Weg in "no space left on device".]
        quellen_auffrischen "builds/${target}"   # Zeitstempel-Falle
        bau_eval bauen "$build" 2>&1 | tee >(tail -n 300 > "$baulog") \
          | bau_fortschritt "${target}@${host}  bauen"
        eval_rc=${PIPESTATUS[0]}

        # SICHERHEITSNETZ: DEM RUECKGABEWERT NICHT BLIND TRAUEN.
        # [apk@buildserver meldete OK, obwohl im Ausgang stand:
        #      ninja: build stopped: subcommand failed.
        #  build_apk.sh leitet seine Ausgabe durch eine Pipe, die Zeilen
        #  stempelt -- und ohne  set -o pipefail  zaehlt in einer Pipe nur
        #  der LETZTE Befehl. Der Stempler meldet 0, der Fehler ist weg.
        #  Ein "Erfolg", in dessen Ausgabe der Bau selbst seinen Abbruch
        #  meldet, ist keiner. Diese Marken sind eindeutig; keine davon
        #  taucht in einem gelungenen Bau auf.]
        # Marken IRGENDWO in der Zeile -- build_apk.sh stellt jeder Zeile
        # "build@build build_apk.sh {Zeit}" voran, ein ^ verfehlt sie.
        local abbruchmuster='(ninja: build stopped|ninja: error:|(^|[^a-zA-Z_])FAILED: |g?make(\[[0-9]+\])?: \*\*\* )'
        if (( eval_rc == 0 )) && [[ -s $baulog ]] \
           && grep -qE "$abbruchmuster" "$baulog" 2>/dev/null; then
          err "  Rueckgabewert 0, aber der Ausgang meldet einen Abbruch:"
          grep -E "$abbruchmuster" "$baulog" | head -3 | cut -c1-140 \
            | sed 's/^/      /' >&2
          err "  -- der Baubefehl verschluckt den Fehler (Pipe ohne pipefail?)."
          err "     Als FEHLER gewertet."
          eval_rc=1
        fi

        # ZWEITE STUFE: WARNUNGEN, DIE DAS ERGEBNIS UNBRAUCHBAR MACHEN.
        # [Aus deinem apk-Log:
        #      WARNUNG: Paket 'build-tools;34.0.0' konnte nicht installiert werden
        #      WARNUNG: Paket 'platform-tools' konnte nicht installiert werden
        #  Danach lief der Bau weiter und meldete "FERTIG" -- das APK
        #  entstand, aber ohne die Werkzeuge, die es signieren und
        #  ausrichten. Ein Bau, der OK sagt und ein unbrauchbares Ergebnis
        #  liefert, ist schlimmer als einer, der abbricht. Diese Meldungen
        #  gelten deshalb ebenfalls als Fehlschlag; wer sie hinnehmen will,
        #  setzt XBM_WARN_OK=1.]
        # [ERST EIN FEHLALARM GEWESEN, JETZT GENAUER.
        #  Die Fassung davor wertete jedes "konnte nicht installiert
        #  werden" als Fehlschlag. In deinem Log stand das zweimal -- und
        #  danach:
        #      ==> d8: java -cp .../build-tools/34.0.0/lib/d8.jar
        #      ==> OK: classes.dex im APK
        #      FERTIG: .../x_bookmark_manager.apk
        #  Die Werkzeuge WAREN also da; der sdkmanager wollte sie nur
        #  erneut pruefen und brach bei 10 % ab (kein Netz auf dem
        #  Bauserver). Harmlos.
        #
        #  Die Meldung beschreibt einen VERSUCH, nicht das Ergebnis.
        #  Richtig ist, das Ergebnis zu pruefen: build_apk.sh schreibt bei
        #  Erfolg selbst "FERTIG: <pfad>". Fehlt das, ist die Warnung
        #  ernst; steht es da, war sie Laerm.]
        if (( eval_rc == 0 )) && [[ -s $baulog && ${XBM_WARN_OK:-0} != 1 ]] \
           && grep -qE 'konnte nicht installiert werden|INSTALL_FAILED|Failed to install' \
              "$baulog" 2>/dev/null \
           && ! grep -qE '(FERTIG:|Linking CXX (executable|shared library))' \
                "$baulog" 2>/dev/null; then
          err "  Der Bau meldet Erfolg, aber Werkzeuge fehlten UND es"
          err "  entstand kein Ergebnis:"
          grep -E 'konnte nicht installiert werden|INSTALL_FAILED|Failed to install' \
            "$baulog" | head -3 | cut -c1-140 | sed 's/^/      /' >&2
          err "  -- als FEHLER gewertet. Hinnehmen: XBM_WARN_OK=1 ./build.sh ..."
          eval_rc=1
        elif [[ -s $baulog ]] \
             && grep -qE 'konnte nicht installiert werden' "$baulog" 2>/dev/null; then
          # Ergebnis ist da -- nur als Hinweis, nicht als Fehler.
          warn "  SDK-Pakete liessen sich nicht pruefen (Netz auf dem Bauserver?)."
          warn "  Das Ergebnis entstand trotzdem -- die Pakete lagen schon vor."
        fi

        # SELBSTHEILUNG BEI EINEM UNBRAUCHBAREN BAUORDNER.
        # [Aus deinem Log:
        #      ninja: error: build.ninja:660: unknown build rule
        #             'CXX_SHARED_LIBRARY_LINKER__ggml-base_Release'
        #  Die build.ninja verweist auf eine Regel, die es nicht mehr
        #  gibt. Das passiert, wenn sich der Bibliothekstyp aendert --
        #  genau das hat CMAKE_POSITION_INDEPENDENT_CODE bewirkt.
        #
        #  Der bisherige Erkenner sucht eine FEHLENDE Generatordatei.
        #  Hier ist sie da, nur unbrauchbar -- also muss der INHALT der
        #  Meldung entscheiden. Einmal raeumen, einmal neu versuchen;
        #  scheitert es wieder, liegt es an etwas anderem, und dann soll
        #  das Skript auch nicht endlos weiterprobieren.]
        if (( eval_rc != 0 )) && grep -qE \
             "unknown build rule|build\.ninja:[0-9]+: error|manifest .* not found|does not match the generator|CMakeCache\.txt.*directory" \
             "$baulog" 2>/dev/null; then
          log "  '$bdir' ist unbrauchbar geworden (Regeln passen nicht mehr)."
          log "  -- wird geraeumt und EINMAL neu versucht."
          rm -rf "$bdir"; mkdir -p "$bdir"
          if bau_eval konfigurieren "$conf" 2>&1 | bau_fortschritt "${target}@${host}  konfigurieren"
          then
            quellen_auffrischen "builds/${target}"   # Zeitstempel-Falle
            bau_eval bauen "$build" 2>&1 | bau_fortschritt "${target}@${host}  bauen"
            eval_rc=${PIPESTATUS[0]}
          else
            eval_rc=1
          fi
        fi
        rm -f "$baulog"
      fi
    fi
    local st=ok; (( ${eval_rc:-0} != 0 )) && st=fail
    run_hook post-action "$target" "$host" "$st" || {
      err "  post-action-Hook fehlgeschlagen"; return 1; }
    # --publish: NACH ERFOLGREICHEM BAU PUBLISH_CMD[ziel] AUSFUEHREN --
    # unabhaengig/SEPARAT von --run, wie gewuenscht. Laeuft VOR --run,
    # damit ein direkt anschliessendes --run-only auf einem anderen Host
    # (siehe unten) das GERADE veroeffentlichte Release schon vorfindet,
    # falls beides in ein und demselben Aufruf gemeint war.
    if (( ${XBM_TUE_PUBLISH:-0} )) && [[ $st == ok ]]; then
      if [[ -n $HOOKS_ONLY_MODE ]]; then
        log "  [Hook-Testmodus] --publish uebersprungen -- es wurde ja gar nicht wirklich gebaut"
      elif [[ -n ${PUBLISH_CMD[$target]:-} ]]; then
        log "  Veroeffentliche: ${PUBLISH_CMD[$target]}"
        lauf_notiz "${target}@${host}" publish "-" gestartet
        # XBM_TARGET steht Hooks und eigenen Skripten zur Verfuegung.
        # (publish_release.sh braucht es nicht mehr: der Release-Name ist
        # der Name des Bauordners.)
        if XBM_TARGET="$target" XBM_BAU_BEGINN="${bau_beginn:-0}" \
           eval "${PUBLISH_CMD[$target]}"; then
          lauf_notiz "${target}@${host}" publish "-" ok
        else
          lauf_notiz "${target}@${host}" publish "-" fehlgeschlagen
          err "  PUBLISH_CMD[$target] fehlgeschlagen"
          # AUFTRAG GILT DANN ALS FEHLGESCHLAGEN. [Vorher blieb st=ok: das
          #  Protokoll zeigte "OK", obwohl nichts veroeffentlicht war --
          #  release.json kannte das Ziel nicht, und niemand sah warum
          #  (so bei exe@windows mit "zip fehlt"). Wer --publish verlangt,
          #  hat das Veroeffentlichen als Ziel; ohne es ist der Auftrag
          #  nicht erledigt. "fail" ist der Wert, den der uebrige Code
          #  fuer st kennt; der Rueckgabewert des Auftrags kommt aus
          #  eval_rc -- beides muss gesetzt werden, sonst meldet die
          #  Uebersicht weiter "OK".]
          st=fail
          eval_rc=1
        fi
      else
        warn "  --publish gesetzt, aber PUBLISH_CMD[$target] ist in config/targets.conf nicht eingetragen"
      fi
    fi
    # --run: NACH ERFOLGREICHEM BAU RUN_CMD[ziel] STARTEN -- direkt das
    # GERADE GEBAUTE (kein Herunterladen, siehe xbm_vielleicht_ausfuehren).
    # [Hier, VOR der AS_HOST-Pruefung, damit es sowohl fuer einen wirklich
    # oertlichen Auftrag (deb@local) als auch fuer den rekursiven
    # Fernaufruf greift, der sich selbst als "lokal" behandelt
    # (exe@windows -- AS_HOST ist dort gesetzt, genau deshalb laeuft
    # post-job weiter unten fuer diesen Zweig NICHT -- das Starten soll
    # aber trotzdem auf der Zielmaschine passieren, nicht nur beim
    # wirklich oertlichen Bau).]
    if [[ $st == ok ]]; then
      xbm_vielleicht_ausfuehren "$target" "$host" 0
    fi
    if [[ -z ${AS_HOST:-} ]]; then
      # Bei einem oertlichen Auftrag gibt es kein Uebertragen -- post-job
      # laeuft trotzdem, damit derselbe Hook fuer local und remote taugt.
      run_hook post-job "$target" "$host" "$st" || {
        err "  post-job-Hook fehlgeschlagen"; return 1; }
    fi
    return ${eval_rc:-0}
  fi

  # WERKZEUGE AUF DER GEGENSEITE PRUEFEN, BEVOR uebertragen wird.
  # [Sonst erfaehrt man ein fehlendes cmake erst nach 83 MB und
  #  zehntausend Dateien. Die Pruefung kostet eine ssh-Verbindung.]
  local fehlend=""
  local w
  messpunkt "Start Auftrag $target@$host"
  # DIE GEBUENDELTE VERBINDUNG VORAB OEFFNEN.
  # [Sonst traegt der erste Fernbefehl den ganzen Verbindungsaufbau --
  #  und das ist meist die Werkzeugpruefung, die gar nichts ausgibt.
  #  Dann sieht es aus, als haenge das Skript vor dem ersten Log-Eintrag.
  #  Ein eigener Aufbau vorweg macht die Wartezeit sichtbar und alle
  #  folgenden Aufrufe schnell.]
  if [[ $host != local && -n ${HOST_SSH[$host]:-} ]] && (( ! XBM_KEIN_MUX )) \
     && (( ! DRY_RUN )); then
    messpunkt "oeffne Verbindung zu $host"
    ssh_cmd "$host"
    local vlog; vlog=$(xtmp) || return 1
    if ! "${SSH_ARGV[@]}" -O check >/dev/null 2>&1; then
      if ! "${SSH_ARGV[@]}" -f -N >"$vlog" 2>&1; then
        # NICHT ERREICHBAR -- SAGEN, WAS ZU PRUEFEN IST.
        # [Bisher lief nur die nackte ssh-Meldung durch
        #      ssh: connect to host build port 22: Connection timed out
        #  und der Auftrag scheiterte irgendwo weiter unten. Das ist kein
        #  Baufehler; es hilft, das gleich zu sagen -- und die uebrigen
        #  Ziele laufen ohnehin unberuehrt weiter, weil jeder Auftrag
        #  seinen eigenen Rueckgabewert hat.]
        err "  '$host' ist nicht erreichbar (${HOST_SSH[$host]}):"
        sed 's/^/      /' "$vlog" >&2
        case $(cat "$vlog") in
          *"Connection timed out"*|*"No route to host"*)
            err "  -> Rechner aus, im Ruhezustand, oder anderes Netz/VPN?" ;;
          *"Name or service not known"*|*"Could not resolve"*)
            err "  -> Der Name laesst sich nicht aufloesen. In config/hosts.conf" 
            err "     eine IP statt des Namens eintragen." ;;
          *"Permission denied"*)
            err "  -> Anmeldung abgelehnt: Schluessel oder Passwort pruefen." ;;
          *"Connection refused"*)
            err "  -> Kein SSH-Dienst auf dem Rechner (sshd laeuft nicht?)." ;;
        esac
        err "  Pruefen:  ssh ${HOST_SSH[$host]} echo ok"
        rm -f "$vlog"
        return 1
      fi
    fi
    rm -f "$vlog"
    messpunkt "Verbindung steht"

    # WSL SCHON MAL HOCHFAHREN, waehrend wir uebertragen.
    # [Windows faehrt die WSL-Instanz nach kurzer Untaetigkeit herunter.
    #  Jeder Lauf zahlt deshalb den Kaltstart -- bei dir 4,5 s, gemessen
    #  an der Luecke zwischen "uebertragen: 28/28" und der ersten Zeile
    #  von drueben. Der Start laesst sich nicht abschaffen, aber
    #  VORZIEHEN: angestossen wird er hier, im Hintergrund, und laeuft
    #  dann waehrend der Uebertragung.]
    case ${HOST_OS[$host]:-posix} in
      cmd|gitbash|wsl)
        messpunkt "waerme bash/WSL vor"
        ( ssh_cmd "$host"
          case ${HOST_OS[$host]:-posix} in
            wsl) ssh_cmd "$host"; SSH_ARGV+=("wsl.exe true") ;;
            *)   SSH_ARGV+=("bash -c :") ;;
          esac
          "${SSH_ARGV[@]}" >/dev/null 2>&1 ) &
        XBM_WARM_PID=$!
        ;;
    esac
  fi
  hook_pakete_laden "$target" "$host"
  # BEI --exec GAR NICHT VON HIER AUS PRUEFEN.
  # [Das war mit 7,00 s der teuerste Einzelposten -- ein  bash -c  auf
  #  der Gegenseite, und dort startet bash das WSL. Die Pruefung ist
  #  hier auch entbehrlich: sie soll eine grosse Uebertragung verhindern,
  #  bei --exec sind es aber ein paar Kilobyte. Und die Gegenseite
  #  prueft ohnehin selbst, bevor sie den Hook startet.]
  (( IST_EXEC )) && SKIP_TOOLCHECK=1
  # Bei --sync-only wird drueben nichts ausgefuehrt -- also auch nichts
  # gebraucht.
  (( SYNC_ONLY )) && SKIP_TOOLCHECK=1

  # ALLE WERKZEUGE IN EINEM EINZIGEN AUFRUF PRUEFEN.
  # [Vorher eine ssh-Verbindung JE WERKZEUG. Bei vier Werkzeugen waren
  #  das vier Verbindungen -- der groesste Einzelposten.]
  if (( ! SKIP_TOOLCHECK )); then
    local -a wliste=()
    while IFS= read -r w; do
      [[ -n $w ]] && wliste+=("$w")
    done < <(XBM_HOST_JETZT=$host werkzeuge_von "$target" | grep -v '^$' | sort -u)
    if (( ${#wliste[@]} > 0 )); then
      local pruefskript="for w in ${wliste[*]}; do"
      pruefskript+=' command -v "$w" >/dev/null 2>&1 ||'
      pruefskript+=' command -v "$w.exe" >/dev/null 2>&1 ||'
      pruefskript+=' echo "FEHLT:$w"; done'
      local antwort
      case ${HOST_OS[$host]:-posix} in
        cmd|gitbash) antwort=$(remote "$host" \
                       "${XBM_REMOTE_SHELL:-bash -c} \"$pruefskript\"" 2>/dev/null) ;;
        *)           antwort=$(remote "$host" "$pruefskript" 2>/dev/null) ;;
      esac
      while IFS= read -r w; do
        [[ $w == FEHLT:* ]] && fehlend+=" ${w#FEHLT:}"
      done <<< "$antwort"
    fi
  fi

  # COMPILER AUCH AUS DER FERNE PRUEFEN -- VOR der Uebertragung.
  # [Bisher fiel ein fehlender Compiler erst drueben auf, also nach
  #  83 MB und zehntausend Dateien. Die Pruefung kostet eine
  #  ssh-Verbindung und spart im Fehlerfall die ganze Uebertragung.]
  if (( ! SKIP_TOOLCHECK )) && [[ -z $fehlend ]] \
     && [[ "${CONF_CMD[$target]-}${BUILD_CMD[$target]-}" == *cmake* ]]; then
    local ccgef=""
    for w in cc gcc clang cl x86_64-w64-mingw32-gcc; do
      if fern_hat_werkzeug "$host" "$w"; then ccgef=$w; break; fi
    done
    if [[ -z $ccgef ]] && (( AUTO_INSTALL )); then
      local verw2=""; fern_verwalter "$host" && verw2=$VERWALTER
      if [[ -n $verw2 ]]; then
        log "  kein Compiler auf '$host' -- Installation wird versucht"
        # g++ zieht auf beiden Wegen die ganze Werkzeugkette nach.
        if fern_installieren "$host" "g++" "$verw2"; then
          for w in cc gcc clang cl x86_64-w64-mingw32-gcc; do
            if fern_hat_werkzeug "$host" "$w"; then ccgef=$w; break; fi
          done
        fi
      fi
    fi
    if [[ -z $ccgef ]]; then
      err "Auf '$host' ist kein C/C++-Compiler auffindbar."
      err "  Gesucht: cc gcc clang cl x86_64-w64-mingw32-gcc (auch .exe)"
      err "  cmake wuerde dort melden: No CMAKE_C_COMPILER could be found."
      err "  Es wird deshalb GAR NICHT erst uebertragen."
      err ""
      err "  Auf Windows am einfachsten:"
      err "      winget install BrechtSanders.WinLibs.POSIX.UCRT"
      err "      winget install Ninja-build.Ninja"
      err "    danach SYSTEM-PATH ergaenzen und  Restart-Service sshd"
      err "    pruefen:  ssh ${HOST_SSH[$host]} \"where gcc ninja cmake\""
      err ""
      err "  Oder ganz ohne Windows-Maschine, per Cross-Compile:"
      err "      apt install mingw-w64 cmake ninja-build"
      err "      ./build.sh ${target}@local"
      err "    mit -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mingw-clang.cmake"
      err ""
      err "  Pruefung ueberspringen: --skip-toolcheck"
      return 1
    fi
    log "  Compiler auf '$host': $ccgef"
  fi
  # FEHLENDES NACHINSTALLIEREN und danach ERNEUT PRUEFEN.
  if [[ -n $fehlend ]] && (( AUTO_INSTALL )); then
    local verw=""; fern_verwalter "$host" && verw=$VERWALTER
    if [[ -z $verw ]]; then
      # NICHT STILL AUFGEBEN.
      # [Vorher wurde bei fehlendem Paketverwalter einfach nichts
      #  getan -- man sah nur "fehlen Programme" und wunderte sich,
      #  warum nichts installiert wird.]
      err "Auf '$host' fehlen Programme:$fehlend"
      err "  Es wurde kein Paketverwalter gefunden -- deshalb wird nichts"
      err "  installiert. Gesucht wurde nach:"
      if [[ ${HOST_OS[$host]:-posix} == cmd || ${HOST_OS[$host]:-posix} == gitbash ]]; then
        err "      where winget"
        err "      %LOCALAPPDATA%\\Microsoft\\WindowsApps\\winget.exe"
        err "  winget ist eine Store-Anwendung und liegt im BENUTZER-PATH."
        err "  Der SSH-Dienst laeuft als Dienst und sieht nur den"
        err "  MASCHINEN-PATH. Pruef es selbst:"
        err "      ssh ${HOST_SSH[$host]} \"where winget\""
        err "  Abhilfe: den Ordner in den System-PATH aufnehmen,"
        err "      [Environment]::SetEnvironmentVariable(\"Path\","
        err "        \$env:Path + \";\$env:LOCALAPPDATA\\Microsoft\\WindowsApps\","
        err "        \"Machine\")"
        err "      Restart-Service sshd"
      else
        err "      apt-get"
      fi
      return 1
    fi
    if [[ -n $verw ]]; then
      log "  fehlt auf '$host':$fehlend -- Paketverwalter: $verw"
      local nochfehlend=""
      for w in $fehlend; do
        fern_installieren "$host" "$w" "$verw" || { nochfehlend+=" $w"; continue; }
        fern_hat_werkzeug "$host" "$w" || nochfehlend+=" $w"
      done
      if [[ -n $nochfehlend ]]; then
        # DER HAEUFIGSTE FALL NACH EINER INSTALLATION.
        # [winget ergaenzt den PATH der MASCHINE. Der SSH-Dienst hat
        #  seinen PATH aber beim Start uebernommen und merkt davon
        #  nichts -- auch eine neue Sitzung nicht. Erst ein Neustart des
        #  Dienstes bringt ihn auf Stand. Ohne diesen Hinweis sucht man
        #  lange, warum ein frisch installiertes Programm "fehlt".]
        err "Nach der Installation immer noch nicht auffindbar:$nochfehlend"
        if [[ ${HOST_OS[$host]:-posix} == cmd || ${HOST_OS[$host]:-posix} == gitbash ]]; then
          err "  Das ist normal: winget ergaenzt den PATH der MASCHINE,"
          err "  der SSH-Dienst kennt aber noch seinen alten. Einmal:"
          err "      ssh ${HOST_SSH[$host]} \"powershell -Command Restart-Service sshd\""
          err "  (braucht Administratorrechte) und dann erneut bauen."
        fi
        fehlend=$nochfehlend
      else
        fehlend=""
        log "  alle fehlenden Programme installiert."
      fi
    fi
  fi

  if [[ -n $fehlend ]]; then
    err "Auf '$host' fehlen Programme fuer '$target':$fehlend"
    err "  Pruef den PATH der SSH-Sitzung -- er ist oft ein anderer als"
    err "  der in deinem Fenster:"
    err "      ssh ${HOST_SSH[$host]} 'bash -lc \"echo \$PATH\"'"
    for w in $fehlend; do
      case $w in
        cmake) err "  cmake: winget install Kitware.CMake" ;;
        ninja) err "  ninja: winget install Ninja-build.Ninja" ;;
        git)   err "  git:   winget install Git.Git" ;;
      esac
    done
    err "  Ueberspringen mit --skip-toolcheck (falls die Pruefung irrt)."
    return 1
  fi

  messpunkt "Pruefungen fertig"
  run_hook pre-job "$target" "$host" || {
    err "  pre-job-Hook fehlgeschlagen -- nichts uebertragen"; return 1; }

  # SCHNELLWEG: EIN EINZIGER FERNAUFRUF.
  # [Deine Messung zeigt, wo die Zeit steckt -- nicht in der Verbindung
  #  (1,09 s, einmalig), sondern in jedem bash auf der Gegenseite:
  #      3,00 s  Werkzeugpruefung
  #      2,40 s  Uebertragung
  #      2,00 s  Aufruf von build.sh
  #  Dort ist bash die Datei C:\Windows\System32\bash.exe, und die
  #  startet WSL. Jeder Aufruf zahlt den WSL-Start.
  #
  #  Ohne action-Hooks gibt es drueben aber nichts zu tun ausser dem
  #  Befehl selbst: kein Ordner, keine Uebertragung, kein zweites
  #  build.sh. Ein Aufruf statt vier.
  #
  #  Der Befehl reist base64-verpackt -- so gibt es nichts zu zitieren,
  #  egal ob cmd.exe, WSL oder Git Bash den Empfang macht.]
  if (( IST_EXEC )) && ! hat_action_hooks "$target" "$host"; then
    messpunkt "Schnellweg (keine action-Hooks)"
    local b64 schnell frc=0
    # $path wird erst weiter unten gesetzt -- hier selbst holen.
    local spath=${HOST_PATH[$host]}
    b64=$(printf '%s\n' "$EXEC_CMD" | base64 | tr -d '\n')
    local innen="cd '$spath' 2>/dev/null; echo $b64 | base64 -d | bash"
    case ${HOST_OS[$host]:-posix} in
      cmd|gitbash) schnell="bash -c \"XBM_LAUF_ID=$XBM_LAUF_ID; $innen\"" ;;
      # KEIN wsl.exe hier -- build_remote_argv stellt es bereits voran.
      # [Sonst steht es doppelt da:  wsl.exe wsl.exe bash -c ...  und
      #  die Gegenseite meldet "wsl.exe: command not found". Genau das
      #  kam im Test heraus.]
      wsl)         schnell="bash -c \"$innen\"" ;;
      *)           schnell="$innen" ;;
    esac
    remote "$host" "$schnell" 2>&1 | bau_fortschritt "${target}@${host}  bauen"
    frc=${PIPESTATUS[0]}
    messpunkt "Schnellweg fertig"
    local sts=ok; (( frc == 0 )) || sts=fail
    (( frc == 0 )) || err "  Ausfuehrung auf '$host' fehlgeschlagen"
    run_hook post-job "$target" "$host" "$sts" \
      || err "  post-job-Hook fehlgeschlagen"
    return $frc
  fi

  # UEBERTRAGUNG UND AUFRUF IN EINEM EINZIGEN bash-START.
  # [Deine Messung: 2,70 s fuer die Uebertragung und 3,00 s fuer den
  #  Aufruf -- beides fast nur WSL-Startzeit. In EINEM Aufruf entpackt
  #  tar aus der Standardeingabe und build.sh laeuft danach im selben
  #  bash weiter. tar liest bis zum Archivende und gibt den Rest frei;
  #  build.sh liest ohnehin nichts von dort.
  #  Das spart einen kompletten WSL-Start.]
  # ZUSAMMENLEGEN NUR, WO bash DEN PFAD VERSTEHT.
  # [Bei os=cmd macht CMD den Verzeichniswechsel:
  #      cd /d C:\...\x && bash build.sh
  #  Legt man das zusammen, muesste BASH den Wechsel machen -- und dort
  #  ist bash oft WSLs bash. Die kennt C:\... nicht: "C:" ist fuer sie
  #  ein ganz normaler Verzeichnisname. mkdir hat deshalb einen Ordner
  #  namens "C:" im WSL-Heimatordner angelegt, und alles landete unter
  #      /mnt/c/Users/win/C:/Users/win/Desktop/x/...
  #  Genau die Zeile stand in deinem Log. Brücke, .xbm-exec.sh und
  #  Hooks lagen am falschen Ort -- daher auch "mpv: command not found".
  #
  #  Bei wsl und posix gibt es das Problem nicht: dort sind die Pfade
  #  ohnehin POSIX-Pfade.]
  local ZUSAMMENGELEGT=0
  if (( IST_EXEC )) && [[ $host != local ]] \
     && [[ ${HOST_OS[$host]:-posix} =~ ^(wsl|posix)$ ]] \
     && (( ! DRY_RUN )); then
    ZUSAMMENGELEGT=1
  fi

  if (( SYNC_ONLY )); then
    messpunkt "nur uebertragen"
    push_project "$host" || return 1
    messpunkt "Uebertragung fertig"
    run_hook post-job "$target" "$host" ok || {
      err "  post-job-Hook fehlgeschlagen"; return 1; }
    return 0
  fi

  if (( IST_EXEC )); then startskript_bauen ".xbm-run-${XBM_LAUF_ID}.sh" "$target" "$host"; fi
  if (( ! ZUSAMMENGELEGT )); then
    messpunkt "vor der Uebertragung"
    # Bei --exec nur die Steuerdateien -- den Projektbaum nicht ansehen.
    # [Das war der zweite grosse Posten: xfer_find lief ueber 18500
    #  Dateien, obwohl die Gegenseite nur build.sh, config/, hooks/ und
    #  das Skript braucht.]
    if (( IST_EXEC )); then
      XBM_NUR_STEUERDATEIEN=1
    else
      XBM_NUR_STEUERDATEIEN=0
    fi
    push_project "$host" || return 1
    XBM_NUR_STEUERDATEIEN=0
    messpunkt "Uebertragung fertig"
  fi

  # DIE GEGENSEITE SOLL ALLES DURCHREICHEN, nichts selbst wegschreiben.
  # [Sonst legt sie den Bauausgang in IHRE eigene Logdatei, und durch
  #  ssh kommt nur die Zusammenfassung an -- dein Log enthielte dann
  #  gerade nicht den vollen Bauausgang, und der Bildschirm bekaeme
  #  nichts zum Anzeigen.
  #    --show-output  volle Ausgabe in den ssh-Kanal
  #    --no-log       drueben keine Logdatei anlegen
  #  Was hier ankommt, schreibt die steuernde Seite ins Log und bildet
  #  daraus den Prozentsatz.]
  # --run/--run-only/--publish MUESSEN VOR --target STEHEN. [Beide sind
  # POSITIONAL (wie --parallel): sie gelten fuer alle AB DORT folgenden
  # Ziele. "--target" loest add_target() aber SOFORT beim Einlesen aus
  # -- staende --run-only ERST DANACH in der Befehlszeile, haette die
  # Gegenseite ihr Ziel schon mit dem VORHERIGEN (falschen) Stand
  # eingetragen, bevor sie das Flag ueberhaupt gesehen hat.]
  local flags=()
  if (( ${XBM_TUE_RUN_ONLY:-0} )); then flags+=(--run-only)
  elif (( ${XBM_TUE_RUN:-0} )); then flags+=(--run)
  fi
  (( ${XBM_TUE_PUBLISH:-0} )) && flags+=(--publish)
  flags+=("--target" "${target}@local" "--jobs" "$JOBS"
          "--as-host" "$host" "--proto" "$XBM_BUILD_PROTO"
          "--show-output")
  # [Hier stand auch "--no-log". Dann schreibt die Gegenseite KEIN
  #  builds/logs/<ziel>@local.log -- genau die Datei, die weiter unten bei
  #  einem Fehlschlag geholt wird ("kein Protokoll ... gefunden"). Das Log
  #  dort kostet nichts und ist bei einem Fehler das Einzige, was zaehlt.]
  (( CONFIGURE_ONLY )) && flags+=(--configure-only)
  (( BUILD_ONLY ))     && flags+=(--build-only)
  # HOOK-TESTMODUS DURCHREICHEN. [Ohne das wuerde die Gegenseite ihre
  #  EIGENEN, echten Bau-Befehle aus IHRER targets.conf lesen -- der
  #  Beispielbefehl gilt ja nur fuer DIESEN Lauf hier und lebt nur im
  #  Speicher der steuernden Seite, kommt bei einem entfernten Host also
  #  gar nicht von selbst an. WORTGLEICH weitergereicht (HOOKS_ONLY_FLAG),
  #  nicht aus HOOKS_ONLY_MODE neu zusammengesetzt -- sonst wuerde ein
  #  eingegebenes "--hooks-only" drueben als "--hooks-only-success"
  #  ankommen. Beide wirken zwar gleich, sind aber nicht dieselbe
  #  Formulierung, und genau das wurde bemaengelt.]
  if [[ -n $HOOKS_ONLY_MODE ]]; then
    flags+=("$HOOKS_ONLY_FLAG")
  fi
  (( CLEAN ))          && flags+=(--clean)
  (( CLEANDEEP ))      && flags+=(--clean-deep)

  local path=${HOST_PATH[$host]}

  xbm_werkzeug_senden "$host" "$path" "$target" || return 1

  # FASSUNG AUS DER FERNDATEI LESEN, bevor sie aufgerufen wird.
  # [Eine ALTE Fassung kennt weder --proto noch --chdir und bricht mit
  #  "unbekannte Option" ab -- die mitgereiste Nummer wird also nie
  #  verglichen. Die Datei selbst zu lesen funktioniert dagegen
  #  unabhaengig davon, wie alt sie ist.]
  local fernproto=""
  # NICHT FRAGEN, wenn es nichts nuetzt:
  #  * bei --exec wird drueben nicht gebaut, die Fassung ist egal
  #  * im Probelauf gibt remote nur die Befehlszeile aus -- die Zuweisung
  #    fing sie ein und hielt sie fuer eine Fassungsnummer
  if (( EXEC_MODE )) || (( DRY_RUN )); then
    :
  elif [[ ${HOST_OS[$host]:-posix} == cmd ]]; then
    fernproto=$(remote "$host" \
      "findstr /b XBM_BUILD_PROTO= $(winpfad "$path/build.sh")" 2>/dev/null)
  else
    fernproto=$(remote "$host" \
      "grep -m1 '^XBM_BUILD_PROTO=' '$path/build.sh'" 2>/dev/null)
  fi
  fernproto=${fernproto#*=}
  fernproto=${fernproto//[$'\r'$'\n'$' ']/}
  # Bei --exec laeuft drueben kein build.sh mehr -- die Fassung ist
  # dann bedeutungslos und wird nicht gemeldet.
  (( IST_EXEC )) || log "  build.sh auf '$host': Fassung ${fernproto:-(keine Angabe)}"

  if [[ -n $fernproto && $fernproto != "$XBM_BUILD_PROTO" ]]; then
    err "build.sh auf '$host' ist Fassung ${fernproto},"
    err "  hier laeuft Fassung $XBM_BUILD_PROTO."
    err "  Die Uebertragung hat die Datei also NICHT ersetzt, obwohl sie"
    err "  Erfolg gemeldet hat. Sieh dort nach:"
    if [[ ${HOST_OS[$host]:-posix} == cmd ]]; then
      err "      ssh ${HOST_SSH[$host]} \"dir $(winpfad "$path")\\build.sh\""
    else
      err "      ssh ${HOST_SSH[$host]} \"ls -l '$path/build.sh'\""
    fi
    return 1
  fi

  # DEN AUFRUF UNABHAENGIG VON DER FERNFASSUNG MACHEN.
  # [Dein Log zeigt einen Widerspruch: findstr liest Fassung 3, und
  #  DIESELBE Datei antwortet "unbekannte Option: --chdir". Statt das
  #  aufzuklaeren, verzichte ich auf --chdir: ohne Leerzeichen im Pfad
  #  braucht cmd keine Anfuehrungszeichen, und dann funktioniert
  #      cd /d <pfad> && bash build.sh ...
  #  wieder -- das versteht JEDE Fassung, auch eine aeltere.]
  # Auf das Vorwaermen warten -- meist laengst fertig.
  if [[ -n ${XBM_WARM_PID:-} ]]; then
    wait "$XBM_WARM_PID" 2>/dev/null || true
    XBM_WARM_PID=""
    messpunkt "Vorwaermen abgeschlossen"
  fi

  # DEN FERNSTROM DURCH DEN FORTSCHRITTSFILTER LEITEN.
  # [Damit landet der volle Bauausgang der Gegenseite im Log -- und die
  #  steuernde Seite zeigt daraus den Prozentsatz auf IHREM Bildschirm.
  #  Vorher gab es fuer einen Fernbau ueberhaupt keine Anzeige.]
  FERNHOSTS_AKTIV[$host]=1
  local fern_rc=0 fernbefehl
  if (( IST_EXEC )) && (( ZUSAMMENGELEGT )); then
    messpunkt "Uebertragung + Aufruf (ein bash-Start)"
    local ef2=${XBM_EXEC_DATEI##*/}
    local efl2=("--as-host" "$host" "--exec-file" "$ef2"
                "--show-output" "--no-log" "--target" "ausfuehren@local")
    # NUR DIE STEUERDATEIEN -- den Projektbaum gar nicht erst ansehen.
    # [Hier stand xfer_find, das den GANZEN Baum durchlaeuft: bei dir
    #  18500 Dateien, jede einzeln durch die Ausschlussregeln in einer
    #  bash-Schleife. Das kostet allein 0,8 s -- und mit set -x erzeugt
    #  es ueber eine Million Trace-Zeilen, die dann auch noch durch zwei
    #  weitere bash-Schleifen wandern. Daher die vier Minuten und das
    #  ruckelnde Log.
    #
    #  Fuer --exec braucht die Gegenseite aber nur build.sh, config/,
    #  hooks/ und das Skript selbst -- ein paar Dutzend Dateien.]
    local liste2; liste2=$(xtmp) || return 1
    local st2
    for st2 in build.sh config hooks cmds; do
      [[ -e $st2 ]] || continue
      find "./$st2" -type f ! -name '*.log' 2>/dev/null
    done > "$liste2"
    printf '%s\n' "./$ef2" >> "$liste2"
    sort -u -o "$liste2" "$liste2"

    local innen2="mkdir -p '$path'; cd '$path' || exit 1"
    innen2+="; tar -xzUf - ; bash build.sh ${efl2[*]}"
    local zbefehl
    case ${HOST_OS[$host]:-posix} in
      wsl) zbefehl="bash -c \"$innen2\"" ;;
      *)   zbefehl="bash -c \"$innen2\"" ;;
    esac
    build_remote_argv "$host" "$zbefehl"
    GZIP=-1 tar -czf - -T "$liste2" 2>/dev/null \
      | "${SSH_ARGV[@]}" 2>&1 | bau_fortschritt "${target}@${host}  bauen"
    fern_rc=${PIPESTATUS[1]}
    rm -f "$liste2"
    messpunkt "fertig (ein Aufruf)"
    local stz=ok; (( fern_rc == 0 )) || stz=fail
    (( fern_rc == 0 )) || err "  Ausfuehrung auf '$host' fehlgeschlagen"
    run_hook post-job "$target" "$host" "$stz" \
      || err "  post-job-Hook fehlgeschlagen"
    return $fern_rc
  fi

  if (( IST_EXEC )); then
    # KEIN build.sh mehr drueben -- nur ein erzeugtes Startskript.
    local rs=".xbm-run-${XBM_LAUF_ID}.sh"
    startskript_bauen "$rs" "$target" "$host"
    case ${HOST_OS[$host]:-posix} in
      cmd) fernbefehl="cd /d $(winpfad "$path") && bash $rs" ;;
      wsl) fernbefehl="wsl.exe bash -c \"cd '$path' && bash $rs\"" ;;
      *)   fernbefehl="cd '$path' && bash $rs" ;;
    esac
    messpunkt "vor dem Fernaufruf"
    remote "$host" "$fernbefehl" 2>&1 | bau_fortschritt "${target}@${host}  bauen"
    fern_rc=${PIPESTATUS[0]}
    messpunkt "Fernaufruf fertig"
    local st_j=ok; (( fern_rc == 0 )) || st_j=fail
    (( fern_rc == 0 )) || err "  Ausfuehrung auf '$host' fehlgeschlagen"
    run_hook post-job "$target" "$host" "$st_j" \
      || err "  post-job-Hook fehlgeschlagen"
    return $fern_rc
  fi
  if [[ ${HOST_OS[$host]:-posix} == wsl ]]; then
    fernbefehl="bash $path/build.sh --chdir $path ${flags[*]}"
  elif [[ ${HOST_OS[$host]:-posix} == cmd ]]; then
    if [[ $path == *" "* ]]; then
      fernbefehl="bash $path/build.sh --chdir $path ${flags[*]}"
    else
      fernbefehl="cd /d $(winpfad "$path") && bash build.sh --run-id $XBM_LAUF_ID ${flags[*]}"
    fi
  else
    # bash build.sh statt ./build.sh -- wie bei cmd/wsl; haengt so nicht
    # vom Ausfuehrungsrecht der Datei ab.
    fernbefehl="cd '$path' && bash build.sh ${flags[*]}"
  fi
  # UNMISSVERSTAENDLICH BESTAETIGEN, OB DER HOOK-TESTMODUS TATSAECHLICH
  # MITGEHT. [Die Kurzanzeige weiter unten kuerzt den Befehl auf einen
  #  Ausschnitt -- bei einem langen fernbefehl (mehrere Flags, langer
  #  Pfad) stand "--hooks-only-..." dort oft ausserhalb des sichtbaren
  #  Bereichs, ganz am Ende der Zeile. Diese Zeile hier zeigt es IMMER,
  #  unabhaengig von der Laenge, und steht auch im Log, wenn --verbose
  #  nicht gesetzt ist.]
  if [[ -n $HOOKS_ONLY_MODE ]]; then
    if [[ $fernbefehl == *--hooks-only* ]]; then
      log "  [Hook-Testmodus:${HOOKS_ONLY_MODE}] wird an '${target}@${host}' weitergereicht (im Fernbefehl enthalten)"
    else
      err "  [Hook-Testmodus:${HOOKS_ONLY_MODE}] FEHLT im Fernbefehl fuer '${target}@${host}' -- das ist ein Fehler"
    fi
  fi
  remote "$host" "$fernbefehl" 2>&1 | bau_fortschritt "${target}@${host}  bauen"
  fern_rc=${PIPESTATUS[0]}

  if (( fern_rc != 0 )); then
    # DAS PROTOKOLL VON DER GEGENSEITE HOLEN.
    # [Der eigentliche Fehler steht dort in
    #      builds/logs/<ziel>@local.log
    #  -- also auf der Zielmaschine. Hier war bisher nur das AEUSSERE
    #  Protokoll zu sehen, und dessen letzte Zeilen sind bei set -x
    #  reines Ablaufrauschen. Man sah, DASS es fehlschlug, nie WARUM.]
    err "  Bau auf '$host' fehlgeschlagen -- Protokoll von dort:"
    local fernlog="$path/builds/logs/${target}@local.log"
    local inhalt=""
    if [[ ${HOST_OS[$host]:-posix} == wsl ]]; then
      inhalt=$(remote "$host" "cat $fernlog" 2>/dev/null)
    elif [[ ${HOST_OS[$host]:-posix} == cmd ]]; then
      inhalt=$(remote "$host" "type $(winpfad "$fernlog")" 2>/dev/null)
    else
      inhalt=$(remote "$host" "cat '$fernlog'" 2>/dev/null)
    fi
    if [[ -n $inhalt ]]; then
      # Ablaufrauschen von set -x herausnehmen -- es verdeckt sonst
      # genau die Zeilen, um die es geht.
      printf '%s\n' "$inhalt" | grep -v '^+' | grep -v '^++' \
        | tail -n 25 | sed 's/^/         | /' >&2
    else
      err "         (kein Protokoll unter $fernlog gefunden)"
      err "         Von Hand:"
      if [[ ${HOST_OS[$host]:-posix} == cmd ]]; then
        err "           ssh ${HOST_SSH[$host]} \"type $(winpfad "$fernlog")\""
      else
        err "           ssh ${HOST_SSH[$host]} \"cat '$fernlog'\""
      fi
    fi
    return 1
  fi

  pull_artifacts "$host" "$target"
  run_hook post-job "$target" "$host" ok || {
    err "  post-job-Hook fehlgeschlagen (der Bau selbst war erfolgreich)"
    return 1; }
}

# ---------------------------------------------------------------------------
# Parallel, mit lesbarem Fortschritt
# [Die alte Buchfuehrung zaehlte 'running' in einer Schleife ueber ALLE
#  Kennungen herunter und konnte denselben Auftrag mehrfach abziehen.
#  Ausserdem schrieben alle Auftraege gleichzeitig ins Terminal, was den
#  Balken zerriss. Jetzt bekommt jeder Auftrag seine eigene Logdatei.]
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# WARTEN INNERHALB EINES AUFTRAGS (statt in der Startschleife).
# ---------------------------------------------------------------------------
# xbm_auftrag_warten <idx> <host> <grenze> <braucht_platz> <deps> <statusdatei>
#   deps: "idx:name idx:name ..." -- Auftraege, deren Ende abzuwarten ist.
# Setzt XBM_WARTE_DEP_FEHLER (Name eines gescheiterten Vorgaengers oder
# leer) und XBM_WARTE_SLOT (belegter Bauplatz, von xbm_auftrag_ende
# wieder freigegeben). Laeuft IM Hintergrundprozess des Auftrags.
xbm_auftrag_warten() {
  local idx=$1 h=$2 grenze=$3 braucht_platz=$4 deps=$5 sdatei=$6
  local ich="${TARGETS[$idx]}@${HOSTS[$idx]}"
  XBM_WARTE_DEP_FEHLER=""
  XBM_WARTE_SLOT=""

  # 1) VORGAENGER ABWARTEN (nur --run-only: der Bau desselben Ziels).
  local d didx dname offen rcwert p
  while :; do
    offen=""
    for d in $deps; do
      didx=${d%%:*}; dname=${d#*:}
      [[ -f "$STATUS_DIR/.rc/$didx" ]] && continue
      # Ohne .rc gestorben (hart beendet)? Dann nicht ewig warten.
      if [[ -f "$STATUS_DIR/.pid/$didx" ]]; then
        p=$(cat "$STATUS_DIR/.pid/$didx" 2>/dev/null)
        if [[ -n $p ]] && ! kill -0 "$p" 2>/dev/null; then
          echo 1 > "$STATUS_DIR/.rc/$didx"
          continue
        fi
      fi
      offen=$dname
      break
    done
    [[ -z $offen ]] && break
    printf '%s  wartet auf %s\n' "$ich" "$offen" > "$sdatei"
    sleep 1
  done
  for d in $deps; do
    didx=${d%%:*}; dname=${d#*:}
    rcwert=$(cat "$STATUS_DIR/.rc/$didx" 2>/dev/null || echo 1)
    if [[ ${rcwert:-1} != 0 ]]; then XBM_WARTE_DEP_FEHLER=$dname; break; fi
  done

  # 2) BAUPLATZ AUF DEM HOST BELEGEN.
  # [mkdir ist atomar: von mehreren gleichzeitig Wartenden bekommt genau
  #  einer denselben Platz -- ohne Sperrdatei, ohne Wettlauf. Ein Auftrag
  #  mit Grenze N versucht die Plaetze 1..N.]
  if (( braucht_platz )); then
    local k
    while :; do
      for (( k = 1; k <= grenze; k++ )); do
        if mkdir "$STATUS_DIR/.slots/$h.$k" 2>/dev/null; then
          XBM_WARTE_SLOT="$STATUS_DIR/.slots/$h.$k"
          break 2
        fi
      done
      printf '%s  wartet auf freien Platz auf %s\n' "$ich" "$h" > "$sdatei"
      sleep 1
    done
  fi
  : > "$sdatei"
  return 0
}

# xbm_auftrag_ende <idx> <host> <rc> -- Ergebnis fuer Abhaengige ablegen,
# Bauplatz freigeben.
xbm_auftrag_ende() {
  echo "$3" > "$STATUS_DIR/.rc/$1"
  [[ -n ${XBM_WARTE_SLOT:-} ]] && rmdir "$XBM_WARTE_SLOT" 2>/dev/null
  return 0
}

run_all() {
  local total=${#TARGETS[@]}
  # SPERRDATEI FUER DIE GANZE LAUFZEIT.
  # [Ein post-job-Hook eines FRUEH fertigen Auftrags (z.B. apk) kann
  #  einen eigenen Nachlauf anstossen, waehrend andere Auftraege noch
  #  bauen. Ohne Kennzeichen wusste ein solcher Hook nicht, ob er
  #  wirklich alleine ist -- und ein zweiter Zeichner/Status-Schreiber
  #  gleichzeitig liess bei EINEM Job den Fortschritt verschwinden
  #  (beide teilen sich builds/logs/.status). Ein Hook, der sich daran
  #  halten will, wartet: while [[ -f builds/.xbm-lauf.lock ]]; do sleep 1; done]
  mkdir -p builds
  : > builds/.xbm-lauf.lock
  trap 'rm -f builds/.xbm-lauf.lock' EXIT
  # PHASEN UM DEN GANZEN LAUF.
  # [pre-job/post-job laufen je AUFTRAG. Fuer "nur wenn ALLE gelangen"
  #  bzw. "sobald EINER scheitert" braucht es eine Ebene darueber --
  #  sonst muesste ein Hook selbst mitzaehlen, was er gar nicht kann.]
  run_hook pre-run "alle" "$DEFAULT_HOST" || {
    err "pre-run-Hook fehlgeschlagen -- nichts gestartet"; return 1; }
  local -a pid=() name=() logf=() host_of=() rc=()
  # PARALLEL ZU pid[] GEFUEHRT -- fuer die Abhaengigkeit "--run-only wartet
  # auf den Bau desselben Ziels". [Bewusst eigene Arrays statt eines
  # Zugriffs auf TARGETS[$idx]: pid[] wird der Reihe nach befuellt, die
  # Indizes stimmen also NUR solange ueberein, wie jeder Auftrag auch
  # wirklich einen Hintergrundprozess startet. Das ist heute so, waere
  # aber eine stille Falle, sobald irgendwann ein Auftrag uebersprungen
  # wird -- dann zeigte der Index auf das falsche Ziel.]
  local -a target_of=() runonly_of=()
  local started=0 idx

  # LOGORDNER EINSTELLBAR.
  # [Warum: hooks/post-job.apk.sh startet einen ZWEITEN build.sh-Lauf,
  #  waehrend der erste noch baut. Beide schrieben in builds/logs -- der
  #  innere ueberschrieb also die Protokolle des aeusseren, und die Logs
  #  brachen mitten im Bau ab (1447 Bytes statt 40000). Viermal haben wir
  #  darin nach einem Fehler gesucht, der keiner war.
  #  Der innere Lauf setzt jetzt XBM_LOGDIR und stoert nicht mehr.]
  LOGDIR=${XBM_LOGDIR:-builds/logs}
  mkdir -p "$LOGDIR"
  STATUS_DIR="$LOGDIR/.status"
  rm -rf "$STATUS_DIR"; mkdir -p "$STATUS_DIR"
  # .rc/<idx>   Rueckgabewert eines fertigen Auftrags (fuer Abhaengige)
  # .pid/<idx>  Prozesskennung (erkennt einen Auftrag, der ohne .rc starb)
  # .slots/     Bauplaetze je Host (siehe xbm_auftrag_warten)
  mkdir -p "$STATUS_DIR/.rc" "$STATUS_DIR/.pid" "$STATUS_DIR/.slots"
  # LAUF_UEBERSICHT/KOPF_UEBERSICHT werden JETZT NICHT MEHR hier
  # eingerichtet -- das passiert bereits VOR diesem Aufruf (siehe ganz
  # unten im Skript, vor den "build.sh Fassung ..."-Kopfzeilen), damit
  # genau diese Kopfzeilen noch mit in KOPF_UEBERSICHT landen. Wuerde
  # hier erneut geleert, waeren sie sofort wieder weg.
  # Timing-Datei anlegen, sobald der Ordner existiert.
  if (( TIMING )) && [[ -z $XBM_TIMING_DATEI ]]; then
    XBM_TIMING_DATEI="$LOGDIR/timing.log"
    : > "$XBM_TIMING_DATEI"
    log "  Zeitmessung auch in $XBM_TIMING_DATEI"
  fi
  for idx in "${!TARGETS[@]}"; do
    local t=${TARGETS[$idx]} h=${HOSTS[$idx]} ej=${EXEC_JOB[$idx]:-0}
    local grenze=${PARALLEL_JE_ZIEL[$idx]:-1}
    # NUR AUFTRAEGE AUF DEMSELBEN HOST DROSSELN -- NIE ueber Hosts hinweg.
    # [Vorher gab es zusaetzlich eine GLOBALE Bremse (insgesamt hoechstens
    #  MAX_PARALLEL Auftraege gleichzeitig, ganz gleich auf welchem Host)
    #  UND eine starre volle Serialisierung gleicher Hosts (immer genau
    #  1 gleichzeitig, ohne Einstellmoeglichkeit). Jetzt: verschiedene
    #  Hosts laufen IMMER unabhaengig und gleichzeitig; nur mehrere
    #  Auftraege auf DEMSELBEN Host teilen sich eine Grenze, die jeder
    #  Auftrag aus dem Moment seines Hinzufuegens mitbringt (PARALLEL_JE_
    #  ZIEL, siehe add_target) -- so wirkt
    #      --parallel 4 test@gut --unparallel deb@local --parallel 2 test@schlecht
    #  wie beschrieben: bis zu 4 gleichzeitig auf "gut", "local" strikt
    #  nacheinander (Vorgabe, == --unparallel), bis zu 2 gleichzeitig auf
    #  "schlecht" -- die drei Gruppen dabei UNTEREINANDER voellig
    #  unabhaengig.]
    # ALLE AUFTRAEGE SOFORT STARTEN -- GEWARTET WIRD IM AUFTRAG SELBST.
    # [Vorher wartete HIER, in der Startschleife, jeder Auftrag auf einen
    #  freien Platz auf seinem Host und (bei --run-only) auf den Bau
    #  desselben Ziels. Das hielt die GANZE Schleife an -- und die
    #  Live-Anzeige (zeichner_start) kommt erst nach ihr. Bei
    #      --publish deb@local exe@windows apk@buildserver --run-only apk@windows
    #  wartete apk@windows erst minutenlang auf exe@windows (gleicher Host)
    #  und dann auf apk@buildserver, ohne jede Ausgabe: der Bildschirm blieb
    #  bei "gestartet: 3/4" stehen und sah aus wie ein Haenger.
    #  Jetzt startet jeder Auftrag sofort als Hintergrundprozess und wartet
    #  dort selbst (xbm_auftrag_warten); seine Statuszeile zeigt, worauf.]
    local lf="$LOGDIR/${t}@${h}.log"
    local ziel=$lf
    # [Erst NACH der --no-log-Pruefung leeren: vorher blieb bei --no-log
    #  eine leere Logdatei zurueck, die wie ein Protokoll aussah.]
    if (( NO_LOG )); then ziel=/dev/null; else : > "$lf"; fi
    local sdatei="$STATUS_DIR/$idx"
    : > "$sdatei"
    # Abhaengigkeiten dieses Auftrags: bei --run-only alle BAUENDEN
    # Auftraege desselben Ziels -- egal, an welcher Stelle sie in der
    # Befehlszeile stehen (auch wenn sie erst NACH diesem kommen).
    local deps="" didx
    if (( ${RUN_ONLY_JE_ZIEL[$idx]:-0} )); then
      for didx in "${!TARGETS[@]}"; do
        [[ $didx == "$idx" ]] && continue
        [[ ${TARGETS[$didx]} == "$t" ]] || continue
        (( ${RUN_ONLY_JE_ZIEL[$didx]:-0} )) && continue
        deps+="$didx:${TARGETS[$didx]}@${HOSTS[$didx]} "
      done
    fi
    # --run-only baut nicht -- er belegt keinen Bauplatz auf dem Host.
    # [Er laedt nur herunter und startet; neben einem laufenden Bau auf
    #  derselben Maschine stoert das nicht. Frueher wartete er trotzdem
    #  auf exe@windows, bloss weil es derselbe Rechner war.]
    local braucht_platz=1
    (( ${RUN_ONLY_JE_ZIEL[$idx]:-0} )) && braucht_platz=0
    local modus=still
    (( LOG_STDOUT )) && modus=logstdout
    (( ! LOG_STDOUT && VERBOSE )) && modus=verbose
    ( xbm_auftrag_warten "$idx" "$h" "$grenze" "$braucht_platz" "$deps" "$sdatei"
      dep_fehler=$XBM_WARTE_DEP_FEHLER
      exec 3>&1
      case $modus in
        logstdout)
          # GENAU DER LOGINHALT, auch auf dem Bildschirm.
          # [Erst stempeln, dann verteilen -- so ist die Bildschirmausgabe
          #  Zeile fuer Zeile das, was auch in der Datei steht.]
          XBM_STATUS_DATEI="$sdatei" XBM_DEP_FEHLER="$dep_fehler" XBM_TUE_RUN="${RUN_JE_ZIEL[$idx]:-0}" XBM_TUE_RUN_ONLY="${RUN_ONLY_JE_ZIEL[$idx]:-0}" XBM_TUE_PUBLISH="${PUBLISH_JE_ZIEL[$idx]:-0}" do_one "$t" "$h" "$ej" 2>&1 \
            | zeitstempel | tee "$ziel" >&3
          rc=${PIPESTATUS[0]} ;;
        verbose)
          # Volle Ausgabe auf BEIDES: Bildschirm ohne, Datei mit Zeitstempel.
          XBM_STATUS_DATEI="$sdatei" XBM_DEP_FEHLER="$dep_fehler" XBM_TUE_RUN="${RUN_JE_ZIEL[$idx]:-0}" XBM_TUE_RUN_ONLY="${RUN_ONLY_JE_ZIEL[$idx]:-0}" XBM_TUE_PUBLISH="${PUBLISH_JE_ZIEL[$idx]:-0}" do_one "$t" "$h" "$ej" 2>&1 \
            | tee >(zeitstempel > "$ziel") >&3
          rc=${PIPESTATUS[0]} ;;
        *)
          # Volle Ausgabe nur ins Log; der Bildschirm bekommt ueber
          # Kennung 3 nur den Fortschritt. Auch was die Unterschale SELBST
          # meldet, gehoert ins Log (sonst verschiebt es die Statusflaeche).
          exec 2>>"$ziel"
          XBM_STATUS_DATEI="$sdatei" XBM_DEP_FEHLER="$dep_fehler" XBM_TUE_RUN="${RUN_JE_ZIEL[$idx]:-0}" XBM_TUE_RUN_ONLY="${RUN_ONLY_JE_ZIEL[$idx]:-0}" XBM_TUE_PUBLISH="${PUBLISH_JE_ZIEL[$idx]:-0}" do_one "$t" "$h" "$ej" 2>&1 | zeitstempel > "$ziel"
          # [Ohne das Festhalten waere der Rueckgabewert der des FILTERS --
          #  jeder Auftrag haette dann Erfolg gemeldet.]
          rc=${PIPESTATUS[0]} ;;
      esac
      xbm_auftrag_ende "$idx" "$h" "$rc"
      exit "$rc" ) &
    pid+=($!); XBM_JOB_PIDS+=($!); name+=("${t}@${h}"); logf+=("$lf")
    echo "$!" > "$STATUS_DIR/.pid/$idx"
    host_of+=("$h")
    target_of+=("$t")
    runonly_of+=("${RUN_ONLY_JE_ZIEL[$idx]:-0}")
    lauf_notiz "${t}@${h}" job "-" gestartet
    ((started++))
    # Ueber fortschritt() -- sonst landet diese Zeile im Log, und auf
    # der Gegenseite sogar im ssh-Kanal.
    fortschritt "$(printf '\r  gestartet: %d/%d   ' "$started" "$total")"
  done
  fortschritt "$(printf '\r%*s\r' 40 '')"

  # Erst jetzt zeichnen -- alle Auftraege laufen, die Namen stehen fest.
  zeichner_start "${name[@]}"

  local fails=0
  # Auf ALLE warten UND die Rueckgabewerte MERKEN.
  # [wait liefert den Wert nur EINMAL -- ein zweites wait auf dieselbe
  #  Kennung meldet 127, und jeder Auftrag haette dann als
  #  fehlgeschlagen gegolten. Deshalb hier festhalten -- UND deshalb wird
  #  rc[] NICHT neu angelegt: ein Auftrag auf einer Maschine, die schon
  #  belegt war, wurde weiter oben (Serialisierung gleicher Hosts) schon
  #  fertig abgewartet, sein Rueckgabewert steht dort bereits in rc[].
  #  Ein zweites wait darauf traefe genau die 127-Falle.]
  for idx in "${!pid[@]}"; do
    [[ -n ${rc[$idx]+x} ]] && continue   # schon serialisiert abgewartet
    if wait "${pid[$idx]}" 2>/dev/null; then rc[$idx]=0; else rc[$idx]=$?; fi
  done
  zeichner_stop "${#name[@]}"

  for idx in "${!pid[@]}"; do
    # LETZTE FORTSCHRITTSZEILE DIESES AUFTRAGS SICHERN, BEVOR SIE WEG IST.
    # [$STATUS_DIR/$idx haelt genau eine Zeile: den letzten Stand, den
    #  fortschritt() dort abgelegt hat (z.B. "apk@buildserver  hook:
    #  hooks/post-job.apk.sh" oder "exe@windows  bauen  243 Zeilen").
    #  Das ist WAEHREND des Laufs nur am Bildschirm sichtbar und danach
    #  verloren -- hier landet der letzte Stand zusaetzlich dauerhaft in
    #  KOPF_UEBERSICHT, damit --show-last ihn spaeter noch zeigen kann.]
    if [[ -s "$STATUS_DIR/$idx" ]]; then
      kopf_notiz "  $(cat "$STATUS_DIR/$idx")"
    fi
    if (( ${rc[$idx]} == 0 )); then
      lauf_notiz "${name[$idx]}" job "-" ok
      printf '  \033[32mOK\033[0m    %-24s (%s)\n' "${name[$idx]}" "${logf[$idx]}"
      kopf_notiz "  OK    ${name[$idx]}  (${logf[$idx]})"
    else
      lauf_notiz "${name[$idx]}" job "-" fehlgeschlagen
      printf '  \033[31mFEHLER\033[0m %-24s (%s)\n' "${name[$idx]}" "${logf[$idx]}"
      kopf_notiz "  FEHLER ${name[$idx]}  (${logf[$idx]})"
      # LOGINHALT NUR AUF WUNSCH.
      # [Hier standen 25 Logzeilen -- auf STDOUT. Das ist genau das,
      #  was standardmaessig nicht dorthin gehoert: wer die Ausgabe
      #  weiterverarbeitet, bekam ploetzlich fremden Text dazwischen.
      #  Jetzt nur ein Hinweis auf die Datei; die Zeilen gibt es mit
      #  --excerpt, und dann auf STDERR, wo Diagnose hingehoert.]
      if (( AUSZUG )); then
        grep -v '^+' "${logf[$idx]}" | grep -v '^++' | tail -n "$AUSZUG_N" \
          | sed 's/^/         | /' >&2
      else
        printf '         letzte Zeilen:  tail -n 25 %s\n' "${logf[$idx]}" >&2
        kopf_notiz "         letzte Zeilen:  tail -n 25 ${logf[$idx]}"
      fi
      ((fails++))
    fi
  done

  # GEBUENDELTE VERBINDUNGEN SCHLIESSEN.
  # [ControlPersist wuerde sie noch zwei Minuten offen halten. Das ist
  #  beim naechsten Aufruf schnell, hinterlaesst aber einen Prozess --
  #  sauberer ist, sie am Ende gezielt zu beenden.]
  if (( ! XBM_KEIN_MUX )) && (( ! DRY_RUN )); then
    local _h
    for _h in $(printf '%s\n' "${HOSTS[@]}" | sort -u); do
      [[ $_h == local || -z ${HOST_SSH[$_h]:-} ]] && continue
      ssh_cmd "$_h"
      "${SSH_ARGV[@]}" -O exit >/dev/null 2>&1 || true
    done
  fi

  # post-run mit dem GESAMTergebnis: ok nur, wenn alle gelangen.
  local gesamt=ok
  (( fails )) && gesamt=fail
  # AUCH HIER: Bildschirm bekommt nur, ob es geklappt hat -- die
  # Hook-Ausgabe selbst geht ins Log. [Das war die undichte Stelle:
  # jeder einzelne Auftrag laeuft in do_one() innerhalb einer
  # abgesicherten Unterschale (siehe weiter oben, "BILDSCHIRM UND
  # LOGDATEI TRENNEN"), post-run aber NICHT -- es steht hier, GANZ AM
  # ENDE von run_all(), ausserhalb jeder solchen Umleitung. Seine
  # Ausgabe (die "Hook: ..."-Zeile UND alles, was das Hook-Skript
  # selbst schreibt) ging deshalb bisher ungefiltert auf den Bildschirm,
  # unabhaengig von --verbose/--show-output.]
  local post_run_log="$LOGDIR/post-run.log"
  if (( VERBOSE )) || (( LOG_STDOUT )); then
    run_hook post-run "alle" "$DEFAULT_HOST" "$gesamt" \
      || err "post-run-Hook fehlgeschlagen"
  else
    : > "$post_run_log"
    if ! run_hook post-run "alle" "$DEFAULT_HOST" "$gesamt" \
         >>"$post_run_log" 2>&1; then
      err "post-run-Hook fehlgeschlagen (siehe $post_run_log)"
    fi
  fi

  if (( fails )); then
    err "$fails von $total Auftraegen fehlgeschlagen"
    kopf_notiz "$fails von $total Auftraegen fehlgeschlagen"
    return 1
  fi
  log "alle $total Auftraege erfolgreich"
  kopf_notiz "alle $total Auftraege erfolgreich"
}

# FASSUNG IN JEDES PROTOKOLL.
# [Zwei Runden lang war unklar, welche Fassung ueberhaupt lief -- weder
#  bei dir noch bei mir. Ein Log ohne diese Angabe laesst sich nicht
#  deuten: dieselbe Fehlermeldung kann von einem alten Skript kommen,
#  von einem neuen, oder von einer alten Fassung auf der Gegenseite.
#  Eine Zeile, die das ein fuer alle Mal beantwortet.]

# ---------------------------------------------------------------------------
# ÜBERSICHT
# ---------------------------------------------------------------------------
zeige_letzten_lauf() {
  local datei="${XBM_LOGDIR:-builds/logs}/letzter-lauf.log"
  local kopf="${XBM_LOGDIR:-builds/logs}/letzter-lauf-kopf.log"
  if [[ ! -f $datei ]]; then
    log "Keine Uebersicht gefunden unter: $datei"
    log "(Noch kein Lauf mit dieser build.sh-Fassung, oder ein anderer"
    log " LOGDIR wurde verwendet -- ggf. XBM_LOGDIR=... setzen.)"
    return 1
  fi
  if [[ -f $kopf ]]; then
    cat "$kopf"
    log ""
  fi
  log "UEBERSICHT DES LETZTEN LAUFS  ($datei)"
  log ""
  printf '  %-8s  %-20s %-9s %-38s %s\n' ZEIT "ZIEL@HOST" PHASE DETAIL STATUS
  printf '  %s\n' "----------------------------------------------------------------------------------"
  cat "$datei"
}

zeige_liste() {
  log "Projekt: $PWD"
  log ""
  log "HOSTS"
  local n
  local -a hnamen=("${!HOST_SSH[@]}")
  if (( ${#hnamen[@]} == 0 )); then
    log "  (keine -- weder global noch in config/hosts.conf)"
  else
    printf '  %-14s %-8s %-24s %-20s %s\n' NAME OS "BENUTZER@HOST" PFAD GIT
    for n in $(printf '%s\n' "${hnamen[@]}" | sort); do
      printf '  %-14s %-8s %-24s %-20s %s\n' \
        "$n" "${HOST_OS[$n]:-posix}" \
        "${HOST_SSH[$n]:-(oertlich)}" "${HOST_PATH[$n]:-.}" \
        "${HOST_GIT[$n]:-(kein Git -- tar/rsync)}"
    done
  fi
  log ""
  log "ZIELE"
  local -a znamen=("${!CONF_CMD[@]}")
  if (( ${#znamen[@]} == 0 )); then
    log "  (keine -- config/targets.conf fehlt oder ist leer)"
  else
    for n in $(printf '%s\n' "${znamen[@]}" | sort); do
      printf '  %-10s %s\n' "$n" "$(printf '%s' "${BUILD_CMD[$n]:-}" | head -c 60)"
    done
  fi
  log ""
  log "HOOKS"
  local f gefunden=0
  shopt -s nullglob
  for f in hooks/*.sh; do
    printf '  %s\n' "${f##*/}"; gefunden=1
  done
  shopt -u nullglob
  (( gefunden )) || log "  (keine in hooks/)"
  log ""
  log "Globale Hosts werden gesucht in:"
  local g
  for g in "${XBM_HOSTS_GLOBAL[@]}"; do
    printf '  %-40s %s\n' "$g" "$([[ -f $g ]] && echo vorhanden || echo '-')"
  done
}

# MUTTERPROJEKT VON EINEM ANDEREN RECHNER HOLEN.
# [Erst hier, denn vorher sind die Hosts noch nicht eingelesen. Geholt
#  wird in einen Arbeitsordner unter builds/, damit das oertliche
#  Verzeichnis unangetastet bleibt.]
if [[ -n $MUTTER_HOST ]]; then
  if [[ $MUTTER_HOST == local ]]; then
    PROJEKT_DIR=$MUTTER_PFAD
    cd "$PROJEKT_DIR" || { err "kann nicht wechseln nach: $PROJEKT_DIR"; exit 1; }
  else
    [[ -n ${HOST_SSH[$MUTTER_HOST]:-} ]] || {
      err "unbekannter Host '$MUTTER_HOST' (siehe --list)"; exit 1; }
    arbeit="builds/mutter/$MUTTER_HOST"
    mkdir -p "$arbeit"
    log "Mutterprojekt: $MUTTER_HOST:$MUTTER_PFAD -> $arbeit"
    ssh_cmd "$MUTTER_HOST"
    if [[ ${HOST_OS[$MUTTER_HOST]:-posix} == cmd ]]; then
      SSH_ARGV+=("cd /d $(winpfad "$MUTTER_PFAD") && tar -czf - .")
    else
      SSH_ARGV+=("cd '$MUTTER_PFAD' && tar -czf - .")
    fi
    if ! "${SSH_ARGV[@]}" | tar -xzf - -C "$arbeit"; then
      err "konnte das Mutterprojekt nicht holen"
      exit 1
    fi
    cd "$arbeit" || exit 1
    log "Mutterprojekt geholt ($(find . -type f | wc -l) Dateien)"
    # Konfiguration von DORT neu einlesen -- sie gehoert zum Projekt.
    HOST_SSH=() HOST_OS=() HOST_PATH=() HOST_PASS=() HOST_XFER=()
    for _hf in "${XBM_HOSTS_GLOBAL[@]}"; do
      [[ -f $_hf ]] && hosts_einlesen "$_hf"
    done
    hosts_einlesen "config/hosts.conf"
    [[ -f config/targets.conf ]] && source config/targets.conf
  fi
fi

if (( LIST_MODE )); then zeige_liste; exit 0; fi
if (( SHOW_LAST_MODE )); then zeige_letzten_lauf; exit $?; fi
if (( MOVE_TO_MODE )); then move_to_host "$MOVE_TO_HOST" "$MOVE_TO_DATEI"; exit $?; fi

# UEBERSICHTSDATEIEN EINRICHTEN -- HIER, VOR den Kopfzeilen, nicht erst
# in run_all(), damit "build.sh Fassung ...", "Auftraege: ..." und die
# per-Ziel-Zeilen gleich mit in KOPF_UEBERSICHT landen (--show/--show-last
# sollen ja genau diese Zeilen mit anzeigen, nicht nur die Job-Tabelle).
# [Frisch geleert bei JEDEM Lauf -- "letzter Lauf" heisst immer DER hier
#  gerade gestartete, nicht irgendein aelterer Rest. Liegt im selben
#  (ggf. per XBM_LOGDIR umgeleiteten) Ordner wie die einzelnen Job-Logs
#  -- ein verschachtelter Lauf (siehe post-job.apk.sh) bekommt dadurch
#  automatisch seine EIGENE Uebersicht, vermischt sich nicht mit der des
#  aeusseren Laufs.]
LOGDIR=${XBM_LOGDIR:-builds/logs}
mkdir -p "$LOGDIR"
LAUF_UEBERSICHT="$LOGDIR/letzter-lauf.log"
: > "$LAUF_UEBERSICHT"
KOPF_UEBERSICHT="$LOGDIR/letzter-lauf-kopf.log"
: > "$KOPF_UEBERSICHT"

log "build.sh Fassung $XBM_BUILD_PROTO${AS_HOST:+  (aufgerufen von $AS_HOST)}"
kopf_notiz "build.sh Fassung $XBM_BUILD_PROTO${AS_HOST:+  (aufgerufen von $AS_HOST)}"
log "Auftraege: ${#TARGETS[@]}   Jobs je Bau: $JOBS"
kopf_notiz "Auftraege: ${#TARGETS[@]}   Jobs je Bau: $JOBS"
for idx in "${!TARGETS[@]}"; do
  aktionen=""
  (( ${RUN_ONLY_JE_ZIEL[$idx]:-0} )) && aktionen+=" --run-only"
  if (( ! ${RUN_ONLY_JE_ZIEL[$idx]:-0} )) && (( ${RUN_JE_ZIEL[$idx]:-0} )); then
    aktionen+=" --run"
  fi
  (( ${PUBLISH_JE_ZIEL[$idx]:-0} )) && aktionen+=" --publish"
  zeile="  ${TARGETS[$idx]} -> ${HOSTS[$idx]}  (parallel je Host: ${PARALLEL_JE_ZIEL[$idx]:-1}${aktionen:+, Aktionen:$aktionen})"
  log "$zeile"
  kopf_notiz "$zeile"
done
run_all
lauf_ergebnis=$?
if (( SHOW_MODE )); then
  log ""
  zeige_letzten_lauf
fi
exit $lauf_ergebnis
