#|
 This file is a part of trial
 (c) 2017 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)

(defclass uniform-buffer (gl-asset buffer-object)
  ((layout :initarg :layout :accessor layout)
   (qualifiers :initarg :qualifiers :accessor qualifiers)
   (binding :initarg :binding :accessor binding)
   (offsets :initarg :offsets :initform NIL :accessor offsets))
  (:default-initargs
   :buffer-type :uniform-buffer
   :layout :shared
   :qualifiers ()))

(defmethod initialize-instance :after ((buffer uniform-buffer) &key name binding)
  (unless binding
    (setf (binding buffer) (cffi:translate-underscore-separated-name name))))

(defmethod reinitialize-instance :after ((buffer uniform-buffer) &key)
  ;; Clear offsets as the underlying struct might have changed.
  (setf (offsets buffer) ()))

(defmethod gl-type ((buffer uniform-buffer))
  (gl-type (gl-struct (input buffer))))

(defmethod fields ((buffer uniform-buffer))
  (fields (gl-struct (input buffer))))

(defmethod gl-source ((buffer uniform-buffer))
  `(glsl-toolkit:shader
    ,@(loop for dependent in (compute-dependant-types buffer)
            collect (gl-source (gl-struct dependent)))
    (glsl-toolkit:interface-declaration
     (glsl-toolkit:type-qualifier
      ,@(when (layout buffer)
          `((glsl-toolkit:layout-qualifier
             ,@(loop for id in (enlist (layout buffer))
                     collect `(glsl-toolkit:layout-qualifier-id ,@(enlist id))))))
      :uniform
      ,@(qualifiers buffer))
     ,(gl-type buffer)
     ,(if (binding buffer)
          `(glsl-toolkit:instance-name ,(binding buffer))
          'glsl-toolkit:no-value)
     ,@(mapcar #'gl-source (fields buffer)))))

(defmethod compute-dependant-types ((buffer uniform-buffer))
  (compute-dependant-types (gl-struct (input buffer))))

(defun compute-uniform-buffer-fields (buffer)
  (labels ((gather-for-type (type name prefix)
             (etypecase type
               (cons
                (ecase (first type)
                  (:array
                   (loop for i from 0 below (third type)
                         nconc (gather-for-type (second type) ""
                                                (format NIL "~a~a[~d]" prefix name i))))
                  (:struct
                   (gather-fields (gl-struct (second type))
                                  (format NIL "~a~a." prefix name)))))
               (symbol (list (format NIL "~a~a" prefix name)))))
           (gather-fields (struct prefix)
             (loop for field in (fields struct)
                   nconc (gather-for-type (gl-type field) (gl-name field) prefix))))
    (gather-fields (gl-struct (input buffer)) (format NIL "~@[~a.~]" (gl-type buffer)))))

(defmethod compute-offsets ((buffer uniform-buffer) (program shader-program))
  (let* ((struct (gl-struct (input buffer)))
         (index (gl:get-uniform-block-index (gl-name program) (gl-type struct)))
         (size (gl:get-active-uniform-block (gl-name program) index :uniform-block-data-size))
         (offsets (make-hash-table :test 'equal))
         (fields (compute-uniform-buffer-fields buffer)))
    (cffi:with-foreign-objects ((names :pointer 1)
                                (indices :int 1)
                                (params :int 1))
      (dolist (field fields)
        (cffi:with-foreign-string (name field)
          (setf (cffi:mem-aref names :pointer 0) name)
          (%gl:get-uniform-indices (gl-name program) 1 names indices)
          (%gl:get-active-uniforms-iv (gl-name program) 1 indices :uniform-offset params)
          (setf (gethash field offsets) (cffi:mem-ref params :int)))))
    (values offsets size)))

(defmethod compute-offsets ((buffer uniform-buffer) (standard symbol))
  (compute-offsets (gl-struct (input buffer)) standard))

(defmethod load ((buffer uniform-buffer))
  ;; If the layout is std140 we can compute the size and offsets without a program.
  (when (and (find :std140 (enlist (layout buffer)))
             (null (offsets buffer)))
    (multiple-value-bind (offsets size) (compute-offsets (input buffer) :std140)
      (setf (offsets buffer) offsets)
      (setf (size buffer) size)))
  (allocate buffer)
  ;; If we have no buffer data supplied already, or bad data, create a data vector so we
  ;; can do easy batch updates. We do this after allocation to not waste time uploading the data
  ;; and no earlier because we might not know the size.
  (cond ((null (buffer-data buffer))
         (setf (buffer-data buffer) (make-static-vector (size buffer) :initial-element 0)))
        ((/= (size buffer) (length (buffer-data buffer)))
         (let ((old (buffer-data buffer))
               (new (make-static-vector (size buffer) :initial-element 0)))
           (setf (buffer-data buffer) (replace new old))
           (maybe-free-static-vector old)))))

(defmethod bind ((buffer uniform-buffer) (program shader-program) (binding-point integer))
  ;; Calculate size and offsets now.
  (unless (offsets buffer)
    (multiple-value-bind (offsets size) (compute-offsets buffer program)
      (setf (offsets buffer) offsets)
      (setf (size buffer) size)))
  ;; FIXME: at this point we could compile an optimised accessor for the fields
  ;;        that has the offsets and such rolled out so that there's no lookup
  ;;        costs beyond calling the function from a slot.
  ;;        The problem with this approach is the presence of arrays, as the index
  ;;        to access will very very likely not be constant...
  ;;        It should be possible to infer the stride between array bases and reduce
  ;;        the access functions to a number of multiplications and additions.
  ;; Allocate the buffer with the correct sizing information.
  (load buffer)
  ;; Bind the buffer to the program's specified binding point.
  (let ((index (gl:get-uniform-block-index (gl-name program) (gl-type buffer))))
    (%gl:uniform-block-binding (gl-name program) index binding-point)
    (%gl:bind-buffer-base :uniform-buffer binding-point (gl-name buffer))))

(defmethod buffer-field ((buffer uniform-buffer) field)
  (let ((offset (gethash field (offsets buffer)))
        (type :FIXME))
    #-elide-buffer-access-checks
    (unless offset
      (error "Field ~s not found in ~a." field buffer))
    (with-pointer-to-vector-data (ptr (buffer-data buffer))
      (gl-memref (cffi:inc-pointer ptr offset) type))))

(defmethod (setf buffer-field) (value (buffer uniform-buffer) field)
  ;; FIXME: wouldn't it be better to keep the C-memory block for the UBO around,
  ;;        write the values in there ourselves, and then call an update call
  ;;        instead of going through the slow, generic variants of buffer-object?
  (let ((offset (gethash field (offsets buffer))))
    #-elide-buffer-access-checks
    (unless offset
      (error "Field ~s not found in ~a." field buffer))
    (update-buffer-data buffer value :buffer-start offset)))
