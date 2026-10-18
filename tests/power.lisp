(in-package #:darterfly/test)

(def-suite power :in host)
(in-suite power)

(defmacro with-fake-backlight ((level reads saves) &body body)
  `(let ((,level 0.8) (,reads 0) (,saves 0))
     (sb-int:encapsulate 'darterfly/devices:brightness 'fake (lambda (f) (declare (ignore f)) (incf ,reads) ,level))
     (sb-int:encapsulate 'darterfly/devices:set-brightness 'fake
                         (lambda (f fraction &key (save t)) (declare (ignore f)) (when save (incf ,saves)) (setf ,level (max 0.05 fraction))))
     (unwind-protect (progn ,@body)
       (sb-int:unencapsulate 'darterfly/devices:brightness 'fake)
       (sb-int:unencapsulate 'darterfly/devices:set-brightness 'fake))))

(test an-idle-screen-dims-and-input-brings-it-back
  (with-fake-backlight (level reads saves)
    (let ((after darterfly/power:*dim-after*))
      (setf darterfly/power:*dim-after* 0.3
            darterfly/power::*last-activity* (get-internal-real-time)
            darterfly/power::*dimmed-from* nil)
    (let ((thread (sb-thread:make-thread #'darterfly/power:dim-when-idle :name "dim test")))
      (unwind-protect
           (progn
             (sleep 0.1)
             (is (= level 0.8) "not yet idle")
             (sleep 0.5)
             (is (< (abs (- level 0.24)) 1e-6) "dimmed to 30% after the idle time")
             (darterfly/power:note-activity)
             (is (= level 0.8) "input brings the brightness back")
             (is (zerop saves) "dimming never overwrites the saved brightness")
             (setf level 0.06)
             (sleep 0.6)
             (let ((before reads))
               (sleep 0.5)
               (is (= before reads) "a screen too dim to dim further leaves the thread waiting, not spinning")))
        (sb-thread:terminate-thread thread)
        (setf darterfly/power:*dim-after* after darterfly/power::*dimmed-from* nil))))))
