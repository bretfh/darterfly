(asdf:defsystem #:finch/mach
  :description "Ports, rights, names and messages"
  :serial t
  :pathname "src/mach/"
  :components ((:file "kern") (:file "port") (:file "msg") (:file "task")))

(asdf:defsystem #:finch/bsd
  :description "Processes, signals and files"
  :depends-on (#:finch/mach #:finch/net #:finch/vfs)
  :serial t
  :pathname "src/bsd/"
  :components ((:file "errno") (:file "proc") (:file "file") (:file "socket") (:file "vfs") (:file "stdio") (:file "exec") (:file "libsa")))

(asdf:defsystem #:finch/xpc
  :description "XPC's wire"
  :serial t
  :pathname "src/xpc/"
  :components ((:file "xpc")))

(asdf:defsystem #:finch/launchd
  :description "launchd and launchctl"
  :depends-on (#:finch/bsd #:finch/mach #:finch/plist #:finch/xpc)
  :serial t
  :pathname "src/launchd/"
  :components ((:file "launchd")))

(asdf:defsystem #:finch/shell
  :description "The shell"
  :depends-on (#:finch/bsd)
  :serial t
  :pathname "src/shell/"
  :components ((:file "shell")))

(asdf:defsystem #:finch/io
  :description "Frame buffers and input devices"
  :depends-on (#:uiop #:finch/iokit (:require #:sb-posix))
  :serial t
  :pathname "src/io/"
  :components ((:file "framebuffer") (:file "hid") (:file "blend") (:file "keymap")))

(asdf:defsystem #:finch/text
  :description "Fonts and text"
  :depends-on (#:zpb-ttf #:cl-vectors #:cl-paths-ttf)
  :serial t
  :pathname "src/text/"
  :components ((:file "text")))

(asdf:defsystem #:finch/edit
  :description "Buffers"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/edit/"
  :components ((:file "package") (:file "buffer") (:file "lisp")))

(asdf:defsystem #:finch/imageio
  :description "Images and icons"
  :depends-on (#:chipz)
  :serial t
  :pathname "src/imageio/"
  :components ((:file "imageio")))

(asdf:defsystem #:finch/kit
  :description "Views, windows and menus"
  :depends-on (#:finch/ca #:finch/text #:finch/mach #:finch/server #:finch/bsd #:finch/imageio)
  :serial t
  :pathname "src/kit/"
  :components ((:file "kit")))

(asdf:defsystem #:finch/windowserver
  :description "WindowServer"
  :depends-on (#:finch/ca #:finch/server #:finch/bsd #:finch/mach #:finch/launchd #:finch/io)
  :serial t
  :pathname "src/server/"
  :components ((:file "windowserver")))

(asdf:defsystem #:finch/apps
  :description "Applications"
  :depends-on (#:finch/ca #:finch/server #:finch/bsd #:finch/text #:finch/imageio #:finch/kit #:finch/edit)
  :serial t
  :pathname "src/apps/"
  :components ((:file "hello") (:file "terminal") (:file "listener") (:file "editor") (:file "session")))

(asdf:defsystem #:finch/iokit
  :description "IOKit: the registry, PCI and drivers"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/iokit/"
  :components ((:file "machine") (:file "registry") (:file "acpi") (:file "pci") (:file "interrupt") (:file "virtio") (:file "storage") (:file "block") (:file "input") (:file "network")))

(asdf:defsystem #:finch/net
  :description "Networking"
  :depends-on (#:uiop #:finch/iokit)
  :serial t
  :pathname "src/net/"
  :components ((:file "net") (:file "ip6") (:file "tcp") (:file "dhcp") (:file "dns")))

(asdf:defsystem #:finch/vfs
  :description "The virtual file system"
  :depends-on (#:uiop (:require #:sb-posix))
  :serial t
  :pathname "src/vfs/"
  :components ((:file "vfs") (:file "ramfs") (:file "start") (:file "host")))

(asdf:defsystem #:finch/apfs
  :description "Apple File System"
  :depends-on (#:uiop #:finch/iokit #:finch/vfs)
  :serial t
  :pathname "src/apfs/"
  :components ((:file "apfs") (:file "iokit") (:file "newfs") (:file "transaction") (:file "write") (:file "vfs") (:file "root")))

(asdf:defsystem #:finch/fat
  :description "FAT32"
  :depends-on (#:uiop #:finch/vfs #:finch/iokit)
  :serial t
  :pathname "src/fat/"
  :components ((:file "fat") (:file "vfs")))

(asdf:defsystem #:finch/install
  :description "Generations"
  :depends-on (#:uiop #:finch/fat)
  :serial t
  :pathname "src/install/"
  :components ((:file "install")))

(asdf:defsystem #:finch/asm
  :description "x86-64 objects"
  :serial t
  :pathname "src/asm/"
  :components ((:file "asm")))

(asdf:defsystem #:finch/low
  :description "Lisp below the heap"
  :depends-on (#:finch/asm)
  :serial t
  :pathname "src/low/"
  :components ((:file "low")))

(asdf:defsystem #:finch/pexpert
  :description "Serial console"
  :depends-on (#:finch/low)
  :serial t
  :pathname "src/pexpert/i386/"
  :components ((:file "serial") (:file "init")))

(asdf:defsystem #:finch/osfmk
  :description "Kernel"
  :depends-on (#:finch/low)
  :serial t
  :pathname "src/osfmk/i386/"
  :components ((:file "mtrr") (:file "printf") (:file "rtclock") (:file "vm-map") (:file "pmap") (:file "memory")))

(asdf:defsystem #:finch/kernel
  :description "The kernel, run as pid 1"
  :depends-on (#:finch/mach #:finch/bsd #:finch/io #:uiop)
  :serial t
  :pathname "src/kernel/"
  :components ((:file "kernel")))

(asdf:defsystem #:finch/image
  :description "The bootable image"
  :depends-on (#:uiop #:finch/plist #:finch/qmp #:finch/io #:finch/apfs #:finch/fat #:finch/pexpert #:finch/osfmk (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/image/"
  :components ((:file "image") (:file "runtime") (:file "efi")))

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
  :components ((:file "transaction") (:file "event") (:file "region")))

(asdf:defsystem #:finch/ca
  :description "The layer render protocol"
  :depends-on (#:finch/mach #:finch/bsd #:finch/launchd #:finch/server)
  :serial t
  :pathname "src/ca/"
  :components ((:file "render") (:file "client")))

(asdf:defsystem #:finch/qmp
  :description "QEMU's machine protocol"
  :depends-on (#:com.inuoe.jzon #:uiop (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/qmp/"
  :components ((:file "qmp")))

(asdf:defsystem #:finch/tahoe
  :description "The Tahoe reference guest"
  :depends-on (#:finch/plist #:finch/qmp #:com.inuoe.jzon #:uiop (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/tahoe/"
  :components ((:static-file "SSDT-EC-USBX.dsl") (:static-file "transactions.c") (:static-file "commit-tap.c") (:static-file "commits.m") (:static-file "ports.c") (:static-file "ports.script") (:static-file "bsd.c") (:static-file "bsd.script") (:static-file "mach-tap.c") (:static-file "lookup.c") (:static-file "events.c") (:static-file "windows.c") (:static-file "media.sh") (:static-file "apfs-check.sh") (:file "opencore") (:file "qmp") (:file "guest")))

(asdf:defsystem #:finch
  :description "A live, hackable OS on SBCL"
  :depends-on (#:finch/mach #:finch/plist #:finch/macho #:finch/dyld #:finch/objc #:finch/mig #:finch/server #:finch/ca #:finch/bsd #:finch/xpc #:finch/launchd #:finch/shell #:finch/io #:finch/text #:finch/edit #:finch/imageio #:finch/kit #:finch/windowserver #:finch/apps #:finch/iokit #:finch/vfs #:finch/apfs #:finch/fat #:finch/install #:finch/net #:finch/kernel #:finch/image)
  :in-order-to ((asdf:test-op (asdf:test-op #:finch/test))))

(asdf:defsystem #:finch/test
  :depends-on (#:finch #:finch/tahoe #:fiveam (:require #:sb-posix) (:require #:sb-md5) (:require #:sb-bsd-sockets))
  :serial t
  :pathname "tests/"
  :components ((:file "suite") (:file "mach") (:file "plist") (:file "macho") (:file "dyld") (:file "objc") (:file "mig") (:file "server") (:file "ca") (:file "bsd") (:file "xpc") (:file "launchd") (:file "boot") (:file "apfs") (:file "net") (:file "tahoe"))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :finch/test :run-them)))
