#!/bin/bash
echo """Be Aware, this test will zip the current working directory `pwd`
  zip.sh . ac.mp3"""
read -n 1 -p "Go on? (yY): " ans
if [ "$ans" == "y" ]; then
  zip.sh . ac.mp3
fi
