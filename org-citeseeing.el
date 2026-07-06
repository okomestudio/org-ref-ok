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

(defgroup org-citeseeing nil
  "Customization group for `org-citeseeing'."
  :group 'faces
  :prefix "org-citeseeing-")

(defcustom org-citeseeing-debug nil
  "Set non-nil for verbose debug messages."
  :type 'boolean
  :group 'org-citeseeing)

(defcustom org-citeseeing-bibliography
  citar-bibliography
  "Bibliography files."
  :type '(choice
          (repeat :tag "Literal list of files" file)
          (function :tag "Function returning file list")
          (variable :tag "Variable holding file list"))
  :group 'org-citeseeing)

(defcustom org-citeseeing-cache-eviction-registry
  '(citar-cache--update-bibliography
    bibtex-completion-clear-cache)
  "Function registry for adding after-advise for cache eviction."
  :type '(repeat :tag "List of functions to add cache eviction" function))

(defcustom org-citeseeing-csl-dir
  "/usr/share/citation-style-language"
  "The CSL directory path.
On Debian, you need the following packages:

  - citation-style-language-locales
  - citation-style-language-styles

to fill the necessary files under this directory tree."
  :type 'directory
  :group 'org-citeseeing)

(defcustom org-citeseeing-csl-style
  "chicago-note-bibliography.csl"
  "A function or string file path. See `org-citeseeing--citeproc-csl-style'."
  :type '(choice (function :tag "Function")
                 (file :tag "Path to CSL style file"))
  :group 'org-citeseeing)

(defcustom org-citeseeing-command-alist
  '((("cite" "Cite" "parencite" "Parencite") . ((nil) "${nil}"))
    (("citeauthor" "citeauthor*") . ((author-only) "${author-only}"))
    (("citetitle" "citetitle*" "citeurl") . ((title-only) "${title-only}"))
    (("citeyear" "citeyear*") . ((year-only) "${year-only}"))
    ;; (("footfullcite") . ((nil) "${nil}"))
    (("fullcite") . ((bib-entry) "${bib-entry}"))
    ;; (("textcite") . ((author-only year-only) "${author-only} (${year-only})"))
    ;; (("textcite-bare") . ((author-only year-only) "${author-only} ${year-only}"))
    )
  "Alist mapping of cite commands to string format.
Each value is a list of (MODES FORMAT-STRING)."
  :type 'alist
  :set (lambda (sym val)
         (set-default sym val)
         (setq org-citeseeing--commands
               (seq-mapcat #'car org-citeseeing-command-alist)))
  :group 'org-citeseeing)

(defface org-citeseeing-cite-face '((t :inherit org-cite))
  "TBD.")

(defface org-citeseeing-cite-error-face '((t :inherit org-warning))
  "TBD.")

(defvar org-citeseeing--commands nil)
(defvar org-citeseeing--citeproc-modes
  '( author-only bib-entry locator-only nil suppress-author
     textual title-only year-only ))

;;;###autoload
(define-minor-mode org-citeseeing-mode
  "Minor mode for org-citeseeing support."
  :lighter " orvis"
  :group 'org-citeseeing
  (pcase org-citeseeing-mode
    ('t (org-citeseeing-mode--on))
    (_ (org-citeseeing-mode--off))))

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

(defun org-citeseeing--citeproc-csl-style (command lang)
  "Get CSL style file path.
If `org-citeseeing-csl-style' is a function, it will be called with `(command lang)' as
arguments. Otherwise, it should be a string file path, either absolute or
relative (to `org-citeseeing-csl-dir/styles')."
  (let* ((style-file
          (cond
           ((functionp org-citeseeing-csl-style)
            (funcall org-citeseeing-csl-style command lang))
           (t
            (if (file-name-absolute-p org-citeseeing-csl-style)
                org-citeseeing-csl-style
              (file-name-concat org-citeseeing-csl-dir
                                "styles"
                                org-citeseeing-csl-style))))))
    (if (and style-file (file-exists-p style-file))
        style-file
      (error "CSL style file not found (%s)" style-file))))

(defun org-citeseeing--citeproc-csl-locale-getter ()
  "Return CSL locale getter function.
In Debian, the directory is installed with the citation-style-language-locales
package."
  (let ((dir (file-name-concat org-citeseeing-csl-dir "locales")))
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

(defun org-citeseeing--citeproc-render-spec (command)
  "Look up COMMAND in `org-citeseeing-command-alist'.
Returns a list containing (MODES FORMAT-STRING). Defaults to ((nil) \"%s\")."
  (if-let* ((entry (seq-find (lambda (x) (member command (car x)))
                             org-citeseeing-command-alist)))
      (cdr entry)
    '((nil) "%s")))

(defun org-citeseeing-item-locale (citekey)
  (if-let* ((langid (citar-get-value "langid" citekey))
            (locale (alist-get langid
                               citeproc-blt--langid-to-lang-alist
                               nil nil #'equal)))
      locale
    "en-US"))

(defun org-citeseeing-render (citekey command)
  "Render CITEKEY according to COMMAND."
  (pcase-let ((`(,modes ,r-format) (org-citeseeing--citeproc-render-spec command)))
    (if-let* ((locale (org-citeseeing-item-locale citekey))
              (proc (org-citeseeing--citeproc-proc command locale))
              (citations (mapcar
                          (lambda (mode)
                            (when (member mode org-citeseeing--citeproc-modes)
                              (org-citeseeing--citeproc-citation-create
                               (list citekey) mode)))
                          modes)))
        (let* ((mode-to-s
                (cl-pairlis
                 modes (org-citeseeing--citeproc-citation-render proc citations))))
          (s-format r-format
                    (lambda (key)
                      (let ((mode (intern key)))
                        (or (alist-get mode mode-to-s)
                            ;; (alist-get mode item)
                            )))))
      (error "Item cannot be rendered (%s)" citekey))))

(defun org-citeseeing-render-isolated (citekey command)
  "Render CITEKEY according to COMMAND format.
This version renders isolated references using `citeproc-create-style' and
`citeproc-render-item'."
  (if-let* ((ig (org-citeseeing--citeproc-itemgetter (org-citeseeing-bibliography)))
            (item (cdr (assoc citekey (funcall ig (list citekey)))))
            (lang (or (cdr (assoc "language" item))
                      (cdr (assoc 'language item))
                      "en-US"))
            (lg (org-citeseeing--citeproc-csl-locale-getter))
            (style (citeproc-create-style
                    (org-citeseeing--citeproc-csl-style command lang) lg)))
      (citeproc-render-item item style 'bib 'org)
    (error "Item cannot be rendered (%s)" citekey)))

(defun org-citeseeing--propertize (str &optional face)
  "Convert plain Org text tokens in STR into proper face properties.
When given, FACE is applied additionally."
  (let* ((s str)

         ;; BUG(2026-06-05): Somehow, `citeproc-render-item' can produce
         ;; Org-rendered string including these HTML tags. Strip them here.
         (case-fold-search t)
         (s (replace-regexp-in-string
             "<Span Class=\"Nocase\">\\|</Span>" "" s))

         (s (with-temp-buffer
              (insert s)
              (org-mode)
              (font-lock-ensure)
              (buffer-string))))
    (when face
      (add-face-text-property 0 (length s) face t s))
    s))

(defun org-citeseeing-links-generator (lnk)
  "A default fallback generator for link (LNK).
LNK is the content of an Org link, meaning [[LNK][...]]."
  (if (string-match "^\\([^:]+\\):\\(.*\\)$" lnk)
      (when-let*
          ((type (match-string 1 lnk))
           (path (match-string 2 lnk))
           (citekey (and (member type org-citeseeing--commands)
                         (when (string-match "\\`&\\(.*\\)" path)
                           (substring-no-properties (match-string 1 path))))))
        (apply #'org-citeseeing--propertize
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
                         'org-citeseeing-cite-face)))))))

(provide 'org-citeseeing)
;;; org-citeseeing.el ends here
