(in-package #:darterfly/edit)

(defclass buffer ()
  ((lines :initarg :lines :accessor buffer-lines)
   (path :initarg :path :initform nil :accessor buffer-path)
   (point-line :initform 0 :accessor buffer-point-line)
   (point-col :initform 0 :accessor buffer-point-col)
   (goal :initform nil :accessor buffer-goal)
   (edits :initform 0 :accessor buffer-edits)
   (saved :initform 0 :accessor buffer-saved)))

(defun split-lines (text)
  (let ((out (make-array 0 :adjustable t :fill-pointer 0))
        (from 0))
    (loop :for at := (position #\Newline text :start from)
          :do (vector-push-extend (subseq text from (or at (length text))) out)
              (if at (setf from (1+ at)) (return)))
    out))

(defun make-buffer (&key (text "") path)
  (make-instance 'buffer :lines (split-lines text) :path path))

(defun buffer-line-count (buffer)
  (length (buffer-lines buffer)))

(defun buffer-line (buffer n)
  (aref (buffer-lines buffer) n))

(defun (setf buffer-line) (text buffer n)
  (setf (aref (buffer-lines buffer) n) text))

(defun buffer-text (buffer)
  (with-output-to-string (s)
    (loop :for line :across (buffer-lines buffer)
          :for first := t :then nil
          :do (unless first (write-char #\Newline s))
              (write-string line s))))

(defun buffer-name (buffer)
  (if (buffer-path buffer)
      (file-namestring (buffer-path buffer))
      "*scratch*"))

(defun buffer-modified-p (buffer)
  (/= (buffer-edits buffer) (buffer-saved buffer)))

(defun read-buffer (path)
  (make-buffer :path path
               :text (if (probe-file path)
                         (uiop:read-file-string path :external-format :utf-8)
                         "")))

(defun save-buffer (buffer)
  (with-open-file (s (buffer-path buffer) :direction :output :if-exists :supersede
                                          :if-does-not-exist :create :external-format :utf-8)
    (write-string (buffer-text buffer) s))
  (setf (buffer-saved buffer) (buffer-edits buffer))
  (buffer-path buffer))

(defun current-line (buffer)
  (buffer-line buffer (buffer-point-line buffer)))

(defun edited (buffer)
  (incf (buffer-edits buffer))
  (setf (buffer-goal buffer) nil)
  buffer)

(defun goto (buffer line col)
  (let ((line (max 0 (min line (1- (buffer-line-count buffer))))))
    (setf (buffer-point-line buffer) line
          (buffer-point-col buffer) (max 0 (min col (length (buffer-line buffer line))))))
  buffer)

(defun insert (buffer text)
  (let ((parts (split-lines text))
        (line (current-line buffer))
        (col (buffer-point-col buffer))
        (at (buffer-point-line buffer)))
    (if (= 1 (length parts))
        (progn
          (setf (buffer-line buffer at)
                (concatenate 'string (subseq line 0 col) text (subseq line col)))
          (incf (buffer-point-col buffer) (length text)))
        (let* ((head (subseq line 0 col))
               (tail (subseq line col))
               (n (length parts))
               (last (aref parts (1- n)))
               (lines (buffer-lines buffer))
               (new (concatenate 'vector
                                 (subseq lines 0 at)
                                 (list (concatenate 'string head (aref parts 0)))
                                 (subseq parts 1 (1- n))
                                 (list (concatenate 'string last tail))
                                 (subseq lines (1+ at)))))
          (setf (buffer-lines buffer) (make-array (length new) :adjustable t :fill-pointer t
                                                               :initial-contents new)
                (buffer-point-line buffer) (+ at n -1)
                (buffer-point-col buffer) (length last))))
    (edited buffer)))

(defun newline (buffer)
  (insert buffer (string #\Newline)))

(defun join-next (buffer at)
  (let ((lines (buffer-lines buffer)))
    (when (< (1+ at) (length lines))
      (setf (aref lines at) (concatenate 'string (aref lines at) (aref lines (1+ at))))
      (replace lines lines :start1 (1+ at) :start2 (+ at 2))
      (decf (fill-pointer lines))
      t)))

(defun delete-forward (buffer)
  (let ((line (current-line buffer))
        (col (buffer-point-col buffer))
        (at (buffer-point-line buffer)))
    (cond ((< col (length line))
           (setf (buffer-line buffer at)
                 (concatenate 'string (subseq line 0 col) (subseq line (1+ col))))
           (edited buffer))
          ((join-next buffer at) (edited buffer))
          (t buffer))))

(defun delete-backward (buffer)
  (let ((col (buffer-point-col buffer))
        (at (buffer-point-line buffer)))
    (cond ((plusp col)
           (decf (buffer-point-col buffer))
           (delete-forward buffer))
          ((plusp at)
           (goto buffer (1- at) (length (buffer-line buffer (1- at))))
           (delete-forward buffer))
          (t buffer))))

(defun kill-line (buffer)
  (let ((line (current-line buffer))
        (col (buffer-point-col buffer)))
    (if (= col (length line))
        (delete-forward buffer)
        (progn
          (setf (buffer-line buffer (buffer-point-line buffer)) (subseq line 0 col))
          (edited buffer)))))

(defun forward-char (buffer)
  (setf (buffer-goal buffer) nil)
  (let ((col (buffer-point-col buffer))
        (at (buffer-point-line buffer)))
    (cond ((< col (length (current-line buffer))) (incf (buffer-point-col buffer)))
          ((< (1+ at) (buffer-line-count buffer)) (goto buffer (1+ at) 0))))
  buffer)

(defun backward-char (buffer)
  (setf (buffer-goal buffer) nil)
  (let ((col (buffer-point-col buffer))
        (at (buffer-point-line buffer)))
    (cond ((plusp col) (decf (buffer-point-col buffer)))
          ((plusp at) (goto buffer (1- at) (length (buffer-line buffer (1- at)))))))
  buffer)

(defun vertical (buffer by)
  (let ((goal (or (buffer-goal buffer) (buffer-point-col buffer))))
    (goto buffer (+ (buffer-point-line buffer) by) goal)
    (setf (buffer-goal buffer) goal)
    buffer))

(defun next-line (buffer &optional (n 1)) (vertical buffer n))

(defun previous-line (buffer &optional (n 1)) (vertical buffer (- n)))

(defun line-start (buffer)
  (setf (buffer-goal buffer) nil)
  (goto buffer (buffer-point-line buffer) 0))

(defun line-end (buffer)
  (setf (buffer-goal buffer) nil)
  (goto buffer (buffer-point-line buffer) (length (current-line buffer))))

(defun buffer-start (buffer)
  (setf (buffer-goal buffer) nil)
  (goto buffer 0 0))

(defun buffer-end (buffer)
  (setf (buffer-goal buffer) nil)
  (let ((last (1- (buffer-line-count buffer))))
    (goto buffer last (length (buffer-line buffer last)))))
