(in-package #:finch/apfs)

(defparameter +apfs-partition+ "7C3457EF-0000-11AA-AA11-00306543ECAC")
(defparameter +apfs-container+ "EF57347C-0000-11AA-AA11-00306543ECAC")
(defparameter +apfs-volume+ "41504653-0000-11AA-AA11-00306543ECAC")

(iokit:define-io-class apfs-container-scheme "APFSContainerScheme" (iokit:io-partition-scheme))
(iokit:define-io-class apfs-media "APFSMedia" (iokit:io-media))
(iokit:define-io-class apfs-media-bsd-client "APFSMediaBSDClient" (iokit:io-media-bsd-client))
(iokit:define-io-class apfs-container-driver "APFSContainer" (iokit:io-service)
  ((container :accessor apfs-container)))
(iokit:define-io-class apfs-volume-media "APFSVolume" (iokit:io-media)
  ((volume :initarg :volume :reader apfs-volume)))
(iokit:define-io-class apfs-volume-bsd-client "APFSVolumeBSDClient" (iokit:io-media-bsd-client))

(defmethod iokit:bsd-client-class ((m apfs-media)) 'apfs-media-bsd-client)
(defmethod iokit:bsd-client-class ((m apfs-volume-media)) 'apfs-volume-bsd-client)

(iokit:add-personality "IOClass" "APFSContainerScheme" "IOProviderClass" "IOMedia"
                       "IOPropertyMatch" (list (iokit:personality "Content Hint" +apfs-partition+)
                                                              (iokit:personality "Whole" t))
                       "IOProbeScore" 2000)
(iokit:add-personality "IOClass" "APFSContainer" "IOProviderClass" "IOMedia"
                       "IOPropertyMatch" (list (iokit:personality "Content Hint" +apfs-container+)) "IOProbeScore" 1000)

(defun media-device (media)
  (lambda (at length) (iokit:media-read media at length)))

(defun set-properties (entry &rest kv)
  (loop for (k v) on kv by #'cddr do (iokit:set-property entry k v)))

(defmethod iokit:start ((scheme apfs-container-scheme) (partition iokit:io-media))
  (let ((c (and (not (typep partition 'apfs-media))
                (handler-case (open-container (media-device partition)) (apfs-error () nil)))))
    (when c
      (let* ((unit (iokit:next-bsd-unit))
             (media (make-instance 'apfs-media :device (iokit:media-device partition) :base (iokit:media-base partition))))
        (set-properties media "Logical Block Size" 4096 "Preferred Block Size" 4096 "Physical Block Size" 4096
                        "Writable" t "Size" (iokit:get-property partition "Size")
                        "Content" +apfs-container+ "Content Hint" +apfs-container+ "Whole" t "Leaf" t
                        "UUID" (container-uuid c) "BSD Name" (format nil "disk~d" unit) "BSD Unit" unit "BSD Major" 1)
        (iokit:set-property partition "Leaf" nil)
        (iokit:publish-media media scheme)
        t))))

(defmethod iokit:start ((driver apfs-container-driver) (media iokit:io-media))
  (let ((c (handler-case (open-container (media-device media)) (apfs-error () nil))))
    (when c
      (setf (apfs-container driver) c)
      (set-properties driver "UUID" (container-uuid c) "ContainerBlockSize" (container-block-size c)
                      "Logical Block Size" (container-block-size c) "Status" "Online")
      (iokit:set-property media "Leaf" nil)
      (dolist (v (container-volumes c))
        (let ((vol (make-instance 'apfs-volume-media :volume v :name (volume-name v)
                                                     :location (princ-to-string (1+ (volume-index v)))
                                                     :device (iokit:media-device media) :base (iokit:media-base media))))
          (set-properties vol "Logical Block Size" 4096 "Preferred Block Size" 4096 "Physical Block Size" 4096
                          "RoleValue" (volume-role v) "Writable" t "IncompatibleFeatures" (volume-incompatible-features v)
                          "FullName" (volume-name v) "Size" (container-size c)
                          "Content" +apfs-volume+ "Content Hint" +apfs-volume+ "Whole" nil "Leaf" t
                          "UUID" (volume-uuid v) "CaseSensitive" (not (volume-case-insensitive-p v))
                          "FormattedBy" (volume-formatted-by v)
                          "BSD Name" (format nil "~as~d" (iokit:get-property media "BSD Name") (1+ (volume-index v)))
                          "Status" "Online")
          (iokit:publish-media vol driver)))
      t)))
