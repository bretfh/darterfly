(asdf:defsystem #:finch/mach
  :description "Ports, rights, names and messages"
  :serial t
  :pathname "src/mach/"
  :components ((:file "kern") (:file "port") (:file "msg")))

(asdf:defsystem #:finch/plist
  :description "Property lists, XML and binary"
  :depends-on (#:plump)
  :serial t
  :pathname "src/plist/"
  :components ((:file "plist") (:file "binary") (:file "xml")))

(asdf:defsystem #:finch/macho
  :description "Mach-O images, thin and fat"
  :serial t
  :pathname "src/macho/"
  :components ((:file "macho")))

(asdf:defsystem #:finch/dyld
  :description "The dyld shared cache and its subcaches"
  :depends-on (#:finch/macho #:uiop)
  :serial t
  :pathname "src/dyld/"
  :components ((:file "dyld")))

(asdf:defsystem #:finch
  :description "A Darwin in Common Lisp"
  :depends-on (#:finch/mach #:finch/plist #:finch/macho #:finch/dyld)
  :in-order-to ((asdf:test-op (asdf:test-op #:finch/test))))

(asdf:defsystem #:finch/test
  :depends-on (#:finch #:fiveam (:require #:sb-posix))
  :serial t
  :pathname "tests/"
  :components ((:file "suite") (:file "mach") (:file "plist") (:file "macho") (:file "dyld"))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :finch/test :run-them)))
