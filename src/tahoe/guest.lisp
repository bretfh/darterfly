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
      (uiop:delete-file-if-exists (qmp-socket))
      (uiop:launch-program
             (append
              (list "setsid" "qemu-system-x86_64" "-name" "tahoe" "-pidfile" (uiop:native-namestring (home "qemu.pid"))
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
                    "-display" "gtk,zoom-to-fit=on"
                    "-qmp" (format nil "unix:~a,server=on,wait=off" (uiop:native-namestring (qmp-socket)))
                    "-serial" (format nil "file:~a" (uiop:native-namestring (serial-log)))))
             :output (uiop:native-namestring (home "qemu.log")) :if-output-exists :supersede
             :error-output :output)
      (loop :repeat 100 :until (probe-file (qmp-socket)) :do (sleep 0.1))
      (query-status))))

(defparameter *user* "finch")
(defparameter *password* "finch")
(defparameter *ssh-port* 2222)

(defun ssh-key () (home "id_ed25519"))

(defun ssh-options ()
  (list "-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null" "-o" "LogLevel=ERROR"
        "-p" (princ-to-string *ssh-port*)))

(defun authorize ()
  (unless (probe-file (ssh-key))
    (sh "ssh-keygen" "-q" "-t" "ed25519" "-N" "" "-f" (ssh-key)))
  (apply #'sh "sshpass" "-p" *password* "ssh"
         (append (ssh-options)
                 (list (format nil "~a@127.0.0.1" *user*)
                       (format nil "mkdir -p .ssh && chmod 700 .ssh && echo '~a' >> .ssh/authorized_keys && chmod 600 .ssh/authorized_keys"
                               (string-trim '(#\Newline) (uiop:read-file-string (format nil "~a.pub" (uiop:native-namestring (ssh-key))))))))))

(defun guest (command)
  (apply #'sh "ssh" "-i" (ssh-key) "-o" "BatchMode=yes"
         (append (ssh-options) (list (format nil "~a@127.0.0.1" *user*) command))))

(defparameter *node* "v24.21.0")
(defparameter *node-sha256* "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097")

(defun node-tarball ()
  (let ((file (home (format nil "node-~a-darwin-x64.tar.gz" *node*))))
    (unless (probe-file file)
      (sh "curl" "-4" "-sSfL" "--cacert" "/etc/ssl/certs/ca-certificates.crt" "-o" file
          (format nil "https://nodejs.org/dist/~a/node-~a-darwin-x64.tar.gz" *node* *node*)))
    (let ((sum (subseq (sh "sha256sum" file) 0 64)))
      (unless (string= sum *node-sha256*)
        (delete-file file)
        (error "~a: sha256 ~a, expected ~a" file sum *node-sha256*)))
    file))

(defun rea-root ()
  (let ((rea (string-trim '(#\Newline) (sh "readlink" "-f" (sh-which "rea")))))
    (uiop:parse-native-namestring (format nil "~a/../share/" (directory-namestring rea)))))

(defun sh-which (name)
  (loop :for dir :in (uiop:split-string (uiop:getenv "PATH") :separator ":")
        :for file := (format nil "~a/~a" dir name)
        :when (probe-file file) :return file
        :finally (error "~a is not on PATH" name)))

(defun scp (file destination)
  (apply #'sh "scp" "-i" (ssh-key) "-o" "BatchMode=yes"
         (append (substitute "-P" "-p" (ssh-options) :test #'string=)
                 (list (uiop:native-namestring file)
                       (format nil "~a@127.0.0.1:~a" *user* destination)))))

(defun install-rea ()
  (let ((rea (home "rea.tar.gz")))
    (sh "tar" "-C" (rea-root) "-czf" rea "rea")
    (scp (node-tarball) "node.tar.gz")
    (scp rea "rea.tar.gz")
    (guest (format nil "rm -rf node rea && mkdir node && tar -xzf node.tar.gz -C node --strip-components 1 && tar -xzf rea.tar.gz && rm node.tar.gz rea.tar.gz && mkdir -p bin && printf '#!/bin/sh~%exec ~~/node/bin/node ~~/rea/node_modules/rea-agents/scripts/rea.mjs \"$@\"~%' > bin/rea && chmod +x bin/rea && bin/rea --version"))))
