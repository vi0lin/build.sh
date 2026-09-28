# ---------------------------------------------------------------------------
# Kreuzbau fuer Windows (x86_64) mit MinGW-w64 -- von Linux oder FreeBSD aus.
#
# Verwendung in build.sh.conf, [targets]:
#   CONF_CMD[exe]='cmake -B builds/exe -S . -G Ninja -DCMAKE_BUILD_TYPE=Release
#                  -DCMAKE_TOOLCHAIN_FILE=$XBM_WERKZEUG_DIR/toolchains/windows-mingw.cmake'
# build.sh setzt XBM_WERKZEUG_DIR auf den Ordner, in den es sich samt
# toolchains/ auf jeden Bauhost kopiert.
#
# Voraussetzung auf dem Bauhost:  Debian/Ubuntu  apt install g++-mingw-w64-x86-64
#                                 FreeBSD        pkg install mingw64-gcc
# NICHT noetig, wenn das Ziel ohnehin AUF einem Windows-Host gebaut wird
# (so wie exe@windows bei bookmarks) -- dann nimmt CMake den dortigen gcc.
# ---------------------------------------------------------------------------
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(_mingw x86_64-w64-mingw32)
# Auf Debian/Ubuntu gibt es -posix (Threads/std::thread) und -win32.
find_program(CMAKE_C_COMPILER   NAMES ${_mingw}-gcc-posix ${_mingw}-gcc)
find_program(CMAKE_CXX_COMPILER NAMES ${_mingw}-g++-posix ${_mingw}-g++)
find_program(CMAKE_RC_COMPILER  NAMES ${_mingw}-windres)
if (NOT CMAKE_C_COMPILER OR NOT CMAKE_CXX_COMPILER)
    message(FATAL_ERROR "MinGW-w64 (${_mingw}-gcc/g++) nicht gefunden -- siehe Kopf dieser Datei")
endif()

# Bibliotheken und Header nur aus der MinGW-Umgebung, Programme vom Host.
set(CMAKE_FIND_ROOT_PATH /usr/${_mingw} /usr/local/${_mingw})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Laufzeitbibliotheken statisch: die .exe laeuft dann ohne mitgelieferte
# libgcc/libstdc++/winpthread-DLLs.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++ -static")
