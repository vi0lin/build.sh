# build.sh
Bash-Script for building projects on different machines with nice to have features.
The User Experience And Text Flushing On The Console Is Still Not Good - But It Works.

# Usage
This Github Repo Delivers A '''config/''' Folder.
Its An Example How To Set Projects Up For Running build.sh

# Features:
* defining build targets for cmake
* defining hosts
* configuring and building projects parallel and on different machines
* defining release.git repository
* defining a repository, that machines will pull from
* retain their build output back to the invoking machine
* publishing
* ./build.sh --add-to-path (brings it into the environment path: Linux/FreeBSD/macOS via the
  shell startup files, Windows via the user PATH; add --machine for the system PATH)
* ./build.sh --remove-from-path (undoes it)
* ./build.sh --wsl-keep-warm / --no-wsl-keep-warm (Windows: keeps the WSL VM running,
  so remote builds do not pay the WSL cold start every time)
* ./build.sh --install (allows installing missing tools, may ask for sudo)
* ./build.sh --help (shows the functions - someday the functions will be better explained)
* excluding logic

# Example
This will push the current changes of the project to its git repository.
Then it builds the project as defined.
--run-only will in my case pull the .apk and install it over cable to my connected phone. (that function will be renamed)
'''
push() {
  git add .; git commit -m "Publishing"; git push
}
push; build.sh --publish exe@windows apk@buildserver deb@local --run-only apk@windows
'''
