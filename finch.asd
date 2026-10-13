(asdf:defsystem #:finch/mach
  :description "Ports, rights, names and messages"
  :serial t
  :pathname "src/mach/"
  :components ((:file "kern") (:file "port") (:file "msg") (:file "task")))

(asdf:defsystem #:finch/bsd
  :description "Processes, signals and files"
  :depends-on (#:finch/mach)
  :serial t
  :pathname "src/bsd/"
  :components ((:file "errno") (:file "proc") (:file "file")))

(asdf:defsystem #:finch/kernel
  :description "The kernel, run as pid 1"
  :depends-on (#:finch/mach #:finch/bsd #:uiop)
  :serial t
  :pathname "src/kernel/"
  :components ((:file "kernel")))

(asdf:defsystem #:finch/image
  :description "The bootable image"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/image/"
  :components ((:file "image")))

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
  :components ((:file "dyld") (:file "extract")))

(asdf:defsystem #:finch/objc
  :description "Objective-C metadata in cache images"
  :depends-on (#:finch/dyld #:finch/macho)
  :serial t
  :pathname "src/objc/"
  :components ((:file "objc")))

(asdf:defsystem #:finch/mig
  :description "MIG subsystems in images"
  :depends-on (#:finch/macho)
  :serial t
  :pathname "src/mig/"
  :components ((:file "mig")))

(asdf:defsystem #:finch/server
  :description "The window server"
  :serial t
  :pathname "src/server/"
  :components ((:file "transaction")))

(asdf:defsystem #:finch/ca
  :description "CoreAnimation's render protocol"
  :serial t
  :pathname "src/ca/"
  :components ((:file "render")))

(asdf:defsystem #:finch/tahoe
  :description "The Tahoe reference guest"
  :depends-on (#:finch/plist #:com.inuoe.jzon #:uiop (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/tahoe/"
  :components ((:static-file "SSDT-EC-USBX.dsl") (:static-file "transactions.c") (:static-file "commit-tap.c") (:static-file "commits.m") (:static-file "ports.c") (:static-file "ports.script") (:static-file "bsd.c") (:static-file "bsd.script") (:file "opencore") (:file "qmp") (:file "guest")))

(asdf:defsystem #:finch
  :description "A Darwin in Common Lisp"
  :depends-on (#:finch/mach #:finch/plist #:finch/macho #:finch/dyld #:finch/objc #:finch/mig #:finch/server #:finch/ca #:finch/bsd #:finch/kernel #:finch/image)
  :in-order-to ((asdf:test-op (asdf:test-op #:finch/test))))

(asdf:defsystem #:finch/test
  :depends-on (#:finch #:finch/tahoe #:fiveam (:require #:sb-posix))
  :serial t
  :pathname "tests/"
  :components ((:file "suite") (:file "mach") (:file "plist") (:file "macho") (:file "dyld") (:file "objc") (:file "mig") (:file "server") (:file "ca") (:file "bsd") (:file "kernel") (:file "tahoe"))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :finch/test :run-them)))
