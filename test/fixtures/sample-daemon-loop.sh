#!/bin/bash
cd /opt/example || exit
while true; do
  claude --continue --permission-mode auto
  sleep 3
done
