(require :asdf)
(asdf:load-system :darterfly/image)
;; Explicit boot arguments keep this local review image free of remote REPL keys.
(format t "~&Harbor image: ~a~%"
        (darterfly/image:usb-image
         :path (asdf:system-relative-pathname :darterfly "build/harbor-live.img")
         :boot-args "rd=ram init"))
