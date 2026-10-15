(defpackage #:finch/edit
  (:use #:cl)
  (:export
   #:buffer #:make-buffer #:buffer-lines #:buffer-line #:buffer-line-count #:buffer-text
   #:buffer-path #:buffer-name #:buffer-point-line #:buffer-point-col #:buffer-modified-p
   #:read-buffer #:save-buffer
   #:insert #:newline #:delete-backward #:delete-forward #:kill-line
   #:forward-char #:backward-char #:next-line #:previous-line
   #:line-start #:line-end #:buffer-start #:buffer-end #:goto
   #:spans #:toplevel-form))
