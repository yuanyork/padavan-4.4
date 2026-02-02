ifndef ROOTDIR
ROOTDIR=../..
endif

USERDIR = $(ROOTDIR)/user
SHDIR = $(ROOTDIR)/user/shared
INSTALLDIR = $(ROOTDIR)/romfs

include $(SHDIR)/boards.mk
include $(SHDIR)/cflags.mk

CFLAGS += -Wall -O2 -s

EXEC = hw_watchdog

all: $(EXEC)

$(EXEC): hw_watchdog.c
	$(CC) $(CFLAGS) -o $@ $<
	$(STRIP) $@

clean:
	rm -f $(EXEC) *.o

romfs:
	$(ROMFSINST) /usr/sbin/$(EXEC)
