(in-package :cl-user)
(defpackage fast-http.body-buffer
  (:use :cl
        :xsubseq
        :fast-http.error)
  (:export :*default-memory-limit*
           :*default-disk-limit*
           :make-body-buffer
           :buffer-memory-limit
           :buffer-disk-limit
           :buffer-on-memory-p
           :write-to-buffer
           :finalize-buffer
           :body-buffer-limit-exceeded))
(in-package :fast-http.body-buffer)

(defvar *default-memory-limit* (expt 2 20))
(defvar *default-disk-limit* (expt 2 30))

(defstruct (body-buffer (:conc-name :buffer-)
                        (:constructor %make-body-buffer))
  (memory-limit *default-memory-limit*)
  (disk-limit *default-disk-limit*)
  (current-len 0)
  (on-memory-p t)
  (memory-buffer (make-concatenated-xsubseqs))
  (disk-buffer nil))

(defun make-body-buffer (&rest initargs &key memory-limit disk-limit &allow-other-keys)
  (let ((buffer (apply #'%make-body-buffer initargs)))
    (when (and memory-limit
               disk-limit
               (< disk-limit memory-limit))
      (setf (buffer-memory-limit buffer) disk-limit))
    buffer))

(define-condition body-buffer-limit-exceeded (fast-http-error)
  ((limit :initarg limit
          :initform nil))
  (:report (lambda (condition stream)
             (format stream "Body buffer exceeded the limit~:[~;~:* ~A~]"
                     (slot-value condition 'disk-limit)))))

(defun write-to-buffer (buffer seq &optional (start 0) (end (length seq)))
  (incf (buffer-current-len buffer) (- end start))
  (check-limit buffer)
  (if (buffer-on-memory-p buffer)
      (xnconcf (buffer-memory-buffer buffer) (xsubseq seq start end))
      (with-open-file (out (buffer-disk-buffer buffer)
                           :direction :output
                           :element-type '(unsigned-byte 8)
                           :if-exists :append)
        (write-sequence seq out :start start :end end))))

(defun check-limit (buffer)
  (cond
    ((and (buffer-on-memory-p buffer)
          (< (buffer-memory-limit buffer)
             (buffer-current-len buffer)))
     (setf (buffer-disk-buffer buffer)
           (uiop:with-temporary-file (:stream stream :pathname tmp :direction :output :element-type '(unsigned-byte 8) :keep t)
             (typecase (buffer-memory-buffer buffer)
               (null-concatenated-xsubseqs)
               (T (write-sequence (coerce-to-sequence (buffer-memory-buffer buffer)) stream)))
             tmp)
           (buffer-on-memory-p buffer) nil
           (buffer-memory-buffer buffer) nil))
    ((and (not (buffer-on-memory-p buffer))
          (< (buffer-disk-limit buffer)
             (buffer-current-len buffer)))
     (error 'body-buffer-limit-exceeded))))

(defun finalize-buffer (buffer)
  (if (buffer-on-memory-p buffer)
      (flex:make-in-memory-input-stream
       (typecase (buffer-memory-buffer buffer)
         (null-concatenated-xsubseqs #())
         (T (coerce-to-sequence (buffer-memory-buffer buffer)))))
      (open (buffer-disk-buffer buffer) :direction :input :element-type '(unsigned-byte 8))))
