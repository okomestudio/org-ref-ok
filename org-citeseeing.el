;;; org-citeseeing.el --- Render Org Citation  -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Taro Sato
;;
;; Author: Taro Sato <okomestudio@gmail.com>
;; URL: https://github.com/okomestudio/org-citeseeing/org-citeseeing.el
;; Version: 0.1.1
;; Keywords: convenience
;; Package-Requires: ((emacs "30.1") (compat "31.0.0.1))
;;
;;; License:
;;
;; This program is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation, either version 3 of the License, or (at your option) any later
;; version.
;;
;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
;; details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this program. If not, see <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; The `org-citeseeing' provides a minor mode to render citations according to
;; CSL using `citeproc'.
;;
;;; Code:

(require 'compat)
(require 'citeproc)
(require 'org)
(require 's)
(require 'seq)

(defvar org-citeseeing-csl--styles-dir nil)
(defvar org-citeseeing-csl--locales-dir nil)
(defvar org-citeseeing--cite-commands nil)
(defvar org-citeseeing--citeproc-modes
  '( author-only bib-entry locator-only nil suppress-author
     textual title-only year-only ))

(defgroup org-citeseeing nil
  "Customization group for `org-citeseeing'."
  :group 'faces
  :prefix "org-citeseeing-")

(defcustom org-citeseeing-debug nil
  "Set non-nil for verbose debug messages."
  :type 'boolean
  :group 'org-citeseeing)

(defcustom org-citeseeing-bibliography nil
  "Bibliography files to watch."
  :type '(choice
          (repeat :tag "Literal list of files" file)
          (function :tag "Function returning file list")
          (variable :tag "Variable holding file list"))
  :group 'org-citeseeing)

(defcustom org-citeseeing-bib-item-value-getter nil
  "A function that takes in a field name and a citekey as arguments.
It should return the field value from the record with given citekey."
  :type 'function
  :group 'org-citeseeing)

(defcustom org-citeseeing-bib-item-locale-getter nil
  "A function that takes in a citekey as an argument and returns the locale
string (e.g., 'en-US', 'ja-JP')."
  :type 'function
  :group 'org-citeseeing)

(defcustom org-citeseeing-bib-item-locale-default "en-US"
  "Default locale to use when not found in bibliography items."
  :type 'string
  :group 'org-citeseeing)

(defcustom org-citeseeing-csl-dir
  "/usr/share/citation-style-language"
  "The CSL directory path.
The subdirectories 'styles' (for style files) and 'locales' (for locale files)
should exist under this directory."
  :type 'directory
  :set (lambda (sym val)
         (set-default sym val)
         (setq-default org-citeseeing-csl--styles-dir
                       (file-name-concat val "styles")
                       org-citeseeing-csl--locales-dir
                       (file-name-concat val "locales")))
  :group 'org-citeseeing)

(defcustom org-citeseeing-csl-style
  "chicago-note-bibliography.csl"
  "A function or a filesystem path to a CSL style file.
A function should take two arguments, a command (e.g., 'cite') and a
locale (e.g., 'en-US'), returning a CSL style file path.

Unless the file path is absolute, it will be sought in `org-citeseeing-csl--styles-dir'."
  :type '(choice
          (function :tag "Function returning CSL style file")
          (file :tag "Path to CSL style file"))
  :group 'org-citeseeing)

(defcustom org-citeseeing-command-alist
  '((("cite" "Cite" "parencite" "Parencite") . "${cp:nil}")
    (("citeauthor" "citeauthor*") . "${cp:author-only}")
    (("citetitle" "citetitle*" "citeurl") . "${cp:title-only}")
    (("citeyear" "citeyear*") . "${cp:year-only}")
    ("fullcite" . "${cp:bib-entry}"))
  "Alist mapping of cite command(s) to `s-string' formatter.
The field name starting with 'cp:' refers to a `citeproc' mode (see
`org-citeseeing--citeproc-modes' for all available modes). A non-mode field referes to that of
current bibliography item, its value obtained via `org-citeseeing-bib-item-value-getter'."
  :type '(alist :key-type (choice (string :tag "Single command")
                                  (repeat :tag "List of commands" string))
                :value-type (string :tag "Format template"))
  :set
  (lambda (sym val)
    (set-default sym val)

    ;; Ensure `org-citeseeing--cite-commands' is an empty hash table:
    (if (and org-citeseeing--cite-commands
             (hash-table-p org-citeseeing--cite-commands))
        (clrhash org-citeseeing--cite-commands)
      (setq-default org-citeseeing--cite-commands
                    (make-hash-table :test #'equal)))

    (pcase-dolist (`(,commands . ,fmt) val)
      (dolist (command (or (and (stringp commands) (list commands))
                           commands))
        (let ((modes
               (mapcar #'intern
                       (seq-keep
                        (lambda (item)
                          (let ((field (cadr item)))
                            (and (string-prefix-p "cp:" field)
                                 (substring field 3))))
                        (s-match-strings-all "\\${\\([^}]+\\)}" fmt)))))
          (puthash command (list modes fmt) org-citeseeing--cite-commands)))))
  :group 'org-citeseeing)

(defcustom org-citeseeing-cache-eviction-registry
  '(citar-cache--update-bibliography
    bibtex-completion-clear-cache)
  "Function registry for adding after-advise for cache eviction.
The cache eviction is necessary to keep bibliography in sync with the
bibliography manager you are using (e.g., `bibtex-completion' or `citar'."
  :type '(repeat :tag "List of functions to add cache eviction" function))

(defface org-citeseeing-cite-face '((t :inherit org-cite))
  "Face used for citation.")

(defface org-citeseeing-cite-error-face '((t :inherit org-warning))
  "Face used for citation when error occurs while rendering.")

;;;###autoload
(define-minor-mode org-citeseeing-mode
  "Minor mode for org-citeseeing support."
  :lighter " OCs"
  :group 'org-citeseeing
  (if org-citeseeing-mode
      (org-citeseeing-mode--on)
    (org-citeseeing-mode--off)))

(defun org-citeseeing-mode--on ()
  "Activate `org-citeseeing-mode'."
  (dolist (fun org-citeseeing-cache-eviction-registry)
    (when (and (boundp fun)
               (functionp fun))
      (advice-add fun :after #'org-citeseeing--cache-clear)))
  (advice-add #'org-activate-links :around #'org-citeseeing--activate-links-ad)
  ;; Ensure font-lock natively tracks and cleans up the 'display property when
  ;; redrawing:
  (make-local-variable 'font-lock-extra-managed-props)
  (add-to-list 'font-lock-extra-managed-props 'display)
  (when (derived-mode-p 'org-mode)
    (org-restart-font-lock)))

(defun org-citeseeing-mode--off ()
  "Deactivate `org-citeseeing-mode'."
  (advice-remove #'org-activate-links #'org-citeseeing--activate-links-ad)
  (setq font-lock-extra-managed-props
        (remove 'display font-lock-extra-managed-props))
  (when (derived-mode-p 'org-mode)
    (org-restart-font-lock))
  (dolist (fun org-citeseeing-cache-eviction-registry)
    (when (and (boundp fun) (functionp fun))
      (advice-remove fun #'org-citeseeing--cache-clear))))

(defun org-citeseeing--activate-links-ad (fun _limit)
  "Around-advice wrapper for FUN (`org-activate-links').
Intercepts font-lock execution to inject dynamic display strings."
  (let* ((start-pos (point))
         (retval (funcall fun _limit)))
    (when org-link-descriptive
      (catch :exit
        (save-excursion
          (goto-char start-pos)
          (while (re-search-forward "\\[\\[\\([^]]+\\)\\]\\]" _limit t)
            (when-let* ((beg (match-beginning 0))
                        (end (match-end 0))
                        (lnk (match-string 1))
                        (txt (org-citeseeing-links-generator lnk)))
              (put-text-property beg end 'display txt)
              (throw :exit t))))))
    retval))

(defun org-citeseeing--cache-clear (&rest _args)
  "Reset item getter."
  (interactive)               ; add for debug convenience
  (setq org-citeseeing--citeproc-itemgetter--cache nil
        org-citeseeing--citeproc-proc--cache nil))

(defun org-citeseeing-bibliography ()
  "Get bibliography files based on custom variable `org-citeseeing-bibliography'."
  (or (and (listp org-citeseeing-bibliography)
           org-citeseeing-bibliography)
      (and (functionp org-citeseeing-bibliography)
           (apply org-citeseeing-bibliography))
      (and (symbolp org-citeseeing-bibliography)
           (symbol-value org-citeseeing-bibliography))))

(defun org-citeseeing--citeproc-csl-style (command locale)
  "Get CSL style file path for COMMAND in LOCALE."
  (if-let* ((path (expand-file-name
                   (cond
                    ((functionp org-citeseeing-csl-style)
                     (funcall org-citeseeing-csl-style command locale))
                    (t org-citeseeing-csl-style))
                   org-citeseeing-csl--styles-dir))
            (path (and (file-exists-p path) path)))
      path
    (error "CSL style file not found (%s)" path)))

(defun org-citeseeing--citeproc-csl-locale-getter ()
  "Return CSL locale getter function.
In Debian, the directory is installed with the citation-style-language-locales
package."
  (let ((dir org-citeseeing-csl--locales-dir))
    (if (file-directory-p dir)
        (citeproc-locale-getter-from-dir dir)
      (error "CSL locales directory not found (%s)" dir))))

(defvar org-citeseeing--citeproc-itemgetter--cache nil)

(defun org-citeseeing--citeproc-itemgetter (bib-files)
  "Return citeproc itemgetter function for BIB-FILES.
The itemgetter function gets cached for BIB-FILES and will be reused."
  (if-let* ((itemgetter
             (alist-get bib-files
                        org-citeseeing--citeproc-itemgetter--cache
                        nil nil #'equal)))
      itemgetter
    (let ((itemgetter (citeproc-hash-itemgetter-from-any bib-files)))
      (prog1
          itemgetter
        (setf (alist-get bib-files
                         org-citeseeing--citeproc-itemgetter--cache
                         nil nil #'equal)
              itemgetter)))))

(defvar org-citeseeing--citeproc-proc--cache nil)

(defun org-citeseeing--citeproc-proc (command locale)
  "Get CSL processor for LANG and COMMAND."
  (let ((key (list command locale)))
    (if-let* ((proc (alist-get key
                               org-citeseeing--citeproc-proc--cache
                               nil nil #'equal)))
        (progn
          (citeproc-clear proc)
          proc)
      (if-let* ((bib-files (org-citeseeing-bibliography))
                (itemgetter (org-citeseeing--citeproc-itemgetter bib-files)))
          (if-let* ((style (org-citeseeing--citeproc-csl-style command locale))
                    (locgetter (org-citeseeing--citeproc-csl-locale-getter)))
              (let* ((proc (citeproc-create style itemgetter locgetter locale t)))
                (prog1
                    proc
                  (setf (alist-get key
                                   org-citeseeing--citeproc-proc--cache
                                   nil nil #'equal)
                        proc)))
            (error "CSL style/locale not found for command (%s) and locale (%s)"
                   command locale))
        (error "Item getter creation failed")))))

(defun org-citeseeing--citeproc-citation-create (citekeys mode)
  "Create citations from CITEKEYS using MODE."
  (let ((cites (mapcar (lambda (citekey)
                         (list (cons 'id citekey)))
                       citekeys)))
    (citeproc-citation-create :cites cites
                              :mode mode
                              :suppress-affixes t)))

(defun org-citeseeing--citeproc-citation-render (proc citations)
  "Render CITATIONS using citeproc PROC."
  (citeproc-append-citations citations proc)
  (citeproc-render-citations proc 'org 'no-links))

;; (defun org-citeseeing--citeproc-render-spec (command)
;;   "Look up COMMAND in `org-citeseeing-command-alist'.
;; Returns a list containing (MODES FORMAT-STRING). Defaults to ((nil) \"%s\")."
;;   (if-let* ((entry (seq-find (lambda (x) (member command (car x)))
;;                              org-citeseeing-command-alist)))
;;       (cdr entry)
;;     '((nil) "%s")))

(defun org-citeseeing-render (citekey command)
  "Render CITEKEY according to COMMAND."
  (if-let* ((spec (gethash command org-citeseeing--cite-commands)))
      (let* ((modes (car spec))
             (r-format (cadr spec))
             (locale (or (and (functionp org-citeseeing-bib-item-locale-getter)
                              (funcall org-citeseeing-bib-item-locale-getter citekey))
                         org-citeseeing-bib-item-locale-default))
             (proc (org-citeseeing--citeproc-proc command locale))
             (citations
              (mapcar (lambda (mode)
                        (org-citeseeing--citeproc-citation-create
                         (list citekey) mode))
                      modes))
             (mode-to-str
              (cl-pairlis modes
                          (org-citeseeing--citeproc-citation-render
                           proc citations))))
        (s-format r-format
                  (lambda (field)
                    (if (string-prefix-p "cp:" field)
                        (let ((field (intern (substring field 3))))
                          (or (alist-get field mode-to-str)
                              (format "?%s?" field)))
                      (or (and (functionp org-citeseeing-bib-item-value-getter)
                               (funcall org-citeseeing-bib-item-value-getter
                                        field citekey))
                          (format "?%s?" field))))))
    (error "Unknown renderer spec for cite command (%s)" command)))

(defun org-citeseeing--propertize (str &optional face)
  "Convert plain Org text tokens in STR into proper face properties.
When given, FACE is applied additionally."
  (let* (;; BUG(2026-06-05): Somehow, `citeproc-render-item' can produce
         ;; Org-rendered string including these HTML tags. Strip them here.
         (case-fold-search t)
         (str (replace-regexp-in-string
               "<Span Class=\"Nocase\">\\|</Span>" "" str))

         (str (with-temp-buffer
                (insert str)
                (org-mode)
                (font-lock-ensure)
                (buffer-string))))
    (when face
      (add-face-text-property 0 (length str) face t str))
    str))

(defun org-citeseeing-links-generator (lnk)
  "A default fallback generator for link (LNK).
LNK is the content of an Org link, meaning [[LNK][...]]."
  (if (string-match "^\\([^:]+\\):\\(.*\\)$" lnk)
      (when-let*
          ((type (match-string 1 lnk))
           (path (match-string 2 lnk))
           (citekey (and (gethash type org-citeseeing--cite-commands)
                         (when (string-match "\\`&\\(.*\\)" path)
                           (substring-no-properties (match-string 1 path)))))
           (str
            (catch 'error-intercepted
              (handler-bind
                  ((error
                    (lambda (err)
                      (let ((em (error-message-string err)))
                        (message "Error: %s" em)
                        (when org-citeseeing-debug
                          (message "Backtrace:\n%s" (backtrace-to-string)))
                        (throw 'error-intercepted
                               (list (format "%s:%s (err: %s)"
                                             type citekey em)
                                     'org-citeseeing-cite-error-face))))))
                (list (org-citeseeing-render citekey type)
                      'org-citeseeing-cite-face)))))
        (apply #'org-citeseeing--propertize str))))

;;; Utility Functions

(defun org-citeseeing-langid-to-locale (langid)
  "Get locale for given LANGID."
  (alist-get langid citeproc-blt--langid-to-lang-alist nil nil #'equal))

(provide 'org-citeseeing)
;;; org-citeseeing.el ends here
