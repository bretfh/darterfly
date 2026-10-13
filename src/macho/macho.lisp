(defpackage #:finch/macho
  (:use #:cl)
  (:export
   #:read-macho #:macho-error
   #:fat #:fat-slices #:slice #:slice-cputype #:slice-cpusubtype #:slice-offset
   #:slice-size #:slice-align #:slice-image
   #:image #:image-bits #:image-cputype #:image-cpusubtype #:image-filetype
   #:image-flags #:image-commands
   #:load-command #:command-kind #:command-offset #:command-size
   #:segment #:segment-name #:segment-vmaddr #:segment-vmsize #:segment-fileoff
   #:segment-filesize #:segment-maxprot #:segment-initprot #:segment-flags
   #:segment-sections
   #:section #:section-name #:section-segment-name #:section-addr #:section-size
   #:section-offset #:section-align #:section-flags
   #:symtab #:symtab-symoff #:symtab-nsyms #:symtab-stroff #:symtab-strsize
   #:nlist #:nlist-name #:nlist-type #:nlist-sect #:nlist-desc #:nlist-value
   #:dylib-command #:dylib-name #:dylib-timestamp #:dylib-current-version
   #:dylib-compatibility-version
   #:path-command #:command-path
   #:uuid-command #:uuid
   #:build-version #:build-platform #:build-minos #:build-sdk #:build-tools
   #:entry-point #:entry-offset #:entry-stacksize
   #:linkedit-data #:linkedit-dataoff #:linkedit-datasize
   #:source-version #:source-version-string
   #:fileset-entry #:fileset-entry-id #:fileset-entry-vmaddr #:fileset-entry-fileoff
   #:segments #:sections #:symbols #:dylibs #:install-name #:find-command #:read-address
   #:version-string))
(in-package #:finch/macho)

(define-condition macho-error (error)
  ((what :initarg :what :reader what))
  (:report (lambda (c s) (format s "not Mach-O: ~a" (what c)))))

(defun bad (fmt &rest args)
  (error 'macho-error :what (apply #'format nil fmt args)))

(defun file-octets (source)
  (etypecase source
    ((vector (unsigned-byte 8)) (coerce source '(simple-array (unsigned-byte 8) (*))))
    ((or pathname string)
     (with-open-file (in source :element-type '(unsigned-byte 8))
       (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
         (read-sequence v in)
         v)))))

(defun le (o at count)
  (loop :with n := 0
        :for i :from (+ at count -1) :downto at
        :do (setf n (logior (ash n 8) (aref o i)))
        :finally (return n)))

(defun be (o at count)
  (loop :with n := 0
        :for i :from at :below (+ at count)
        :do (setf n (logior (ash n 8) (aref o i)))
        :finally (return n)))

(defun u32 (o at) (le o at 4))
(defun u64 (o at) (le o at 8))

(defun cstring (o at &optional (limit (length o)))
  (let ((end (or (position 0 o :start at :end (min limit (length o)))
                 (min limit (length o)))))
    (map 'string #'code-char (subseq o at end))))

(defparameter +cputypes+
  '((7 . :x86) (#x01000007 . :x86-64) (12 . :arm) (#x0100000c . :arm64)
    (#x0200000c . :arm64-32)))

(defparameter +filetypes+
  '((1 . :mh-object) (2 . :mh-execute) (3 . :mh-fvmlib) (4 . :mh-core)
    (5 . :mh-preload) (6 . :mh-dylib) (7 . :mh-dylinker) (8 . :mh-bundle)
    (9 . :mh-dylib-stub) (10 . :mh-dsym) (11 . :mh-kext-bundle) (12 . :mh-fileset)))

(defparameter +commands+
  '((#x1 . :lc-segment) (#x2 . :lc-symtab) (#x3 . :lc-symseg) (#x4 . :lc-thread)
    (#x5 . :lc-unixthread) (#x6 . :lc-loadfvmlib) (#x7 . :lc-idfvmlib) (#x8 . :lc-ident)
    (#x9 . :lc-fvmfile) (#xa . :lc-prepage) (#xb . :lc-dysymtab) (#xc . :lc-load-dylib)
    (#xd . :lc-id-dylib) (#xe . :lc-load-dylinker) (#xf . :lc-id-dylinker)
    (#x10 . :lc-prebound-dylib) (#x11 . :lc-routines) (#x12 . :lc-sub-framework)
    (#x13 . :lc-sub-umbrella) (#x14 . :lc-sub-client) (#x15 . :lc-sub-library)
    (#x16 . :lc-twolevel-hints) (#x17 . :lc-prebind-cksum)
    (#x80000018 . :lc-load-weak-dylib) (#x19 . :lc-segment-64) (#x1a . :lc-routines-64)
    (#x1b . :lc-uuid) (#x8000001c . :lc-rpath) (#x1d . :lc-code-signature)
    (#x1e . :lc-segment-split-info) (#x8000001f . :lc-reexport-dylib)
    (#x20 . :lc-lazy-load-dylib) (#x21 . :lc-encryption-info) (#x22 . :lc-dyld-info)
    (#x80000022 . :lc-dyld-info-only) (#x80000023 . :lc-load-upward-dylib)
    (#x24 . :lc-version-min-macosx) (#x25 . :lc-version-min-iphoneos)
    (#x26 . :lc-function-starts) (#x27 . :lc-dyld-environment) (#x80000028 . :lc-main)
    (#x29 . :lc-data-in-code) (#x2a . :lc-source-version) (#x2b . :lc-dylib-code-sign-drs)
    (#x2c . :lc-encryption-info-64) (#x2d . :lc-linker-option)
    (#x2e . :lc-linker-optimization-hint) (#x2f . :lc-version-min-tvos)
    (#x30 . :lc-version-min-watchos) (#x31 . :lc-note) (#x32 . :lc-build-version)
    (#x80000033 . :lc-dyld-exports-trie) (#x80000034 . :lc-dyld-chained-fixups)
    (#x80000035 . :lc-fileset-entry)))

(defparameter +classes+
  '((:lc-segment . segment) (:lc-segment-64 . segment) (:lc-symtab . symtab)
    (:lc-load-dylib . dylib-command) (:lc-id-dylib . dylib-command)
    (:lc-load-weak-dylib . dylib-command) (:lc-reexport-dylib . dylib-command)
    (:lc-lazy-load-dylib . dylib-command) (:lc-load-upward-dylib . dylib-command)
    (:lc-load-dylinker . path-command) (:lc-id-dylinker . path-command)
    (:lc-dyld-environment . path-command) (:lc-rpath . path-command)
    (:lc-sub-framework . path-command) (:lc-sub-umbrella . path-command)
    (:lc-sub-client . path-command) (:lc-sub-library . path-command)
    (:lc-uuid . uuid-command) (:lc-build-version . build-version) (:lc-main . entry-point)
    (:lc-source-version . source-version) (:lc-fileset-entry . fileset-entry)
    (:lc-code-signature . linkedit-data) (:lc-segment-split-info . linkedit-data)
    (:lc-function-starts . linkedit-data) (:lc-data-in-code . linkedit-data)
    (:lc-dylib-code-sign-drs . linkedit-data) (:lc-linker-optimization-hint . linkedit-data)
    (:lc-dyld-exports-trie . linkedit-data) (:lc-dyld-chained-fixups . linkedit-data)))

(defun named (table n)
  (or (cdr (assoc n table)) n))

(defun version-string (v)
  (format nil "~d.~d.~d" (ldb (byte 16 16) v) (ldb (byte 8 8) v) (ldb (byte 8 0) v)))

(defclass image ()
  ((octets :initarg :octets :reader octets)
   (start :initarg :start :reader start)
   (bits :initarg :bits :reader image-bits)
   (cputype :initarg :cputype :reader image-cputype)
   (cpusubtype :initarg :cpusubtype :reader image-cpusubtype)
   (filetype :initarg :filetype :reader image-filetype)
   (flags :initarg :flags :reader image-flags)
   (commands :initform nil :accessor image-commands)))

(defmethod print-object ((image image) stream)
  (print-unreadable-object (image stream :type t)
    (format stream "~(~a ~a~) ~d commands" (image-cputype image) (image-filetype image)
            (length (image-commands image)))))

(defclass fat ()
  ((slices :initarg :slices :reader fat-slices)))

(defclass slice ()
  ((cputype :initarg :cputype :reader slice-cputype)
   (cpusubtype :initarg :cpusubtype :reader slice-cpusubtype)
   (offset :initarg :offset :reader slice-offset)
   (size :initarg :size :reader slice-size)
   (align :initarg :align :reader slice-align)
   (image :initarg :image :reader slice-image)))

(defclass load-command ()
  ((kind :initarg :kind :reader command-kind)
   (offset :initarg :offset :reader command-offset)
   (size :initarg :size :reader command-size)))

(defmethod print-object ((c load-command) stream)
  (print-unreadable-object (c stream :type t)
    (format stream "~(~a~)" (command-kind c))))

(defclass segment (load-command)
  ((name :reader segment-name) (vmaddr :reader segment-vmaddr)
   (vmsize :reader segment-vmsize) (fileoff :reader segment-fileoff)
   (filesize :reader segment-filesize) (maxprot :reader segment-maxprot)
   (initprot :reader segment-initprot) (flags :reader segment-flags)
   (sections :reader segment-sections)))

(defclass section ()
  ((name :initarg :name :reader section-name)
   (segment-name :initarg :segment-name :reader section-segment-name)
   (addr :initarg :addr :reader section-addr)
   (size :initarg :size :reader section-size)
   (offset :initarg :offset :reader section-offset)
   (align :initarg :align :reader section-align)
   (flags :initarg :flags :reader section-flags)))

(defmethod print-object ((s section) stream)
  (print-unreadable-object (s stream :type t)
    (format stream "~a,~a" (section-segment-name s) (section-name s))))

(defclass symtab (load-command)
  ((symoff :reader symtab-symoff) (nsyms :reader symtab-nsyms)
   (stroff :reader symtab-stroff) (strsize :reader symtab-strsize)))

(defstruct nlist name type sect desc value)

(defclass dylib-command (load-command)
  ((name :reader dylib-name) (timestamp :reader dylib-timestamp)
   (current-version :reader dylib-current-version)
   (compatibility-version :reader dylib-compatibility-version)))

(defclass path-command (load-command)
  ((path :reader command-path)))

(defclass uuid-command (load-command)
  ((uuid :reader uuid)))

(defclass build-version (load-command)
  ((platform :reader build-platform) (minos :reader build-minos)
   (sdk :reader build-sdk) (tools :reader build-tools)))

(defclass entry-point (load-command)
  ((offset :reader entry-offset) (stacksize :reader entry-stacksize)))

(defclass linkedit-data (load-command)
  ((dataoff :reader linkedit-dataoff) (datasize :reader linkedit-datasize)))

(defclass source-version (load-command)
  ((version :reader source-version)))

(defclass fileset-entry (load-command)
  ((vmaddr :reader fileset-entry-vmaddr) (fileoff :reader fileset-entry-fileoff)
   (id :reader fileset-entry-id)))

(defgeneric decode (command image at))

(defmethod decode ((c load-command) image at)
  (declare (ignore image at))
  c)

(defmethod decode ((c segment) image at)
  (let* ((o (octets image))
         (wide (= (image-bits image) 64))
         (w (if wide 8 4))
         (field (+ at 24)))
    (flet ((next () (prog1 (le o field w) (incf field w))))
      (with-slots (name vmaddr vmsize fileoff filesize maxprot initprot flags sections) c
        (setf name (cstring o (+ at 8) (+ at 24))
              vmaddr (next) vmsize (next) fileoff (next) filesize (next)
              maxprot (u32 o field) initprot (u32 o (+ field 4)) flags (u32 o (+ field 12)))
        (let ((count (u32 o (+ field 8)))
              (s (+ field 16)))
          (setf sections
                (loop :repeat count
                      :collect (make-instance 'section
                                              :name (cstring o s (+ s 16))
                                              :segment-name (cstring o (+ s 16) (+ s 32))
                                              :addr (le o (+ s 32) w)
                                              :size (le o (+ s 32 w) w)
                                              :offset (u32 o (+ s 32 w w))
                                              :align (u32 o (+ s 36 w w))
                                              :flags (u32 o (+ s 48 w w)))
                      :do (incf s (if wide 80 68)))))))
    c))

(defmethod decode ((c symtab) image at)
  (let ((o (octets image)))
    (with-slots (symoff nsyms stroff strsize) c
      (setf symoff (u32 o (+ at 8)) nsyms (u32 o (+ at 12))
            stroff (u32 o (+ at 16)) strsize (u32 o (+ at 20)))))
  c)

(defmethod decode ((c dylib-command) image at)
  (let ((o (octets image)))
    (with-slots (name timestamp current-version compatibility-version) c
      (setf name (cstring o (+ at (u32 o (+ at 8))) (+ at (command-size c)))
            timestamp (u32 o (+ at 12))
            current-version (u32 o (+ at 16))
            compatibility-version (u32 o (+ at 20)))))
  c)

(defmethod decode ((c path-command) image at)
  (let ((o (octets image)))
    (setf (slot-value c 'path) (cstring o (+ at (u32 o (+ at 8))) (+ at (command-size c)))))
  c)

(defmethod decode ((c uuid-command) image at)
  (let ((o (octets image)))
    (setf (slot-value c 'uuid)
          (format nil "~{~2,'0X~2,'0X~2,'0X~2,'0X-~2,'0X~2,'0X-~2,'0X~2,'0X-~2,'0X~2,'0X-~2,'0X~2,'0X~2,'0X~2,'0X~2,'0X~2,'0X~}"
                  (coerce (subseq o (+ at 8) (+ at 24)) 'list))))
  c)

(defmethod decode ((c build-version) image at)
  (let ((o (octets image)))
    (with-slots (platform minos sdk tools) c
      (setf platform (u32 o (+ at 8)) minos (u32 o (+ at 12)) sdk (u32 o (+ at 16))
            tools (loop :for i :below (u32 o (+ at 20))
                        :for t0 := (+ at 24 (* 8 i))
                        :collect (cons (u32 o t0) (u32 o (+ t0 4)))))))
  c)

(defmethod decode ((c entry-point) image at)
  (let ((o (octets image)))
    (setf (slot-value c 'offset) (u64 o (+ at 8))
          (slot-value c 'stacksize) (u64 o (+ at 16))))
  c)

(defmethod decode ((c linkedit-data) image at)
  (let ((o (octets image)))
    (setf (slot-value c 'dataoff) (u32 o (+ at 8))
          (slot-value c 'datasize) (u32 o (+ at 12))))
  c)

(defmethod decode ((c source-version) image at)
  (setf (slot-value c 'version) (u64 (octets image) (+ at 8)))
  c)

(defmethod decode ((c fileset-entry) image at)
  (let ((o (octets image)))
    (setf (slot-value c 'vmaddr) (u64 o (+ at 8))
          (slot-value c 'fileoff) (u64 o (+ at 16))
          (slot-value c 'id) (cstring o (+ at (u32 o (+ at 24))) (+ at (command-size c)))))
  c)

(defun source-version-string (c)
  (let ((v (source-version c)))
    (format nil "~d.~d.~d.~d.~d" (ldb (byte 24 40) v) (ldb (byte 10 30) v)
            (ldb (byte 10 20) v) (ldb (byte 10 10) v) (ldb (byte 10 0) v))))

(defun thin (o start)
  (let* ((magic (u32 o start))
         (bits (case magic (#xfeedfacf 64) (#xfeedface 32)
                 (t (bad "magic #x~8,'0x at ~d" magic start))))
         (image (make-instance 'image :octets o :start start :bits bits
                                      :cputype (named +cputypes+ (u32 o (+ start 4)))
                                      :cpusubtype (u32 o (+ start 8))
                                      :filetype (named +filetypes+ (u32 o (+ start 12)))
                                      :flags (u32 o (+ start 24))))
         (at (+ start (if (= bits 64) 32 28))))
    (setf (image-commands image)
          (loop :repeat (u32 o (+ start 16))
                :collect (let* ((cmd (u32 o at))
                                (size (u32 o (+ at 4)))
                                (kind (named +commands+ cmd))
                                (class (or (cdr (assoc kind +classes+)) 'load-command)))
                           (when (< size 8) (bad "load command of ~d bytes at ~d" size at))
                           (prog1 (decode (make-instance class :kind kind :offset at :size size)
                                          image at)
                             (incf at size)))))
    image))

(defun read-macho (source)
  (let* ((o (file-octets source))
         (magic (be o 0 4)))
    (case magic
      ((#xcafebabe #xcafebabf)
       (let ((w (if (= magic #xcafebabf) 8 4)))
         (make-instance 'fat
           :slices (loop :for i :below (be o 4 4)
                         :for at := (+ 8 (* i (+ 12 w w)))
                         :for offset := (be o (+ at 8) w)
                         :collect (make-instance 'slice
                                    :cputype (named +cputypes+ (be o at 4))
                                    :cpusubtype (be o (+ at 4) 4)
                                    :offset offset
                                    :size (be o (+ at 8 w) w)
                                    :align (be o (+ at 8 w w) 4)
                                    :image (thin o offset))))))
      (t (thin o 0)))))

(defun find-command (image kind)
  (find kind (image-commands image) :key #'command-kind))

(defun segments (image)
  (remove-if-not (lambda (c) (typep c 'segment)) (image-commands image)))

(defun sections (image)
  (mapcan (lambda (s) (copy-list (segment-sections s))) (segments image)))

(defun dylibs (image)
  (loop :for c :in (image-commands image)
        :when (and (typep c 'dylib-command) (not (eq (command-kind c) :lc-id-dylib)))
          :collect (dylib-name c)))

(defun install-name (image)
  (let ((c (find-command image :lc-id-dylib)))
    (and c (dylib-name c))))

(defun symbols (image)
  (let ((c (find-command image :lc-symtab)))
    (when c
      (let* ((o (octets image))
             (base (start image))
             (wide (= (image-bits image) 64))
             (stride (if wide 16 12))
             (strings (+ base (symtab-stroff c))))
        (loop :for i :below (symtab-nsyms c)
              :for at := (+ base (symtab-symoff c) (* i stride))
              :collect (make-nlist :name (cstring o (+ strings (u32 o at))
                                                  (+ strings (symtab-strsize c)))
                                   :type (aref o (+ at 4))
                                   :sect (aref o (+ at 5))
                                   :desc (le o (+ at 6) 2)
                                   :value (le o (+ at 8) (if wide 8 4))))))))

(defun read-address (image address count)
  (let ((s (find-if (lambda (s) (<= (segment-vmaddr s) address
                                    (+ (segment-vmaddr s) (segment-filesize s) (- count))))
                    (segments image))))
    (unless s (bad "no segment holds #x~x" address))
    (let ((at (+ (start image) (segment-fileoff s) (- address (segment-vmaddr s)))))
      (subseq (octets image) at (+ at count)))))
