;;; Copy completed guest artifacts out of the stopped build disk, read-only.
(require :asdf)
(asdf:load-system :darterfly/image)
(let* ((root (asdf:system-source-directory :darterfly))
       (disk (merge-pathnames "build/tblgen-rebuild.img" root))
       (out (merge-pathnames "build/tblgen-rebuild/native/" root)))
  (when (darterfly/image::in-use-p disk)
    (error "Stop the rebuild VM before exporting ~a" disk))
  (let* ((container (darterfly/apfs:open-container (darterfly/apfs:file-device disk)))
         (volume (first (darterfly/apfs:container-volumes container))))
    (dolist (name '("clang-tblgen" "libLLVMSupport.a" "libLLVMTableGen.a"
                    "libLLVMDemangle.a" "runtime.a" "DeclNodes.inc" "StmtNodes.inc"
                    "AttrList.inc" "EditedNodes.inc" "destructors"))
      (let* ((id (or (darterfly/apfs:lookup volume (concatenate 'string "/work/tblgen/" name))
                     (error "Missing guest artifact ~a" name)))
             (path (merge-pathnames name out)))
        (ensure-directories-exist path)
        (with-open-file (s path :direction :output :if-exists :supersede
                               :element-type '(unsigned-byte 8))
          (write-sequence (darterfly/apfs:read-file volume id) s))
        (format t "Exported ~a (~d bytes)~%" name
                (darterfly/apfs:inode-size (darterfly/apfs:inode volume id)))))
    (dolist (name '("plan.sexp" "inputs.json"))
      (let ((id (or (darterfly/apfs:lookup volume
                      (concatenate 'string "/usr/share/tblgen-rebuild/" name))
                    (error "Missing guest provenance ~a" name))))
        (with-open-file (s (merge-pathnames name out) :direction :output
                         :if-exists :supersede :element-type '(unsigned-byte 8))
          (write-sequence (darterfly/apfs:read-file volume id) s))))))
