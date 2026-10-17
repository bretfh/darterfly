(defpackage #:darterfly/bsd
  (:use #:cl)
  (:export
   #:errno #:errno-name #:errno-code
   #:proc #:procs #:end-processes #:*resume* #:suspend-processes #:resume-processes #:keep-running #:stop-keeping #:*recording* #:*safe* #:suspend-threads #:resume-activities #:proc-pid #:proc-path #:*proc* #:*proc0* #:getpid #:getppid #:proc-task #:pfind #:task-pid
   #:fork #:exit #:wait4 #:kill #:pause #:sigaction #:sigprocmask #:signo #:signame
   #:pipe #:read #:write #:close #:dup #:dup2 #:fcntl
   #:+o-nonblock+ #:+f-getfl+ #:+f-setfl+
   #:open #:lseek #:stat #:lstat #:fstat #:mkdir #:rmdir #:unlink #:rename #:symlink #:readdir
   #:chdir #:getcwd #:+o-rdonly+ #:+o-wronly+ #:+o-rdwr+ #:+o-append+ #:+o-creat+ #:+o-trunc+
   #:chroot #:execve #:posix-spawn #:define-program #:reboot #:*reboot* #:with-stdio #:proc-comm #:bsdthread-create #:define-process-variable
   #:+o-excl+ #:+o-directory+ #:+s-ifmt+ #:+s-ifdir+ #:+s-ifreg+ #:+s-ififo+ #:+s-iflnk+
   #:socket #:bind #:listen #:accept #:connect #:send #:recv #:sendto #:recvfrom #:+af-inet+ #:+af-inet6+ #:+sock-stream+ #:+sock-dgram+
   #:wifexited #:wexitstatus #:wifsignaled #:wtermsig #:wifstopped #:wstopsig #:wifcontinued)
  (:shadow #:read #:write #:close #:open #:listen)
  (:local-nicknames (#:vfs #:darterfly/vfs)))
(in-package #:darterfly/bsd)

(defparameter +errno+
  '((:eperm . 1) (:enoent . 2) (:esrch . 3) (:eintr . 4) (:eio . 5) (:enxio . 6) (:e2big . 7)
    (:enoexec . 8) (:ebadf . 9) (:echild . 10) (:edeadlk . 11) (:enomem . 12) (:eacces . 13)
    (:efault . 14) (:enotblk . 15) (:ebusy . 16) (:eexist . 17) (:exdev . 18) (:enodev . 19)
    (:enotdir . 20) (:eisdir . 21) (:einval . 22) (:enfile . 23) (:emfile . 24) (:enotty . 25)
    (:etxtbsy . 26) (:efbig . 27) (:enospc . 28) (:espipe . 29) (:erofs . 30) (:emlink . 31)
    (:epipe . 32) (:edom . 33) (:erange . 34) (:eagain . 35) (:einprogress . 36) (:ealready . 37)
    (:enotsock . 38) (:edestaddrreq . 39) (:eprotonosupport . 43) (:eopnotsupp . 45) (:eafnosupport . 47)
    (:eaddrinuse . 48) (:enetdown . 50) (:enetunreach . 51) (:econnreset . 54) (:eisconn . 56) (:enotconn . 57)
    (:etimedout . 60) (:econnrefused . 61) (:enametoolong . 63) (:ehostunreach . 65) (:enotempty . 66) (:enosys . 78)))

(define-condition errno (error)
  ((name :initarg :name :reader errno-name))
  (:report (lambda (c s) (format s "~a (~d)" (symbol-name (errno-name c)) (errno-code c)))))

(defun errno-code (c)
  (cdr (assoc (if (typep c 'errno) (errno-name c) c) +errno+)))

(defun fail (name)
  (error 'errno :name name))

(defparameter +signals+
  #(nil :sighup :sigint :sigquit :sigill :sigtrap :sigabrt :sigemt :sigfpe :sigkill :sigbus :sigsegv
    :sigsys :sigpipe :sigalrm :sigterm :sigurg :sigstop :sigtstp :sigcont :sigchld :sigttin :sigttou
    :sigio :sigxcpu :sigxfsz :sigvtalrm :sigprof :sigwinch :siginfo :sigusr1 :sigusr2))

(defun signo (signal)
  (if (integerp signal)
      signal
      (or (position signal +signals+) (fail :einval))))

(defun signame (signo)
  (aref +signals+ signo))

(defun default-action (signo)
  (case (signame signo)
    ((:sigurg :sigchld :sigwinch :siginfo :sigio :sigcont) :ignore)
    ((:sigstop :sigtstp :sigttin :sigttou) :stop)
    (t :term)))

(defun w-exitcode (code signo) (logior (ash code 8) signo))
(defconstant +wstopped+ #o177)
(defun w-stopcode (signo) (logior (ash signo 8) +wstopped+))
(defconstant +continued+ #x13)

(defun wstatus (status) (logand status #o177))
(defun wifexited (status) (zerop (wstatus status)))
(defun wexitstatus (status) (ldb (byte 8 8) status))
(defun wstopsig (status) (ash status -8))
(defun wifstopped (status) (and (= (wstatus status) +wstopped+) (/= (wstopsig status) +continued+)))
(defun wifcontinued (status) (and (= (wstatus status) +wstopped+) (= (wstopsig status) +continued+)))
(defun wifsignaled (status) (and (/= (wstatus status) +wstopped+) (/= (wstatus status) 0)))
(defun wtermsig (status) (wstatus status))
