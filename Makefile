.PHONY: repl check test bare desktop sbcl usb deploy

GUIX := guix shell -m manifest.scm --
ENV  := CL_SOURCE_REGISTRY="$$PWD//:$$GUIX_ENVIRONMENT/share/common-lisp//" ASDF_OUTPUT_TRANSLATIONS="/:$$HOME/.cache/common-lisp/finch/"
SBCL := sbcl --no-userinit --eval "(require :asdf)"

repl:
	$(GUIX) sh -c '$(ENV) $(SBCL) --eval "(asdf:load-system :finch)"'

check:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --load bench/check.lisp'

test:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:test-system :finch)"'

bare:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :finch/image)" --eval "(finch/image:bare-boot)"'

desktop:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :finch/image)" --eval "(finch/image:desktop)"'

sbcl:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :finch/image)" --eval "(finch/image:build-sbcl)"'

usb:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :finch/image)" --eval "(format t \"~a~%\" (finch/image:usb-image))"'

deploy:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :finch/image)" --eval "(format t \"~a~%\" (finch/image:deploy \"$(HOST)\"))"'
