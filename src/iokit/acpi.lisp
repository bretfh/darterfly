(in-package #:finch/iokit)

(defun efi-system-table ()
  (sb-sys:sap-ref-32 (sb-sys:int-sap (boot-args)) 1104))

(defun acpi-rsdp ()
  (let* ((st (efi-system-table))
         (count (ml-phys-read-64 (+ st 104)))
         (table (ml-phys-read-64 (+ st 112))))
    (loop for i below count
          for entry = (+ table (* i 24))
          when (and (= (ml-phys-read-32 entry) #x8868e871)
                    (= (ml-phys-read-64 (+ entry 8)) #x81883cc7800022bc))
            return (ml-phys-read-64 (+ entry 16)))))

(defun acpi-table (signature)
  (let* ((xsdt (ml-phys-read-64 (+ (acpi-rsdp) 24)))
         (n (floor (- (ml-phys-read-32 (+ xsdt 4)) 36) 8)))
    (loop for i below n
          for table = (ml-phys-read-64 (+ xsdt 36 (* i 8)))
          when (string= (ml-phys-string table 4) signature)
            return table)))
