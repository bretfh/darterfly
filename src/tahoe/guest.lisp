(in-package #:finch/tahoe)

(defparameter *memory* 16384)
(defparameter *cpus* 8)
(defparameter *disk-size* "192G")
(defparameter *cpu*
  "Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check")
(defparameter *osk* "ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc")

(defun home (name) (merge-pathnames name *home*))

(defun recovery ()
  (merge-pathnames "../recovery/BaseSystem.img" *home*))

(defun recovery-image ()
  (let ((img (recovery))
        (dmg (merge-pathnames "../recovery/BaseSystem.dmg" *home*)))
    (unless (probe-file img)
      (unless (probe-file dmg) (error "no ~a" (uiop:native-namestring dmg)))
      (sh "qemu-img" "convert" "-f" "dmg" "-O" "raw" dmg img))
    img))

(defun serial-log () (home "serial.log"))

(defun drive (id file format &rest more)
  (list "-drive" (format nil "id=~a,if=none,format=~a,file=~a~{,~a~}" id format
                         (if (pathnamep file) (uiop:native-namestring file) file) more)))

(defun boot (&key install)
  (ensure-directories-exist *home*)
  (let ((vars (home "OVMF_VARS.fd"))
        (disk (home "disk.qcow2")))
    (unless (probe-file vars)
      (sh "cp" (share "firmware/ovmf_vars_x64.bin") vars)
      (sh "chmod" "u+w" vars))
    (unless (probe-file disk)
      (sh "qemu-img" "create" "-f" "qcow2" disk *disk-size*))
    (let ((esp (esp)))
      (apply #'sh "qemu-system-x86_64"
             (append
              (list "-name" "tahoe" "-daemonize" "-pidfile" (home "qemu.pid")
                    "-enable-kvm" "-m" (princ-to-string *memory*) "-cpu" *cpu*
                    "-machine" "q35" "-smp" (format nil "~d,cores=~d,sockets=1" *cpus* (/ *cpus* 2))
                    "-device" "qemu-xhci,id=xhci"
                    "-device" "usb-kbd,bus=xhci.0" "-device" "usb-tablet,bus=xhci.0"
                    "-device" (format nil "isa-applesmc,osk=~a" *osk*)
                    "-drive" (format nil "if=pflash,format=raw,readonly=on,file=~a"
                                     (uiop:native-namestring (share "firmware/ovmf_code_x64.bin")))
                    "-drive" (format nil "if=pflash,format=raw,file=~a" (uiop:native-namestring vars))
                    "-smbios" "type=2"
                    "-device" "ich9-ahci,id=sata")
              (drive "esp" (format nil "fat:~a" (uiop:native-namestring esp)) "raw" "snapshot=on")
              (list "-device" "ide-hd,bus=sata.0,drive=esp")
              (when install
                (append (drive "install" (recovery-image) "raw")
                        (list "-device" "ide-hd,bus=sata.1,drive=install")))
              (drive "disk" disk "qcow2" "discard=unmap")
              (list "-device" "ide-hd,bus=sata.2,drive=disk"
                    "-netdev" "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22"
                    "-device" "virtio-net-pci,netdev=net0,mac=52:54:00:c9:18:27"
                    "-device" "vmware-svga"
                    "-display" "none" "-vnc" "127.0.0.1:31"
                    "-qmp" (format nil "unix:~a,server=on,wait=off" (uiop:native-namestring (qmp-socket)))
                    "-serial" (format nil "file:~a" (uiop:native-namestring (serial-log))))))
      (query-status))))
