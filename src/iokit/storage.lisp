(in-package #:finch/iokit)

(define-io-class io-block-storage-device "IOBlockStorageDevice" (io-service))
(define-io-class io-block-storage-driver "IOBlockStorageDriver" (io-service))
(define-io-class io-media "IOMedia" (io-service)
  ((device :initarg :device :reader media-device)
   (base :initarg :base :reader media-base)))
(define-io-class io-media-bsd-client "IOMediaBSDClient" (io-service))
(define-io-class io-partition-scheme "IOPartitionScheme" (io-service))
(define-io-class io-guid-partition-scheme "IOGUIDPartitionScheme" (io-partition-scheme))

(add-personality "IOClass" "IOBlockStorageDriver" "IOProviderClass" "IOBlockStorageDevice")
(add-personality "IOClass" "IOGUIDPartitionScheme" "IOProviderClass" "IOMedia"
                 "IOPropertyMatch" (personality "Whole" t) "Content Mask" "GUID_partition_scheme")


(defun media-size (media) (get-property media "Size"))

(defun media-read (media offset length)
  (let* ((at (+ (media-base media) offset))
         (first (floor at 512))
         (last (ceiling (+ at length) 512))
         (blocks (read-blocks (media-device media) first (- last first))))
    (subseq blocks (- at (* first 512)) (+ (- at (* first 512)) length))))

(defun media-write (media offset vector)
  (let ((at (+ (media-base media) offset)))
    (unless (and (zerop (mod at 512)) (zerop (mod (length vector) 512)))
      (error "media-write: ~d bytes at ~d are not whole blocks" (length vector) at))
    (write-blocks (media-device media) (floor at 512) vector)))

(defgeneric bsd-client-class (media)
  (:method ((media io-media)) 'io-media-bsd-client))

(defun next-bsd-unit () (prog1 *bsd-units* (incf *bsd-units*)))

(defun publish-media (media parent)
  (attach media parent)
  (attach (make-instance (bsd-client-class media)) media)
  (register-service media)
  media)

(defmethod start ((driver io-block-storage-driver) (device io-block-storage-device))
  (let* ((unit (next-bsd-unit))
         (media (make-instance 'io-media :name "Media" :device device :base 0)))
    (loop for (k v) on (list "Content" "" "Content Hint" "" "Whole" t "Leaf" t "Writable" t
                             "Removable" nil "Ejectable" nil "Preferred Block Size" (block-size device)
                             "Size" (* (block-count device) (block-size device))
                             "BSD Name" (format nil "disk~d" unit) "BSD Unit" unit "BSD Major" 1 "BSD Minor" 0)
          by #'cddr
          do (set-property media k v))
    (publish-media media driver)
    t))

(defun crc32 (octets &key (start 0) (end (length octets)))
  (let ((crc #xffffffff))
    (loop for i from start below end
          do (setf crc (logxor crc (aref octets i)))
             (dotimes (k 8)
               (setf crc (if (logtest crc 1) (logxor (ash crc -1) #xedb88320) (ash crc -1)))))
    (logxor crc #xffffffff)))

(defun u16 (v at) (logior (aref v at) (ash (aref v (1+ at)) 8)))
(defun u32 (v at) (logior (u16 v at) (ash (u16 v (+ at 2)) 16)))
(defun u64 (v at) (logior (u32 v at) (ash (u32 v (+ at 4)) 32)))

(defun guid-string (v at)
  (format nil "~8,'0X-~4,'0X-~4,'0X-~{~2,'0X~}-~{~2,'0X~}"
          (u32 v at) (u16 v (+ at 4)) (u16 v (+ at 6))
          (coerce (subseq v (+ at 8) (+ at 10)) 'list) (coerce (subseq v (+ at 10) (+ at 16)) 'list)))

(defun utf-16-name (v at max)
  (coerce (loop for i from at below (+ at max) by 2
                for c = (u16 v i)
                until (zerop c) collect (code-char c))
          'string))

(defmethod start ((scheme io-guid-partition-scheme) (media io-media))
  (let* ((header (media-read media 512 512))
         (header-size (u32 header 12)))
    (when (and (string= (map 'string #'code-char (subseq header 0 8)) "EFI PART")
               (= (u32 header 16)
                  (crc32 (let ((h (copy-seq header))) (fill h 0 :start 16 :end 20) h) :end header-size)))
      (let* ((count (u32 header 80))
             (size (u32 header 84))
             (entries (media-read media (* 512 (u64 header 72)) (* count size))))
        (when (= (u32 header 88) (crc32 entries))
          (set-property scheme "UUID" (guid-string header 56))
          (set-property media "Content" "GUID_partition_scheme")
          (set-property media "Leaf" nil)
          (dotimes (i count)
            (let ((at (* i size)))
              (unless (every #'zerop (subseq entries at (+ at 16)))
                (let* ((id (1+ i))
                       (type (guid-string entries at))
                       (first (u64 entries (+ at 32)))
                       (last (u64 entries (+ at 40)))
                       (name (utf-16-name entries (+ at 56) 72))
                       (part (make-instance 'io-media :name (if (string= name "") (format nil "Untitled ~d" id) name)
                                                       :location (princ-to-string id)
                                                       :device (media-device media)
                                                       :base (+ (media-base media) (* first 512)))))
                  (loop for (k v) on (list "Preferred Block Size" 512 "Base" (* first 512) "Writable" t
                                           "Size" (* 512 (1+ (- last first))) "Content" type "Content Hint" type
                                           "Whole" nil "Leaf" t "UUID" (guid-string entries (+ at 16))
                                           "BSD Name" (format nil "~as~d" (get-property media "BSD Name") id)
                                           "Partition ID" id)
                        by #'cddr
                        do (set-property part k v))
                  (publish-media part scheme)))))
          t)))))
