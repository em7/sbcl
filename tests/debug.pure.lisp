
(defun foo (x) (values 'fo x))
(compile 'foo)
(defmacro with-messed-up-foo (&body body)
  `(let ((f #'foo))
     (sb-sys:with-pinned-objects (f)
       (let* ((sap (sb-sys:sap+ (sb-sys:int-sap (sb-kernel:get-lisp-obj-address f))
                                (- sb-vm:fun-pointer-lowtag)))
              (good (sb-sys:sap-ref-word sap 0)))
         (setf (ldb (byte 24 sb-vm:n-widetag-bits) (sb-sys:sap-ref-word sap 0)) 0)
         ;;(sb-vm:hexdump sap 2)
         ,@body
         (setf (sb-sys:sap-ref-word sap 0) good)))))

(with-test (:name :fun-code-header-bogus
                  :skipped-on :darwin-jit)
  ;; This "should" tests two things:
  ;; (1) that FUN-CODE-HEADER returns NIL if the simple-fun lacks a backpointer
  ;;     (expressed as a nonzero word count) to its containing code object.
  ;; (2) that GC doesn't crash in that situation.
  ;; Unfortunately the immobile-space GC *does* crash on it,
  ;; so I can't really test the second thing. But can it ever occur?
  ;; Specifically, why do all the variations of FUN-CODE-HEADER check for 0 ?
  (with-messed-up-foo
      (assert (null (sb-kernel:fun-code-header #'foo)))))

;;; Cross-check the C and lisp implementations of varint decoding
;;; the compiled debug fun locations.
(with-test (:name :c-decode-compiled-debug-fun-locs)
  (let ((ok t))
    (with-alien ((df-decode-locs (function int unsigned (* int) (* int))
                                 :extern)
                 (offset int)
                 (elsewhere-pc int))
      (dolist (code (sb-vm::list-allocated-objects
                     :all :type sb-vm:code-header-widetag))
        (when (typep (sb-kernel:%code-debug-info code)
                     'sb-c::compiled-debug-info)
          (do ((cdf (sb-c::compiled-debug-info-fun-map
                     (sb-kernel:%code-debug-info code))
                    (sb-c::compiled-debug-fun-next cdf)))
              ((null cdf))
            (let* ((locs (sb-c::compiled-debug-fun-encoded-locs cdf))
                   (res (sb-sys:with-pinned-objects (locs)
                          (alien-funcall df-decode-locs (sb-kernel:get-lisp-obj-address locs)
                                         (addr offset) (addr elsewhere-pc)))))
              (assert (= res 1))
              (multiple-value-bind (start-pc expect-elsewhere-pc form-number expect-offset)
                  (sb-c::cdf-decode-locs cdf)
                (declare (ignore start-pc form-number))
                (unless (and (= offset expect-offset)
                             (= elsewhere-pc expect-elsewhere-pc))
                  (setq ok nil)
                  (format t "Fail: ~X ~S ~S ~S ~S~%"
                          (sb-kernel:get-lisp-obj-address cdf)
                          offset expect-offset
                          elsewhere-pc expect-elsewhere-pc))))))))
    (assert ok)))

;;; Check that valid_tagged_pointer_p is correct for all pure boxed objects
;;; using the super quick check of header validity.
(defun randomly-probe-pure-boxed-objects ()
  (let (list)
    (sb-vm:map-allocated-objects
     (lambda (obj widetag size)
       (declare (ignore widetag))
       (let* ((index
               (sb-vm::find-page-index (sb-kernel:get-lisp-obj-address obj)))
              (type (sb-alien:slot (sb-alien:deref sb-vm::page-table index)
                                   'sb-vm::flags)))
         ;; mask off the SINGLE_OBJECT and OPEN_REGION bits
         (when (and (eq (logand type 7) 2) ; PAGE_TYPE_BOXED
                    ;; Cons cells on boxed pags are page filler
                    (not (listp obj)))
           (push (cons obj size) list))))
     :dynamic)
    (dolist (cell list)
      (let ((obj (car cell)) (size (cdr cell)))
        (sb-sys:with-pinned-objects (obj)
          ;; Check a random selection of pointers in between the untagged
          ;; base address up to the last byte in the object.
          ;; Exactly 1 should be OK.
          (let* ((taggedptr (sb-kernel:get-lisp-obj-address obj))
                 (base (logandc2 taggedptr sb-vm:lowtag-mask)))
            (dotimes (i 40)
              (let* ((ptr (+ base (random size)))
                     (valid (sb-di::valid-tagged-pointer-p (sb-sys:int-sap ptr))))
                (if (= ptr taggedptr)
                    (assert (= valid 1))
                    (assert (= valid 0)))))))))))
(compile 'randomly-probe-pure-boxed-objects)
(with-test (:name :fast-valid-tagged-pointer-p
                  :broken-on :mark-region-gc)
  (randomly-probe-pure-boxed-objects))
