;; Development-only native review window. Load from Terminal in the Harbor VM:
;; (load "/usr/src/darterfly/tools/harbor/control-review.lisp")
(in-package #:darterfly/kit)

(defvar *review-controls* nil)
(defvar *review-window* nil)
(defvar *review-actions* 0)

(defun review-state ()
  (let ((entry (getf *review-controls* :entry)) (popup (getf *review-controls* :popup))
        (check (getf *review-controls* :check)) (slider (getf *review-controls* :slider)))
    (list :text (string-value entry) :choice (selected-value popup) :checked (checked-p check)
          :slider (slider-value slider) :enabled (button-enabled entry) :error (entry-error entry)
          :long (selected-value (getf *review-controls* :long)) :actions *review-actions*
          :frame (list (window-x *review-window*) (window-y *review-window*)
                       (window-width *review-window*) (window-height *review-window*)))))

(defun review-note (event status)
  (setf (string-value status) (format nil "~a" event))
  (with-open-file (out "/dev/console" :direction :output :if-exists :append)
    (format out "~&HARBOR-CONTROL ~s ~s~%" event (review-state))))

(defun start-control-review ()
  (bsd:fork
   (lambda ()
     (let ((*application* (make-instance 'application)) (*run-set* nil)
           (*menus* (standard-menus "Control Review")))
       (setf (bsd::proc-comm bsd:*proc*) "Control Review")
       (let* ((window (make-window :title "Shared controls — native review" :x 240 :y 100
                                  :width 800 :height 550 :min-width 800 :min-height 550))
              (page (content-view window))
              (status (make-instance 'text-field :string "Tab through the controls; Escape cancels open choices."
                                     :font-size 11 :text-color (theme-color :muted) :frame #(24 454 730 22)))
              (validation (make-instance 'text-field :string "Enter a name, then press Return."
                                         :font-size 11 :text-color (theme-color :muted) :frame #(160 126 500 22)))
              (entry (make-instance 'entry-field :string "Darterfly" :frame #(160 94 360 26)
                         :validator (lambda (value)
                                      (let ((error (and (zerop (length value)) "Enter a name to continue.")))
                                        (setf (string-value validation) (or error "Name is ready."))
                                        error))
                         :action (lambda (sender) (declare (ignore sender)) (review-note :name status))))
              (popup (make-instance 'popup-button :frame #(160 164 260 26) :value :ocean
                         :choices '((:label "Ocean" :value :ocean)
                                    (:label "Automatic" :value :auto :enabled nil :reason "No network")
                                    (:label "Forest" :value :forest)
                                    (:label "Slate" :value :slate))
                         :action (lambda (sender) (declare (ignore sender)) (review-note :choice status))))
              (check (make-instance 'checkbox :frame #(160 220 360 26) :title "Keep my place when I return"
                                   :checked t :action (lambda (sender) (declare (ignore sender)) (review-note :check status))))
              (value (make-instance 'text-field :string "50%" :frame #(460 270 80 24)))
              (slider (make-instance 'slider :frame #(160 266 280 26) :value 50
                         :action (lambda (sender) (setf (string-value value) (format nil "~d%" (slider-value sender)))
                                           (review-note :slider status))))
              (long (make-instance 'popup-button :frame #(548 164 200 26) :value 0
                       :choices (loop for i below 40 collect (list :label (format nil "Choice ~2,'0d" i) :value i))
                       :action (lambda (sender) (declare (ignore sender)) (review-note :long status))))
              (actions nil))
         (setf *review-window* window *review-actions* 0
               *review-controls* (list :entry entry :popup popup :check check :slider slider :long long))
         (flet ((caption (text x y &optional (size 12))
                  (add-subview page (make-instance 'text-field :string text :font-size size
                                     :text-color (theme-color :muted) :frame (vector x y 720 28)))))
           (caption "Shared controls" 24 16 18)
           (caption "A native toolkit review. These controls change only this test window." 24 48)
           (caption "Name" 24 98) (caption "Choice" 24 168) (caption "Options" 24 224) (caption "Level" 24 270)
           (caption "Commands" 24 366))
         (dolist (control (list entry validation popup long check slider value)) (add-subview page control))
         (loop for label in '("Secondary" "Primary" "Review…" "Remove…")
               for role in '(:secondary :primary :caution :danger) for x from 24 by 122 do
                 (let ((name label))
                   (let ((button (make-instance 'button :title name :role role :frame (vector x 394 110 26)
                                  :action (lambda (sender) (declare (ignore sender)) (incf *review-actions*) (review-note name status)))))
                     (push button actions) (add-subview page button))))
         (add-subview page (make-instance 'button :title "Unavailable" :enabled nil :frame #(512 394 126 26)))
         (add-subview page
           (make-instance 'checkbox :title "Enable controls" :checked t :frame #(24 316 220 26)
             :action (lambda (sender)
                       (dolist (target (append actions (list entry popup long check slider)))
                         (setf (button-enabled target) (checked-p sender)))
                       (review-note :enabled status))))
         (let* ((children (subviews page)) (enable (car (last children)))
                (before (position (car (last actions)) children)))
           (setf (subviews page) (append (subseq children 0 before) (list enable)
                                        (butlast (subseq children before)))))
         (add-subview page status)
         (set-key-focus window entry t)
         (show window)
         (review-note :ready status)
         (run))))))

(start-control-review)
