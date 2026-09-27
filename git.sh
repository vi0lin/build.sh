#!/bin/bash

# --create-bare {name}
create_git_repository() {
  dir=`pwd`
  branchname="main"
  mkdir $1
  cd $1
  git init --bare
  git branch -m $branchname
  # revpack
  echo ""
  cd $dir
}

# --create-release {name}
create_release_repository() {
  git.sh --create-bare $1
  # git -C
  # git -C
  # git -C
}

# --install
clone_git_server_binary() {
  # git clone -b releases https://github.com/vi0lin/git_server
  # linking *.service files
}
