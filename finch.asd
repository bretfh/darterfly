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

(asdf:defsystem #:finch/init
  :description "init and service"
  :depends-on (#:finch/bsd #:finch/mach)
  :serial t
  :pathname "src/init/"
  :components ((:file "init")))

(asdf:defsystem #:finch/shell
  :description "The shell"
  :depends-on (#:finch/bsd)
  :serial t
  :pathname "src/shell/"
  :components ((:file "shell")))

(asdf:defsystem #:finch/io
  :description "Frame buffers and input devices"
  :depends-on (#:uiop #:finch/devices (:require #:sb-posix))
  :serial t
  :pathname "src/io/"
  :components ((:file "framebuffer") (:file "hid") (:file "report") (:file "blend") (:file "keymap")))

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

(asdf:defsystem #:finch/power
  :description "Restart and shut down"
  :depends-on (#:finch/devices #:finch/vfs)
  :serial t
  :pathname "src/power/"
  :components ((:file "power")))

(asdf:defsystem #:finch/kit
  :description "Views, windows and menus"
  :depends-on (#:finch/layer #:finch/text #:finch/mach #:finch/server #:finch/bsd #:finch/imageio #:finch/power)
  :serial t
  :pathname "src/kit/"
  :components ((:file "kit")))

(asdf:defsystem #:finch/windowserver
  :description "WindowServer"
  :depends-on (#:finch/layer #:finch/server #:finch/bsd #:finch/mach #:finch/init #:finch/io)
  :serial t
  :pathname "src/server/"
  :components ((:file "windowserver")))

(asdf:defsystem #:finch/apps
  :description "Applications"
  :depends-on (#:finch/layer #:finch/server #:finch/bsd #:finch/text #:finch/imageio #:finch/kit #:finch/edit #:finch/install #:finch/generation #:finch/devices #:finch/net)
  :serial t
  :pathname "src/apps/"
  :components ((:file "hello") (:file "terminal") (:file "listener") (:file "forcequit") (:file "editor") (:file "generations") (:file "session") (:file "fetch") (:file "install")))

(asdf:defsystem #:finch/devices
  :description "Devices: the registry, PCI and drivers"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/devices/"
  :components ((:file "machine") (:file "registry") (:file "acpi") (:file "pci") (:file "interrupt") (:file "virtio") (:file "storage") (:file "block") (:file "nvme") (:file "ramdisk") (:file "xhci") (:file "i2c") (:file "input") (:file "network") (:file "ecm") (:file "battery") (:file "backlight")))

(asdf:defsystem #:finch/nrepl
  :description "Remote eval"
  :depends-on (#:finch/net #:finch/devices)
  :serial t
  :pathname "src/nrepl/"
  :components ((:file "nrepl")))

(asdf:defsystem #:finch/net
  :description "Networking"
  :depends-on (#:uiop #:finch/devices)
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
  :description "APFS"
  :depends-on (#:uiop #:finch/devices #:finch/vfs)
  :serial t
  :pathname "src/apfs/"
  :components ((:file "apfs") (:file "devices") (:file "newfs") (:file "transaction") (:file "write") (:file "vfs") (:file "root")))

(asdf:defsystem #:finch/fat
  :description "FAT32"
  :depends-on (#:uiop #:finch/vfs #:finch/devices #:finch/gpt)
  :serial t
  :pathname "src/fat/"
  :components ((:file "fat") (:file "vfs")))

(asdf:defsystem #:finch/cc
  :description "C through libtcc"
  :depends-on (#:uiop)
  :pathname "src/cc/"
  :components ((:file "cc")))

(asdf:defsystem #:finch/build
  :description "Bootstrap inputs and trees"
  :depends-on (#:uiop (:require #:sb-md5))
  :pathname "src/build/"
  :components ((:file "build")))

(asdf:defsystem #:finch/run
  :description "Runs a core and collects its files"
  :depends-on (#:uiop #:finch/vfs #:finch/install)
  :pathname "src/run/"
  :components ((:file "run")))

(asdf:defsystem #:finch/generation
  :description "Builds a generation"
  :depends-on (#:uiop #:finch/vfs #:finch/run #:finch/cc #:finch/build #:finch/install #:finch/boot)
  :pathname "src/generation/"
  :components ((:file "generation")))

(asdf:defsystem #:finch/install
  :description "Generations"
  :depends-on (#:uiop #:finch/fat #:finch/low #:finch/platform #:finch/kern #:finch/link #:finch/gpt #:finch/apfs #:finch/devices #:finch/vfs #:finch/power #:finch/bsd (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/install/"
  :components ((:file "install") (:file "disk") (:file "deploy")))

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

(asdf:defsystem #:finch/gpt
  :description "GUID partition tables"
  :pathname "src/gpt/"
  :components ((:file "gpt")))

(asdf:defsystem #:finch/platform
  :description "Serial console"
  :depends-on (#:finch/low)
  :serial t
  :pathname "src/platform/i386/"
  :components ((:file "serial") (:file "init") (:file "font") (:file "console") (:file "ec")))

(asdf:defsystem #:finch/kern
  :description "Kernel"
  :depends-on (#:finch/low)
  :serial t
  :pathname "src/kern/i386/"
  :components ((:file "mtrr") (:file "power") (:file "printf") (:file "rtclock") (:file "vm-map") (:file "pmap") (:file "lapic") (:file "sched")
               (:file "signal" :pathname "../../bsd/kern/signal") (:file "trap") (:file "mp")
               (:file "systemcalls" :pathname "../../bsd/dev/i386/systemcalls")
               (:file "start" :pathname "../x86_64/start") (:file "init") (:file "stubs" :pathname "../x86_64/stubs") (:file "mp-desc") (:file "memory")))

(asdf:defsystem #:finch/link
  :description "Kernel linker"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/link/"
  :components ((:file "link")))

(asdf:defsystem #:finch/boot
  :description "boot.efi"
  :depends-on (#:finch/low)
  :serial t
  :pathname "src/boot/"
  :components ((:file "boot")))

(asdf:defsystem #:finch/kernel
  :description "The kernel, run as pid 1"
  :depends-on (#:finch/mach #:finch/bsd #:finch/io #:uiop)
  :serial t
  :pathname "src/kernel/"
  :components ((:file "kernel")))

(asdf:defsystem #:finch/image
  :description "The bootable image"
  :depends-on (#:uiop #:finch/qmp #:finch/io #:finch/apfs #:finch/fat #:finch/gpt #:finch/install #:finch/cc #:finch/build #:finch/platform #:finch/kern #:finch/low #:finch/boot #:finch/link (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/image/"
  :components ((:file "image") (:file "tcc") (:file "runtime") (:file "efi") (:file "deploy")))

(asdf:defsystem #:finch/server
  :description "The window server"
  :serial t
  :pathname "src/server/"
  :components ((:file "event")))

(asdf:defsystem #:finch/layer
  :description "Layers and their commits"
  :depends-on (#:finch/mach #:finch/bsd #:finch/init #:finch/server)
  :serial t
  :pathname "src/layer/"
  :components ((:file "client")))

(asdf:defsystem #:finch/qmp
  :description "QEMU's machine protocol"
  :depends-on (#:com.inuoe.jzon #:uiop (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/qmp/"
  :components ((:file "qmp")))

(asdf:defsystem #:finch
  :description "A live, hackable OS on SBCL"
  :depends-on (#:finch/mach #:finch/server #:finch/layer #:finch/bsd #:finch/init #:finch/shell #:finch/io #:finch/text #:finch/edit #:finch/imageio #:finch/kit #:finch/windowserver #:finch/apps #:finch/devices #:finch/vfs #:finch/apfs #:finch/fat #:finch/install #:finch/net #:finch/nrepl #:finch/run #:finch/generation #:finch/kernel #:finch/image)
  :in-order-to ((asdf:test-op (asdf:test-op #:finch/test))))

(asdf:defsystem #:finch/test
  :depends-on (#:finch #:fiveam (:require #:sb-posix) (:require #:sb-md5) (:require #:sb-bsd-sockets))
  :serial t
  :pathname "tests/"
  :components ((:file "suite") (:file "mach") (:file "server") (:file "init") (:file "boot") (:file "apfs") (:file "net") (:static-file "low-harness.c") (:file "low"))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :finch/test :run-them)))
