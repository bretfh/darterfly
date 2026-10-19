(use-modules (guix profiles) (gnu packages))
(specifications->manifest
 '("sbcl" "sbcl-alexandria" "sbcl-babel" "sbcl-bordeaux-threads"
   "sbcl-cffi" "sbcl-cl-json" "sbcl-nclasses" "sbcl-lisp-unit2"
   "python" "xorg-server" "nss"))
