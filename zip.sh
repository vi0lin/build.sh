#!/usr/bin/env bash
# zip.sh – zip one or more directories, respecting .gitignore files
# Requires: bash >= 4, git, zip, (optional) mv_to_laptop
#
# Usage:
#   source zip.sh                  -> only defines the functions
#   zip.sh [paths] [parameters]    -> runs: zip_dirs [paths] [parameters]
#
# The main function is called zip_dirs, not zip: a function named "zip"
# would hide the zip program itself.

# Normalize a submodule path: "./external/pdf" -> "external/pdf/"
_zip_dirs_norm() {
  local p=$1
  while [[ $p == ./* ]]; do p=${p#./}; done
  p=${p#/}
  while [[ $p == */ ]]; do p=${p%/}; done
  [[ -n $p ]] && printf '%s/' "$p"
}

# Should we descend into the nested repo at $1 ("path/")?
# Uses all_subs, sub_in, sub_ex, seen from zip_dirs (bash dynamic scoping).
_zip_dirs_want_sub() {
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
_zip_dirs_list() {
  local tmp=$1 prefix=$2
  local entry path
  while IFS= read -r -d '' entry; do
    path=$prefix$entry
    if [[ $entry == */ ]]; then
      # Git reports nested repositories / submodules as "path/"
      if _zip_dirs_want_sub "$path"; then
        _zip_dirs_list "$tmp" "$path" || return 1
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
_zip_dirs_list_include() {
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
      if _zip_dirs_want_sub "$entry"; then
        _zip_dirs_list "$tmp" "$entry" || return 1
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

# Make $1 unique among the names in used[] (caller's array):
# "app" -> "app", then "app_2", "app_3", ...  Result in uniq.
_zip_dirs_unique() {
  local base=$1 n=2
  uniq=$base
  while [[ -n ${used[$uniq]} ]]; do
    uniq=${base}_$n
    n=$((n + 1))
  done
  used[$uniq]=1
}

# Go back to the start directory and remove the temp dir
# (uses orig, tmp from zip_dirs)
_zip_dirs_cleanup() {
  cd -- "$orig" 2>/dev/null
  rm -rf "$tmp"
}

zip_dirs() {
  local all_subs=false mode=one have_path=false path_arg=.
  local excludes=() includes=() sub_in=() sub_ex=() parts=()
  local -A seen=() inc_seen=() used=()
  local opt val p q added uniq abs name z

  while (($#)); do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: zip.sh [PATHS] [options] [exclude patterns...]
       zip_dirs [PATHS] [options] [exclude patterns...]   (when sourced)

Zips the directories in PATHS (default: current directory), respecting all
.gitignore files, and passes the zip file(s) to mv_to_laptop. The zip files
are created in the current directory.

PATHS is the first plain argument: one directory, or several separated by
commas ("~/proj/a,~/proj/b"). Every further plain argument is an exclude
pattern. All other options apply to every path.

Zip modes:
  --one-zipfile                  (default) Everything goes into one zip:
                                   one path:  <dir>.zip with the contents
                                              of the directory
                                   several:   <dir1>_<dir2>_....zip, each
                                              path as its own folder <dirN>/
  --multiple-zipfiles            One zip per path: <dir1>.zip, <dir2>.zip
  Identical directory names are numbered: app, app_2, app_3, ...

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

PATHS / PATTERNS of options take all following arguments up to the next
option:
  --include build/ notes.txt --exclude ac.mp3 '*.log'
Comma-separated ("a/,b/"), quoted ("a/ b/") and --option=a/,b/ also work,
and options may be repeated. Plain arguments (the zip PATHS and exclude
patterns) must therefore come before the first list option; exclude
patterns may also come after "--". Quote patterns with * or ? so the shell
does not expand them. To use exclude patterns on the current directory,
give "." as PATHS: zip.sh . ac.mp3

Exclude patterns use .gitignore syntax, relative to each zipped directory:
  ac.mp3     file or dir named ac.mp3 at any depth
  build/     directory named build at any depth
  /build     only <dir>/build
  *.log      any .log file

Examples:
  zip.sh
  zip.sh ~/proj/a,~/proj/b --exclude '*.log'
  zip.sh ~/proj/a,~/proj/b --multiple-zipfiles --submodules
  zip.sh . ac.mp3 build/ --include-submodules external/pdf/ external/zlib/
  zip.sh ~/proj/a --exclude ac.mp3 '*.log' --include build/release/ notes.txt
  zip.sh ~/proj/a --include-submodules=external/pdf/,external/zlib/
EOF
        return 0 ;;
      --submodules)
        all_subs=true ;;
      --one-zipfile)
        mode=one ;;
      --multiple-zipfiles)
        mode=multiple ;;
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
              p=$(_zip_dirs_norm "$p")
              p=${p%/}
              [[ -z $p ]] && continue
              includes+=("$p") ;;
            --exclude-submodules)
              p=$(_zip_dirs_norm "$p")
              [[ -z $p ]] && continue
              sub_ex+=("$p") ;;
            *)
              p=$(_zip_dirs_norm "$p")
              [[ -z $p ]] && continue
              sub_in+=("$p") ;;
          esac
          added=1
        done
        if ((added == 0)); then
          echo "zip.sh: $opt needs a path" >&2
          return 1
        fi ;;
      --)
        shift
        excludes+=("$@")
        break ;;
      -*)
        echo "zip.sh: unknown option '$1' (see --help)" >&2
        return 1 ;;
      *)
        # First plain argument: path(s) to zip; all others: excludes
        if $have_path; then
          excludes+=("$1")
        else
          path_arg=$1
          have_path=true
        fi ;;
    esac
    shift
  done

  for p in "${sub_ex[@]}"; do
    for q in "${sub_in[@]}"; do
      if [[ $p == "$q" ]]; then
        echo "zip.sh: '$p' is both included and excluded" >&2
        return 1
      fi
    done
  done

  for p in zip git; do
    if ! command -v "$p" >/dev/null; then
      echo "zip.sh: $p is not installed" >&2
      return 1
    fi
  done

  # Split the path argument on commas, resolve paths, number equal names
  local -a dirs=() names=()
  IFS=',' read -r -a parts <<< "$path_arg"
  for p in "${parts[@]}"; do
    p=${p#"${p%%[![:space:]]*}"}     # trim leading whitespace
    p=${p%"${p##*[![:space:]]}"}     # trim trailing whitespace
    [[ -z $p ]] && continue
    # The shell expands ~ only at the start of the whole argument
    [[ $p == "~" || $p == "~/"* ]] && p=$HOME${p:1}
    if [[ ! -d $p ]]; then
      echo "zip.sh: '$p' is not a directory" >&2
      return 1
    fi
    abs=$(CDPATH='' cd -- "$p" && pwd) || return 1
    name=$(basename -- "$abs")
    [[ -z $name || $name == / ]] && name=root
    _zip_dirs_unique "$name"
    dirs+=("$abs")
    names+=("$uniq")
  done
  if ((${#dirs[@]} == 0)); then
    echo "zip.sh: no path given" >&2
    return 1
  fi

  # Zip file names (index i belongs to dirs[i] in --multiple-zipfiles mode)
  local -a zipnames=()
  if [[ $mode == one ]]; then
    zipnames=("$(IFS=_; printf '%s' "${names[*]}").zip")
  else
    for name in "${names[@]}"; do
      zipnames+=("$name.zip")
    done
  fi

  local orig=$PWD tmp
  tmp=$(mktemp -d) || return 1

  # Empty throwaway repo: used only for git's .gitignore matching
  if ! git init -q "$tmp/repo" || ! mkdir "$tmp/out" "$tmp/stage"; then
    rm -rf "$tmp"
    return 1
  fi

  printf '%s\n' "${excludes[@]}" > "$tmp/excludes"

  # Zips are built in $tmp/out, so they never end up inside each other.
  # Remove old zips first, in case the current directory is zipped too.
  for z in "${zipnames[@]}"; do
    rm -f -- "$orig/$z"
  done

  local i dir inc_count
  for i in "${!dirs[@]}"; do
    dir=${dirs[i]}
    : > "$tmp/files"
    : > "$tmp/dirs"

    if ! cd -- "$dir"; then
      _zip_dirs_cleanup
      return 1
    fi

    if ! _zip_dirs_list "$tmp" ""; then
      _zip_dirs_cleanup
      return 1
    fi

    for p in "${includes[@]}"; do
      inc_count=0
      if ! _zip_dirs_list_include "$tmp" "$p"; then
        _zip_dirs_cleanup
        return 1
      fi
      ((inc_count > 0)) && inc_seen[$p]=1
    done

    if ! cd -- "$orig"; then
      _zip_dirs_cleanup
      return 1
    fi

    # Includes may overlap with the normal listing
    sort -u -o "$tmp/files" "$tmp/files"
    sort -u -o "$tmp/dirs" "$tmp/dirs"
    cat "$tmp/files" "$tmp/dirs" > "$tmp/list_$i"

    [[ -s $tmp/list_$i ]] ||
      echo "zip.sh: warning: nothing to zip in '$dir'" >&2
  done

  # Warn only if a path was not found in any of the zipped directories
  for p in "${includes[@]}"; do
    [[ -n ${inc_seen[$p]} ]] ||
      echo "zip.sh: warning: --include '$p' matched nothing" >&2
  done
  for p in "${sub_in[@]}" "${sub_ex[@]}"; do
    [[ -n ${seen[$p]} ]] ||
      echo "zip.sh: warning: no submodule found at '$p'" >&2
  done

  # No -r: directory entries ("sub/") are added empty, not recursed
  local -a made=()
  if [[ $mode == one ]] && ((${#dirs[@]} > 1)); then
    # One zip, each path as folder <name>/: zip from a staging dir
    # with symlinks <name> -> path (zip follows them)
    : > "$tmp/all"
    for i in "${!dirs[@]}"; do
      [[ -s $tmp/list_$i ]] || continue
      name=${names[i]}
      if ! ln -s -- "${dirs[i]}" "$tmp/stage/$name"; then
        _zip_dirs_cleanup
        return 1
      fi
      while IFS= read -r p; do
        printf '%s/%s\n' "$name" "$p"
      done < "$tmp/list_$i" >> "$tmp/all"
    done
    if [[ -s $tmp/all ]]; then
      if ! (cd -- "$tmp/stage" &&
            command zip "$tmp/out/${zipnames[0]}" -@ < "$tmp/all"); then
        _zip_dirs_cleanup
        return 1
      fi
      made+=("${zipnames[0]}")
    fi
  else
    # One zip per path (also: --one-zipfile with a single path)
    for i in "${!dirs[@]}"; do
      [[ -s $tmp/list_$i ]] || continue
      z=${zipnames[i]}
      if ! (cd -- "${dirs[i]}" &&
            command zip "$tmp/out/$z" -@ < "$tmp/list_$i"); then
        _zip_dirs_cleanup
        return 1
      fi
      made+=("$z")
    done
  fi

  if ((${#made[@]} == 0)); then
    echo "zip.sh: nothing to zip" >&2
    _zip_dirs_cleanup
    return 1
  fi

  for z in "${made[@]}"; do
    if ! mv -f -- "$tmp/out/$z" "$orig/$z"; then
      _zip_dirs_cleanup
      return 1
    fi
  done
  _zip_dirs_cleanup

  local rc=0
  for z in "${made[@]}"; do
    if declare -F mv_to_laptop >/dev/null || command -v mv_to_laptop >/dev/null; then
      mv_to_laptop "$z" || rc=1
    else
      echo "zip.sh: mv_to_laptop not available, zip left at $orig/$z" >&2
    fi
  done
  return $rc
}

# Executed directly (not sourced): pass all arguments to zip_dirs
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  zip_dirs "$@"
  exit $?
fi
