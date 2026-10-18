(asdf:defsystem #:darterfly/mach
  :description "Ports, rights, names and messages"
  :serial t
  :pathname "src/mach/"
  :components ((:file "kern") (:file "port") (:file "msg") (:file "task")))

(asdf:defsystem #:darterfly/bsd
  :description "Processes, signals and files"
  :depends-on (#:darterfly/mach #:darterfly/net #:darterfly/vfs #:darterfly/worlds)
  :serial t
  :pathname "src/bsd/"
  :components ((:file "errno") (:file "proc") (:file "file") (:file "socket") (:file "vfs") (:file "stdio") (:file "exec") (:file "libsa")))

(asdf:defsystem #:darterfly/init
  :description "init and service"
  :depends-on (#:darterfly/bsd #:darterfly/mach #:darterfly/worlds #:darterfly/run)
  :serial t
  :pathname "src/init/"
  :components ((:file "init")))

(asdf:defsystem #:darterfly/shell
  :description "The shell"
  :depends-on (#:darterfly/bsd)
  :serial t
  :pathname "src/shell/"
  :components ((:file "shell")))

(asdf:defsystem #:darterfly/io
  :description "Frame buffers and input devices"
  :depends-on (#:uiop #:darterfly/devices (:require #:sb-posix))
  :serial t
  :pathname "src/io/"
  :components ((:file "framebuffer") (:file "hid") (:file "report") (:file "blend") (:file "keymap")))

(asdf:defsystem #:darterfly/text
  :description "Fonts and text"
  :depends-on (#:zpb-ttf #:cl-vectors #:cl-paths-ttf)
  :serial t
  :pathname "src/text/"
  :components ((:file "text")))

(asdf:defsystem #:darterfly/edit
  :description "Buffers"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/edit/"
  :components ((:file "package") (:file "buffer") (:file "lisp")))

(asdf:defsystem #:darterfly/imageio
  :description "Images and icons"
  :depends-on (#:chipz)
  :serial t
  :pathname "src/imageio/"
  :components ((:file "imageio")))

(asdf:defsystem #:darterfly/power
  :description "Restart and shut down"
  :depends-on (#:darterfly/devices #:darterfly/vfs #:darterfly/bsd)
  :serial t
  :pathname "src/power/"
  :components ((:file "power")))

(asdf:defsystem #:darterfly/kit
  :description "Views, windows and menus"
  :depends-on (#:darterfly/layer #:darterfly/text #:darterfly/mach #:darterfly/server #:darterfly/bsd #:darterfly/imageio #:darterfly/power)
  :serial t
  :pathname "src/kit/"
  :components ((:file "kit")))

(asdf:defsystem #:darterfly/stats
  :description "What the system is doing"
  :depends-on (#:darterfly/devices #:darterfly/bsd)
  :serial t
  :pathname "src/stats/"
  :components ((:file "stats")))

(asdf:defsystem #:darterfly/windowserver
  :description "WindowServer"
  :depends-on (#:darterfly/layer #:darterfly/server #:darterfly/bsd #:darterfly/mach #:darterfly/init #:darterfly/io #:darterfly/stats #:darterfly/power)
  :serial t
  :pathname "src/server/"
  :components ((:file "windowserver")))

(asdf:defsystem #:darterfly/bench
  :description "The benchmark suite"
  :depends-on (#:darterfly/bsd #:darterfly/mach #:darterfly/vfs #:darterfly/stats #:darterfly/windowserver #:darterfly/worlds #:darterfly/run #:darterfly/install)
  :serial t
  :pathname "src/bench/"
  :components ((:file "bench")))

(asdf:defsystem #:darterfly/apps
  :description "Applications"
  :depends-on (#:darterfly/layer #:darterfly/server #:darterfly/bsd #:darterfly/text #:darterfly/imageio #:darterfly/kit #:darterfly/edit #:darterfly/install #:darterfly/generation #:darterfly/devices #:darterfly/net #:darterfly/wifi #:darterfly/journal #:darterfly/worlds)
  :serial t
  :pathname "src/apps/"
  :components ((:file "hello") (:file "terminal") (:file "listener") (:file "forcequit") (:file "editor") (:file "generations") (:file "session") (:file "fetch") (:file "install") (:file "ocicl")))

(asdf:defsystem #:darterfly/devices
  :description "Devices: the registry, PCI and drivers"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/devices/"
  :components ((:file "machine") (:file "registry") (:file "acpi") (:file "pci") (:file "interrupt") (:file "virtio") (:file "storage") (:file "block") (:file "nvme") (:file "ramdisk") (:file "xhci") (:file "i2c") (:file "input") (:file "network") (:file "ecm") (:file "battery") (:file "backlight")))

(asdf:defsystem #:darterfly/crypto
  :description "Hashes and ciphers"
  :serial t
  :pathname "src/crypto/"
  :components ((:file "sha1") (:file "aes")))

(asdf:defsystem #:darterfly/wifi
  :description "Wi-Fi"
  :depends-on (#:darterfly/crypto #:darterfly/devices #:darterfly/net #:darterfly/bsd)
  :serial t
  :pathname "src/wifi/"
  :components ((:file "eapol") (:file "firmware") (:file "ax210") (:file "join")))

(asdf:defsystem #:darterfly/worlds
  :description "Worlds and ports"
  :serial t
  :pathname "src/worlds/"
  :components ((:file "worlds")))

(asdf:defsystem #:darterfly/journal
  :description "Forms evaluated since the last save"
  :depends-on (#:darterfly/vfs)
  :serial t
  :pathname "src/journal/"
  :components ((:file "journal")))

(asdf:defsystem #:darterfly/nrepl
  :description "Remote eval"
  :depends-on (#:darterfly/net #:darterfly/devices #:darterfly/bsd #:darterfly/journal)
  :serial t
  :pathname "src/nrepl/"
  :components ((:file "nrepl")))

(asdf:defsystem #:darterfly/net
  :description "Networking"
  :depends-on (#:uiop #:darterfly/devices)
  :serial t
  :pathname "src/net/"
  :components ((:file "net") (:file "ip6") (:file "tcp") (:file "dhcp") (:file "dns")))

(asdf:defsystem #:darterfly/vfs
  :description "The virtual file system"
  :depends-on (#:uiop (:require #:sb-posix))
  :serial t
  :pathname "src/vfs/"
  :components ((:file "vfs") (:file "ramfs") (:file "start") (:file "host")))

(asdf:defsystem #:darterfly/apfs
  :description "APFS"
  :depends-on (#:uiop #:darterfly/devices #:darterfly/vfs)
  :serial t
  :pathname "src/apfs/"
  :components ((:file "apfs") (:file "devices") (:file "newfs") (:file "tree") (:file "transaction") (:file "write") (:file "vfs") (:file "root")))

(asdf:defsystem #:darterfly/fat
  :description "FAT32"
  :depends-on (#:uiop #:darterfly/vfs #:darterfly/devices #:darterfly/gpt)
  :serial t
  :pathname "src/fat/"
  :components ((:file "fat") (:file "vfs")))

(asdf:defsystem #:darterfly/cc
  :description "C through libtcc"
  :depends-on (#:uiop)
  :pathname "src/cc/"
  :components ((:file "cc")))

(asdf:defsystem #:darterfly/build
  :description "Bootstrap inputs and trees"
  :depends-on (#:uiop (:require #:sb-md5))
  :pathname "src/build/"
  :components ((:file "build")))

(asdf:defsystem #:darterfly/run
  :description "Runs a core and collects its files"
  :depends-on (#:uiop #:darterfly/vfs #:darterfly/install #:darterfly/worlds)
  :pathname "src/run/"
  :components ((:file "run")))

(asdf:defsystem #:darterfly/generation
  :description "Builds a generation"
  :depends-on (#:uiop #:darterfly/vfs #:darterfly/run #:darterfly/cc #:darterfly/build #:darterfly/install #:darterfly/boot)
  :pathname "src/generation/"
  :components ((:file "generation")))

(asdf:defsystem #:darterfly/install
  :description "Generations"
  :depends-on (#:uiop #:darterfly/fat #:darterfly/low #:darterfly/platform #:darterfly/kern #:darterfly/link #:darterfly/gpt #:darterfly/apfs #:darterfly/devices #:darterfly/vfs #:darterfly/power #:darterfly/bsd #:darterfly/journal #:darterfly/worlds (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/install/"
  :components ((:file "install") (:file "disk") (:file "deploy")))

(asdf:defsystem #:darterfly/asm
  :description "x86-64 objects"
  :serial t
  :pathname "src/asm/"
  :components ((:file "asm")))

(asdf:defsystem #:darterfly/low
  :description "Lisp below the heap"
  :depends-on (#:darterfly/asm)
  :serial t
  :pathname "src/low/"
  :components ((:file "low")))

(asdf:defsystem #:darterfly/gpt
  :description "GUID partition tables"
  :pathname "src/gpt/"
  :components ((:file "gpt")))

(asdf:defsystem #:darterfly/platform
  :description "Serial console"
  :depends-on (#:darterfly/low)
  :serial t
  :pathname "src/platform/i386/"
  :components ((:file "serial") (:file "init") (:file "font") (:file "console") (:file "ec")))

(asdf:defsystem #:darterfly/kern
  :description "Kernel"
  :depends-on (#:darterfly/low)
  :serial t
  :pathname "src/kern/i386/"
  :components ((:file "mtrr") (:file "power") (:file "printf") (:file "rtclock") (:file "vm-map") (:file "pmap") (:file "lapic") (:file "sched")
               (:file "signal" :pathname "../../bsd/kern/signal") (:file "trap") (:file "mp")
               (:file "systemcalls" :pathname "../../bsd/dev/i386/systemcalls") (:file "world")
               (:file "start" :pathname "../x86_64/start") (:file "init") (:file "stubs" :pathname "../x86_64/stubs") (:file "mp-desc") (:file "memory")))

(asdf:defsystem #:darterfly/link
  :description "Kernel linker"
  :depends-on (#:uiop)
  :serial t
  :pathname "src/link/"
  :components ((:file "link")))

(asdf:defsystem #:darterfly/boot
  :description "boot.efi"
  :depends-on (#:darterfly/low)
  :serial t
  :pathname "src/boot/"
  :components ((:file "boot")))

(asdf:defsystem #:darterfly/kernel
  :description "The kernel, run as pid 1"
  :depends-on (#:darterfly/mach #:darterfly/bsd #:darterfly/io #:uiop)
  :serial t
  :pathname "src/kernel/"
  :components ((:file "kernel")))

(asdf:defsystem #:darterfly/image
  :description "The bootable image"
  :depends-on (#:uiop #:darterfly/qmp #:darterfly/io #:darterfly/apfs #:darterfly/fat #:darterfly/gpt #:darterfly/install #:darterfly/cc #:darterfly/build #:darterfly/platform #:darterfly/kern #:darterfly/low #:darterfly/boot #:darterfly/link (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/image/"
  :components ((:file "image") (:file "tcc") (:file "runtime") (:file "efi") (:file "deploy") (:file "bench")))

(asdf:defsystem #:darterfly/server
  :description "The window server"
  :serial t
  :pathname "src/server/"
  :components ((:file "event")))

(asdf:defsystem #:darterfly/layer
  :description "Layers and their commits"
  :depends-on (#:darterfly/mach #:darterfly/bsd #:darterfly/init #:darterfly/server)
  :serial t
  :pathname "src/layer/"
  :components ((:file "client")))

(asdf:defsystem #:darterfly/qmp
  :description "QEMU's machine protocol"
  :depends-on (#:com.inuoe.jzon #:uiop (:require #:sb-bsd-sockets))
  :serial t
  :pathname "src/qmp/"
  :components ((:file "qmp")))

(asdf:defsystem #:darterfly
  :description "A live, hackable OS on SBCL"
  :depends-on (#:darterfly/mach #:darterfly/server #:darterfly/layer #:darterfly/bsd #:darterfly/init #:darterfly/shell #:darterfly/io #:darterfly/text #:darterfly/edit #:darterfly/imageio #:darterfly/kit #:darterfly/stats #:darterfly/windowserver #:darterfly/bench #:darterfly/apps #:darterfly/devices #:darterfly/vfs #:darterfly/apfs #:darterfly/fat #:darterfly/install #:darterfly/net #:darterfly/nrepl #:darterfly/run #:darterfly/generation #:darterfly/kernel #:darterfly/image #:darterfly/crypto #:darterfly/wifi #:darterfly/journal #:darterfly/worlds)
  :in-order-to ((asdf:test-op (asdf:test-op #:darterfly/test))))

(asdf:defsystem #:darterfly/test
  :depends-on (#:darterfly #:fiveam (:require #:sb-posix) (:require #:sb-md5) (:require #:sb-bsd-sockets))
  :serial t
  :pathname "tests/"
  :components ((:file "suite") (:file "mach") (:file "server") (:file "init") (:file "boot") (:file "apfs") (:file "net") (:file "wifi") (:file "power") (:file "install") (:static-file "low-harness.c") (:file "low"))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :darterfly/test :run-them)))
