(in-package #:darterfly/display)

(defconstant +phy-a+ #x162000)
(defconstant +phy-b+ #x6C000)
(defconstant +cdclk-pll+ #x46070)
(defconstant +cdclk-ctl+ #x46000)
(defparameter *dbuf-slices* '(#x45008 #x44FE8 #x44300 #x44304))
(defconstant +aux-a-well+ #x45444)
(defconstant +ddi-a-well+ #x45454)

(defun lane-registers ()
  (loop for lane below 4
        append (loop for dw in '(#x804 #x888 #x890 #x89C #x894)
                     collect (+ +phy-a+ (* lane #x100) dw))))

(defun saved-registers ()
  (append (list +cdclk-pll+ +cdclk-ctl+ #x64C00 #x64C04
                (+ +phy-a+ #x104) (+ +phy-a+ #x124) (+ +phy-a+ #x128)
                (+ +phy-b+ #x104) (+ +phy-b+ #x124) (+ +phy-b+ #x128))
          *dbuf-slices*
          (list #x45038 #x45048 #x4438C #x45130 #x45134 #x45140 #x45144 #x46434 #x4421C
                +driver-wells+ +aux-a-well+ +ddi-a-well+ (+ +phy-a+ #x28) #x164280)
          (lane-registers)
          (list #xC8254 #xC8258 #xC8250
                #x70030 #x70188 #x7018C #x70190 #x701A4 #x701CC #x7027C #x70268)
          (loop for i below 8 collect (+ #x70240 (* 4 i)))
          (list +plane-surface-a+ +plane-ctl-a+)))

(defvar *saved* nil)
(defvar *saved-plan* nil)
(defvar *saved-psr* nil)
(defvar *sleeping* nil)
(defvar *wake-differences* nil)

(defun saved (offset) (cdr (assoc offset *saved*)))

(defun put-back (offsets)
  (dolist (offset offsets) (setf (reg offset) (saved offset))))

(defun until-set (what offset bit)
  (wait-until what (lambda () (logbitp bit (reg offset))) :seconds 0.05))

(defun init-phy (base misc master)
  (setf (reg misc) (logandc2 (saved misc) (ash 1 23)))
  (put-back (list (+ base #x104) (+ base #x124) (+ base #x128)))
  (when master (set-bits (+ base #x120) (ash 1 24) t))
  (set-bits (+ base #x100) (ash 1 31) t)
  (set-bits (+ base #x14) (ash 1 4) t))

(defun request-wells (offset)
  (let ((want (saved offset)))
    (setf (reg offset) (logand want #xAAAAAAAA))
    (wait-until "the power wells" (lambda () (= (logand (reg offset) #x55555555) (logand want #x55555555))) :seconds 0.05)))

(defun init-display-core ()
  (set-bits #x46408 (ash 1 4) t)
  (init-phy +phy-a+ #x64C00 t)
  (init-phy +phy-b+ #x64C04 nil)
  (set-bits +driver-wells+ 2 t)
  (until-set "power well 1" +driver-wells+ 0)
  (until-set "the PG1 fuses" #x42000 26)
  (let ((ratio (ldb (byte 8 0) (saved +cdclk-pll+))))
    (setf (reg +cdclk-pll+) ratio)
    (setf (reg +cdclk-pll+) (logior ratio (ash 1 31)))
    (until-set "the CDCLK PLL to lock" +cdclk-pll+ 30))
  (put-back (list +cdclk-ctl+))
  (dolist (slice *dbuf-slices*)
    (setf (reg slice) (logandc2 (saved slice) (ash 1 30)))
    (until-set "a DBUF slice" slice 30))
  (put-back '(#x45038 #x45048 #x4438C #x45130 #x45134 #x45140 #x45144))
  (load-dmc)
  (put-back '(#x46434 #x4421C))
  (dolist (wells (list +driver-wells+ +aux-a-well+ +ddi-a-well+)) (request-wells wells))
  (put-back (list* (+ +phy-a+ #x28) #x164280 (lane-registers)))
  (put-back '(#xC8254 #xC8258 #xC8250
              #x70030 #x70188 #x7018C #x70190 #x701A4 #x701CC #x7027C #x70268))
  (put-back (loop for i below 8 collect (+ #x70240 (* 4 i))))
  (put-back (list +plane-surface-a+)))

(defun display-suspend ()
  (hold-awake)
  (setf *sleeping* t)
  (setf *saved* (loop for offset in (saved-registers) collect (cons offset (reg offset)))
        *saved-plan* (plan-display-awake nil 270000 2 8 1)
        *saved-psr* *psr*)
  (when *psr* (disable-psr))
  (output-off (getf *saved-plan* :pll)))

(defun display-wake ()
  (unwind-protect
       (when *saved*
         (wake)
         (init-display-core)
         (output-on *saved-plan* (saved +plane-ctl-a+))
         (setf *flips-armed* nil)
         (arm-flips)
         (when *saved-psr* (enable-psr))
         (setf *wake-differences*
               (loop for (offset . value) in *saved*
                     unless (= value (reg offset))
                       collect (list (format nil "~x" offset) :before (format nil "~x" value) :after (format nil "~x" (reg offset))))))
    (setf *saved* nil *sleeping* nil)
    (release-awake)))

(defun display-sleep (event device)
  (declare (ignore device))
  (when (graphics)
    (case event
      (:suspending (display-suspend))
      (:woke (when *sleeping* (display-wake))))))

(pushnew 'display-sleep devices:*device-hooks*)
