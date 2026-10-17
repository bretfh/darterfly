.PHONY: repl check test bare desktop sbcl usb deploy reload bench

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

deploy:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(format t \"~a~%\" (darterfly/image:deploy \"$(HOST)\"))"'

reload:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(format t \"~a~%\" (darterfly/image:deploy \"$(HOST)\" :reload t))"'

bench:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :darterfly/image)" --eval "(darterfly/image:bench $(if $(HOST),:host \"$(HOST)\") $(if $(LABEL),:label \"$(LABEL)\"))"'
