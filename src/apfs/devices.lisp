(in-package #:finch/apfs)

(defparameter +apfs-partition+ "7C3457EF-0000-11AA-AA11-00306543ECAC")
(defparameter +apfs-container+ "EF57347C-0000-11AA-AA11-00306543ECAC")
(defparameter +apfs-volume+ "41504653-0000-11AA-AA11-00306543ECAC")

(devices:define-device-class apfs-container-scheme "APFSContainerScheme" (devices:partition-scheme))
(devices:define-device-class apfs-media "APFSMedia" (devices:media))
(devices:define-device-class apfs-media-node "APFSMediaBSDClient" (devices:media-node))
(devices:define-device-class apfs-container-driver "APFSContainer" (devices:device)
  ((container :accessor apfs-container)))
(devices:define-device-class apfs-volume-media "APFSVolume" (devices:media)
  ((volume :initarg :volume :reader apfs-volume)))
(devices:define-device-class apfs-volume-node "APFSVolumeBSDClient" (devices:media-node))

(defmethod devices:node-class ((m apfs-media)) 'apfs-media-node)
(defmethod devices:node-class ((m apfs-volume-media)) 'apfs-volume-node)

(devices:add-personality "Class" "APFSContainerScheme" "ProviderClass" "Media"
                       "PropertyMatch" (list (devices:personality "Content Hint" +apfs-partition+)
                                                              (devices:personality "Whole" t))
                       "ProbeScore" 2000)
(devices:add-personality "Class" "APFSContainer" "ProviderClass" "Media"
                       "PropertyMatch" (list (devices:personality "Content Hint" +apfs-container+)) "ProbeScore" 1000)

(defun media-device (media)
  (lambda (at length) (devices:media-read media at length)))

(defun set-properties (entry &rest kv)
  (loop for (k v) on kv by #'cddr do (devices:set-property entry k v)))

(defmethod devices:start ((scheme apfs-container-scheme) (partition devices:media))
  (let ((c (and (not (typep partition 'apfs-media))
                (handler-case (open-container (media-device partition)) (apfs-error () nil)))))
    (when c
      (let* ((unit (devices:next-bsd-unit))
             (media (make-instance 'apfs-media :device (devices:media-device partition) :base (devices:media-base partition))))
        (set-properties media "Logical Block Size" 4096 "Preferred Block Size" 4096 "Physical Block Size" 4096
                        "Writable" t "Size" (devices:get-property partition "Size")
                        "Content" +apfs-container+ "Content Hint" +apfs-container+ "Whole" t "Leaf" t
                        "UUID" (container-uuid c) "BSD Name" (format nil "disk~d" unit) "BSD Unit" unit "BSD Major" 1)
        (devices:set-property partition "Leaf" nil)
        (devices:publish-media media scheme)
        t))))

(defmethod devices:start ((driver apfs-container-driver) (media devices:media))
  (let ((c (handler-case (open-container (media-device media)) (apfs-error () nil))))
    (when c
      (setf (apfs-container driver) c)
      (set-properties driver "UUID" (container-uuid c) "ContainerBlockSize" (container-block-size c)
                      "Logical Block Size" (container-block-size c) "Status" "Online")
      (devices:set-property media "Leaf" nil)
      (dolist (v (container-volumes c))
        (let ((vol (make-instance 'apfs-volume-media :volume v :name (volume-name v)
                                                     :location (princ-to-string (1+ (volume-index v)))
                                                     :device (devices:media-device media) :base (devices:media-base media))))
          (set-properties vol "Logical Block Size" 4096 "Preferred Block Size" 4096 "Physical Block Size" 4096
                          "RoleValue" (volume-role v) "Writable" t "IncompatibleFeatures" (volume-incompatible-features v)
                          "FullName" (volume-name v) "Size" (container-size c)
                          "Content" +apfs-volume+ "Content Hint" +apfs-volume+ "Whole" nil "Leaf" t
                          "UUID" (volume-uuid v) "CaseSensitive" (not (volume-case-insensitive-p v))
                          "FormattedBy" (volume-formatted-by v)
                          "BSD Name" (format nil "~as~d" (devices:get-property media "BSD Name") (1+ (volume-index v)))
                          "Status" "Online")
          (devices:publish-media vol driver)))
      t)))
