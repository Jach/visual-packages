(defpackage #:com.thejach.visual-packages
  (:use #:cl)
  (:export #:main))
(in-package #:com.thejach.visual-packages)

(defun file (name)
  (namestring (asdf:system-relative-pathname "visual-packages" name)))

(defparameter *auto-refresh-timer* nil)
(defparameter *auto-refresh-enabled* t)

(defun create-package-tree-model ()
  ;; Creates GtkTreeStore with columns:
  ;; 0: name (string)
  ;; 1: weight (int) - bold for packages, normal for nicknames
  ;; 2: type (string) - "Package" or "Nickname"
  ;; 3: style (int) - normal or italic
  (let ((store (make-instance 'gtk:tree-store
                              :column-types '("gchararray" "gint" "gchararray" "gint"))))
    store))



(defun populate-packages (tree-store)
  (gtk:tree-store-clear tree-store)
  (let ((packages (sort (mapcar #'package-name (list-all-packages)) #'string<)))
    (dolist (pkg-name packages)
      (let* ((pkg (find-package pkg-name))
             (iter (gtk:tree-store-append tree-store nil)))
        ;; Try setting one column at a time
        (gtk:tree-store-set-value tree-store iter 0 pkg-name)
        (gtk:tree-store-set-value tree-store iter 1 700)
        (gtk:tree-store-set-value tree-store iter 2 "Package")
        (gtk:tree-store-set-value tree-store iter 3 0)

        ;; Add nickname rows (only if there are any)
        (when (package-nicknames pkg)
          (dolist (nickname (package-nicknames pkg))
            (let ((child-iter (gtk:tree-store-append tree-store iter)))
              (gtk:tree-store-set-value tree-store child-iter 0 nickname)
              (gtk:tree-store-set-value tree-store child-iter 1 400)
              (gtk:tree-store-set-value tree-store child-iter 2 "Nickname")
              (gtk:tree-store-set-value tree-store child-iter 3 2))))))))

(defun get-expanded-paths (tree-view)
  "Get a list of all currently expanded tree paths"
  (let ((expanded-paths '()))
    (gtk:tree-view-map-expanded-rows
     tree-view
     (lambda (tree-view path)
       (declare (ignore tree-view))
       (push (gtk:tree-path-to-string path) expanded-paths)))
    expanded-paths))

(defun restore-expanded-paths (tree-view expanded-paths)
  "Restore the expanded state for the given paths"
  (dolist (path-string expanded-paths)
    (let ((path (gtk:tree-path-new-from-string path-string)))
      (gtk:tree-view-expand-row tree-view path nil))))


(defun get-expanded-package-names (tree-view)
  "Get a list of expanded package names"
  (let ((expanded-packages '())
        (model (gtk:tree-view-model tree-view)))
    (gtk:tree-view-map-expanded-rows
     tree-view
     (lambda (tree-view path)
       (declare (ignore tree-view))
       (let ((iter (gtk:tree-model-iter model path)))
         (when iter
           (let ((pkg-name (gtk:tree-model-value model iter 0))
                 (pkg-type (gtk:tree-model-value model iter 2)))
             (when (string= pkg-type "Package")
               (push pkg-name expanded-packages)))))))
    expanded-packages))



(defun get-selected-item-name (tree-view)
  "Get the name of the currently selected item (package or nickname)"
  (let ((selection (gtk:tree-view-selection tree-view))
        (model (gtk:tree-view-model tree-view)))
    (let ((iter (gtk:tree-selection-selected selection)))  ; iter is the direct return value
      (when iter
        (handler-case
          (let ((item-name (gtk:tree-model-value model iter 0))
                (item-type (gtk:tree-model-value model iter 2)))
            (list item-name item-type))
          (error (e)
            (format t "Error getting selection values: ~A~%" e)
            nil))))))

(defun restore-expanded-package-names (tree-view expanded-package-names)
  "Restore expansion state by package name"
  (let ((model (gtk:tree-view-model tree-view)))
    (dolist (pkg-name expanded-package-names)
      (gtk:tree-model-foreach
       model
       (lambda (model path iter)
         (declare (ignore path))
         (let ((current-name (gtk:tree-model-value model iter 0))
               (current-type (gtk:tree-model-value model iter 2)))
           (when (and (string= current-name pkg-name)
                      (string= current-type "Package"))
             (let ((tree-path (gtk:tree-model-path model iter)))
               (gtk:tree-view-expand-row tree-view tree-path nil))
             t))))))) ; return t to stop foreach

(defun restore-selected-item (tree-view selected-item)
  "Restore selection state by item name and type"
  (when selected-item
    (let ((model (gtk:tree-view-model tree-view))
          (selection (gtk:tree-view-selection tree-view))
          (target-name (first selected-item))
          (target-type (second selected-item)))
      (gtk:tree-model-foreach
       model
       (lambda (model path iter)
         (declare (ignore path))
         (let ((current-name (gtk:tree-model-value model iter 0))
               (current-type (gtk:tree-model-value model iter 2)))
           (when (and (string= current-name target-name)
                      (string= current-type target-type))
             (gtk:tree-selection-select-iter selection iter)
             t))))))) ; return t to stop foreach

(defun refresh-package-list-old (tree-view status-label package-count)
  "Refresh the package list and update status, preserving all UI state

   (trashes the whole tree, causes scrolling issues)"
  (let ((model (gtk:tree-view-model tree-view))
        (expanded-packages (get-expanded-package-names tree-view))
        (selected-item (get-selected-item-name tree-view)))

    ;; Refresh the data
    (populate-packages model)

    ;; Restore expansion and selection immediately
    (restore-expanded-package-names tree-view expanded-packages)
    (restore-selected-item tree-view selected-item)

    ;; Update status
    (let ((count (length (list-all-packages))))
      (setf (gtk:label-text status-label)
            (format nil "Last refreshed: ~A" (format-timestamp (get-universal-time))))
      (setf (gtk:label-text package-count)
            (format nil "~D packages" count)))))

(defparameter *package-timestamps* (make-hash-table :test 'equal)
  "Hash table tracking when each package was first seen")

(defun get-package-timestamp (pkg-name)
  "Get timestamp for when package was first seen, or current time if new"
  (or (gethash pkg-name *package-timestamps*)
      (setf (gethash pkg-name *package-timestamps*) (get-universal-time))))

(defun find-insertion-position (tree-store pkg-name)
  "Find the correct position to insert a package to maintain alphabetical order"
  (let ((insert-position nil)
        (model tree-store))
    (gtk:tree-model-foreach
     model
     (lambda (model path iter)
       (declare (ignore path))
       (let ((existing-name (gtk:tree-model-value model iter 0))
             (existing-type (gtk:tree-model-value model iter 2)))
         (when (string= existing-type "Package")
           (when (and (not insert-position)
                      (string< pkg-name existing-name))
             (setf insert-position iter)
             t))))) ; return t to stop iteration when found
    insert-position))

(defun insert-package-sorted (tree-store pkg-name)
  "Insert a package at the correct alphabetical position"
  (let* ((pkg (find-package pkg-name))
         (insert-before (find-insertion-position tree-store pkg-name))
         (iter (if insert-before
                   (gtk:tree-store-insert-before tree-store nil insert-before)
                   (gtk:tree-store-append tree-store nil))))

    ;; Record when we first saw this package
    (get-package-timestamp pkg-name)

    ;; Set package data
    (gtk:tree-store-set-value tree-store iter 0 pkg-name)
    (gtk:tree-store-set-value tree-store iter 1 700)
    (gtk:tree-store-set-value tree-store iter 2 "Package")
    (gtk:tree-store-set-value tree-store iter 3 0)

    ;; Add nickname rows (only if there are any)
    (when (package-nicknames pkg)
      (dolist (nickname (package-nicknames pkg))
        (let ((child-iter (gtk:tree-store-append tree-store iter)))
          (gtk:tree-store-set-value tree-store child-iter 0 nickname)
          (gtk:tree-store-set-value tree-store child-iter 1 400)
          (gtk:tree-store-set-value tree-store child-iter 2 "Nickname")
          (gtk:tree-store-set-value tree-store child-iter 3 2))))

    iter))

(defun update-packages-in-place (tree-store)
  "Update the tree store by modifying existing entries instead of clearing"
  (let ((current-packages (sort (mapcar #'package-name (list-all-packages)) #'string<))
        (existing-tree-items '())
        (model tree-store))

    ;; First pass: collect all existing items with their iters
    (gtk:tree-model-foreach
     model
     (lambda (model path iter)
       (declare (ignore path))
       (let ((pkg-name (gtk:tree-model-value model iter 0))
             (pkg-type (gtk:tree-model-value model iter 2)))
         (push (list iter pkg-name pkg-type) existing-tree-items))
       nil))

    ;; Separate packages from nicknames
    (let ((existing-packages (remove-if-not (lambda (item) (string= (third item) "Package"))
                                           existing-tree-items)))

      ;; Find packages to add and remove
      (let ((existing-pkg-names (mapcar #'second existing-packages))
            (packages-to-remove '())
            (packages-to-add '()))

        ;; Find packages that no longer exist
        (dolist (existing-item existing-packages)
          (unless (member (second existing-item) current-packages :test #'string=)
            (push existing-item packages-to-remove)))

        ;; Find new packages
        (dolist (pkg-name current-packages)
          (unless (member pkg-name existing-pkg-names :test #'string=)
            (push pkg-name packages-to-add)))

        ;; Remove obsolete packages (and their nicknames)
        (dolist (pkg-item packages-to-remove)
          (let ((pkg-iter (first pkg-item))
                (pkg-name (second pkg-item)))
            ;; Remove timestamp tracking
            (remhash pkg-name *package-timestamps*)
            ;; Remove all children (nicknames) first
            (loop
              (let ((child-iter (gtk:tree-model-iter-children model pkg-iter)))
                (if child-iter
                    (gtk:tree-store-remove tree-store child-iter)
                    (return))))
            ;; Remove the package itself
            (gtk:tree-store-remove tree-store pkg-iter)))

        ;; Add new packages in sorted order
        (dolist (pkg-name packages-to-add)
          (insert-package-sorted tree-store pkg-name))

        ;; Update nicknames for existing packages
        (dolist (pkg-item existing-packages)
          (let ((pkg-iter (first pkg-item))
                (pkg-name (second pkg-item))
                (pkg (find-package (second pkg-item))))
            (declare (ignore pkg-name))

            ;; Remove existing nicknames
            (loop
              (let ((child-iter (gtk:tree-model-iter-children model pkg-iter)))
                (if child-iter
                    (gtk:tree-store-remove tree-store child-iter)
                    (return))))

            ;; Add current nicknames
            (when (package-nicknames pkg)
              (dolist (nickname (package-nicknames pkg))
                (let ((child-iter (gtk:tree-store-append tree-store pkg-iter)))
                  (gtk:tree-store-set-value tree-store child-iter 0 nickname)
                  (gtk:tree-store-set-value tree-store child-iter 1 400)
                  (gtk:tree-store-set-value tree-store child-iter 2 "Nickname")
                  (gtk:tree-store-set-value tree-store child-iter 3 2))))))))))

;; Utility functions for future sorting options
(defun get-package-first-seen-time (pkg-name)
  "Get human-readable time when package was first seen"
  (let ((timestamp (gethash pkg-name *package-timestamps*)))
    (if timestamp
        (multiple-value-bind (sec min hour date month year)
            (decode-universal-time timestamp)
          (format nil "~D/~2,'0D/~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                  year month date hour min sec))
        "Unknown")))

(defun reset-package-timestamps ()
  "Clear all package timestamp tracking (useful for development)"
  (clrhash *package-timestamps*))



(defun refresh-package-list (tree-view status-label package-count)
  "Refresh the package list using in-place updates to preserve scroll position"
  (let ((model (gtk:tree-view-model tree-view))
        (expanded-packages (get-expanded-package-names tree-view))
        (selected-item (get-selected-item-name tree-view)))

    ;; Update in place instead of clearing
    (update-packages-in-place model)

    ;; Restore states
    (restore-expanded-package-names tree-view expanded-packages)
    (restore-selected-item tree-view selected-item)

    ;; Update status
    (let ((count (length (list-all-packages))))
      (setf (gtk:label-text status-label)
            (format nil "Last refreshed: ~A" (format-timestamp (get-universal-time))))
      (setf (gtk:label-text package-count)
            (format nil "~D packages" count)))))


(defun format-timestamp (universal-time)
  "Format universal time as a readable timestamp"
  (multiple-value-bind (sec min hour *** ** *)
      (decode-universal-time universal-time)
    (format nil "~2,'0D:~2,'0D:~2,'0D" hour min sec)))

(defun setup-auto-refresh (tree-view status-label package-count refresh-interval-spin)
  "Setup automatic refresh timer"
  (when *auto-refresh-timer*
    (g:source-remove *auto-refresh-timer*))

  (when *auto-refresh-enabled*
    (let ((interval (* 1000 (gtk:spin-button-value-as-int refresh-interval-spin))))
      (setf *auto-refresh-timer*
            (g:timeout-add interval
                          (lambda ()
                            (refresh-package-list tree-view status-label package-count)
                            t)))))) ; return t to keep timer running

(defun on-refresh-button-clicked (button tree-view status-label package-count)
  "Manual refresh button handler"
  (declare (ignore button))
  (refresh-package-list tree-view status-label package-count))

(defun on-toggle-auto-refresh (button tree-view status-label package-count refresh-interval-spin)
  "Toggle auto refresh on/off"
  (setf *auto-refresh-enabled* (not *auto-refresh-enabled*))
  (setf (gtk:button-label button)
        (if *auto-refresh-enabled* "Auto Refresh: ON" "Auto Refresh: OFF"))
  (setup-auto-refresh tree-view status-label package-count refresh-interval-spin))

(defun on-refresh-interval-changed (spin-button tree-view status-label package-count)
  "Handler when refresh interval changes"
  (setup-auto-refresh tree-view status-label package-count spin-button))

(defun pb-activate-callback (application)
  (let ((builder (make-instance 'gtk:builder)))
    (gtk:builder-add-from-file builder (file "ui/package-browser.ui"))

    (let ((window (gtk:builder-object builder "main_window"))
          (package-tree (gtk:builder-object builder "package_tree"))
          (refresh-button (gtk:builder-object builder "refresh_button"))
          (toggle-auto-refresh (gtk:builder-object builder "toggle_auto_refresh"))
          (refresh-interval (gtk:builder-object builder "refresh_interval"))
          (status-label (gtk:builder-object builder "status_label"))
          (package-count (gtk:builder-object builder "package_count")))

      ;; Create and set the tree model
      (let ((model (create-package-tree-model)))
        (setf (gtk:tree-view-model package-tree) model)

        ;; Initial population
        (populate-packages model)

        ;; Update initial counts
        (let ((count (length (list-all-packages))))
          (setf (gtk:label-text status-label) "Ready")
          (setf (gtk:label-text package-count)
                (format nil "~D packages" count)))

        ;; Connect signals
        (g:signal-connect refresh-button "clicked"
                         (lambda (btn)
                           (on-refresh-button-clicked btn package-tree status-label package-count)))

        (g:signal-connect toggle-auto-refresh "clicked"
                         (lambda (btn)
                           (on-toggle-auto-refresh btn package-tree status-label package-count refresh-interval)))

        (g:signal-connect refresh-interval "value-changed"
                         (lambda (spin)
                           (on-refresh-interval-changed spin package-tree status-label package-count)))

        ;; Setup initial auto-refresh
        (setup-auto-refresh package-tree status-label package-count refresh-interval)

        ;; Associate window with application and show
        (setf (gtk:window-application window) application)
        (gtk:window-present window)))))

(defun pb-main ()
  (let ((app (make-instance 'gtk:application
                            :application-id (format nil "com.example.package-browser~a" (get-universal-time))
                            :flags :default-flags)))

    ;; Connect the activate signal
    (g:signal-connect app "activate" #'pb-activate-callback)

    ;; Run the application
    (g:application-run app nil)))

;; Cleanup function to stop timer when exiting
(defun cleanup ()
  (when *auto-refresh-timer*
    (g:source-remove *auto-refresh-timer*)
    (setf *auto-refresh-timer* nil)))

(defun main ()
  (bt:make-thread (lambda ()
                    (pb-main))))
