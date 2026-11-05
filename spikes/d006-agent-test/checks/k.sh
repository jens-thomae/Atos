#!/bin/bash
# k.sh <shotname> <wtype args...>   (sends keys then screenshots)
source $HOME/agent-test/tools/desktop.env; s=$1; shift
wtype -s 300 "$@"; sleep 1; grim /tmp/$s.png
