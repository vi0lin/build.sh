#!/usr/bin/env bash
# ===========================================================================
# git.sh -- ein Werkzeug fuer Projekt + Submodule.
#
#   git.sh --push-all   [-m MSG] [Auswahl...]      committen und pushen (Auswahl)
#   git.sh --commit-all -m MSG [-n] [-P] [-S]      ALLES committen (und pushen)
#   git.sh --clone-submodule PFAD URL [BRANCH] [--no-recursively] [--remote NAME]
#                                                 Submodul registrieren, klonen,
#                                                 in .gitmodules eintragen
#   git.sh --update-all   [--no-recursively]       alle Submodule: init, fetch,
#                                                 auf Branch-Stand (wenn branch
#                                                 gesetzt) oder Zeiger-Commit
#   git.sh --update PFAD... [--no-recursively]     dasselbe fuer bestimmte
#   git.sh --create-bare NAME / --create-release NAME / --install
#
# Jeder git-Aufruf laeuft mit protocol.file.allow=always (lokale Pfade als
# Submodul-URL). Submodule werden REKURSIV geklont, ausser --no-recursively.
# Mehrere --clone-submodule / --update in EINEM Aufruf sind erlaubt.
# ===========================================================================
set -euo pipefail
export GIT_TERMINAL_PROMPT=0     # never block on a password prompt; fail with the URL instead

g()    { git -c protocol.file.allow=always "$@"; }
info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; }

usage_main() {
    cat <<'EOF'
git.sh -- Projekt und Submodule in einem Werkzeug

  git.sh --push-all   [-m MSG] [Auswahl...]              siehe: git.sh --push-all -h
  git.sh --commit-all -m MSG [-n] [-P] [-S]               alles committen (und pushen)
  git.sh --clone-submodule PFAD URL [BRANCH] [Optionen]   Submodul anlegen + klonen
          --no-recursively   verschachtelte Submodule des neuen Submoduls NICHT klonen
          --remote NAME      Name des Remotes im Submodul (Vorgabe: origin)
          (mehrfach in einem Aufruf: --clone-submodule P1 U1 B1 --clone-submodule P2 U2)
  git.sh --update-all [--no-recursively]                  alle Submodule holen/aktualisieren
  git.sh --update PFAD [PFAD...] [--no-recursively]       bestimmte Submodule
  git.sh --pull-all | --pull PFAD[=@REMOTE[/BRANCH]]...   Fast-Forward holen (Root: "." oder --root)
  git.sh --check-pointers                                 Submodul-Zeiger, die auf KEINEM Remote
                                                          liegen (jeder Host faellt dort auf den
                                                          Branch-Stand zurueck -- Zeit bei jedem Lauf)
  git.sh --create-bare NAME | --create-release NAME | --install

Beispiele:
  git.sh --clone-submodule external/general_c http://192.168.1.69:3000/general_c.git master
  git.sh --clone-submodule external/seperated/timeline http://192.168.1.69:3000/general_c.git timeline
  git.sh --push-all -m "fix" --root=master:@offline,origin -r external/general_c=@* --exclude external/general_c/unsorted
  git.sh --pull --root=@origin external/timeline=@offline/timeline
  git.sh --update external/pdf external/general_c
EOF
}

# ---------------------------------------------------------------------------
# --create-bare / --create-release / --install (wie bisher)
# ---------------------------------------------------------------------------
create_git_repository() {
    local dir; dir=$(pwd)
    mkdir -p "$1" && cd "$1" && g init --bare -q && g symbolic-ref HEAD refs/heads/main
    echo "bare: $1 (HEAD -> main)"
    cd "$dir"
}
create_release_repository() { create_git_repository "$1"; }
clone_git_server_binary() {
    # git clone -b releases https://github.com/vi0lin/git_server
    # linking *.service files
    echo "--install: noch nicht umgesetzt"
}

# ---------------------------------------------------------------------------
# SUBMODUL ANLEGEN: registrieren (.gitmodules: path, url, branch), klonen,
# Branch auschecken (kein detached HEAD), rekursiv die inneren holen.
# [Von Hand ging das schief: "already exists in the index", fehlender
#  .gitmodules-Eintrag, lokale Pfad-URL verboten. Hier in EINER Funktion.]
# ---------------------------------------------------------------------------
cmd_clone_submodule() {
    local pfad=$1 url=$2 branch=${3:-} rekursiv=$4 remote=$5
    local top; top=$(git rev-parse --show-toplevel 2>/dev/null) || { err "nicht in einem Git-Repository"; return 1; }
    cd "$top"
    pfad=${pfad#./}; pfad=${pfad%/}
    local name=$pfad
    info "Submodul $pfad  <-  $url${branch:+  (Branch $branch)}"
    mkdir -p "$(dirname "$pfad")"
    local add=(submodule add --force)
    [ -n "$branch" ] && add+=(-b "$branch")
    add+=(--name "$name" "$url" "$pfad")
    if [ -e "$pfad/.git" ]; then
        # Repository liegt schon da: registrieren statt neu klonen
        warn "$pfad ist bereits ein Repository -- wird registriert, nicht neu geklont"
        g -C "$pfad" remote get-url "$remote" >/dev/null 2>&1 || g -C "$pfad" remote add "$remote" "$url"
        g config -f .gitmodules "submodule.$name.path" "$pfad"
        g config -f .gitmodules "submodule.$name.url" "$url"
        [ -n "$branch" ] && g config -f .gitmodules "submodule.$name.branch" "$branch"
        g add .gitmodules "$pfad"
    else
        if ! g "${add[@]}"; then
            err "git submodule add fehlgeschlagen fuer $pfad ($url)"; return 1
        fi
        # branch = ... nachtragen, falls git ihn nicht geschrieben hat
        [ -n "$branch" ] && g config -f .gitmodules "submodule.$name.branch" "$branch"
    fi
    g submodule sync -q -- "$pfad" 2>/dev/null || true
    g submodule init -- "$pfad"
    [ -e "$pfad/.git" ] || g submodule update --init -- "$pfad"
    # Branch auschecken, nicht detached stehen lassen
    if [ -n "$branch" ]; then
        g -C "$pfad" fetch -q "$remote" "$branch" 2>/dev/null || true
        if g -C "$pfad" rev-parse -q --verify "refs/remotes/$remote/$branch" >/dev/null; then
            g -C "$pfad" checkout -q -B "$branch" "$remote/$branch"
        else
            g -C "$pfad" checkout -q -B "$branch"
            warn "$remote/$branch gibt es noch nicht -- lokaler Branch '$branch' angelegt"
        fi
    fi
    # Remote-Name abweichend von origin?
    if [ "$remote" != origin ] && ! g -C "$pfad" remote get-url "$remote" >/dev/null 2>&1; then
        g -C "$pfad" remote rename origin "$remote" 2>/dev/null || g -C "$pfad" remote add "$remote" "$url"
    fi
    if [ "$rekursiv" = 1 ]; then
        if [ -f "$pfad/.gitmodules" ]; then
            echo "    verschachtelte Submodule holen (rekursiv) ..."
            g -C "$pfad" submodule sync -q --recursive 2>/dev/null || true
            g -C "$pfad" submodule update --init --recursive || warn "nicht alle verschachtelten Submodule konnten geholt werden"
        fi
    else
        echo "    (--no-recursively: verschachtelte Submodule nicht geholt)"
    fi
    g add .gitmodules "$pfad"
    echo "    eingetragen in .gitmodules:"; g config -f .gitmodules --get-regexp "^submodule\.$name\." | sed 's/^/      /'
    echo "    -> committen mit:  git.sh --push-all -m \"Submodul $pfad\" --root"
}

# ---------------------------------------------------------------------------
# SUBMODUL(E) AKTUALISIEREN: init wenn noetig, fetch, Branch-Stand (wenn
# "branch" in .gitmodules steht) sonst der eingetragene Zeiger; rekursiv.
# ---------------------------------------------------------------------------
update_one() {
    local pfad=$1 rekursiv=$2
    local top; top=$(git rev-parse --show-toplevel)
    cd "$top"
    pfad=${pfad#./}; pfad=${pfad%/}
    local name; name=$(g config -f .gitmodules --get-regexp '\.path$' | awk -v p="$pfad" '$2==p{sub(/^submodule\./,"",$1); sub(/\.path$/,"",$1); print $1; exit}')
    [ -n "$name" ] || { err "$pfad steht nicht in .gitmodules"; return 1; }
    local branch; branch=$(g config -f .gitmodules "submodule.$name.branch" 2>/dev/null || true)
    info "update $pfad${branch:+  (Branch $branch)}"
    g submodule sync -q -- "$pfad" 2>/dev/null || true
    if [ ! -e "$pfad/.git" ]; then
        echo "    noch nicht geklont -> init"
        g submodule update --init -- "$pfad" || { err "klonen von $pfad fehlgeschlagen"; return 1; }
    fi
    local remote=origin
    if [ -n "$branch" ]; then
        g -C "$pfad" fetch -q "$remote" "$branch" || { err "$pfad: fetch $remote/$branch fehlgeschlagen"; return 1; }
        if g -C "$pfad" symbolic-ref -q HEAD >/dev/null && [ "$(g -C "$pfad" symbolic-ref --short HEAD)" = "$branch" ]; then
            g -C "$pfad" merge -q --ff-only "$remote/$branch" 2>/dev/null || warn "$pfad: $branch ist nicht fast-forward zu $remote/$branch -- bitte von Hand zusammenfuehren"
        else
            g -C "$pfad" checkout -q -B "$branch" "$remote/$branch"
        fi
        echo "    auf $remote/$branch: $(g -C "$pfad" log -1 --format='%h %s')"
    else
        g submodule update --init -- "$pfad"
        echo "    auf Zeiger-Commit: $(g -C "$pfad" log -1 --format='%h %s')"
    fi
    if [ "$rekursiv" = 1 ] && [ -f "$pfad/.gitmodules" ]; then
        g -C "$pfad" submodule sync -q --recursive 2>/dev/null || true
        g -C "$pfad" submodule update --init --recursive || warn "$pfad: nicht alle verschachtelten Submodule geholt"
    fi
}
cmd_update() {   # $1 = rekursiv, dann Pfade (leer = alle)
    local rekursiv=$1; shift
    local top; top=$(git rev-parse --show-toplevel 2>/dev/null) || { err "nicht in einem Git-Repository"; return 1; }
    cd "$top"
    [ -f .gitmodules ] || { echo "keine Submodule (.gitmodules fehlt)"; return 0; }
    local -a pfade=("$@")
    if [ ${#pfade[@]} -eq 0 ]; then
        mapfile -t pfade < <(g config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')
    fi
    local p rc=0
    for p in "${pfade[@]}"; do update_one "$p" "$rekursiv" || rc=1; done
    return $rc
}

# ---------------------------------------------------------------------------
# ZEIGER PRUEFEN: zeigt bookmarks auf einen Submodul-Commit, den kein Remote
# kennt, scheitert auf jedem Host "not our ref", und der Rueckfall holt den
# Branch-Stand -- bei JEDEM Lauf, je Host 10-20 s extra (curl, hello_imgui).
# ---------------------------------------------------------------------------
cmd_check_pointers() {
    local top; top=$(git rev-parse --show-toplevel 2>/dev/null) || { err "nicht in einem Git-Repository"; return 1; }
    cd "$top"; local n=0
    while IFS= read -r line; do
        local pfad=${line#* }; [ -e "$pfad/.git" ] || continue
        local head; head=$(g -C "$pfad" rev-parse HEAD 2>/dev/null) || continue
        if [ -z "$(g -C "$pfad" for-each-ref --count=1 --contains "$head" refs/remotes refs/tags 2>/dev/null)" ]; then
            n=$((n+1))
            local url; url=$(g -C "$pfad" remote get-url origin 2>/dev/null || echo "?")
            local b; b=$(g config -f .gitmodules "submodule.${line%% *}.branch" 2>/dev/null || echo main); b=${b:-main}
            warn "$pfad: $head liegt auf keinem Remote ($url)"
            echo "    Loesung A (veroeffentlichen):  git.sh --push-all -m \"...\" $pfad=origin:$b"
            echo "    Loesung B (auf Upstream setzen, lokale Commits verwerfen):"
            echo "        git -C $pfad fetch origin $b && git -C $pfad checkout -q origin/$b && git add $pfad && git commit -m \"$pfad auf origin/$b\""
        fi
    done < <(g config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^submodule\.//; s/\.path / /')
    [ $n -eq 0 ] && echo "alle Submodul-Zeiger sind veroeffentlicht."
    return 0
}

# ---------------------------------------------------------------------------
# PULL: Fast-Forward von einem Remote, gleiche Schreibweise PFAD[=@REMOTE[/BRANCH]]
# ---------------------------------------------------------------------------
cmd_pull() {   # Argumente: Pfad-Specs; leer = Root + alle Submodule von origin
    local top; top=$(git rev-parse --show-toplevel 2>/dev/null) || { err "nicht in einem Git-Repository"; return 1; }
    cd "$top"
    local -a eintraege=("$@")
    if [ ${#eintraege[@]} -eq 0 ]; then
        eintraege=(".")
        [ -f .gitmodules ] && mapfile -t -O 1 eintraege < <(g config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')
    fi
    local e p sp rc=0
    for e in "${eintraege[@]}"; do
        [ "$e" = "--root" ] && e="."
        [[ "$e" == --root=* ]] && e=".=${e#--root=}"
        p=${e%%=*}; sp=""; [[ "$e" == *=* ]] && sp=${e#*=}
        p=${p#./}; p=${p%/}; [ -z "$p" ] && p="."
        [ "$p" = "." ] || [ -e "$p/.git" ] || { warn "$p ist kein (initialisiertes) Submodul -- uebersprungen"; continue; }
        local r="" b=""
        if [ -n "$sp" ]; then r=${sp#@}; [[ "$r" == */* ]] && { b=${r#*/}; r=${r%%/*}; }; r=${r%%,*}; fi
        [ -n "$r" ] && [ "$r" != "*" ] || r=origin
        local cur; cur=$(g -C "$p" symbolic-ref --short -q HEAD || true)
        [ -n "$b" ] || b=$cur
        if [ -z "$b" ]; then warn "$p: detached HEAD und kein Branch angegeben -- uebersprungen"; continue; fi
        info "pull $p  <-  $r/$b"
        if ! g -C "$p" fetch -q "$r" "$b"; then warn "$p: fetch $r/$b fehlgeschlagen"; rc=1; continue; fi
        if [ "$cur" = "$b" ]; then
            if g -C "$p" merge -q --ff-only "$r/$b" 2>/dev/null; then echo "    $(g -C "$p" log -1 --format='%h %s')"; else warn "$p: $b ist nicht fast-forward zu $r/$b -- bitte von Hand zusammenfuehren"; rc=1; fi
        else
            if g -C "$p" fetch -q "$r" "$b:$b" 2>/dev/null; then echo "    $b aktualisiert (nicht ausgecheckt): $(g -C "$p" log -1 --format='%h %s' "$b")"; else warn "$p: $b nicht fast-forward -- bitte von Hand"; rc=1; fi
        fi
    done
    return $rc
}

# ---------------------------------------------------------------------------
# --push-all / --commit-all (Kern aus git-push-all.sh)
# ---------------------------------------------------------------------------
usage_push() {
    cat <<'EOF'
Usage: git.sh --push-all -m "message" [options] [selection...]

Selection (paths are relative to the root project):
  --root[=SPEC]            the root project itself
  PATH[=SPEC]              this submodule only (not its nested submodules)
  -r, --recursive PATH[=SPEC]
                           this submodule AND all its nested submodules
                           (nested ones inherit SPEC; use "-r ." for everything)

  SPEC = [SOURCE_BRANCH:]@REMOTES[/TARGET_BRANCH]      REMOTES = name | name,name | *
      @origin                    current branch -> origin, same name
      @offline,origin            current branch -> both remotes
      master:@*/master           local "master" -> "master" on ALL remotes
      hub:@origin/hub            local "hub" -> origin/hub
  "@" always marks remotes, so a branch can never be mistaken for one.
  Repeat a PATH to give it several targets:
      external/hub=hub:@origin/hub external/hub=hub:@offline/hub
  Without SPEC: current branch -> origin. A detached HEAD needs a target branch.

  A more specific entry wins, so you can override a remote inside a
  recursive selection:
      -r external/general_c=@gitlab  external/general_c/external/hub=@backup/main

  --include PATH[=SPEC]    same as PATH[=SPEC] (reads better in long lines)
  --exclude PATH           leave this submodule (and everything below) out,
                           even inside a recursive selection

Options:
  -m, --message MSG        commit message (required)
      --remote NAME        default remote if none is given (default: origin)
  -n, --dry-run            show what would happen, change nothing
  -P, --no-push            commit only
  -S, --no-checkout        don't move detached submodules onto their branch
  -h, --help               this help

Examples:
  git.sh --push-all -m "fix" --root -r external/general_c
  git.sh --push-all -m "fix" --root=master:@*/master -r external/general_c=@gitlab
  git.sh --push-all -n -m "test" -r .
EOF
}

cmd_push_all() {
    # ------------------------------------------------------------------ options
    declare -A SEL=()   # exact path     -> remote ("" = default)
    declare -A REC=()   # recursive path -> remote ("" = default)
    declare -A EXCL=()  # excluded path (and everything below it)
    MSG=""
    DEFAULT_REMOTE="origin"
    DRY=0
    PUSH=1
    CHECKOUT=1

    norm() {
        local p="$1"
        p=${p#./}
        while [[ "$p" == */ ]]; do p=${p%/}; done
        [ -z "$p" ] && p="."
        printf '%s' "$p"
    }

    # "path=spec" -> SPEC_PATH / SPEC_REMOTE  (spec kept as text; "" = default)
    split_spec() {
        if [[ "$1" == *=* ]]; then
            SPEC_PATH=$(norm "${1%%=*}")
            SPEC_REMOTE=${1#*=}
            [[ "$SPEC_REMOTE" == *@* ]] || { echo "Error: '$1' -- remotes are written with '@': PATH=[SRC:]@REMOTES[/DST]" >&2; exit 1; }
        elif [[ "$1" == *:* ]]; then
            echo "Error: '$1' -- use PATH=[SRC:]@REMOTES[/DST]" >&2
            exit 1
        else
            SPEC_PATH=$(norm "$1")
            SPEC_REMOTE=""
        fi
    }
    # "[src:]@remotes[/dst]" -> SP_SRC / SP_REMOTES (comma list or "*") / SP_DST
    split_remote_spec() {
        local a="$1"
        SP_SRC=""; SP_REMOTES=""; SP_DST=""
        [ -n "$a" ] || return 0
        if [[ "$a" == *:@* ]]; then SP_SRC=${a%%:@*}; a="@${a#*:@}"; fi
        a=${a#@}
        if [[ "$a" == */* ]]; then SP_REMOTES=${a%%/*}; SP_DST=${a#*/}; else SP_REMOTES=$a; fi
    }
    # add a target to a path (several per path allowed)
    sel_add() { local p=$1 sp=$2; if [ -n "${SEL[$p]+x}" ] && [ -n "${SEL[$p]}" ]; then SEL[$p]="${SEL[$p]}"$'\n'"$sp"; else SEL[$p]=$sp; fi; }

    need_arg() { [ $# -ge 2 ] || { echo "Error: $1 needs an argument" >&2; exit 1; }; }

    while [ $# -gt 0 ]; do
        case "$1" in
            -m|--message)   need_arg "$@"; MSG="$2"; shift 2 ;;
            --message=*)    MSG="${1#*=}"; shift ;;
            --remote)       need_arg "$@"; DEFAULT_REMOTE="$2"; shift 2 ;;
            --remote=*)     DEFAULT_REMOTE="${1#*=}"; shift ;;
            --root)         sel_add "." ""; shift ;;
            --root=*)       split_spec ".=${1#*=}"; sel_add "." "$SPEC_REMOTE"; shift ;;
            -r|--recursive) need_arg "$@"; split_spec "$2"; REC["$SPEC_PATH"]="$SPEC_REMOTE"; shift 2 ;;
            --recursive=*)  split_spec "${1#*=}"; REC["$SPEC_PATH"]="$SPEC_REMOTE"; shift ;;
            -n|--dry-run)   DRY=1; shift ;;
            -P|--no-push)   PUSH=0; shift ;;
            -S|--no-checkout) CHECKOUT=0; shift ;;
            -h|--help)      usage_push; exit 0 ;;
            --include)      need_arg "$@"; split_spec "$2"; sel_add "$SPEC_PATH" "$SPEC_REMOTE"; shift 2 ;;
            --include=*)    split_spec "${1#*=}"; sel_add "$SPEC_PATH" "$SPEC_REMOTE"; shift ;;
            --exclude)      need_arg "$@"; EXCL["$(norm "$2")"]=1; shift 2 ;;
            --exclude=*)    EXCL["$(norm "${1#*=}")"]=1; shift ;;
            --)             shift; while [ $# -gt 0 ]; do split_spec "$1"; sel_add "$SPEC_PATH" "$SPEC_REMOTE"; shift; done ;;
            -*)             echo "Error: unknown option $1" >&2; usage_push; exit 1 ;;
            *)              split_spec "$1"; sel_add "$SPEC_PATH" "$SPEC_REMOTE"; shift ;;
        esac
    done

    if [ -z "$MSG" ]; then
        echo "Error: commit message missing (-m)" >&2; usage_push; exit 1
    fi
    if [ ${#SEL[@]} -eq 0 ] && [ ${#REC[@]} -eq 0 ]; then
        echo "Error: nothing selected (use --root, PATH or -r PATH)" >&2; usage_push; exit 1
    fi

    # ------------------------------------------------------------------ helpers
    g()    { git -c protocol.file.allow=always "$@"; }
    run()  { if [ "$DRY" -eq 1 ]; then echo "    [dry-run] git $*"; else g "$@"; fi; }
    info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
    skip() { printf '\033[2m    %s (not selected)\033[0m\n' "$*"; }
    warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }

    # Prints the spec (remote[:src:]dst) for a repo path, or returns 1 if not selected.
    remote_for() {
        local rel="$1" p best="" bestlen=-1 len
        for p in "${!EXCL[@]}"; do
            if [ "$rel" = "$p" ] || [[ "$rel" == "$p"/* ]]; then return 1; fi     # --exclude wins
        done
        if [ -n "${SEL[$rel]+x}" ]; then
            printf '%s' "${SEL[$rel]}"; return 0
        fi
        for p in "${!REC[@]}"; do
            if [ "$p" = "." ] || [ "$rel" = "$p" ] || [[ "$rel" == "$p"/* ]]; then
                if [ "$p" = "." ]; then len=0; else len=${#p}; fi
                if [ $len -gt $bestlen ]; then best=$p; bestlen=$len; fi
            fi
        done
        [ $bestlen -ge 0 ] || return 1
        # Inherited by a NESTED repo: pass on the remote only -- branch names
        # belong to the repo they were written for.
        if [ "$best" != "$rel" ]; then
            # inherited: remotes only (first target), no branch names
            local erst=${REC[$best]%%$'\n'*}; split_remote_spec "$erst"
            [ -n "$SP_REMOTES" ] && printf '@%s' "$SP_REMOTES"
            return 0                      # ohne Angabe: Vorgabe (@origin), aber AUSGEWAEHLT
        else printf '%s' "${REC[$best]}"; fi
    }

    # Move a detached submodule onto its branch without losing commits/changes.
    ensure_branch() {
        local b="$1" remote="$2" head tip
        PLANNED_BRANCH=""
        [ -n "$b" ] || return 0
        g symbolic-ref -q HEAD >/dev/null && return 0

        g fetch -q "$remote" "$b" 2>/dev/null || true
        head=$(g rev-parse HEAD)
        if g rev-parse -q --verify "refs/heads/$b" >/dev/null; then
            tip=$(g rev-parse "refs/heads/$b")
        elif g rev-parse -q --verify "refs/remotes/$remote/$b" >/dev/null; then
            tip=$(g rev-parse "refs/remotes/$remote/$b")
        else
            tip=""
        fi

        if [ -z "$tip" ] || g merge-base --is-ancestor "$tip" "$head"; then
            echo "    set branch '$b' to current HEAD"
            run checkout -q -B "$b" HEAD
            PLANNED_BRANCH=$b
        elif g merge-base --is-ancestor "$head" "$tip"; then
            echo "    switch to branch '$b' (fast-forward)"
            run checkout -q -B "$b" "$tip"
            PLANNED_BRANCH=$b
        else
            warn "HEAD and branch '$b' have diverged - please merge manually"
        fi
    }

    # ------------------------------------------------------------------ main walk
    process() {
        local dir="$1" branch="$2" rel="$3"
        (
            cd "$dir"
            local remote="" selected=0
            PLANNED_BRANCH=""
            if remote=$(remote_for "$rel"); then selected=1; fi

            local specs=""
            if [ $selected -eq 1 ]; then
                specs=$remote
                [ -n "$specs" ] || specs="@$DEFAULT_REMOTE"
                split_remote_spec "${specs%%$'\n'*}"; remote=${SP_REMOTES%%,*}; [ "$remote" = "*" ] && remote=$(g remote | head -1)
                remote=${remote:-$DEFAULT_REMOTE}
                info "$rel   [targets: $(printf '%s' "$specs" | tr '\n' ' ')]"
                [ "$CHECKOUT" -eq 1 ] && ensure_branch "$branch" "$remote"
            else
                skip "$rel"
            fi

            # 1. Nested submodules first
            local excl=() lines=() line key path name b child
            if [ -f .gitmodules ]; then
                mapfile -t lines < <(g config -f .gitmodules --get-regexp '^submodule\..*\.path$' || true)
                for line in ${lines[@]+"${lines[@]}"}; do
                    key=${line%% *}; path=${line#* }
                    name=${key#submodule.}; name=${name%.path}
                    b=$(g config -f .gitmodules "submodule.$name.branch" || true)
                    if [ "$rel" = "." ]; then child="$path"; else child="$rel/$path"; fi

                    if [ -e "$path/.git" ]; then
                        process "$dir/$path" "$b" "$child"
                        if [ $selected -eq 1 ] && remote_for "$child" >/dev/null; then
                            info "$rel   (back)"
                        fi
                    elif [ $selected -eq 1 ]; then
                        warn "$child is not initialized - skipped"
                    fi

                    # Pointer of an UNselected submodule changed in a selected parent:
                    # only commit it if that commit is already published somewhere.
                    if [ $selected -eq 1 ] && ! remote_for "$child" >/dev/null \
                       && [ -e "$path/.git" ] && ! g diff --quiet --ignore-submodules=dirty HEAD -- "$path" 2>/dev/null; then
                        if [ -n "$(g -C "$path" for-each-ref --count=1 --contains HEAD refs/remotes refs/tags)" ]; then
                            echo "    pointer of $path changed (commit is published) -> included"
                        else
                            warn "pointer of $path points to an unpushed commit -> NOT committed"
                            excl+=("$path")
                        fi
                    fi
                done
            fi

            [ $selected -eq 1 ] || exit 0

            # 2. Commit
            if [ "$DRY" -eq 1 ]; then
                local changes
                changes=$(g status --porcelain)
                if [ -n "$changes" ]; then
                    printf '%s\n' "$changes" | sed 's/^/    /'
                    echo "    [dry-run] git add -A && git commit -m \"$MSG\""
                else
                    echo "    no changes"
                fi
            else
                g add -A
                for path in ${excl[@]+"${excl[@]}"}; do
                    g reset -q -- "$path" 2>/dev/null || true
                done
                if g diff --cached --quiet; then
                    echo "    no changes"
                else
                    g commit -q -m "$MSG"
                    echo "    committed: $(g log -1 --format='%h %s')"
                fi
            fi

            # 3. Push
            if [ "$PUSH" -eq 1 ]; then
                local cur; cur=$(g symbolic-ref --short -q HEAD || true)
                [ -z "$cur" ] && [ "$DRY" -eq 1 ] && cur=${PLANNED_BRANCH:-}
                local sp src dst rlist r
                while IFS= read -r sp; do
                    [ -n "$sp" ] || sp="@$DEFAULT_REMOTE"
                    split_remote_spec "$sp"
                    src=${SP_SRC:-${cur:-HEAD}}; dst=${SP_DST:-${SP_SRC:-$cur}}
                    if [ -n "$SP_SRC" ] && ! g rev-parse -q --verify "refs/heads/$SP_SRC" >/dev/null; then
                        warn "$rel: source branch '$SP_SRC' does not exist - not pushed"; continue
                    fi
                    if [ -z "$dst" ]; then
                        warn "$rel is in detached HEAD - not pushed (give a target: @REMOTE/BRANCH)"; continue
                    fi
                    if [ "$SP_REMOTES" = "*" ]; then rlist=$(g remote | tr '\n' ' '); else rlist=${SP_REMOTES//,/ }; fi
                    for r in $rlist; do
                        if ! g remote get-url "$r" >/dev/null 2>&1; then
                            warn "$rel has no remote '$r' - not pushed (remotes: $(g remote | tr '\n' ' '))"; continue
                        fi
                        # No interactive credential prompt: fail with the URL instead.
                        if [ "$src" = "$dst" ] && [ -n "$cur" ] && [ "$src" = "$cur" ]; then
                            GIT_TERMINAL_PROMPT=0 run push -q -u "$r" "$cur" || { warn "$rel: push to $(g remote get-url "$r") failed (credentials? wrong remote?)"; exit 1; }
                        else
                            GIT_TERMINAL_PROMPT=0 run push -q "$r" "$src:refs/heads/$dst" || { warn "$rel: push to $(g remote get-url "$r") failed (credentials? wrong remote?)"; exit 1; }
                        fi
                        [ "$DRY" -eq 1 ] || echo "    pushed $src -> $r/$dst"
                    done
                done <<< "$specs"
            fi
        )
    }

    TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Error: not a git repository" >&2; exit 1; }
    cd "$TOP"
    for p in "${!EXCL[@]}"; do [ "$p" = "." ] && { echo "Error: --exclude . would exclude everything" >&2; exit 1; }; done

    # Check that every selected path exists as an initialized repo
    for p in "${!SEL[@]}" "${!REC[@]}"; do
        if [ "$p" != "." ] && [ ! -e "$p/.git" ]; then
            echo "Error: '$p' is not an initialized submodule (paths are relative to $TOP)" >&2
            exit 1
        fi
    done

    [ "$DRY" -eq 1 ] && info "DRY RUN - nothing will be changed"
    process "$TOP" "" "."
    info "Done."

}

# ---------------------------------------------------------------------------
# Einstieg
# ---------------------------------------------------------------------------
[ $# -gt 0 ] || { usage_main; exit 1; }
case "$1" in
    --push-all)   shift; cmd_push_all "$@" ;;
    --commit-all) shift; cmd_push_all -r . "$@" ;;
    --clone-submodule)
        shift
        rekursiv=1; remote=origin; gruppen=(); aktuell=()
        # Gruppen aus PFAD URL [BRANCH]; Optionen gelten fuer alle
        while [ $# -gt 0 ]; do
            case "$1" in
                --no-recursively) rekursiv=0; shift ;;
                --remote)         remote=$2; shift 2 ;;
                --clone-submodule) [ ${#aktuell[@]} -ge 2 ] && gruppen+=("${aktuell[0]}|${aktuell[1]}|${aktuell[2]:-}"); aktuell=(); shift ;;
                -*) err "unbekannte Option $1"; exit 1 ;;
                *)  aktuell+=("$1"); shift ;;
            esac
        done
        [ ${#aktuell[@]} -ge 2 ] && gruppen+=("${aktuell[0]}|${aktuell[1]}|${aktuell[2]:-}")
        [ ${#gruppen[@]} -gt 0 ] || { err "--clone-submodule PFAD URL [BRANCH]"; exit 1; }
        rc=0
        for gr in "${gruppen[@]}"; do
            IFS='|' read -r p u b <<< "$gr"
            ( cmd_clone_submodule "$p" "$u" "$b" "$rekursiv" "$remote" ) || rc=1
        done
        exit $rc ;;
    --update-all) shift; rekursiv=1; for a in "$@"; do [ "$a" = --no-recursively ] && rekursiv=0; done; cmd_update "$rekursiv" ;;
    --update)     shift; rekursiv=1; pfade=(); for a in "$@"; do if [ "$a" = --no-recursively ]; then rekursiv=0; else pfade+=("$a"); fi; done
                  [ ${#pfade[@]} -gt 0 ] || { err "--update PFAD [PFAD...]"; exit 1; }; cmd_update "$rekursiv" "${pfade[@]}" ;;
    --check-pointers) cmd_check_pointers ;;
    --pull-all)   shift; cmd_pull ;;
    --pull)       shift; cmd_pull "$@" ;;
    --create-bare)    create_git_repository "$2" ;;
    --create-release) create_release_repository "$2" ;;
    --install)        clone_git_server_binary ;;
    -h|--help)        usage_main ;;
    *) err "unbekannter Befehl $1"; usage_main; exit 1 ;;
esac
