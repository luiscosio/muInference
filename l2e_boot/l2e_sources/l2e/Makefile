# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile for L2E Init
#

# choose your compiler, e.g. gcc/clang
# example override to clang: make run CC=clang

CC = gcc

MOD_PATH    = model.bin
TOK_PATH    = tokenizer.bin
MUSL_SYSROOT = ../../musl_build
MUSL_SYSINC = ../../musl_build/include
MUSL_LIB = ../../musl_build/lib
INITLINKER= lld


# $(CC) static + embedded model & tokenizer, init

.PHONY: l2e_bin_cc
l2e_bin_cc:
	$(CC) -Ofast -static -D LINUXK -D OSPROMPT="ORACLE$$" -D MODPATH=$(MOD_PATH) -D TOKPATH=$(TOK_PATH) run.c -lm -o l2e_bin
	$(CC) -Ofast -static -nostdinc --sysroot $(MUSL_SYSROOT) -isystem $(MUSL_SYSINC) -L$(MUSL_LIB) -fuse-ld=$(INITLINKER) init.c -o init
	strip -s l2e_bin
	strip -s init

# Clean
.PHONY: clean
clean:
	rm -f l2e_bin init busybox
	find . -name '*~'
	find . -name '*~' -delete

.PHONY: list
list:
	@LC_ALL=C $(MAKE) -pRrq -f $(firstword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/(^|\n)# Files(\n|$$)/,/(^|\n) / {if ($$1 !~ "^[#.]") {print $$1}}' | sort | grep -E -v -e '^[^[:alnum:]]' -e '^$@$$'
	
