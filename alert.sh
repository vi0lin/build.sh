#!/usr/bin/env bash
# alert.sh -- kurzer Klang aus der Tabelle unten.
#
# [GEAENDERT GEGENUEBER DEINER FASSUNG: nur die Robustheit, nicht die
#  Funktion. Deine Klangtabelle, die Ausschnitte aus ac.mp3, die Namen --
#  alles bleibt. Ich hatte das in Runde 48 versehentlich durch ein eigenes
#  Skript ersetzt; das war falsch und ist hier zurueckgenommen.
#
#  Was neu ist:
#   * Fehlt mpv, wird nicht abgebrochen. Vorher endete das Skript mit
#     "mpv: command not found" und einem Fehlercode -- und weil
#     hooks/post-run.sh damit fehlschlug, meldete build.sh den GANZEN
#     Lauf als gescheitert, obwohl das Binary fertig gebunden war.
#   * $selection war leer, wenn man ohne Argument aufruft -- dann brach
#     [ $selection == "list" ] mit einem Syntaxfehler ab.
#   * Die Tondatei wird gesucht statt im Arbeitsverzeichnis erwartet;
#     auf dem Bauserver liegt sie woanders.
#   * Ein unbekannter Name sagt das, statt mpv leere Werte zu geben.
#  Rueckgabewert ist IMMER 0.]

selection=""
while [[ $# -gt 0 ]]; do
  case $1 in
    *) selection=$1; shift;;
  esac
done
[[ -z $selection ]] && selection=lobby

declare -A DATA_FILE DATA_START DATA_DURATION

music=()
music+=("ac.mp3")

finde_datei() {
  local n=$1 hier
  hier=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || hier=.
  for k in "$n" "./$n" "$hier/$n" "$hier/sounds/$n" \
           "data/shared/sounds/$n" "$hier/data/shared/sounds/$n"; do
    [[ -f $k ]] && { printf '%s' "$k"; return 0; }
  done
  return 1
}

play() {
  local name=$1
  local file=${DATA_FILE[$name]:-}
  if [[ -z $file ]]; then
    echo "  alert: '$name' steht nicht in der Tabelle" >&2
    return 0
  fi
  local start=${DATA_START[$name]}
  local duration=${DATA_DURATION[$name]}
  local mp3=${music[$file]:-}
  local pfad
  if ! pfad=$(finde_datei "$mp3"); then
    echo "  alert: $mp3 nicht gefunden -- kein Klang" >&2
    return 0
  fi
  if ! command -v mpv >/dev/null 2>&1; then
    printf '\a' 2>/dev/null || true      # sudo apt install mpv
    return 0
  fi
  mpv --no-video --no-terminal --start="${start}" --length="$duration" \
      "$pfad" >/dev/null 2>&1 || true
  return 0
}

while IFS='|' read -r name file start duration || [[ -n ${name:-} ]]; do
  [[ -z ${name:-} ]] && continue
  DATA_FILE[$name]=$file
  DATA_START[$name]=$start
  DATA_DURATION[$name]=$duration
  if [[ $selection == "list" ]]; then echo "$name"; fi
done << 'EOF'
lobby|0|00:00:20|0.87
flute|0|00:00:40.250|.75
item|0|00:00:42.250|.75
up|0|00:00:47|0.67
down|0|00:00:48.200|0.57
highflute|0|00:01:10|0.87
EOF

[[ $selection == "list" ]] && exit 0
play "$selection"
exit 0
