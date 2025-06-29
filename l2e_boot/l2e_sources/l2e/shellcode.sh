#!/bin/ash
# Minimal shellcode.sh - just the essential fix

# Kill buggy l2e kernel module process after boot
(sleep 15; killall l2e) &>/dev/null &

# Set a normal prompt
export PS1='l2e@μInference:~# '