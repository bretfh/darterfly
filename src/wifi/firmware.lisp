(in-package #:darterfly/wifi)

(defstruct firmware version human sections iml commands api capabilities phy-sku cpus pnvm)

(defconstant +tlv-magic+ #x0A4C5749)
(defconstant +cpu-separator+ #xFFFFCCCC)
(defconstant +paging-separator+ #xAAAABBBB)

(defun u32le (v i)
  (logior (aref v i) (ash (aref v (+ i 1)) 8) (ash (aref v (+ i 2)) 16) (ash (aref v (+ i 3)) 24)))

(defun set-bits (bits index flags)
  (dotimes (i 32 bits)
    (when (logbitp i flags) (setf bits (logior bits (ash 1 (+ i (* 32 index))))))))

(defun parse-firmware (octets)
  (let ((v (octets octets)))
    (unless (and (>= (length v) 88) (zerop (u32le v 0)) (= +tlv-magic+ (u32le v 4)))
      (error "not an iwlwifi firmware file"))
    (let ((fw (make-firmware :version (let ((ver (u32le v 72)))
                                        (list (ldb (byte 8 24) ver) (ldb (byte 8 16) ver) (ldb (byte 8 8) ver)))
                             :human (string-right-trim '(#\Nul) (map 'string #'code-char (subseq v 8 72)))
                             :api 0 :capabilities 0)))
      (loop with at = 88
            while (<= (+ at 8) (length v))
            do (let* ((type (u32le v at)) (length (u32le v (+ at 4))) (start (+ at 8)) (end (+ start length)))
                 (when (> end (length v)) (error "firmware TLV ~d runs past the end" type))
                 (case type
                   (19 (push (cons (u32le v start) (subseq v (+ start 4) end)) (firmware-sections fw)))
                   (23 (setf (firmware-phy-sku fw) (u32le v start)))
                   (27 (setf (firmware-cpus fw) (u32le v start)))
                   (29 (setf (firmware-api fw) (set-bits (firmware-api fw) (u32le v start) (u32le v (+ start 4)))))
                   (30 (setf (firmware-capabilities fw) (set-bits (firmware-capabilities fw) (u32le v start) (u32le v (+ start 4)))))
                   (48 (setf (firmware-commands fw)
                             (loop for i from start below (- end 3) by 4
                                   collect (list (aref v (1+ i)) (aref v i) (aref v (+ i 2)) (aref v (+ i 3))))))
                   (52 (setf (firmware-iml fw) (subseq v start end)))
                   (74 (setf (firmware-pnvm fw) (subseq v start end))))
                 (setf at (+ start (* 4 (ceiling length 4))))))
      (setf (firmware-sections fw) (nreverse (firmware-sections fw)))
      fw)))

(defun firmware-images (fw)
  (let ((groups (list nil)))
    (dolist (s (firmware-sections fw))
      (if (member (car s) (list +cpu-separator+ +paging-separator+))
          (push nil groups)
          (push s (first groups))))
    (destructuring-bind (&optional lmac umac paging &rest more) (mapcar #'reverse (reverse groups))
      (declare (ignore more))
      (list :lmac lmac :umac umac :paging paging))))

(defun command-version (fw group command)
  (third (find-if (lambda (c) (and (= group (first c)) (= command (second c)))) (firmware-commands fw))))
