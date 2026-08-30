.PHONY: lint test install uninstall

lint:
	shellcheck -S warning bin/*.sh lib/*.sh install.sh uninstall.sh test/*.sh

test:
	bash test/run-fixture-tests.sh
	bash test/run-cli-tests.sh

install:
	sudo ./install.sh $(ARGS)

uninstall:
	sudo ./uninstall.sh $(ARGS)
