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

(test failed-suspend-preparation-wakes-already-suspended-devices
  (let ((woke 0) (restored 0))
    (sb-int:encapsulate 'darterfly/devices::acpi-table 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) 4096))
    (sb-int:encapsulate 'darterfly/devices::ml-phys-read-32 'suspend-failure
      (lambda (f at) (declare (ignore f)) (if (= at 4100) 100 1)))
    (sb-int:encapsulate 'darterfly/power::sleep-type 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) 3))
    (sb-int:encapsulate 'darterfly/power:flush-disks 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) t))
    (sb-int:encapsulate 'darterfly/devices::suspend-devices 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) t))
    (sb-int:encapsulate 'darterfly/devices::wake-devices 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) (incf woke)))
    (sb-int:encapsulate 'darterfly/power::quiet-gpes 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) '(1 2)))
    (sb-int:encapsulate 'darterfly/power::restore-gpes 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) (incf restored)))
    (sb-int:encapsulate 'darterfly/power::arm-rtc-wake 'suspend-failure
      (lambda (&rest args) (declare (ignore args)) (error "RTC preparation failed")))
    (unwind-protect
         (progn
           (signals error (darterfly/power:suspend :wake-after 5))
           (is (= 1 woke) "device locks must be released even before entering S3")
           (is (= 1 restored) "previous GPE enables must be restored"))
      (dolist (name '(darterfly/devices::acpi-table darterfly/devices::ml-phys-read-32
                      darterfly/power::sleep-type darterfly/power:flush-disks
                      darterfly/devices::suspend-devices darterfly/devices::wake-devices
                      darterfly/power::quiet-gpes darterfly/power::restore-gpes
                      darterfly/power::arm-rtc-wake))
        (sb-int:unencapsulate name 'suspend-failure)))))

(test overlapping-suspends-are-rejected-without-entering-drivers
  (let ((entered (sb-thread:make-semaphore))
        (release (sb-thread:make-semaphore))
        (calls 0) (thread nil))
    (sb-int:encapsulate 'darterfly/power::perform-suspend 'overlap
      (lambda (&rest args) (declare (ignore args))
        (incf calls) (sb-thread:signal-semaphore entered)
        (sb-thread:wait-on-semaphore release) 1))
    (unwind-protect
         (progn
           (setf thread (sb-thread:make-thread #'darterfly/power:suspend))
           (is (sb-thread:wait-on-semaphore entered :timeout 2))
           (signals error (darterfly/power:suspend))
           (is (= calls 1))
           (sb-thread:signal-semaphore release)
           (is (= 1 (sb-thread:join-thread thread)))
           (is (null (sb-thread:mutex-owner darterfly/power::*suspend-lock*))))
      (sb-thread:signal-semaphore release)
      (when thread (sb-thread:join-thread thread :timeout 2 :default nil))
      (sb-int:unencapsulate 'darterfly/power::perform-suspend 'overlap))))

(test device-suspend-failure-aborts-traversal-but-wake-continues
  (let ((root (make-instance 'darterfly/devices::entry))
        (visited 0))
    (signals error
      (darterfly/devices::each-device
       (lambda (device) (declare (ignore device)) (incf visited) (error "injected drain failure"))
       :children-first root))
    (is (= visited 1))
    (finishes
      (darterfly/devices::each-device
       (lambda (device) (declare (ignore device)) (incf visited) (error "injected wake failure"))
       :parents-first root))
    (is (= visited 2))))
