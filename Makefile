.PHONY: repl check test bare desktop sbcl usb deploy generation reload bench

GUIX := guix shell -m manifest.scm --
ENV  := CL_SOURCE_REGISTRY="$$PWD//:$$GUIX_ENVIRONMENT/share/common-lisp//" ASDF_OUTPUT_TRANSLATIONS="/:$$HOME/.cache/common-lisp/darterfly/"
SBCL := sbcl --no-userinit --eval "(require :asdf)"

repl:
	$(GUIX) sh -c '$(ENV) $(SBCL) --eval "(asdf:load-system :darterfly)"'

check:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --load bench/check.lisp'

test:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:test-system :darterfly)"'

bare:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(darterfly/image:bare-boot)"'

desktop:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(darterfly/image:desktop)"'

sbcl:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(darterfly/image:build-sbcl)"'

usb:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(format t \"~a~%\" (darterfly/image:usb-image))"'

generation:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(format t \"~a~%\" (darterfly/image:push-generation \"$(HOST)\"))"'

deploy:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(format t \"~a~%\" (darterfly/image:deploy \"$(HOST)\"))"'

reload:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(format t \"~a~%\" (darterfly/image:deploy \"$(HOST)\" :reload t))"'

bench:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(darterfly/image:bench $(if $(HOST),:host \"$(HOST)\") $(if $(LABEL),:label \"$(LABEL)\"))"'

# Release builds use fresh source trees and private caches; see release/README.org.
# Add RELEASE_FLAGS=--allow-dirty to capture uncommitted development work.
.PHONY: baseline release test-host test-guest test-recovery test-release-tools
RELEASE_FLAGS ?=

baseline:
	python3 tools/release.py run --tier smoke --image --bench 5 $(RELEASE_FLAGS)

release:
	python3 tools/release.py run --tier all --image --bench 5 $(RELEASE_FLAGS)

test-host:
	python3 tools/release.py run --tier host $(RELEASE_FLAGS)

test-guest:
	python3 tools/release.py run --tier guest $(RELEASE_FLAGS)

test-recovery:
	python3 tools/release.py run --tier recovery $(RELEASE_FLAGS)

test-release-tools:
	python3 -m unittest discover -s tests -p 'test_release.py'

# Focused browser-platform IPC checks; run `make sbcl` before the first guest run.
.PHONY: test-local-sockets test-local-sockets-guest
test-local-sockets:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/test)" --eval "(unless (fiveam:run! (quote darterfly/test::local-socket)) (uiop:quit 1))"'

test-local-sockets-guest:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/test)" --eval "(unless (fiveam:run! (quote darterfly/test::socketpair-c-abi-on-darterfly)) (uiop:quit 1))"'
