(in-package #:darterfly/kit)

(export '(choice make-choice choice-id choice-value choice-label choice-detail choice-search
          choice-enabled choice-reason choice-icon choice-session make-choice-session
          choice-query choice-items choice-selected choice-status choice-error choice-result
          choice-result-status choice-result-value begin-choice-query publish-choices
          choose-candidate move-choice accept-choice cancel-choice read-choice read-window
          *reduced-motion* minimize-window))

(defstruct choice id value (label "") (detail "") search icon (enabled t) reason)
(defstruct choice-result status value)
(defstruct (choice-session (:constructor make-choice-session (&key on-result validator)))
  (query "") (items nil) selected (status :idle) error (serial 0) (closed nil)
  (lost nil) on-result validator)
(defun choice-query (s) (choice-session-query s))
(defun choice-items (s) (choice-session-items s))
(defun choice-selected (s) (choice-session-selected s))
(defun choice-status (s) (choice-session-status s))
(defun choice-error (s) (choice-session-error s))

(defun query-tokens (query)
  (loop with start = 0 for i from 0 to (length query)
        when (or (= i (length query)) (find (char query i) '(#\Space #\Tab #\Newline)))
        when (< start i) collect (subseq query start i)
        end and do (setf start (1+ i))))
(defun subsequence-cost (token text)
  (loop with from = 0 with cost = 0 for ch across token
        for at = (position ch text :start from :test #'char-equal)
        unless at do (return-from subsequence-cost nil)
        do (incf cost (- at from)) (setf from (1+ at)) finally (return (+ 100 cost))))
(defun choice-score (query choice)
  (when (string-equal query (choice-label choice)) (return-from choice-score 0))
  (loop with score = 0 for token in (query-tokens query) do
    (let ((best nil))
      (loop for text in (cons (choice-label choice) (choice-search choice)) for field from 0 do
        (let* ((at (search token text :test #'char-equal))
               (n (if at (+ (if (zerop at) 1 5) (/ at 1000)) (subsequence-cost token text))))
          (when n (incf n (if (zerop field) 0 20)) (setf best (if best (min best n) n)))))
      (unless best (return-from choice-score nil)) (incf score best))
    finally (return score)))
(defun begin-choice-query (session query)
  (unless (choice-session-closed session)
    (unless (string= query (choice-query session))
      (setf (choice-session-selected session) nil (choice-session-lost session) nil))
    (setf (choice-session-query session) query (choice-session-status session) :loading (choice-session-error session) nil)
    (incf (choice-session-serial session))))
(defun publish-choices (session serial candidates &key error)
  "Deliver on the owning UI loop. Old/cancelled requests cannot become actionable."
  (when (or (choice-session-closed session) (/= serial (choice-session-serial session)))
    (return-from publish-choices nil))
  (let ((old (choice-selected session)) (seen (make-hash-table :test #'equal)))
    (setf (choice-session-error session) error
          (choice-session-items session)
          (unless error
            (mapcar #'cdr
                    (stable-sort
                     (loop for c in candidates for id = (choice-id c)
                           for score = (choice-score (choice-query session) c)
                           when (and id score (not (gethash id seen)))
                           collect (cons score c) and do (setf (gethash id seen) t)) #'< :key #'car))))
    (cond (error nil)
          ((and old (find old (choice-items session) :key #'choice-id :test #'equal)))
          (old (setf (choice-session-selected session) nil (choice-session-lost session) t))
          ((not (choice-session-lost session))
           (setf (choice-session-selected session)
                 (let ((first (find-if #'choice-enabled (choice-items session)))) (and first (choice-id first))))))
    (setf (choice-session-status session) (cond (error :error) ((choice-items session) :ready) (t :empty))))
  t)
(defun choose-candidate (session id)
  (let ((item (find id (choice-items session) :key #'choice-id :test #'equal)))
    (when (and item (choice-enabled item))
      (setf (choice-session-selected session) id (choice-session-lost session) nil))))
(defun move-choice (session delta)
  (let* ((items (remove-if-not #'choice-enabled (choice-items session)))
         (at (position (choice-selected session) items :key #'choice-id :test #'equal)))
    (when items
      (let ((index (max 0 (min (1- (length items))
                              (if at (+ at delta) (if (minusp delta) (1- (length items)) 0))))))
        (choose-candidate session (choice-id (nth index items)))))))
(defun finish-choice (session status value)
  (unless (choice-session-closed session)
    (setf (choice-session-closed session) t (choice-session-status session) status)
    (incf (choice-session-serial session))
    (when (choice-session-on-result session)
      (funcall (choice-session-on-result session) (make-choice-result :status status :value value)))
    t))
(defun cancel-choice (session) (finish-choice session :cancelled nil))
(defun accept-choice (session)
  (let ((choice (find (choice-selected session) (choice-items session) :key #'choice-id :test #'equal)))
    (when (and (not (choice-session-closed session)) (eq :ready (choice-status session)) choice (choice-enabled choice))
      (let ((error (and (choice-session-validator session) (funcall (choice-session-validator session) choice))))
        (if error
            (setf (choice-session-error session) error (choice-session-status session) :error)
            (finish-choice session :accepted (choice-value choice)))))))
