(in-package #:finch/test)

(def-suite kernel :in all)
(in-suite kernel)

(defun console-lines (out)
  (mapcar (lambda (line) (string-right-trim '(#\Return) line))
          (uiop:split-string out :separator '(#\Newline))))

(test finch-boots
  (image:image)
  (let ((lines (console-lines (image:check-boot))))
    (is (find "finch Kernel Version" lines :test #'search))
    (is (find "bsd_init: boot-args console=ttyS0 quiet halt" lines :test #'string=))
    (is (find "load_init_program: halt" lines :test #'string=))))

(test finch-boots-to-launchd
  (let ((c (image:console)))
    (unwind-protect
         (progn
           (is (image:expect c "load_init_program: /sbin/launchd pid 1"))
           (is (image:expect c "launchd: pid 1"))
           (image:expect c "# ")
           (image:send c "(run \"/bin/launchctl\" \"list\")")
           (is (search "finch.console" (image:expect c "# ")))
           (image:send c "(+ 1 2)")
           (is (search (format nil "~%3~%") (image:expect c "# ")))
           (image:send c "(halt)"))
      (image:finish c))))

(test finch-draws
  (let ((c (image:console)))
    (unwind-protect
         (progn
           (image:expect c "# ")
           (image:send c "(finch/io:test-pattern (finch/io:open-framebuffer))")
           (image:expect c "# ")
           (let ((screen (image:screendump)))
             (is (= #xffff0000 (image:pixel screen 10 10)))
             (is (= #xff00ff00 (image:pixel screen 1000 10)))
             (is (= #xff0000ff (image:pixel screen 10 700)))
             (is (= #xff202020 (image:pixel screen 1000 700))))
           (image:send c "(halt)"))
      (image:finish c))))

(test finch-opens-a-window
  (let ((c (image:console)))
    (unwind-protect
         (progn
           (image:expect c "# ")
           (image:send c "(spawn \"/Applications/Hello.app/Contents/MacOS/Hello\")")
           (image:expect c "# ")
           (let ((screen (loop :repeat 30
                               :for screen := (image:screendump)
                               :until (= #xffffffff (image:pixel screen 500 300))
                               :finally (return screen))))
             (is (= #xff2e5c8f (image:pixel screen 5 5)) "desktop ~x" (image:pixel screen 5 5))
             (is (= #xffd9d9d9 (image:pixel screen 300 140)) "title ~x" (image:pixel screen 300 140))
             (is (= #xffededed (image:pixel screen 215 300)) "frame ~x" (image:pixel screen 215 300))
             (is (= #xffffffff (image:pixel screen 500 300)) "content ~x" (image:pixel screen 500 300))
             (is (< 50 (loop :for y :from 194 :below 230
                             :sum (loop :for x :from 244 :below 480
                                        :count (< (ldb (byte 8 0) (image:pixel screen x y)) 100))))
                 "the words")
             (is (< 5 (loop :for y :from 136 :below 160
                            :sum (loop :for x :from 470 :below 560
                                       :count (< (ldb (byte 8 0) (image:pixel screen x y)) 120))))
                 "the title"))
           (image:pointer 100 600)
           (let ((screen (loop :repeat 20
                               :for screen := (image:screendump)
                               :until (= #xff000000 (image:pixel screen 100 600))
                               :finally (return screen))))
             (is (= #xff000000 (image:pixel screen 100 600)) "cursor tip ~x" (image:pixel screen 100 600)))
           (image:pointer 300 145)
           (image:pointer 300 145 t)
           (image:pointer 350 245)
           (image:pointer 350 245 nil)
           (let ((screen (loop :repeat 20
                               :for screen := (image:screendump)
                               :until (= #xff2e5c8f (image:pixel screen 230 300))
                               :do (sleep 0.05)
                               :finally (return screen))))
             (is (= #xff2e5c8f (image:pixel screen 230 300)) "old place ~x" (image:pixel screen 230 300))
             (is (= #xffffffff (image:pixel screen 550 400)) "moved content ~x" (image:pixel screen 550 400)))
           (image:send c "(run \"/bin/launchctl\" \"list\")")
           (is (search "com.apple.WindowServer" (image:expect c "# ")))
           (image:send c "(halt)"))
      (image:finish c))))

(test finch-has-a-terminal
  (let ((c (image:console)))
    (unwind-protect
         (progn
           (image:expect c "# ")
           (image:send c "(spawn \"/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal\")")
           (image:expect c "# ")
           (flet ((screen-text (until)
                    (loop :repeat 60
                          :do (image:send c "(progn (cat \"/tmp/Terminal.txt\") :done)")
                              (let ((text (image:expect c ":DONE")))
                                (when (search until text) (return text)))
                              (sleep 0.05))))
             (is (screen-text "# "))
             (image:send-keys (format nil "(+ 1 2)~%"))
             (let ((text (screen-text (format nil "(+ 1 2)~%3"))))
               (is (search (format nil "(+ 1 2)~%3") text) "~s" text)))
           (image:send c "(halt)"))
      (image:finish c))))
