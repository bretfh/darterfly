(require :asdf)
(asdf:load-system :darterfly/test)
;; Focused acceptance checks; full baseline suite remains separately reported.
(let ((results (mapcan #'fiveam:run
                      '(darterfly/test::kit darterfly/test::server darterfly/test::onboarding))))
  (fiveam:explain! results)
  (unless (fiveam:results-status results) (uiop:quit 1)))
