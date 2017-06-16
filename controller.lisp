#|
 This file is a part of trial
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)

(define-action system-action ())

(define-action save-game (system-action)
  (key-press (eql key :f2)))

(define-action load-game (system-action)
  (key-press (eql key :f3)))

(define-action reload-assets (system-action)
  (key-press (eql key :f5)))

(define-action reload-scene (system-action)
  (key-press (eql key :f6)))

(define-action quit-game (system-action)
  (key-press (and (eql key :q) (find :control modifiers))))

(define-subject controller ()
  ((display :initform NIL :accessor display))
  (:default-initargs
   :name :controller))

(define-handler (controller quit-game) (ev)
  (quit *context*))

(define-handler (controller resize) (ev width height)
  (let ((pipeline (pipeline (display controller))))
    (when pipeline (resize pipeline width height))))

(define-handler (controller mapping T 100) (ev)
  (map-event ev *loop*)
  (retain-event ev))

(define-handler (controller reload-assets reload-assets 99) (ev)
  (loop for asset being the hash-keys of (assets *context*)
        do (load (offload asset))))

;; FIXME: make these safer by loading a copy or something
;;        to ensure that if the reload fails we can fall back
;;        to the previous state.
(define-handler (controller reload-scene reload-scene 99) (ev)
  (loop for asset being the hash-keys of (assets *context*)
        do (offload asset))
  (clear (scene (display controller)))
  (clear (pipeline (display controller)))
  (setup-scene (display controller)))

(define-handler (controller load-request) (ev asset action)
  (ecase action
    (offload (offload asset))
    (load    (load asset))
    (reload  (reload asset))))

(defun maybe-reload-scene (&optional (window (or (window :main) (when *context* (handler *context*)))))
  (when window
    (issue (scene window) 'reload-scene)))
