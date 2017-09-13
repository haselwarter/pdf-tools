;;; pdf-tools.el --- Support library for PDF documents. -*- lexical-binding:t -*-

;; Copyright (C) 2013, 2014  Andreas Politz

;; Author: Andreas Politz <politza@fh-trier.de>
;; Keywords: files, multimedia
;; Package: pdf-tools
;; Version: 0.90
;; Package-Requires: ((emacs "24.3") (tablist "0.70") (let-alist "1.0.4"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; PDF Tools is, among other things, a replacement of DocView for PDF
;; files.  The key difference is, that pages are not prerendered by
;; e.g. ghostscript and stored in the file-system, but rather created
;; on-demand and stored in memory.
;;
;; Note: This package requires external libraries and works currently
;; only on GNU/Linux systems.
;;
;; Note: If you ever update it, you need to restart Emacs afterwards.
;;
;; To activate the package put
;;
;; (pdf-tools-install)
;;
;; somewhere in your .emacs.el .
;;
;; M-x pdf-tools-help RET
;;
;; gives some help on using the package and
;;
;; M-x pdf-tools-customize RET
;;
;; offers some customization options.

;; Features:
;;
;; * View
;;   View PDF documents in a buffer with DocView-like bindings.
;;
;; * Isearch
;;   Interactively search PDF documents like any other buffer. (Though
;;   there is currently no regexp support.)
;;
;; * Follow links
;;   Click on highlighted links, moving to some part of a different
;;   page, some external file, a website or any other URI.  Links may
;;   also be followed by keyboard commands.
;;
;; * Annotations
;;   Display and list text and markup annotations (like underline),
;;   edit their contents and attributes (e.g. color), move them around,
;;   delete them or create new ones and then save the modifications
;;   back to the PDF file.
;;
;; * Attachments
;;   Save files attached to the PDF-file or list them in a dired buffer.
;;
;; * Outline
;;   Use imenu or a special buffer to examine and navigate the PDF's
;;   outline.
;;
;; * SyncTeX
;;   Jump from a position on a page directly to the TeX source and
;;   vice-versa.
;;
;; * Misc
;;    + Display PDF's metadata.
;;    + Mark a region and kill the text from the PDF.
;;    + Search for occurrences of a string.
;;    + Keep track of visited pages via a history.

;;; Code:

(require 'pdf-view)
(require 'pdf-util)
(require 'pdf-info)
(require 'cus-edit)
(require 'compile)
(require 'cl-lib)
(require 'package)



;; * ================================================================== *
;; * Customizables
;; * ================================================================== *

(defgroup pdf-tools nil
  "Support library for PDF documents."
  :group 'doc-view)

(defgroup pdf-tools-faces nil
  "Faces determining the colors used in the pdf-tools package.

In order to customize dark and light colors use
`pdf-tools-customize-faces', or set `custom-face-default-form' to
'all."
  :group 'pdf-tools)

(defconst pdf-tools-modes
  '(pdf-history-minor-mode
    pdf-isearch-minor-mode
    pdf-links-minor-mode
    pdf-misc-minor-mode
    pdf-outline-minor-mode
    pdf-misc-size-indication-minor-mode
    pdf-misc-menu-bar-minor-mode
    pdf-annot-minor-mode
    pdf-sync-minor-mode
    pdf-misc-context-menu-minor-mode
    pdf-cache-prefetch-minor-mode
    pdf-view-auto-slice-minor-mode
    pdf-occur-global-minor-mode
    pdf-virtual-global-minor-mode))

(defcustom pdf-tools-enabled-modes
  '(pdf-history-minor-mode
    pdf-isearch-minor-mode
    pdf-links-minor-mode
    pdf-misc-minor-mode
    pdf-outline-minor-mode
    pdf-misc-size-indication-minor-mode
    pdf-misc-menu-bar-minor-mode
    pdf-annot-minor-mode
    pdf-sync-minor-mode
    pdf-misc-context-menu-minor-mode
    pdf-cache-prefetch-minor-mode
    pdf-occur-global-minor-mode
    ;; pdf-virtual-global-minor-mode
    )
  "A list of automatically enabled minor-modes.

PDF Tools is build as a series of minor-modes.  This variable and
the function `pdf-tools-install' merely serve as a convenient
wrapper in order to load these modes in current and newly created
PDF buffers."
  :group 'pdf-tools
  :type `(set ,@(mapcar (lambda (mode)
                          `(function-item ,mode))
                        pdf-tools-modes)))

(defcustom pdf-tools-enabled-hook nil
  "A hook ran after PDF Tools is enabled in a buffer."
  :group 'pdf-tools
  :type 'hook)

(defconst pdf-tools-auto-mode-alist-entry
  '("\\.[pP][dD][fF]\\'" . pdf-view-mode)
  "The entry to use for `auto-mode-alist'.")

(defun pdf-tools-customize ()
  "Customize Pdf Tools."
  (interactive)
  (customize-group 'pdf-tools))

(defun pdf-tools-customize-faces ()
  "Customize PDF Tool's faces."
  (interactive)
  (let ((buffer (format "*Customize Group: %s*"
                        (custom-unlispify-tag-name 'pdf-tools-faces))))
    (when (buffer-live-p (get-buffer buffer))
      (with-current-buffer (get-buffer buffer)
        (rename-uniquely)))
    (customize-group 'pdf-tools-faces)
    (with-current-buffer buffer
      (set (make-local-variable 'custom-face-default-form) 'all))))


;; * ================================================================== *
;; * Installation
;; * ================================================================== *

;;;###autoload
(defcustom pdf-tools-handle-upgrades t
  "Whether PDF Tools should handle upgrading itself."
  :group 'pdf-tools
  :type 'boolean)

(make-obsolete-variable 'pdf-tools-handle-upgrades
                        "Not used anymore" "0.90")

(defconst pdf-tools-directory
  (or (and load-file-name
           (file-name-directory load-file-name))
      default-directory)
  "The directory from where this library was first loaded.")

(defvar pdf-tools-msys2-directory nil)

(defun pdf-tools-identify-build-directory (directory)
  "Return non-nil, if DIRECTORY appears to contain the epdfinfo source.

Returns the expanded directory-name of DIRECTORY or nil."
  (setq directory (file-name-as-directory
                   (expand-file-name directory)))
  (and (file-exists-p (expand-file-name "autobuild" directory))
       (file-exists-p (expand-file-name "epdfinfo.c" directory))
       directory))

(defun pdf-tools-locate-build-directory ()
  "Attempt to locate a source directory.

Returns a appropriate directory or nil.  See also
`pdf-tools-identify-build-directory'."
  (cl-some #'pdf-tools-identify-build-directory
           (list default-directory
                 (expand-file-name "build/server" pdf-tools-directory)
                 (expand-file-name "server")
                 (expand-file-name "../server" pdf-tools-directory))))

(defun pdf-tools-msys2-directory (&optional noninteractive-p)
  "Locate the Msys2 installation directory.

Ask the user if necessary and NONINTERACTIVE-P is nil.
Returns always nil, unless `system-type' equals windows-nt."
  (cl-labels ((if-msys2-directory (directory)
                (and (stringp directory)
                     (file-directory-p directory)
                     (file-exists-p
                      (expand-file-name "usr/bin/bash.exe" directory))
                     directory)))
    (when (eq system-type 'windows-nt)
      (setq pdf-tools-msys2-directory
            (or pdf-tools-msys2-directory
                (cl-some #'if-msys2-directory
                         (cl-mapcan
                          (lambda (drive)
                            (list (format "%c:/msys64" drive)
                                  (format "%c:/msys32" drive)))
                          (number-sequence ?c ?z)))
                (unless (or noninteractive-p
                            (not (y-or-n-p "Do you have Msys2 installed ? ")))
                  (if-msys2-directory
                   (read-directory-name
                    "Please enter Msys2 installation directory: " nil nil t))))))))

(defun pdf-tools-find-bourne-shell ()
  "Locate a usable sh."
  (or (executable-find "sh")
      (and (eq system-type 'windows-nt)
           (let* ((directory (pdf-tools-msys2-directory)))
             (when directory
               (expand-file-name "usr/bin/bash.exe" directory))))))

(defun pdf-tools-build-server (&optional callback
                                         target-directory
                                         build-directory)
  "Build the epdfinfo program in the background.

If CALLBACK is non-nil, it should be a function.  It is called
with the compiled executable as the single argument or nil, if
the build falied.

Install into TARGET-DIRECTORY, which defaults to
~/bin (/ming$arch/bin on Msys2).

Expected sources to be in BUILD-DIRECTORY.  If nil, search for it
using `pdf-tools-locate-build-directory'.

Returns the buffer of the compilation process."

  (unless callback (setq callback #'ignore))
  (unless build-directory
    (setq build-directory (pdf-tools-locate-build-directory)))
  (when target-directory
    (setq target-directory (file-name-as-directory
                            (expand-file-name target-directory))))
  (cl-check-type build-directory (and (not null) file-directory))
  (let* ((compilation-auto-jump-to-first-error nil)
         (compilation-scroll-output t)
         (shell-file-name (pdf-tools-find-bourne-shell))
         (shell-command-switch "-c")
         (process-environment process-environment)
         (default-directory build-directory)
         (autobuild (shell-quote-argument
                     (expand-file-name "autobuild" build-directory)))
         (msys2-p (equal "bash.exe" (file-name-nondirectory shell-file-name))))
    (unless shell-file-name
      (error "No suitable shell found"))
    (when msys2-p
      (push "BASH_ENV=/etc/profile" process-environment))
    (unless target-directory
      (when (eq 0 (call-process-shell-command
                   (concat autobuild " -n") nil t))
        (setq target-directory (buffer-substring
                                (point-min) (1- (point-max))))
        (when msys2-p
          (setq target-directory
                (expand-file-name
                 (concat "." target-directory)
                 (pdf-tools-msys2-directory))))))
    (let ((executable
           (expand-file-name
            (concat "epdfinfo" (and (eq system-type 'windows-nt) ".exe"))
            target-directory))
          (compilation-buffer
           (compilation-start
            (format "%s -i %s"
                    autobuild
                    (shell-quote-argument target-directory))
            t)))
      ;; In most cases user-input is required, so select the window.
      (if (get-buffer-window compilation-buffer)
          (select-window (get-buffer-window compilation-buffer))
        (pop-to-buffer compilation-buffer))
      (with-current-buffer compilation-buffer
        (setq-local compilation-error-regexp-alist nil)
        (add-hook 'compilation-finish-functions
                  (lambda (&rest _)
                    (funcall callback
                             (and (file-exists-p executable)
                                  executable)))
                  nil t)
        (current-buffer)))))

(defun pdf-tools-read-target-directory ()
  "Read a directory for the epdfinfo executable."
  ;;  On MS-Windows always install into the default directory
  ;;  (/mingw*/bin).
  (unless (pdf-tools-msys2-directory)
    (read-directory-name
     "Installation directory: "
     (cond
      ((and (stringp pdf-info-epdfinfo-program)
            (not (file-in-directory-p
                  pdf-info-epdfinfo-program
                  package-user-dir)))
       (file-name-directory pdf-info-epdfinfo-program))
      (t (expand-file-name "~/bin"))))))


;; * ================================================================== *
;; * Initialization
;; * ================================================================== *

;;;###autoload
(defun pdf-tools-install (&rest _)
  "Install PDF-Tools in all current and future PDF buffers.

If the `pdf-info-epdfinfo-program' is not running and is not
executable or does not appear to be working, attempt to rebuild
it.  If this build succeeded, continue with the activation of the
package.  Otherwise fail silently, i.e. no error is signaled.

See `pdf-view-mode' and `pdf-tools-enabled-modes'."
  (declare
   (advertised-calling-convention () "0.90"))
  (interactive)
  (if (or noninteractive
          (pdf-info-running-p)
          (and (stringp pdf-info-epdfinfo-program)
               (file-executable-p pdf-info-epdfinfo-program)
               (ignore-errors (pdf-info-check-epdfinfo) :success)))
      (pdf-tools-install-noverify)
    (when (y-or-n-p "Need to build the PDF Tools server, do it now ? ")
      (pdf-tools-build-server
       (lambda (executable)
         (message "Building the PDF Tools server %s"
                  (if executable "succeeded" "failed"))
         (when executable
           (setq pdf-info-epdfinfo-program executable)
           (unless (file-equal-p pdf-info-epdfinfo-program executable)
             (customize-save-variable 'pdf-info-epdfinfo-program
                                      executable))
           (let ((pdf-info-restart-process-p t))
             (pdf-tools-install-noverify))))
       (pdf-tools-read-target-directory)))))

(defun pdf-tools-install-noverify ()
  "Like `pdf-tools-install', but skip checking `pdf-info-epdfinfo-program'."
  (add-to-list 'auto-mode-alist pdf-tools-auto-mode-alist-entry)
  ;; FIXME: Generalize this sometime.
  (when (memq 'pdf-occur-global-minor-mode
              pdf-tools-enabled-modes)
    (pdf-occur-global-minor-mode 1))
  (when (memq 'pdf-virtual-global-minor-mode
              pdf-tools-enabled-modes)
    (pdf-virtual-global-minor-mode 1))
  (add-hook 'pdf-view-mode-hook 'pdf-tools-enable-minor-modes)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (not (derived-mode-p 'pdf-view-mode))
                 (pdf-tools-pdf-buffer-p)
                 (buffer-file-name))
        (pdf-view-mode)))))

(defun pdf-tools-uninstall ()
  "Uninstall PDF-Tools in all current and future PDF buffers."
  (interactive)
  (pdf-info-quit)
  (setq-default auto-mode-alist
    (remove pdf-tools-auto-mode-alist-entry auto-mode-alist))
  (pdf-occur-global-minor-mode -1)
  (pdf-virtual-global-minor-mode -1)
  (remove-hook 'pdf-view-mode-hook 'pdf-tools-enable-minor-modes)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (pdf-util-pdf-buffer-p buf)
        (pdf-tools-disable-minor-modes pdf-tools-modes)
        (normal-mode)))))

(defun pdf-tools-pdf-buffer-p (&optional buffer)
  "Return non-nil if BUFFER contains a PDF document."
  (save-current-buffer
    (when buffer (set-buffer buffer))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char 1)
        (looking-at "%PDF")))))

(defun pdf-tools-assert-pdf-buffer (&optional buffer)
  (unless (pdf-tools-pdf-buffer-p buffer)
    (error "Buffer does not contain a PDF document")))

(defun pdf-tools-set-modes-enabled (enable &optional modes)
  (dolist (m (or modes pdf-tools-enabled-modes))
    (let ((enabled-p (and (boundp m)
                          (symbol-value m))))
      (unless (or (and enabled-p enable)
                  (and (not enabled-p) (not enable)))
        (funcall m (if enable 1 -1))))))

;;;###autoload
(defun pdf-tools-enable-minor-modes (&optional modes)
  "Enable MODES in the current buffer.

MODES defaults to `pdf-tools-enabled-modes'."
  (interactive)
  (pdf-util-assert-pdf-buffer)
  (pdf-tools-set-modes-enabled t modes)
  (run-hooks 'pdf-tools-enabled-hook))

(defun pdf-tools-disable-minor-modes (&optional modes)
  "Disable MODES in the current buffer.

MODES defaults to `pdf-tools-enabled-modes'."
  (interactive)
  (pdf-tools-set-modes-enabled nil modes))

(declare-function pdf-occur-global-minor-mode "pdf-occur.el")
(declare-function pdf-virtual-global-minor-mode "pdf-virtual.el")

;;;###autoload
(defun pdf-tools-help ()
  (interactive)
  (help-setup-xref (list #'pdf-tools-help)
                   (called-interactively-p 'interactive))
  (with-help-window (help-buffer)
    (princ "PDF Tools Help\n\n")
    (princ "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n")
    (dolist (m (cons 'pdf-view-mode
                     (sort (copy-sequence pdf-tools-modes) 'string<)))
      (princ (format "`%s' is " m))
      (describe-function-1 m)
      (terpri) (terpri)
      (princ "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n"))))


;; * ================================================================== *
;; * Debugging
;; * ================================================================== *

(defvar pdf-tools-debug nil
  "Non-nil, if debugging PDF Tools.")

(defun pdf-tools-toggle-debug ()
  (interactive)
  (setq pdf-tools-debug (not pdf-tools-debug))
  (when (called-interactively-p 'any)
    (message "Toggled debugging %s" (if pdf-tools-debug "on" "off"))))

(provide 'pdf-tools)

;;; pdf-tools.el ends here
