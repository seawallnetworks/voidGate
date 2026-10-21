# voidGate
CC      ?= gcc
CLANG   ?= clang
LLVM_STRIP ?= llvm-strip
BPFTOOL ?= bpftool
# The Seawall stack's prefix, which it shares with mini-fw, sw_authd...
PREFIX  ?= /usr/local/seawall
CONFDIR ?= $(PREFIX)/etc/voidgate
# The stack's OpenResty's site lualib; another OpenResty, Kong / APISIX:
# point at their Lua path.
LUA_DIR ?= $(PREFIX)/openresty/site/lualib
ARCH    := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')
# Debian and Ubuntu keep asm/ under /usr/include/<multiarch>; Amazon
# Linux and RHEL have none, and keep it in /usr/include
MULTIARCH ?= $(shell $(CC) -print-multiarch 2>/dev/null)

SRC     := src
BPFDIR  := src/bpf
CFLAGS  := -O2 -g -Wall -Wextra -Wno-unused-parameter -MMD -MP \
	-I$(SRC) -I$(BPFDIR) -DVG_CONF_PATH='"$(CONFDIR)/voidgate.conf"'
LDFLAGS := -lbpf -lelf -lz
BPF_CFLAGS := -O2 -g -target bpf -D__TARGET_ARCH_$(ARCH) \
	-I$(SRC) -I$(BPFDIR) \
	-Wall -Wno-unused-value -Wno-pointer-sign \
	-Wno-compare-distinct-pointer-types \
	-MMD -MP \
	$(if $(MULTIARCH),-isystem /usr/include/$(MULTIARCH))

USER_OBJS := src/voidgate.o src/config.o src/policy.o src/maps.o src/ipaddr.o \
	src/ctl_server.o src/http.o src/log.o
CTL_OBJS  := src/voidgatectl.o

.PHONY: all clean install install-lua uninstall test

all: voidgate voidgatectl t/unit/policy t/unit/cidr

$(BPFDIR)/voidgate.bpf.o: $(BPFDIR)/voidgate.bpf.c $(BPFDIR)/voidgate.h
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
	$(LLVM_STRIP) -g $@

$(BPFDIR)/voidgate.skel.h: $(BPFDIR)/voidgate.bpf.o
	$(BPFTOOL) gen skeleton $< > $@

src/voidgate.o src/maps.o src/policy.o: \
	$(BPFDIR)/voidgate.skel.h

src/%.o: src/%.c
	$(CC) $(CFLAGS) -c $< -o $@

voidgate: $(USER_OBJS)
	$(CC) $(CFLAGS) -o $@ $(USER_OBJS) $(LDFLAGS)

voidgatectl: $(CTL_OBJS)
	$(CC) $(CFLAGS) -o $@ $(CTL_OBJS)

t/unit/policy: t/unit/policy.c src/policy.c src/policy.h \
	src/log.h src/config.h src/maps.h src/ipaddr.h \
	$(BPFDIR)/voidgate.h src/config.o src/ipaddr.o src/log.o
	$(CC) $(CFLAGS) -DVG_CTRL_TEST -MF t/unit/policy.d -o $@ \
		t/unit/policy.c src/policy.c src/config.o src/ipaddr.o \
		src/log.o

t/unit/cidr: t/unit/cidr.c src/config.o src/ipaddr.o src/log.o
	$(CC) $(CFLAGS) -MF t/unit/cidr.d -o $@ t/unit/cidr.c src/config.o \
		src/ipaddr.o src/log.o

# Unit tests, then XDP verdicts: real daemon + t/*.t (needs root).
test: all
	./t/unit/policy
	./t/unit/cidr
	sudo t/bin/run

clean:
	rm -f voidgate voidgatectl t/unit/policy t/unit/cidr t/unit/*.d \
		src/*.o src/*.d \
		$(BPFDIR)/voidgate.bpf.o $(BPFDIR)/voidgate.bpf.d \
		$(BPFDIR)/voidgate.skel.h

-include $(USER_OBJS:.o=.d) $(CTL_OBJS:.o=.d) t/unit/policy.d t/unit/cidr.d \
	 $(BPFDIR)/voidgate.bpf.d

# The config is made on the first start, by voidgate-mkconf from the
# default in share/voidgate: an install never replaces the operator's,
# and each machine gets its own interface. The unit runs
# /usr/local/seawall/sbin/voidgate whatever PREFIX is.
install: all install-lua
	install -D -m 0755 voidgate $(DESTDIR)$(PREFIX)/sbin/voidgate
	install -D -m 0755 voidgatectl $(DESTDIR)$(PREFIX)/bin/voidgatectl
	install -D -m 0755 voidgate-mkconf \
		$(DESTDIR)$(PREFIX)/libexec/voidgate-mkconf
	install -D -m 0644 configs/voidgate.conf \
		$(DESTDIR)$(PREFIX)/share/voidgate/voidgate.conf
	install -d -m 0755 $(DESTDIR)$(CONFDIR)
	install -D -m 0644 voidgate.service \
		$(DESTDIR)/etc/systemd/system/voidgate.service

# keeps $(CONFDIR): the configuration outlives the program
uninstall:
	rm -f $(DESTDIR)$(PREFIX)/sbin/voidgate \
		$(DESTDIR)$(PREFIX)/bin/voidgatectl \
		$(DESTDIR)$(PREFIX)/libexec/voidgate-mkconf \
		$(DESTDIR)$(PREFIX)/share/voidgate/voidgate.conf \
		$(DESTDIR)/etc/systemd/system/voidgate.service \
		$(DESTDIR)$(LUA_DIR)/resty/voidgate.lua
	-rmdir $(DESTDIR)$(PREFIX)/share/voidgate

install-lua:
	install -d $(DESTDIR)$(LUA_DIR)/resty
	install -m 0644 lua/resty/voidgate.lua $(DESTDIR)$(LUA_DIR)/resty/voidgate.lua
