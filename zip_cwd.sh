#!/usr/bin/env bash
# zip_cwd – zip the current directory, respecting .gitignore files
# Requires: bash >= 4, git, zip, (optional) mv_to_laptop
#
# Usage:
#   source zip_cwd.sh            -> only defines the functions
#   zip_cwd.sh [parameters]      -> runs: zip_cwd [parameters]

# Normalize a submodule path: "./external/pdf" -> "external/pdf/"
_zip_cwd_norm() {
  local p=$1
  while [[ $p == ./* ]]; do p=${p#./}; done
  p=${p#/}
  while [[ $p == */ ]]; do p=${p%/}; done
  [[ -n $p ]] && printf '%s/' "$p"
}

# Should we descend into the nested repo at $1 ("path/")?
# Uses all_subs, sub_in, sub_ex, seen from zip_cwd (bash dynamic scoping).
_zip_cwd_want_sub() {
  local path=$1 p
  for p in "${sub_ex[@]}"; do
    [[ $path == "$p" ]] && { seen[$p]=1; return 1; }
  done
  for p in "${sub_in[@]}"; do
    [[ $path == "$p" ]] && { seen[$p]=1; return 0; }
  done
  # An included submodule lies deeper inside this one -> must descend
  for p in "${sub_in[@]}"; do
    [[ $p == "$path"* ]] && return 0
  done
  $all_subs
}

# Recursively list files (not ignored) below ./$prefix into $tmp/files,
# and nested repos/submodules into $tmp/dirs (or recurse into them).
_zip_cwd_list() {
  local tmp=$1 prefix=$2
  local entry path
  while IFS= read -r -d '' entry; do
    path=$prefix$entry
    if [[ $entry == */ ]]; then
      # Git reports nested repositories / submodules as "path/"
      if _zip_cwd_want_sub "$path"; then
        _zip_cwd_list "$tmp" "$path" || return 1
      else
        printf '%s\n' "$path" >> "$tmp/dirs"
      fi
    else
      printf '%s\n' "$path" >> "$tmp/files"
    fi
  done < <(git --git-dir="$tmp/repo/.git" --work-tree="./$prefix" \
             ls-files -z --others --exclude-standard \
             --exclude-from="$tmp/excludes")
}

# List everything matching an --include path, ignoring .gitignore and
# exclude patterns. If the path lies inside a nested repo/submodule,
# git is run from that repo's root so its files can be reached.
# Stores the number of entries found in inc_count (caller's variable,
# no subshell, so updates to seen[] are kept).
_zip_cwd_list_include() {
  local tmp=$1 path=$2
  local root="" d="" comp entry spec count=0
  local -a comps=()
  IFS=/ read -r -a comps <<< "$path"
  for comp in "${comps[@]}"; do
    d=${d:+$d/}$comp
    [[ -e $d/.git ]] && root=$d/
  done
  spec=${path#"$root"}
  while IFS= read -r -d '' entry; do
    entry=$root$entry
    count=$((count + 1))
    if [[ $entry == */ ]]; then
      if _zip_cwd_want_sub "$entry"; then
        _zip_cwd_list "$tmp" "$entry" || return 1
      else
        printf '%s\n' "$entry" >> "$tmp/dirs"
      fi
    else
      printf '%s\n' "$entry" >> "$tmp/files"
    fi
  done < <(git --git-dir="$tmp/repo/.git" --work-tree="./$root" \
             ls-files -z --others -- ${spec:+"$spec"})
  inc_count=$count
}

zip_cwd() {
  local all_subs=false
  local excludes=() includes=() sub_in=() sub_ex=() parts=()
  local -A seen=()
  local opt val p q added

  while (($#)); do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: zip_cwd [options] [exclude patterns...]

Zips the current directory into ./<dirname>.zip (respecting all .gitignore
files) and passes it to mv_to_laptop.

Options:
  --submodules                   Include the contents of all submodules /
                                 nested git repos. Without it they are
                                 added as empty directories.
  --include-submodules PATHS     Include the contents of these submodules
  --submodule PATHS              (same as --include-submodules)
  --exclude-submodules PATHS     Add these submodules only as empty
                                 directories, even with --submodules
  --include PATHS                Always include these files/directories,
                                 even if .gitignore or an exclude pattern
                                 would drop them (also works for paths
                                 inside submodules)
  --exclude PATTERNS             Exclude these (same as plain arguments)
  --                             Everything after this is an exclude pattern

PATHS / PATTERNS take all following arguments up to the next option:
  --include build/ notes.txt --exclude ac.mp3 '*.log'
Comma-separated ("a/,b/"), quoted ("a/ b/") and --option=a/,b/ also work,
and options may be repeated. Plain exclude arguments must therefore come
before the first list option, or after "--". Quote patterns with * or ?
so the shell does not expand them.

Exclude patterns use .gitignore syntax, relative to the current directory:
  ac.mp3     file or dir named ac.mp3 at any depth
  build/     directory named build at any depth
  /build     only ./build
  *.log      any .log file

Examples:
  zip_cwd --submodules --exclude-submodules external/curl/
  zip_cwd --exclude ac.mp3 '*.log' --include build/release/ notes.txt
  zip_cwd ac.mp3 build/ --include-submodules external/pdf/ external/zlib/
  zip_cwd --include-submodules=external/pdf/,external/zlib/
EOF
        return 0 ;;
      --submodules)
        all_subs=true ;;
      --include-submodules|--submodule|--exclude-submodules|--include|--exclude|\
      --include-submodules=*|--submodule=*|--exclude-submodules=*|--include=*|--exclude=*)
        opt=${1%%=*}
        if [[ $1 == *=* ]]; then
          val=${1#*=}
        else
          # Take all following arguments up to the next option (-...)
          val=""
          while (($# >= 2)) && [[ $2 != -* ]]; do
            val+=" $2"
            shift
          done
        fi
        # Split on commas and whitespace: "a,b" or "a b"
        parts=()
        added=0
        IFS=$', \t\n' read -r -a parts <<< "$val"
        for p in "${parts[@]}"; do
          case "$opt" in
            --exclude)
              excludes+=("$p") ;;             # .gitignore syntax, keep as is
            --include)
              p=$(_zip_cwd_norm "$p")
              p=${p%/}
              [[ -z $p ]] && continue
              includes+=("$p") ;;
            --exclude-submodules)
              p=$(_zip_cwd_norm "$p")
              [[ -z $p ]] && continue
              sub_ex+=("$p") ;;
            *)
              p=$(_zip_cwd_norm "$p")
              [[ -z $p ]] && continue
              sub_in+=("$p") ;;
          esac
          added=1
        done
        if ((added == 0)); then
          echo "zip_cwd: $opt needs a path" >&2
          return 1
        fi ;;
      --)
        shift
        excludes+=("$@")
        break ;;
      -*)
        echo "zip_cwd: unknown option '$1' (see --help)" >&2
        return 1 ;;
      *)
        excludes+=("$1") ;;
    esac
    shift
  done

  for p in "${sub_ex[@]}"; do
    for q in "${sub_in[@]}"; do
      if [[ $p == "$q" ]]; then
        echo "zip_cwd: '$p' is both included and excluded" >&2
        return 1
      fi
    done
  done

  for p in zip git; do
    if ! command -v "$p" >/dev/null; then
      echo "zip_cwd: $p is not installed" >&2
      return 1
    fi
  done

  local zipname tmp
  zipname="$(basename "$PWD").zip"
  tmp=$(mktemp -d) || return 1

  # Empty throwaway repo: used only for git's .gitignore matching
  if ! git init -q "$tmp/repo"; then
    rm -rf "$tmp"
    return 1
  fi

  printf '%s\n' "${excludes[@]}" > "$tmp/excludes"
  printf '/%s\n' "$zipname" >> "$tmp/excludes"   # never zip the zip itself
  : > "$tmp/files"
  : > "$tmp/dirs"

  rm -f "$zipname"

  if ! _zip_cwd_list "$tmp" ""; then
    rm -rf "$tmp"
    return 1
  fi

  local inc_count
  for p in "${includes[@]}"; do
    inc_count=0
    if ! _zip_cwd_list_include "$tmp" "$p"; then
      rm -rf "$tmp"
      return 1
    fi
    ((inc_count > 0)) || echo "zip_cwd: warning: --include '$p' matched nothing" >&2
  done

  # Includes may overlap with the normal listing
  sort -u -o "$tmp/files" "$tmp/files"
  sort -u -o "$tmp/dirs" "$tmp/dirs"

  for p in "${sub_in[@]}" "${sub_ex[@]}"; do
    [[ -n ${seen[$p]} ]] ||
      echo "zip_cwd: warning: no submodule found at '$p'" >&2
  done

  if [[ ! -s "$tmp/files" && ! -s "$tmp/dirs" ]]; then
    echo "zip_cwd: nothing to zip" >&2
    rm -rf "$tmp"
    return 1
  fi

  # No -r: directory entries ("sub/") are added empty, not recursed
  if ! cat "$tmp/files" "$tmp/dirs" | zip "$zipname" -@; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  if declare -F mv_to_laptop >/dev/null || command -v mv_to_laptop >/dev/null; then
    mv_to_laptop "$zipname"
  else
    echo "zip_cwd: mv_to_laptop not available, zip left at $PWD/$zipname" >&2
  fi
}

# Executed directly (not sourced): pass all arguments to zip_cwd
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  zip_cwd "$@"
  exit $?
fi
