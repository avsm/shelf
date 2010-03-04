.PHONY: all

all:
	cd lib && $(MAKE) all

install:
	cd lib && $(MAKE) libinstall

uninstall:
	cd lib && $(MAKE) libuninstall

reinstall:
	-$(MAKE) uninstall
	$(MAKE) install

tests:
	cd tests && $(MAKE) all

clean:
	cd lib && $(MAKE) clean
