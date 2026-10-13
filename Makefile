.PHONY: repl check test tahoe

EVAL ?= (finch/tahoe:boot)
export EVAL

GUIX := guix shell -m manifest.scm --
ENV  := CL_SOURCE_REGISTRY="$$PWD//:$$GUIX_ENVIRONMENT/share/common-lisp//" ASDF_OUTPUT_TRANSLATIONS="/:$$HOME/.cache/common-lisp/finch/"
SBCL := sbcl --no-userinit --eval "(require :asdf)"

repl:
	$(GUIX) sh -c '$(ENV) $(SBCL) --eval "(asdf:load-system :finch)"'

check:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --load bench/check.lisp'

test:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:test-system :finch)"'

tahoe:
	$(GUIX) sh -c '$(ENV) $(SBCL) --non-interactive --eval "(asdf:load-system :finch/tahoe)" --eval "(print (eval (read-from-string (uiop:getenv \"EVAL\"))))"'
