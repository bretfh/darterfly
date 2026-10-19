(require :asdf)
(asdf:load-system :darterfly/test)
(setf darterfly/test::*darterfly-root* #p"/darterfly/")

(push 'darterfly/start:boot sb-ext:*init-hooks*)
(sb-ext:enable-debugger)
(sb-ext:save-lisp-and-die (second sb-ext:*posix-argv*))
