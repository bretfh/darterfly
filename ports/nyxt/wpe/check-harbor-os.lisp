(require :asdf)
(asdf:load-system :darterfly/test)
(in-package #:darterfly/test)
(dolist (test '(stopping-world-calls-does-not-race-late-replies
               a-world-calls-the-system-through-a-port
               calls-left-behind-by-a-world-that-ends-are-freed
               native-bsd-spawn-on-darterfly
               native-ipc-on-darterfly
               init-keeps-world-jobs-alive-and-quarantines
               an-app-in-its-own-world-opens-a-window-and-dying-takes-it-away))
  (format t "~&[INTEGRATION TEST ~a]~%" test) (finish-output)
  (unless (fiveam:run! test) (uiop:quit 1)))
(format t "~&[NYXT HARBOR OS REGRESSIONS PASS]~%")
