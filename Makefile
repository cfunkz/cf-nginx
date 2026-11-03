VERSION := $(shell sed -n 's/^readonly VERSION="\(.*\)"/\1/p' bin/cf-nginx)
SCRIPTS := bin/cf-nginx install.sh packaging/build-deb.sh tests/run-tests.sh

.PHONY: lint test deb dist clean install uninstall

lint:
	shellcheck -x $(SCRIPTS)
	bash -n bin/cf-nginx

# Modifies /etc/nginx: run in a container/VM only.
test:
	sudo CF_NGINX_TEST=1 tests/run-tests.sh

deb:
	bash packaging/build-deb.sh

dist: deb
	mkdir -p dist
	git archive --format=zip --prefix=cf-nginx-$(VERSION)/ -o dist/cf-nginx-$(VERSION).zip HEAD

install:
	sudo ./install.sh

uninstall:
	sudo ./install.sh --uninstall

clean:
	rm -rf dist
