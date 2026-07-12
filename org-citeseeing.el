;;; org-citeseeing.el --- Render Org Citations On Fly  -*- lexical-binding: t -*-
;;
;; Copyright (C) 2026 Taro Sato
;;
;; Author: Taro Sato <okomestudio@gmail.com>
;; URL: https://github.com/okomestudio/org-citeseeing/org-citeseeing.el
;; Version: 0.1.1
;; Keywords: convenience
;; Package-Requires: ((emacs "30.1") (compat "31.0.0.1) (citeproc "0.9.4") (s "1.13.1"))
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
;; `org-citeseeing' is a minor mode to render citations in Org documents using
;; `citeproc'.
;;
;;; Code:

(require 'compat)
(require 'citeproc)
(require 's)

(require 'org)
(require 'seq)

(defgroup org-citeseeing nil
  "Customization group for `org-citeseeing'."
  :group 'faces
  :prefix "org-citeseeing-")

;;; Custom Variables

;; Forward Declarations (to avoid errors within defcustoms)
(defvar org-citeseeing--cite-commands)

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

(defcustom org-citeseeing-bib-item-locale 'en-US
  "Either a locale symbol (e.g., en-US, ja-JP) or a function that takes in a
citekey as an argument and returns a locale symbol."
  :type '(choice
          (function :tag "Function returning locale symbol")
          (symbol :tag "Locale symbol"))
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
locale (e.g., en-US), returning a CSL style file path.

Unless the file path is absolute, it will be sought in `org-citeseeing-csl--styles-dir'."
  :type '(choice
          (function :tag "Function returning CSL style file")
          (file :tag "Path to CSL style file"))
  :group 'org-citeseeing)

;; (setopt org-citeseeing-command-alist nil)
(defcustom org-citeseeing-command-alist
  '(("cite" . (:cite-format "${cp:nil}"))
    (("citep" "citep*")
     . ((ja-JP
         . ( :outer-prefix "（"
             :cite-format "${cp:author-only}、${cp:year-only}"
             :outer-suffix "）" ))
        (t
         . ( :outer-prefix "("
             :cite-format "${cp:author-only}, ${cp:year-only}"
             :outer-suffix ")" ))))
    (("citet" "citet*")
     . ((ja-JP
         . ( :cite-format "${cp:author-only}（${cp:year-only}"
             :inner-suffix "）" ))
        (t
         . ( :cite-format "${cp:author-only} (${cp:year-only}"
             :inner-suffix ")" ))))
    (("citeauthor" "citeauthor*") . (:cite-format "${cp:author-only}"))
    (("citetitle" "citetitle*") . (:cite-format "${cp:title-only}"))
    (("citeyear" "citeyear*") . (:cite-format "${cp:year-only}"))
    ("fullcite" . (:cite-format "${cp:bib-entry}")))
  "Alist mapping of cite command(s) to string format template.
See `org-citeseeing--format' for detail on string format template.

The field name starting with 'cp:' refers to a `citeproc' mode (see
`org-citeseeing--citeproc-modes' for all available modes). A non-mode field referes to that of
current bibliography item, its value obtained via `org-citeseeing-bib-item-value-getter'."
  :type
  '(alist :key-type
          (choice
           (string :tag "Single command")
           (repeat :tag "List of commands" string))
          :value-type
          (choice
           (plist :options
                  ((:outer-prefix (string :tag "Outer prefix string"))
                   (:inner-prefix (string :tag "Inner prefix string"))
                   (:cite-format (string :tag "Citation format string"))
                   (:inner-suffix (string :tag "Inner suffix string"))
                   (:outer-suffix (string :tag "Outer suffix string"))))
           (alist :key-type (symbol :tag "Locale symbol or t")
                  :value-type
                  (plist :options
                         ((:outer-prefix (string :tag "Outer prefix string"))
                          (:inner-prefix (string :tag "Inner prefix string"))
                          (:cite-format (string :tag "Citation format string"))
                          (:inner-suffix (string :tag "Inner suffix string"))
                          (:outer-suffix (string :tag "Outer suffix string")))))))
  :set
  (lambda (sym val)
    (set-default sym val)

    ;; Ensure `org-citeseeing--cite-commands' is an empty hash table:
    (if (and (boundp 'org-citeseeing--cite-commands)
             org-citeseeing--cite-commands
             (hash-table-p org-citeseeing--cite-commands))
        (clrhash org-citeseeing--cite-commands)
      (setq-default org-citeseeing--cite-commands
                    (make-hash-table :test #'equal)))

    (pcase-dolist (`(,commands . ,locale-specs) val)
      (when (null (car-safe (car locale-specs)))
        (setq locale-specs (list (cons t locale-specs))))
      (dolist (command (or (and (stringp commands) (list commands))
                           commands))
        (let (result)
          (pcase-dolist (`(,locale . ,spec) locale-specs)
            (let* ((cite-format (plist-get spec :cite-format))
                   (modes
                    (mapcar #'intern
                            (seq-keep
                             (lambda (item)
                               (let ((field (cadr item)))
                                 (and (string-prefix-p "cp:" field)
                                      (substring field 3))))
                             (s-match-strings-all "\\${\\([^}]+\\)}"
                                                  cite-format)))))
              (push (cons locale (plist-put spec :modes modes)) result)))
          (puthash command result org-citeseeing--cite-commands)))))
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

(defvar org-citeseeing-csl--styles-dir nil)
(defvar org-citeseeing-csl--locales-dir nil)
(defvar org-citeseeing--cite-commands nil)
(defvar org-citeseeing--citeproc-modes
  '( author-only bib-entry locator-only nil suppress-author
     textual title-only year-only ))

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
  (when (featurep 'oc)
    (org-citeseeing--oc-processor-activate))

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
          (while (re-search-forward
                  "\\[\\[\\([^:]+\\)\\:\\([^]]+\\)\\]\\]"
                  _limit t)
            (when-let* ((beg (match-beginning 0))
                        (end (match-end 0))
                        (type (match-string 1))
                        (path (match-string 2))
                        (txt (org-citeseeing--render-citation-link
                              (substring-no-properties type)
                              (substring-no-properties path))))
              (put-text-property beg end 'display txt)
              (throw :exit t))))))
    retval))

(defun org-citeseeing--oc-processor-activate ()
  "Inject custom text properties via `org-cite-activate-processor'."
  (let* ((current-backend-name org-cite-activate-processor)
         (current-backend (org-cite-get-processor current-backend-name))
         (native-activate (org-cite-processor-activate current-backend)))
    (when native-activate
      (org-cite-register-processor 'org-citeseeing-oc-processor
        :activate
        (lambda (citation)
          (funcall native-activate citation)
          (let* ((bounds (org-cite-boundaries citation))
                 (beg (car bounds))
                 (end (cdr bounds)))
            (with-silent-modifications
              (put-text-property beg end 'display
                                 (format "R:%s" citation))))))

      (setq-local org-cite-activate-processor 'org-citeseeing-oc-processor))))

(defun org-citeseeing-bib-item-locale (citekey)
  "Get locale symbol for CITEKEY item."
  (or (and (functionp org-citeseeing-bib-item-locale)
           (funcall org-citeseeing-bib-item-locale citekey))
      org-citeseeing-bib-item-locale))

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
      (prog1
          path
        (org-citeseeing--message
         "CSL style file: %s for command '%s' and locale '%s'"
         path command locale))
    (error "CSL style file not found for command '%s' and locale '%s'"
           command locale)))

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
              (let* ((proc (citeproc-create style itemgetter locgetter
                                            (symbol-name locale) t)))
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
                              :note-index nil
                              :mode mode
                              :suppress-affixes t
                              :capitalize-first nil
                              :ignore-et-al nil)))

(defvar org-citeseeing--citeproc-citation-render-errfun
  (lambda (str)
    (cond
     ((string-prefix-p "NO_ITEM_DATA:" str)
      (error "NO_ITEM_DATA"))
     (t str))))

(defun org-citeseeing--citeproc-citation-render (proc citations)
  "Render CITATIONS using citeproc PROC."
  (citeproc-append-citations citations proc)
  (mapcar (lambda (str)
            (let ((case-fold-search t)
                  ;; BUG(2026-06-05): Somehow, `citeproc-render-item' can
                  ;; produce Org-rendered string including these HTML tags.
                  ;; Strip them here.
                  (str (replace-regexp-in-string
                        "<Span Class=\"Nocase\">\\|</Span>" "" str)))
              (if (functionp org-citeseeing--citeproc-citation-render-errfun)
                  (funcall org-citeseeing--citeproc-citation-render-errfun str)
                str)))
          (citeproc-render-citations proc 'org 'no-links)))

(defun org-citeseeing--format (template fallback)
  "Extended version of `s-format' for `citeproc'."
  (s-format template
            (lambda (field)
              (if (string-prefix-p "cp:" field)
                  (let ((field (intern (substring field 3))))
                    (or (alist-get field fallback)
                        (format "?%s?" field)))
                (or (and (functionp org-citeseeing-bib-item-value-getter)
                         (funcall org-citeseeing-bib-item-value-getter
                                  field (alist-get 'citekey fallback)))
                    (format "?%s?" field))))))

(defun org-citeseeing--propertize (str props)
  "Convert plain Org text tokens in STR into proper face properties.
When given, FACE is applied additionally."
  (let ((str (with-temp-buffer
               (insert str)
               (org-mode)
               (font-lock-ensure)
               (buffer-string))))
    (add-text-properties 0 (length str) props str)
    str))

(defun org-citeseeing--citekey-render (command citekey template modes)
  "Render CITEKEY according to COMMAND.
TEMPLATE ."
  (catch 'error-intercepted
    (handler-bind
        ((error
          (lambda (err)
            (org-citeseeing--warn "Error on rendering '%s' for %s:\n%s"
                                  template
                                  citekey
                                  (error-message-string err))
            (org-citeseeing--backtrace)
            (throw 'error-intercepted
                   (org-citeseeing--propertize
                    (format "%s:%s" command citekey)
                    '(face org-citeseeing-cite-error-face))))))
      (let* ((locale (org-citeseeing-bib-item-locale citekey))
             (proc (org-citeseeing--citeproc-proc command locale))
             (citations
              (mapcar (lambda (mode)
                        (org-citeseeing--citeproc-citation-create
                         (list citekey) mode))
                      modes))
             (fallback
              (cl-pairlis modes
                          (org-citeseeing--citeproc-citation-render
                           proc citations)))
             (fallback (append fallback
                               `((citekey . ,citekey)))))
        (cl-assert template)
        (org-citeseeing--propertize (org-citeseeing--format template fallback)
                                    nil
                                    ;; '(face org-citeseeing-cite-face)
                                    )))))

;; (defun org-citeseeing-render-isolated (citekey command)
;;   "Render CITEKEY according to COMMAND as isolated reference.
;; This version might be faster for a few isolated citations, but only 'bib or
;; 'cite style is available (see `citeproc-render-item')."
;;   (if-let* ((spec (gethash command org-citeseeing--cite-commands)))
;;       (let* ((modes (car spec))
;;              ;; (r-format (cadr spec))
;;              (r-format (plist-get (cadr spec) :cite-format))
;;              (locale (or (and (functionp org-citeseeing-bib-item-locale)
;;                               (funcall org-citeseeing-bib-item-locale citekey))
;;                          org-citeseeing-bib-item-locale))
;;              (style (citeproc-create-style
;;                      (org-citeseeing--citeproc-csl-style command locale)
;;                      (org-citeseeing--citeproc-csl-locale-getter)
;;                      locale t))
;;              (itemgetter (org-citeseeing--citeproc-itemgetter (org-citeseeing-bibliography)))
;;              (item (car (funcall itemgetter (list citekey))))
;;              (mode-to-str
;;               (cl-pairlis modes
;;                           (mapcar (lambda (mode)
;;                                     (citeproc-render-item
;;                                      (cdr item) style 'cite 'org t))
;;                                   modes))))
;;         (org-citeseeing--format r-format mode-to-str))
;;     (error "Unknown renderer spec for cite command (%s)" command)))

(defun org-citeseeing--render-citation-link (command path)
  "Render citation for COMMAND and PATH."
  (if-let* ((locale-specs (gethash command org-citeseeing--cite-commands)))
      (let* ((locale nil)
             (tokens (org-ref-parse-cite-path path))
             (common-prefix (or (plist-get tokens :prefix) ""))
             (common-suffix (or (plist-get tokens :suffix) ""))
             (references (plist-get tokens :references))
             (rendered
              (mapconcat
               (lambda (it)
                 (let* ((prenote (or (plist-get it :prefix) ""))
                        (postnote (or (plist-get it :suffix) ""))
                        (citekey (plist-get it :key)))
                   (setq locale (org-citeseeing-bib-item-locale citekey))
                   (let* ((spec (or (alist-get locale locale-specs)
                                    (alist-get t locale-specs)))
                          (inner-prefix (or (plist-get spec :inner-prefix) ""))
                          (inner-suffix (or (plist-get spec :inner-suffix) ""))
                          (cite-format (plist-get spec :cite-format))
                          (modes (plist-get spec :modes)))
                     (concat inner-prefix prenote
                             (org-citeseeing--citekey-render
                              command citekey cite-format modes)
                             postnote inner-suffix))))
               references))
             (spec (or (alist-get locale locale-specs)
                       (alist-get t locale-specs)))
             (outer-prefix (or (plist-get spec :outer-prefix) ""))
             (outer-suffix (or (plist-get spec :outer-suffix) "")))
        (concat outer-prefix common-prefix rendered common-suffix outer-suffix))
    (org-citeseeing--message "Passed link generation for %s" command)))

;;; Utility Functions

(defun org-citeseeing-langid-to-locale (langid)
  "Get locale symbol for given LANGID string.
Return nil if LANGID is unrecognized."
  (when-let* ((locale (alist-get langid citeproc-blt--langid-to-lang-alist
                                 nil nil #'equal)))
    (intern locale)))

(defun org-citeseeing--message (s &rest _rest)
  "Display an `org-citeseeing' message at the bottom of the screen."
  (apply #'message `(,(concat "[org-citeseeing] " s) ,@_rest)))

(defun org-citeseeing--warn (s &rest _rest)
  "Display an `org-citeseeing' warning message."
  (apply #'warn `(,(concat "[org-citeseeing] " s) ,@_rest)))

(defun org-citeseeing--backtrace ()
  "Display an `org-citeseeing' backtrace buffer when debug mode is on."
  (when org-citeseeing-debug
    (require 'backtrace)
    (let ((buf (get-buffer-create "*Backtrace*")))
      (with-current-buffer buf
        (let* ((inhibit-read-only t)
               (bt (backtrace-to-string))
               (bt (string-join (nthcdr 3 (string-split bt "\n"))
                                "\n")))
          (erase-buffer)
          (insert (format "Backtrace:\n%s" bt))
          (special-mode)
          (goto-char (point-min))))
      (pop-to-buffer buf))))

(provide 'org-citeseeing)
;;; org-citeseeing.el ends here
