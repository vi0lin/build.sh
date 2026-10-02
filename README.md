# build.sh
Bash scripts for building projects on different machines, with some nice-to-have features.
The user experience and the text flushing on the console are still not good, but it works.

## Installation
```
git clone https://github.com/vi0lin/build.sh && cd build.sh
./build.sh --add-to-path
# then, in any project directory with a build.sh.conf in its root:
build.sh --help
build.sh --show
```
`build.sh` puts its own folder at the front of the `PATH`, so the other scripts
(`publish_release.sh`, `zip.sh`, ...) can be called without `./` and are also brought
to the remote hosts.

# alert.sh
Plays a short sound as a notification, e.g. at the end of a build from a hook
(`hooks/post-run.sh`).

```
alert.sh            # plays "lobby" (default)
alert.sh flute      # plays the sound named "flute"
alert.sh list       # lists all sound names
```

- The sounds are snippets of `ac.mp3` (name | file | start | duration), defined in a
  small table at the end of the script: `lobby`, `flute`, `item`, `up`, `down`, `highflute`.
- `ac.mp3` is searched in the current directory, next to the script, in `sounds/` and
  in `data/shared/sounds/`.
- Playback uses `mpv`. If `mpv` or the sound file is missing, it only beeps or prints a
  note.
- It always exits with 0, so a missing sound never makes a build fail.

# build.sh
Configures and builds a project for several targets on several machines (local, Linux,
FreeBSD, macOS, Windows via cmd or WSL) in parallel. Afterwards it fetches the build
output back to the invoking machine and can run or publish it.

```
build.sh [project dir] [options] target@host [target@host ...]

build.sh deb@local exe@windows apk@buildserver   # only build
build.sh --publish exe@windows apk@buildserver   # build and publish
build.sh --run deb-asan@local                    # build and start
```

**Configuration:** `build.sh.conf` in the project root (this repo ships an example). It
replaces the former `config/` folder:

| Section      | Content |
|--------------|---------|
| `[hosts]`    | name, OS (`posix` / `cmd` / `wsl`), user@host, project path, password (empty = ssh key), git URL |
| `[targets]`  | per target: `CONF_CMD`, `BUILD_CMD`, `RUN_CMD`, `PUBLISH_CMD`, `DOWNLOAD` (the file that is fetched back) |
| `[release]`  | `RELEASE_GIT_URL`, `RELEASE_NOTES` for `publish_release.sh` |
| `[packages]` | package names per package manager, e.g. `apt::zip = zip` |
| `[exclude]`  | patterns like `.gitignore`, not transferred to the hosts |

**Sequence of a run:** By default the local state is committed and pushed, so the hosts
pull the current code (`--no-push` turns this off). Then the project is synced to each
host via git, rsync or tar over ssh. Next, each host runs `CONF_CMD` and `BUILD_CMD`.
Finally the `DOWNLOAD` files are fetched back and the overview is shown. Logs go to
`builds/logs/`.

**Hooks:** Executable files in `hooks/` run automatically, without any configuration:
- `pre-job.<target>.sh` and `post-job.<target>.sh` run on your machine, before the
  transfer and after fetching the output back.
- `pre-action.<target>.sh` and `post-action.<target>.sh` run on the build machine,
  before configuring and after building.
- `<target>@<host>` versions take precedence over the general ones.
- A failing `pre-*` hook stops the job. A failing `post-*` hook marks the job as failed,
  but the build output is kept.

**Important options:**

| Option | Effect |
|--------|--------|
| `--run` / `--run-only` / `--no-run` | after building, run `RUN_CMD`; `--run-only` does not build, it downloads the published release and runs it |
| `--publish` / `--no-publish` | after building, run `PUBLISH_CMD` (usually `publish_release.sh`) |
| `--parallel N` / `--unparallel` | how many jobs may run at the same time **on one host**; different hosts always run in parallel |
| `--clean` / `--clean-deep` / `--clean-all` / `--clean-only` | delete object files / the whole build folder / everything incl. `.deps-cache`; with `--clean-only`, nothing is built afterwards |
| `--configure-only`, `--build-only`, `--dry-run` | run only one step, or only show what would happen |
| `--sync-only`, `--sync-report`, `--full-sync` | only transfer / only show what would be transferred / transfer everything |
| `--hooks-only[-success]`, `--hooks-only-fail` | test the hook chain with a dummy command that succeeds or fails |
| `--show`, `--show-last`, `--list` | show the overview of this run / of the last run / list targets and hosts |
| `--exec CMD` | run a command on the given hosts (`@host` without a target) |
| `--move-to <host> <file>` | copy a single file to a host |
| `--project [@host:]/path` | set the project directory, optionally on another host |
| `--zustand` | snapshot of a running or hanging run (processes, logs, CPU), from a second terminal |
| `--install` / `--no-install` | allow / forbid installing missing tools (may ask for sudo) |
| `--add-to-path` / `--remove-from-path` `[--machine]` | add build.sh to the PATH permanently / undo it (Windows: user PATH, `--machine` for the system PATH) |
| `--wsl-keep-warm` / `--no-wsl-keep-warm` | Windows: keep the WSL VM running, so remote builds don't pay the WSL cold start every time |

The options `--run`, `--publish` and `--parallel` are **positional**: they apply to all
targets that follow on the command line. This lets you mix them:
```
build.sh --publish deb@local exe@windows --run-only apk@windows
```
All options: `build.sh --help`.

**Example:** Push the current changes, build three targets, publish them, and then
install the finished `.apk` on the phone connected to the Windows machine:
```
push() {
  git add .; git commit -m "Publishing"; git push
}
push; build.sh --publish exe@windows apk@buildserver deb@local --run-only apk@windows
```

# git.sh
One tool for a project together with its git submodules. Every git call runs with
`protocol.file.allow=always`, so local paths also work as submodule URLs.

| Command | Effect |
|---------|--------|
| `--push-all -m MSG [selection...]` | commit and push the root project and/or selected submodules |
| `--commit-all -m MSG [-n] [-P] [-S]` | the same for **everything** (`-r .`) |
| `--clone-submodule PATH URL [BRANCH]` | register a submodule (incl. `.gitmodules` entry), clone it recursively and check out its branch (no detached HEAD); `--no-recursively`, `--remote NAME` |
| `--update-all` / `--update PATH...` | init and fetch submodules, then set them to their branch state or pointer commit |
| `--pull-all` / `--pull PATH[=@REMOTE[/BRANCH]]...` | fast-forward from a remote (`.` or `--root` = root project) |
| `--check-pointers` | show submodule pointers that are on no remote, and how to fix them |
| `--create-bare NAME` / `--create-release NAME` | create a bare repository (HEAD → `main`) |

Selection for `--push-all`:
- `--root[=SPEC]` selects the root project.
- `PATH[=SPEC]` selects only this submodule.
- `-r PATH[=SPEC]` selects the submodule and all its nested submodules.
- `--exclude PATH` leaves a submodule out.
- `SPEC = [SOURCE_BRANCH:]@REMOTES[/TARGET_BRANCH]`, e.g. `@origin`, `@offline,origin`,
  `master:@*/master`.

Options: `-n` dry run, `-P` commit only (no push), `-S` don't move detached submodules
onto their branch.

```
git.sh --push-all -m "fix" --root=master:@offline,origin -r external/general_c=@*
git.sh --clone-submodule external/general_c http://192.168.1.69:3000/general_c.git master
git.sh --pull --root=@origin external/timeline=@offline/timeline
```

# publish_release.sh
Packages a finished build and publishes it into a separate releases git repository
(`RELEASE_GIT_URL` from `[release]` in `build.sh.conf`). Usually it is called by
`build.sh --publish` via `PUBLISH_CMD`.

```
publish_release.sh builds/deb-asan                    # release name = folder name: "deb-asan"
publish_release.sh linux-debug builds/deb-asan [ver]  # set the name explicitly
```

- **Package type from the content of the folder:** `.apk` gives an Android package,
  `.exe` gives a Windows zip, otherwise a Linux/macOS binary is packed as `.tar.gz`
  (with `data/`).
- Unsigned intermediate APKs (`-aligned` / `-unaligned`) are ignored.
- **Safety check:** If the package is older than the start of the build, nothing is
  published. The build probably failed without reporting it.
- The version is given explicitly, or else taken from the time of the last git commit.
- `release.json` (name, version, file, sha256, notes) and a `.sha256` file are written.
- The releases repo **does not grow:** every release overwrites the one commit
  (`commit --amend` + force push). Only the current state is kept.

# zip.sh
Zips one or more directories and respects all `.gitignore` files. Then it hands the
zip to `mv_to_laptop`, if available.

```
zip.sh [PATHS] [options] [exclude patterns...]

zip.sh                                         # current directory -> <dir>.zip
zip.sh . ac.mp3 '*.log'                        # with excludes
zip.sh ~/proj/a,~/proj/b                       # one zip: a_b.zip with a/ and b/
zip.sh ~/proj/a,~/proj/b --multiple-zipfiles   # a.zip and b.zip
```

- The first plain argument is the path. You can give several paths separated by
  commas. Every further plain argument is an exclude pattern (`.gitignore` syntax).
- `--one-zipfile` (default) puts everything into one zip. `--multiple-zipfiles` creates
  one zip per path. Directories with the same name are numbered: `app`, `app_2`, ...
- `--submodules` includes the contents of all submodules and nested repos. Without it,
  they are only added as empty folders.
- `--include-submodules PATHS` and `--exclude-submodules PATHS` choose individual
  submodules.
- `--include PATHS` always adds the given paths, even if they are ignored (this also
  works inside submodules). `--exclude PATTERNS` and `--` add further excludes.
- With `source zip.sh` the script only defines the function `zip_dirs`.

All options: `zip.sh --help`. Test: `scripts/test_zip.sh`.
