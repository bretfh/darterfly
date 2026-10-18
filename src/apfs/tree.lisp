(in-package #:darterfly/apfs)

(defstruct leaf keys low oid paddr xid dirty root)

(defstruct (tree (:copier nil)) leaves table compare physical subtype info-flags index (longest-key 0) (longest-value 0))

(defun fs-key-compare (a b)
  (let ((ida (logand (u64 a 0) #x0fffffffffffffff)) (idb (logand (u64 b 0) #x0fffffffffffffff))
        (ta (ash (u64 a 0) -60)) (tb (ash (u64 b 0) -60)))
    (cond ((/= ida idb) (if (< ida idb) -1 1))
          ((/= ta tb) (if (< ta tb) -1 1))
          ((= ta +apfs-type-dir-rec+)
           (let ((ha (ash (u32 a 8) -10)) (hb (ash (u32 b 8) -10)))
             (if (/= ha hb) (if (< ha hb) -1 1) (octets-compare a b 12))))
          ((= ta +apfs-type-file-extent+)
           (let ((oa (u64 a 8)) (ob (u64 b 8))) (cond ((< oa ob) -1) ((> oa ob) 1) (t 0))))
          ((= ta +apfs-type-xattr+) (octets-compare a b 10))
          (t 0))))

(defun octets-compare (a b from)
  (loop for i from from
        do (cond ((and (>= i (length a)) (>= i (length b))) (return 0))
                 ((>= i (length a)) (return -1))
                 ((>= i (length b)) (return 1))
                 ((< (aref a i) (aref b i)) (return -1))
                 ((> (aref a i) (aref b i)) (return 1)))))

(defun u64-key-compare (a b)
  (let ((x (u64 a 0)) (y (u64 b 0))) (cond ((< x y) -1) ((> x y) 1) (t 0))))

(defun key< (tree a b) (minusp (funcall (tree-compare tree) a b)))

(defun leaf-for (tree key)
  (let* ((leaves (tree-leaves tree)) (lo 0) (hi (1- (length leaves))))
    (loop while (< lo hi)
          do (let ((mid (ceiling (+ lo hi) 2)))
               (if (key< tree key (leaf-low (aref leaves mid)))
                   (setf hi (1- mid))
                   (setf lo mid))))
    (aref leaves lo)))

(defun key-vector (keys) (make-array (length keys) :adjustable t :fill-pointer t :initial-contents keys))

(defun key-position (tree keys key)
  (let ((lo 0) (hi (length keys)))
    (loop while (< lo hi)
          do (let* ((mid (floor (+ lo hi) 2)) (c (funcall (tree-compare tree) (aref keys mid) key)))
               (cond ((minusp c) (setf lo (1+ mid)))
                     ((plusp c) (setf hi mid))
                     (t (return-from key-position (values mid t))))))
    (values lo nil)))

(defun tree-touch (tree key change)
  (when tree
    (when (zerop (length (tree-leaves tree)))
      (setf (tree-leaves tree) (vector (make-leaf :keys (key-vector nil) :dirty t))))
    (let* ((leaf (leaf-for tree key))
           (keys (leaf-keys leaf)))
      (setf (leaf-dirty leaf) t)
      (multiple-value-bind (at found) (key-position tree keys key)
        (case change
          (:insert (unless found
                     (vector-push-extend key keys)
                     (replace keys keys :start1 (1+ at) :start2 at :end2 (1- (length keys)))
                     (setf (aref keys at) key)))
          (:delete (when found
                     (replace keys keys :start1 at :start2 (1+ at))
                     (decf (fill-pointer keys)))))))))

(defun leaf-first (leaf) (let ((keys (leaf-keys leaf))) (and (plusp (length keys)) (aref keys 0))))

(defun tree-from-leaves (leaves &key compare physical subtype info-flags index)
  (let ((v (coerce leaves 'vector)))
    (loop for leaf across v for i from 0
          do (setf (leaf-low leaf) (if (zerop i) nil (leaf-first leaf))))
    (make-tree :leaves v :compare compare :physical physical :subtype subtype :info-flags info-flags :index index)))

(defun walk-leaves (nx root &key resolve)
  (let ((leaves nil) (index nil) (records nil))
    (labels ((visit (oid)
               (let* ((paddr (if resolve (funcall resolve oid) oid))
                      (block (nx-block nx paddr)))
                 (unless (object-valid-p block) (fail "tree node ~d at ~d fails its checksum" oid paddr))
                 (let ((node (make-node block)) (keys nil))
                   (dotimes (i (node-count node))
                     (multiple-value-bind (k ks v vs) (node-entry node i 16 (if (logtest (node-flags node) +btnode-fixed-kv-size+) 16 0))
                       (if (node-leaf-p node)
                           (let ((key (subseq block k (+ k ks))))
                             (push key keys)
                             (push (cons key (subseq block v (+ v vs))) records))
                           (visit (u64 block v)))))
                   (if (node-leaf-p node)
                       (push (make-leaf :keys (key-vector (nreverse keys)) :oid oid :paddr paddr :xid (object-xid block)
                                        :root (logtest (u16 block 32) 1))
                             leaves)
                       (push paddr index))))))
      (visit root))
    (values (nreverse leaves) (nreverse records) index)))

(defun tree-keys (tree) (reduce #'+ (tree-leaves tree) :key (lambda (l) (length (leaf-keys l)))))

(defun leaf-node (tree leaf records xid root total-keys total-nodes)
  (btree-node (leaf-oid leaf) xid (logior (if (tree-physical tree) +obj-physical+ 0) (if root 2 3)) (tree-subtype tree) records
              :leaf t :root root :level 0 :info-flags (tree-info-flags tree)
              :key-count total-keys :node-count total-nodes
              :longest-key (tree-longest-key tree) :longest-value (tree-longest-value tree)))

(defun tree-commit (tree xid alloc next-oid)
  (let ((freed (shiftf (tree-index tree) nil))
        (writes nil)
        (built nil))
    (flet ((value (key) (gethash key (tree-table tree))))
      (let ((leaves nil))
        (loop for leaf across (tree-leaves tree)
              do (if (not (leaf-dirty leaf))
                     (push leaf leaves)
                     (let ((records (map 'list (lambda (k) (cons k (value k))) (leaf-keys leaf))))
                       (when (leaf-paddr leaf) (push (leaf-paddr leaf) freed))
                       (dolist (r records)
                         (setf (tree-longest-key tree) (max (tree-longest-key tree) (length (car r)))
                               (tree-longest-value tree) (max (tree-longest-value tree) (length (cdr r)))))
                       (when records
                         (loop for group in (if (fits-p records nil nil 0 0) (list records) (split-records records nil 0 0))
                               for first = t then nil
                               do (push (make-leaf :keys (key-vector (mapcar #'car group)) :dirty t
                                                   :oid (and first (not (tree-physical tree)) (leaf-oid leaf)))
                                        leaves))))))
        (setf leaves (coerce (nreverse leaves) 'vector))
        (when (zerop (length leaves)) (setf leaves (vector (make-leaf :keys (key-vector nil) :dirty t))))
        (let ((single (= (length leaves) 1)))
          (loop for leaf across leaves
                do (when (and (not (leaf-dirty leaf)) (not (eq (leaf-root leaf) single)))
                     (push (leaf-paddr leaf) freed)
                     (setf (leaf-dirty leaf) t)))
          (when (and single (not (fits-p (map 'list (lambda (k) (cons k (value k))) (leaf-keys (aref leaves 0))) nil t 0 0)))
            (let* ((keys (coerce (leaf-keys (aref leaves 0)) 'list)) (half (ceiling (length keys) 2)))
              (setf leaves (vector (make-leaf :keys (key-vector (subseq keys 0 half)) :oid (leaf-oid (aref leaves 0)) :dirty t)
                                   (make-leaf :keys (key-vector (subseq keys half)) :dirty t))
                    single nil)))
          (let* ((total-keys (loop for l across leaves sum (length (leaf-keys l))))
                 (index-levels (unless single
                                 (let ((levels nil)
                                       (entries (loop for l across leaves collect (cons (leaf-first l) (le 0 8)))))
                                   (loop
                                     (let ((groups (if (fits-p entries nil t 0 8) (list entries) (split-records entries nil 0 8))))
                                       (push groups levels)
                                       (when (= (length groups) 1) (return))
                                       (setf entries (mapcar (lambda (g) (cons (car (first g)) (le 0 8))) groups))))
                                   (nreverse levels))))
                 (total-nodes (+ (length leaves) (reduce #'+ index-levels :key #'length))))
            (loop for leaf across leaves
                  do (when (leaf-dirty leaf)
                       (let ((paddr (funcall alloc)))
                         (unless (leaf-oid leaf) (setf (leaf-oid leaf) (if (tree-physical tree) paddr (funcall next-oid))))
                         (when (tree-physical tree) (setf (leaf-oid leaf) paddr))
                         (setf (leaf-paddr leaf) paddr (leaf-xid leaf) xid (leaf-root leaf) single (leaf-dirty leaf) nil)
                         (push (cons paddr (leaf-node tree leaf (map 'list (lambda (k) (cons k (value k))) (leaf-keys leaf))
                                                      xid single total-keys total-nodes))
                               writes)))
                     (push (list (leaf-oid leaf) (leaf-xid leaf) (leaf-paddr leaf)) built))
            (let ((children (loop for l across leaves collect (leaf-oid l)))
                  (root-oid (and single (leaf-oid (aref leaves 0)))))
              (loop for groups in index-levels
                    for level from 1
                    for top = (= level (length index-levels))
                    do (let ((oids nil))
                         (dolist (group groups)
                           (let* ((paddr (funcall alloc))
                                  (oid (if (tree-physical tree) paddr (funcall next-oid)))
                                  (entries (mapcar (lambda (e) (cons (car e) (le (pop children) 8))) group)))
                             (push oid oids)
                             (push paddr (tree-index tree))
                             (push (list oid xid paddr) built)
                             (push (cons paddr (btree-node oid xid (logior (if (tree-physical tree) +obj-physical+ 0) (if top 2 3))
                                                           (tree-subtype tree) entries
                                                           :value-size 8 :info-flags (tree-info-flags tree) :root top :level level
                                                           :key-count total-keys :node-count total-nodes
                                                           :longest-key (tree-longest-key tree) :longest-value (tree-longest-value tree)))
                                   writes)
                             (when top (setf root-oid oid))))
                         (setf children (nreverse oids))))
              (loop for leaf across leaves for i from 0
                    do (setf (leaf-low leaf) (if (zerop i) nil (leaf-first leaf))))
              (setf (tree-leaves tree) leaves)
              (values root-oid (nreverse writes) freed built))))))))
