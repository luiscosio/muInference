#!/bin/ash
# Wrapper for llama2.c inference, passing all arguments
/l2e /model.bin -n 256 -i "$*"