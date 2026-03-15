;;; madolt-diff.el --- Tabular diff viewer for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tabular diff viewer for madolt.  This is the most novel component:
;; Dolt diffs are row-level and cell-level, not line-based text diffs
;; like git.  There is no magit equivalent.
;;
;; Two rendering modes:
;;
;; 1. Structured mode (default): parse `dolt diff -r json', render a
;;    custom tabular view with collapsible row-diff sections and
;;    cell-level highlighting for modified rows.
;;
;; 2. Raw mode: insert `dolt diff' native tabular output with syntax
;;    highlighting applied to row markers (<, >, +, -).

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'magit-section)
(require 'transient)
(require 'madolt-dolt)
(require 'madolt-mode)

;;;; Faces

(defface madolt-diff-added
  '((t :inherit magit-diff-added))
  "Face for added rows.  Inherits from `magit-diff-added'."
  :group 'madolt-faces)

(defface madolt-diff-removed
  '((t :inherit magit-diff-removed))
  "Face for deleted rows.  Inherits from `magit-diff-removed'."
  :group 'madolt-faces)

(defface madolt-diff-old
  '((t :inherit magit-diff-removed))
  "Face for old value of a modified row."
  :group 'madolt-faces)

(defface madolt-diff-new
  '((t :inherit magit-diff-added))
  "Face for new value of a modified row."
  :group 'madolt-faces)

(defface madolt-diff-changed-cell
  '((t :weight bold :underline t))
  "Face for the specific cells that changed within a modified row."
  :group 'madolt-faces)

(defface madolt-diff-added-highlight
  '((t :inherit magit-diff-added-highlight))
  "Face for added row values when highlighted."
  :group 'madolt-faces)

(defface madolt-diff-removed-highlight
  '((t :inherit magit-diff-removed-highlight))
  "Face for deleted row values when highlighted."
  :group 'madolt-faces)

(defface madolt-diff-context
  '((t :inherit magit-diff-context))
  "Face for unchanged values in row diff summaries."
  :group 'madolt-faces)

(defface madolt-diff-context-highlight
  '((t :inherit magit-diff-context-highlight))
  "Face for unchanged values when highlighted."
  :group 'madolt-faces)

(defface madolt-diff-column-name
  '((t :weight bold))
  "Face for column names in row diff summaries."
  :group 'madolt-faces)

(defface madolt-diff-column-value
  '((t :inherit default))
  "Face for column values in row diff summaries."
  :group 'madolt-faces)

(defface madolt-diff-table-heading
  '((t :weight bold :extend t))
  "Face for table diff headings."
  :group 'madolt-faces)

(defface madolt-diff-column-header
  '((t :underline t :weight bold))
  "Face for column header rows in raw mode."
  :group 'madolt-faces)

(defface madolt-diff-schema
  '((t :inherit font-lock-type-face))
  "Face for schema change SQL statements."
  :group 'madolt-faces)

(defface madolt-diff-context
  '((((class color) (background light))
     :foreground "grey50" :extend t)
    (((class color) (background dark))
     :foreground "grey70" :extend t))
  "Face for unchanged context in diffs."
  :group 'madolt-faces)

;;;; Indentation

(defvar madolt-diff--indent "  "
  "Current indentation prefix for row-diff and schema sections.
Dynamically bound to increase nesting depth when inserting
diffs inside an already-indented context (e.g. status buffer).")

;;;; Row limits

(defcustom madolt-diff-max-rows 100
  "Maximum number of row changes to display per table in a diff buffer.
When a table diff contains more rows than this limit, only the
first N rows are shown and a \"Type + to show more\" button is
inserted.  Pressing \"+\" doubles the limit and refreshes.
Set to nil to disable the limit entirely."
  :group 'madolt
  :type '(choice (integer :tag "Max rows per table")
                 (const :tag "No limit" nil)))

(defcustom madolt-diff-section-max-rows 20
  "Maximum number of row changes to display in inline status diffs.
This applies to the diff shown when expanding a table entry in
the status buffer.  Lower than `madolt-diff-max-rows' since
performance matters most in the status buffer."
  :group 'madolt
  :type '(choice (integer :tag "Max rows per table")
                 (const :tag "No limit" nil)))

(defcustom madolt-diff-raw-max-lines 200
  "Maximum number of output lines to display per table in raw diff mode.
This counts all lines including headers and separators."
  :group 'madolt
  :type '(choice (integer :tag "Max lines per table")
                 (const :tag "No limit" nil)))

(defvar-local madolt-diff--row-limit nil
  "Current row limit for the diff buffer.
Initialized from `madolt-diff-max-rows' and doubled by `+'.
When nil, use the defcustom value.")

;;;; Truncation

(defcustom madolt-diff-min-value-width 10
  "Minimum display width for truncated field values in row-diff summaries.
Values shorter than this will not be truncated further when fitting
row-diff summary lines to the window width."
  :group 'madolt-faces
  :type 'integer)

(defcustom madolt-diff-max-value-width 40
  "Maximum display width for any single field value in row-diff summaries.
Changed fields showing old→new values are capped at this width so
they leave room for primary key and other unchanged fields."
  :group 'madolt-faces
  :type 'integer)

;;;; Buffer-local variables

(defvar-local madolt-diff-args nil
  "Current diff arguments for this diff buffer.")

(defvar-local madolt-diff-raw-mode nil
  "Non-nil for raw tabular display mode.")

(defvar-local madolt-diff--revisions nil
  "Cons of (REV-A . REV-B) for between-commits diff, or nil.")

(defvar-local madolt-diff--table nil
  "Single table name for table-specific diff, or nil.")

(defvar-local madolt-diff--staged nil
  "Non-nil when showing staged changes.")

(defvar madolt-diff--current-table nil
  "Name of the table currently being rendered.
Dynamically bound during row-diff insertion so that row-summary
functions can look up primary key columns.")

;;;; Transient menu

;;;###autoload (autoload 'madolt-diff "madolt-diff" nil t)
(transient-define-prefix madolt-diff ()
  "Show diffs."
  ["Arguments"
   ("-s" "Statistics only"    "--stat")
   ("-S" "Summary only"      "--summary")
   ("-w" "Where clause"      "--where=")
   ("-k" "Skinny columns"    "--skinny")]
  ["Diff"
   ("d" "Working tree"       madolt-diff-unstaged)
   ("s" "Staged"             madolt-diff-staged)
   ("c" "Between commits"    madolt-diff-commits)
   ("t" "Single table"       madolt-diff-table)
   ("r" "Raw tabular mode"   madolt-diff-unstaged-raw)])

;;;; Diff buffer commands

(defun madolt-diff-unstaged (&optional args)
  "Show diff of unstaged change.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-diff)))
  (madolt-diff--show-buffer args nil nil nil nil))

(defun madolt-diff-staged (&optional args)
  "Show diff of staged change.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-diff)))
  (madolt-diff--show-buffer args nil nil nil t))

(defun madolt-diff-commits (rev-a rev-b &optional args)
  "Show diff between two revisions REV-A and REV-B.
ARGS are additional arguments from the transient."
  (interactive
   (let ((default (madolt-branch-or-commit-at-point)))
     (list (completing-read
            (format "From revision%s: "
                    (if default (format " (default %s)" default) ""))
            (madolt-all-ref-names) nil nil nil nil default)
           (completing-read "To revision (default HEAD): "
                            (madolt-all-ref-names) nil nil nil nil "HEAD")
           (transient-args 'madolt-diff))))
  (madolt-diff--show-buffer args (cons rev-a rev-b) nil nil nil))

(defun madolt-diff-table (table &optional args)
  "Show diff for a single TABLE.
ARGS are additional arguments from the transient."
  (interactive
   (list (completing-read "Table: " (madolt--table-names))
         (transient-args 'madolt-diff)))
  (madolt-diff--show-buffer args nil table nil nil))

(defun madolt-diff-unstaged-raw (&optional args)
  "Show diff in raw tabular format.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-diff)))
  (madolt-diff--show-buffer args nil nil t nil))

;;;; Row limit expansion

(defun madolt-diff-double-limit ()
  "Double the number of diff rows shown per table and refresh."
  (interactive)
  (let ((current (or madolt-diff--row-limit
                     (and (derived-mode-p 'madolt-status-mode)
                          madolt-diff-section-max-rows)
                     madolt-diff-max-rows
                     100)))
    (setq madolt-diff--row-limit (* current 2)))
  (madolt-refresh))

;;;; Buffer setup

(defun madolt-diff--show-buffer (args revisions table raw-mode staged)
  "Set up and display a diff buffer.
ARGS is the list of transient arguments.
REVISIONS is a cons (REV-A . REV-B) or nil.
TABLE is a single table name or nil.
RAW-MODE is non-nil for raw tabular display.
STAGED is non-nil for showing staged changes.
If a buffer already exists with the same parameters, switch to it
without refreshing.  Use \\`g' to refresh manually."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (db-name (file-name-nondirectory
                   (directory-file-name db-dir)))
         (buf-name (if revisions
                       (format "madolt-diff: %s %s..%s%s"
                               db-name
                               (car revisions) (cdr revisions)
                               (if table (format " %s" table) ""))
                     (madolt--buffer-name 'madolt-diff-mode db-dir)))
         (existing (get-buffer buf-name))
         (buffer (or existing (generate-new-buffer buf-name)))
         ;; Reuse without refresh only for between-commits diffs
         ;; (immutable); working tree diffs always need refreshing.
         (same-params (and existing
                           revisions  ; only immutable diffs
                           (with-current-buffer existing
                             (and (derived-mode-p 'madolt-diff-mode)
                                  (equal madolt-diff-args args)
                                  (equal madolt-diff-raw-mode raw-mode)
                                  (equal madolt-diff--revisions revisions)
                                  (equal madolt-diff--table table)
                                  (equal madolt-diff--staged staged))))))
    (unless same-params
      (with-current-buffer buffer
        (unless (derived-mode-p 'madolt-diff-mode)
          (madolt-diff-mode))
        (setq default-directory db-dir)
        (setq madolt-buffer-database-dir db-dir)
        (setq madolt-diff-args args)
        (setq madolt-diff-raw-mode raw-mode)
        (setq madolt-diff--revisions revisions)
        (setq madolt-diff--table table)
        (setq madolt-diff--staged staged)
        (madolt-refresh)))
    (madolt-display-buffer buffer)
    buffer))

;;;; Refresh

(defun madolt-diff-refresh-buffer ()
  "Refresh the diff buffer using the current settings."
  (if madolt-diff-raw-mode
      (madolt-diff--refresh-raw)
    (madolt-diff--refresh-structured)))

;;;; CLI argument building

(defun madolt-diff--build-args ()
  "Build the dolt diff argument list from buffer-local state.
Return a flat list of strings."
  (let ((args (copy-sequence (or madolt-diff-args nil))))
    (when madolt-diff--staged
      (push "--staged" args))
    (when madolt-diff--revisions
      (push (cdr madolt-diff--revisions) args)
      (push (car madolt-diff--revisions) args))
    (when madolt-diff--table
      (push madolt-diff--table args))
    args))

;;;; Structured mode

(defun madolt-diff--refresh-structured ()
  "Refresh the diff buffer in structured (JSON) mode."
  (let* ((args (madolt-diff--build-args))
         (json (apply #'madolt-diff-json args))
         (tables (and json (alist-get 'tables json))))
    (magit-insert-section (diff)
      (if (null tables)
          (insert (propertize "No differences\n" 'font-lock-face 'shadow))
        (dolist (tbl tables)
          (madolt-diff--insert-table-diff tbl))))))

(defun madolt-diff--insert-table-diff (table-data &optional max-rows)
  "Insert a table-diff section for TABLE-DATA.
TABLE-DATA is an alist from the JSON `tables' array.
MAX-ROWS, if non-nil, limits how many row changes are shown.
When omitted, uses `madolt-diff--row-limit' or `madolt-diff-max-rows'."
  (let ((name (alist-get 'name table-data))
        (schema-diff (alist-get 'schema_diff table-data))
        (data-diff (alist-get 'data_diff table-data))
        (limit (or max-rows
                   madolt-diff--row-limit
                   madolt-diff-max-rows)))
    (magit-insert-section (table-diff name t)
      (magit-insert-heading
        (propertize (format "modified  %s" name)
                    'font-lock-face 'madolt-diff-table-heading))
      ;; Schema changes
      (when (and schema-diff (not (seq-empty-p schema-diff)))
        (magit-insert-section (schema-diff)
          (magit-insert-heading
            (propertize (concat madolt-diff--indent "Schema changes")
                        'font-lock-face 'madolt-diff-column-header))
          (let ((sql-indent (concat madolt-diff--indent "  ")))
            (dolist (stmt schema-diff)
              (let ((indented (replace-regexp-in-string
                               "^" sql-indent stmt)))
                (insert (propertize (concat indented "\n")
                                    'font-lock-face 'madolt-diff-schema)))))))
      ;; Data changes (with row limit)
      (when data-diff
        (let ((total (length data-diff))
              (shown 0)
              (madolt-diff--current-table name))
          (dolist (row-change data-diff)
            (when (or (null limit) (< shown limit))
              (madolt-diff--insert-row-diff row-change)
              (cl-incf shown)))
          (when (and limit (> total limit))
            (madolt-insert-show-more-button
             shown total
             'madolt-mode-map 'madolt-diff-double-limit
             madolt-diff--indent))))
      (insert "\n"))))

;;;; Diff statistics

(defun madolt-diff--table-stat (table-data)
  "Compute row-level change stats for TABLE-DATA.
TABLE-DATA is an alist from the JSON `tables' array.
Return a plist (:name :added :deleted :modified :schema-changed)."
  (let ((name (alist-get 'name table-data))
        (schema-diff (alist-get 'schema_diff table-data))
        (data-diff (alist-get 'data_diff table-data))
        (added 0) (deleted 0) (modified 0))
    (dolist (row-change data-diff)
      (pcase (madolt-diff--row-change-type row-change)
        ('added (cl-incf added))
        ('deleted (cl-incf deleted))
        ('modified (cl-incf modified))))
    (list :name name
          :added added :deleted deleted :modified modified
          :schema-changed (and schema-diff (not (seq-empty-p schema-diff))))))

(defun madolt-diff--compute-stats (tables)
  "Compute per-table stats for a list of TABLES from JSON diff.
Return a list of plists, one per table."
  (mapcar #'madolt-diff--table-stat tables))

;;;; Row diff rendering

(defun madolt-diff--row-change-type (row-change)
  "Determine the change type for ROW-CHANGE.
Return `added', `deleted', or `modified'."
  (let ((from-row (alist-get 'from_row row-change))
        (to-row (alist-get 'to_row row-change)))
    (cond
     ((or (null from-row) (and (listp from-row) (null from-row)))
      'added)
     ((or (null to-row) (and (listp to-row) (null to-row)))
      'deleted)
     (t 'modified))))

(defun madolt-diff--row-summary (row-change change-type)
  "Return a one-line summary string for ROW-CHANGE of CHANGE-TYPE.
The +/-/~ prefix uses the appropriate added/removed face.
Column names are bold, values use `madolt-diff-column-value'.
Long values are truncated with \"…\" to fit within the window width."
  (let* ((from-row (alist-get 'from_row row-change))
         (to-row (alist-get 'to_row row-change))
         ;; Available width: window minus indent minus prefix ("+ ")
         ;; Subtract 1 extra so the line stays strictly shorter than
         ;; window-width, avoiding the "$" continuation indicator.
         (prefix-width (+ (length madolt-diff--indent) 2))
         (win-width (1- (window-width)))
         (fields-width (- win-width prefix-width)))
    (pcase change-type
      ('added
       (let ((fields (madolt-diff--format-row-fields
                      to-row fields-width 'madolt-diff-added)))
         (concat (propertize "+" 'font-lock-face 'madolt-diff-added)
                 " " fields)))
      ('deleted
       (let ((fields (madolt-diff--format-row-fields
                      from-row fields-width 'madolt-diff-removed)))
         (concat (propertize "-" 'font-lock-face 'madolt-diff-removed)
                 " " fields)))
      ('modified
       (concat (propertize "~" 'font-lock-face 'madolt-diff-old)
               " "
               (madolt-diff--modified-summary
                from-row to-row fields-width))))))

(defun madolt-diff--modified-summary (from-row to-row max-width)
  "Return a one-line summary for a modified row.
Shows fields in priority order: primary key, changed, then
other unchanged.  Changed fields display old→new values.
FROM-ROW and TO-ROW are alists.  MAX-WIDTH is the character
budget for the fields portion.
Uses `madolt-diff--current-table' to look up primary key columns."
  (let* ((pk-cols (when madolt-diff--current-table
                    (madolt-primary-key-columns
                     madolt-diff--current-table)))
         (pk-set (mapcar #'intern pk-cols))
         (pk-fields nil)
         (changed-fields nil)
         (other-fields nil))
    ;; Partition fields into three groups
    (dolist (pair from-row)
      (let ((key (car pair))
            (old-val (cdr pair)))
        (let ((new-val (alist-get key to-row)))
          (cond
           ((memq key pk-set)
            (push (cons key old-val) pk-fields))
           ((not (equal old-val new-val))
            (push (list key old-val new-val) changed-fields))
           (t
            (push (cons key old-val) other-fields))))))
    ;; Pick up any new columns in to-row not in from-row
    (dolist (pair to-row)
      (unless (assq (car pair) from-row)
        (push (list (car pair) nil (cdr pair)) changed-fields)))
    (setq pk-fields (nreverse pk-fields))
    (setq changed-fields (nreverse changed-fields))
    (setq other-fields (nreverse other-fields))
    ;; Determine how many "other" fields fit.  PK and changed
    ;; fields are always shown; other fields are added only when
    ;; there is enough room to give each at least min-value-width.
    (let* ((n-pk (length pk-fields))
           (n-changed (length changed-fields))
           ;; Compute changed value natural widths (capped)
           (changed-natural
            (mapcar (lambda (triple)
                      (let* ((old-val (nth 1 triple))
                             (new-val (nth 2 triple))
                             (display (concat
                                       (format "%s" (or old-val "∅"))
                                       "→"
                                       (format "%s" (or new-val "∅")))))
                        (min madolt-diff-max-value-width
                             (length display))))
                    changed-fields))
           (changed-total (apply #'+ (or changed-natural '(0))))
           ;; Core overhead: PK keys + changed keys + "=" each +
           ;; changed values + PK min values.  We compute this once
           ;; and incrementally add each "other" field's cost.
           (core-key-cost
            (+ (apply #'+ (or (mapcar (lambda (p)
                                        (length (format "%s" (car p))))
                                      pk-fields)
                              '(0)))
               (apply #'+ (or (mapcar (lambda (tr)
                                        (length (format "%s" (car tr))))
                                      changed-fields)
                              '(0)))))
           (n-core (+ n-pk n-changed))
           (core-fixed (+ core-key-cost n-core))
           (core-values (+ changed-total
                           (* n-pk madolt-diff-min-value-width)))
           ;; Remaining budget after core fields (with separators
           ;; between core fields only)
           (core-seps (* 2 (max 0 (1- n-core))))
           (budget (- max-width core-fixed core-values core-seps))
           ;; Append "other" fields one at a time until there is no
           ;; room to give the next one at least min-value-width.
           (included-others
            (let ((result nil))
              (catch 'done
                (dolist (pair other-fields)
                  ;; Cost of this field: "  " separator + key + "="
                  ;; + min-value-width
                  (let ((cost (+ 2
                                (length (format "%s" (car pair)))
                                1
                                madolt-diff-min-value-width)))
                    (if (>= budget cost)
                        (progn
                          (push pair result)
                          (setq budget (- budget cost)))
                      (throw 'done nil)))))
              (nreverse result))))
      ;; Build final ordered list: PK, changed (with old→new), other
      (let ((ordered nil))
        (dolist (pair pk-fields)
          (push pair ordered))
        (dolist (triple changed-fields)
          (let* ((key (nth 0 triple))
                 (old-val (nth 1 triple))
                 (new-val (nth 2 triple))
                 (display (concat
                           (propertize (format "%s" (or old-val "∅"))
                                      'font-lock-face 'madolt-diff-removed)
                           (propertize "→" 'font-lock-face 'madolt-diff-context)
                           (propertize (format "%s" (or new-val "∅"))
                                      'font-lock-face 'madolt-diff-added))))
            (push (cons key display) ordered)))
        (dolist (pair included-others)
          (push pair ordered))
        (setq ordered (nreverse ordered))
        ;; Width allocation
        (let* ((n-other (length included-others))
               (all-key-lens (mapcar (lambda (p)
                                       (length (format "%s" (car p))))
                                     ordered))
               (fixed-overhead (+ (apply #'+ all-key-lens)
                                  (length ordered)
                                  (* 2 (max 0 (1- (length ordered))))))
               (available (max 1 (- max-width fixed-overhead)))
               (changed-val-lens changed-natural)
               ;; Ensure non-changed fields get at least min-value-width
               (n-nonchanged (+ n-pk n-other))
               (non-changed-min (* n-nonchanged
                                   madolt-diff-min-value-width))
               (changed-budget (max 0 (- available non-changed-min)))
               (changed-total-capped
                (apply #'+ (or changed-val-lens '(0))))
               ;; Shrink changed fields if they exceed budget
               (changed-val-lens
                (if (or (<= changed-total-capped changed-budget)
                        (zerop n-changed))
                    changed-val-lens
                  (let ((scale (/ (float changed-budget)
                                  changed-total-capped)))
                     (mapcar (lambda (w)
                              (max madolt-diff-min-value-width
                                   (floor (* w scale))))
                            changed-val-lens))))
               (changed-total-final
                (apply #'+ (or changed-val-lens '(0))))
               ;; Remaining space for PK + other unchanged fields
               (remaining (max 0 (- available changed-total-final)))
               (non-changed-row (append pk-fields included-others))
               (non-changed-widths
                (when non-changed-row
                  (madolt-diff--compute-value-widths
                   non-changed-row remaining)))
               (pk-widths (seq-take non-changed-widths n-pk))
               (other-widths (seq-drop non-changed-widths n-pk))
               (widths (append pk-widths changed-val-lens other-widths))
               (parts nil)
               (i 0))
          (dolist (pair ordered)
            (let* ((key (format "%s" (car pair)))
                   (val (if (and (>= i n-pk) (< i (+ n-pk n-changed)))
                            (cdr pair)  ; already propertized
                          (format "%s" (cdr pair))))
                   (w (or (nth i widths) (length val)))
                   (tval (madolt-diff--truncate-value val w))
                   (changed-p (and (>= i n-pk)
                                   (< i (+ n-pk n-changed)))))
              (push (concat
                     (propertize key 'font-lock-face 'madolt-diff-column-name)
                     (propertize "=" 'font-lock-face 'madolt-diff-context)
                     (if changed-p
                         tval
                       (propertize tval 'font-lock-face 'madolt-diff-context)))
                    parts))
            (cl-incf i))
          (mapconcat #'identity (nreverse parts) "  "))))))

(defun madolt-diff--truncate-value (value max-len)
  "Truncate VALUE string to MAX-LEN characters, appending \"…\" if needed."
  (if (<= (length value) max-len)
      value
    (concat (substring value 0 (max 0 (1- max-len))) "…")))

(defun madolt-diff--format-field-value (value face value-indent)
  "Format VALUE with FACE for a detail field line.
For single-line values, return the propertized value for inline
display after the field name.  For multi-line values, return a
newline followed by each line indented to VALUE-INDENT and
propertized with FACE."
  (let ((str (format "%s" value)))
    (if (not (string-match-p "\n" str))
        (propertize str 'font-lock-face face)
      (let ((lines (split-string str "\n")))
        (concat "\n"
                (mapconcat
                 (lambda (line)
                   (concat value-indent
                           (propertize line 'font-lock-face face)))
                 lines "\n"))))))

(defun madolt-diff--vec-sum (vec)
  "Return sum of all elements in vector VEC."
  (let ((sum 0))
    (dotimes (i (length vec))
      (setq sum (+ sum (aref vec i))))
    sum))

(defun madolt-diff--vec-max (vec)
  "Return maximum value in vector VEC."
  (let ((m (aref vec 0)))
    (dotimes (i (length vec))
      (when (> (aref vec i) m)
        (setq m (aref vec i))))
    m))

(defun madolt-diff--compute-value-widths (row max-width)
  "Compute per-value display widths for ROW to fit within MAX-WIDTH.
Returns a list of integers, one per field, indicating the max display
width for each value.  Each \"key=value\" contributes (length key) + 1
+ (length value) chars, separated by two spaces between fields.
Shrinks the longest values first, trying to respect
`madolt-diff-min-value-width' but going below it when necessary
to fit all fields."
  (let* ((n (length row))
         (key-lens (mapcar (lambda (pair) (length (format "%s" (car pair)))) row))
         (val-lens (mapcar (lambda (pair) (length (format "%s" (cdr pair)))) row))
         ;; Fixed overhead: each field has "key=" (key-len + 1),
         ;; plus 2-space separators between fields
         (fixed-overhead (+ (apply #'+ key-lens)  ; all key lengths
                            n                      ; one "=" per field
                            (* 2 (max 0 (1- n))))) ; "  " separators
         (available (max 1 (- max-width fixed-overhead)))
         (widths (vconcat val-lens)))
    (if (<= (apply #'+ val-lens) available)
        ;; Everything fits — return original lengths
        val-lens
      ;; Iteratively shrink the longest value(s) to fit.
      ;; Each iteration reduces all max-valued entries to the next
      ;; lower value (or to whatever is needed to hit the budget).
      (let ((floor-width (max 1 madolt-diff-min-value-width)))
        (while (and (> (madolt-diff--vec-sum widths) available)
                    (> (madolt-diff--vec-max widths) floor-width))
          (let* ((max-val (madolt-diff--vec-max widths))
                 (max-count 0)
                 (second-val 0)
                 (sum (madolt-diff--vec-sum widths))
                 (excess (- sum available)))
            ;; Count entries at max-val and find second-largest
            (dotimes (i (length widths))
              (let ((w (aref widths i)))
                (cond ((= w max-val) (cl-incf max-count))
                      ((> w second-val) (setq second-val w)))))
            ;; Compute target: lower max-val entries just enough to
            ;; remove the excess, but no lower than second-val (to keep
            ;; values balanced) — unless that's still too much.
            (let* ((per-item-reduction (ceiling excess max-count))
                   (target (max second-val (- max-val per-item-reduction)))
                   ;; Ensure we make at least 1 char of progress
                   (target (min target (1- max-val)))
                   (target (max floor-width target)))
            (dotimes (i (length widths))
              (when (= (aref widths i) max-val)
                (aset widths i target)))))))
      (append widths nil))))

(defun madolt-diff--format-row-fields (row &optional max-width val-face)
  "Format ROW alist as key=value pairs with per-component faces.
Column names use `madolt-diff-column-name', equals signs use
`madolt-diff-context', and values use VAL-FACE (defaulting to
`madolt-diff-context').
When MAX-WIDTH is non-nil, truncate long values to fit within that
many characters, using \"…\" for truncation."
  (let ((vf (or val-face 'madolt-diff-context)))
    (if (or (null max-width) (null row))
        ;; No width constraint or empty row
        (mapconcat (lambda (pair)
                     (concat
                      (propertize (format "%s" (car pair))
                                  'font-lock-face 'madolt-diff-column-name)
                      (propertize "=" 'font-lock-face 'madolt-diff-context)
                      (propertize (format "%s" (cdr pair))
                                  'font-lock-face vf)))
                   row "  ")
      ;; Width-constrained: compute per-value widths and truncate
      (let* ((widths (madolt-diff--compute-value-widths row max-width))
             (pairs row)
             (parts nil)
             (i 0))
        (while pairs
          (let* ((pair (car pairs))
                 (key (format "%s" (car pair)))
                 (val (format "%s" (cdr pair)))
                 (w (nth i widths))
                 (tval (madolt-diff--truncate-value val w)))
            (push (concat
                   (propertize key 'font-lock-face 'madolt-diff-column-name)
                   (propertize "=" 'font-lock-face 'madolt-diff-context)
                   (propertize tval 'font-lock-face vf))
                  parts))
          (setq pairs (cdr pairs)
                i (1+ i)))
        (mapconcat #'identity (nreverse parts) "  ")))))


(defun madolt-diff--changed-cell-count (from-row to-row)
  "Count cells that differ between FROM-ROW and TO-ROW."
  (let ((count 0))
    (dolist (pair from-row)
      (unless (equal (cdr pair) (alist-get (car pair) to-row))
        (cl-incf count)))
    ;; Also count fields in to-row not in from-row
    (dolist (pair to-row)
      (unless (assq (car pair) from-row)
        (cl-incf count)))
    count))

(defun madolt-diff--insert-row-diff (row-change)
  "Insert a row-diff section for ROW-CHANGE.
The summary line has per-component faces: +/-/~ prefix uses
added/removed colours, column names are bold, values are plain."
  (let* ((change-type (madolt-diff--row-change-type row-change))
         (summary (madolt-diff--row-summary row-change change-type)))
    (magit-insert-section (row-diff row-change)
      (magit-insert-heading
        (concat madolt-diff--indent summary))
      (madolt-diff--insert-row-details row-change change-type))))

(defun madolt-diff--insert-row-details (row-change change-type)
  "Insert expanded detail lines for ROW-CHANGE of CHANGE-TYPE."
  (let ((from-row (alist-get 'from_row row-change))
        (to-row (alist-get 'to_row row-change))
        (detail-indent (concat madolt-diff--indent "    "))
        (value-indent (concat madolt-diff--indent "      ")))
    (pcase change-type
      ('added
       (dolist (pair to-row)
         (insert (format "%s%s:  %s\n"
                         detail-indent
                         (propertize (symbol-name (car pair))
                                     'font-lock-face 'madolt-diff-column-name)
                         (madolt-diff--format-field-value
                          (cdr pair) 'madolt-diff-added value-indent)))))
      ('deleted
       (dolist (pair from-row)
         (insert (format "%s%s:  %s\n"
                         detail-indent
                         (propertize (symbol-name (car pair))
                                     'font-lock-face 'madolt-diff-column-name)
                         (madolt-diff--format-field-value
                          (cdr pair) 'madolt-diff-removed value-indent)))))
      ('modified
       (madolt-diff--insert-modified-details from-row to-row)))))

(defun madolt-diff--insert-modified-details (from-row to-row)
  "Insert cell-by-cell comparison for modified FROM-ROW vs TO-ROW."
  ;; Gather all keys preserving order from from-row, then add new keys
  (let ((keys (mapcar #'car from-row))
        (detail-indent (concat madolt-diff--indent "    "))
        (value-indent (concat madolt-diff--indent "      ")))
    (dolist (pair to-row)
      (unless (memq (car pair) keys)
        (push (car pair) keys)))
    (setq keys (nreverse keys))
    (dolist (key keys)
      (let ((old-val (alist-get key from-row))
            (new-val (alist-get key to-row)))
        (if (equal old-val new-val)
            ;; Unchanged cell
            (insert (format "%s%s:  %s\n"
                            detail-indent
                            (propertize (symbol-name key)
                                        'font-lock-face 'madolt-diff-column-name)
                            (madolt-diff--format-field-value
                             old-val 'madolt-diff-context value-indent)))
          ;; Changed cell
          (let* ((old-str (format "%s" (or old-val "∅")))
                 (new-str (format "%s" (or new-val "∅")))
                 (multiline (or (string-match-p "\n" old-str)
                                (string-match-p "\n" new-str))))
            (if (not multiline)
                (insert (format "%s%s:  %s → %s\n"
                                detail-indent
                                (propertize (symbol-name key)
                                            'font-lock-face 'madolt-diff-changed-cell)
                                (propertize old-str 'font-lock-face 'madolt-diff-old)
                                (propertize new-str 'font-lock-face 'madolt-diff-new)))
              ;; Multi-line changed cell: show old and new on separate
              ;; indented blocks with a separator
              (insert (format "%s%s:\n" detail-indent
                              (propertize (symbol-name key)
                                          'font-lock-face 'madolt-diff-changed-cell)))
              (dolist (line (split-string old-str "\n"))
                (insert (format "%s%s\n" value-indent
                                (propertize line 'font-lock-face 'madolt-diff-old))))
              (insert (format "%s%s\n" value-indent
                              (propertize "→" 'font-lock-face 'madolt-diff-changed-cell)))
              (dolist (line (split-string new-str "\n"))
                (insert (format "%s%s\n" value-indent
                                (propertize line 'font-lock-face 'madolt-diff-new)))))))))
    ))

;;;; Raw mode

(defun madolt-diff--refresh-raw ()
  "Refresh the diff buffer in raw tabular mode."
  (let* ((args (madolt-diff--build-args))
         (output (apply #'madolt-diff-raw args)))
    (magit-insert-section (diff)
      (if (string-empty-p (string-trim output))
          (insert (propertize "No differences\n" 'font-lock-face 'shadow))
        (let ((blocks (madolt-diff--split-raw-tables output)))
          (dolist (block blocks)
            (madolt-diff--insert-raw-table-section block)))))))

(defun madolt-diff--split-raw-tables (output)
  "Split raw diff OUTPUT into per-table blocks.
Return a list of (TABLE-NAME . BODY-TEXT) cons cells."
  (let ((blocks nil)
        (current-name nil)
        (current-lines nil))
    (dolist (line (split-string output "\n"))
      (if (string-match "^diff --dolt a/\\(\\S-+\\) b/\\S-+" line)
          (progn
            ;; Save previous block
            (when current-name
              (push (cons current-name
                          (mapconcat #'identity (nreverse current-lines) "\n"))
                    blocks))
            (setq current-name (match-string 1 line))
            (setq current-lines (list line)))
        (when current-name
          (push line current-lines))))
    ;; Don't forget the last block
    (when current-name
      (push (cons current-name
                  (mapconcat #'identity (nreverse current-lines) "\n"))
            blocks))
    (nreverse blocks)))

(defun madolt-diff--insert-raw-table-section (block)
  "Insert a raw table-diff section for BLOCK.
BLOCK is a cons of (TABLE-NAME . BODY-TEXT)."
  (let* ((name (car block))
         (body (cdr block))
         (lines (split-string body "\n"))
         (total (length lines))
         (limit (or madolt-diff--row-limit madolt-diff-raw-max-lines)))
    (magit-insert-section (table-diff name t)
      (magit-insert-heading
        (propertize (format "Table: %s" name)
                    'font-lock-face 'madolt-diff-table-heading))
      (let ((shown 0))
        (dolist (line lines)
          (when (or (null limit) (< shown limit))
            (insert (madolt-diff--propertize-raw-line line) "\n")
            (cl-incf shown)))
        (when (and limit (> total limit))
          (madolt-insert-show-more-button
           shown total
           'madolt-mode-map 'madolt-diff-double-limit)))
      (insert "\n"))))

(defun madolt-diff--propertize-raw-line (line)
  "Apply face to a raw diff LINE based on its row marker."
  (cond
   ;; diff --dolt header
   ((string-match-p "^diff --dolt " line)
    (propertize line 'font-lock-face 'madolt-diff-table-heading))
   ;; --- a/ and +++ b/ lines
   ((string-match-p "^\\(---\\|\\+\\+\\+\\) " line)
    (propertize line 'font-lock-face 'madolt-diff-table-heading))
   ;; Column header row (| followed by column names, no marker)
   ((string-match-p "^|   |" line)
    (propertize line 'font-lock-face 'madolt-diff-column-header))
   ;; Added row: | + |
   ((string-match-p "^| \\+ |" line)
    (propertize line 'font-lock-face 'madolt-diff-added))
   ;; Deleted row: | - |
   ((string-match-p "^| - |" line)
    (propertize line 'font-lock-face 'madolt-diff-removed))
   ;; Old value of modified row: | < |
   ((string-match-p "^| < |" line)
    (propertize line 'font-lock-face 'madolt-diff-old))
   ;; New value of modified row: | > |
   ((string-match-p "^| > |" line)
    (propertize line 'font-lock-face 'madolt-diff-new))
   ;; Separator lines (+---+...+)
   ((string-match-p "^\\+---\\+" line)
    (propertize line 'font-lock-face 'madolt-diff-context))
   ;; Anything else
   (t line)))

;;;; Inline diff for status buffer

(defun madolt-diff-insert-table (table &optional staged)
  "Insert diff for TABLE at point.
Used by the status buffer's washer to show inline diffs.
When STAGED is non-nil, show the staged diff.
Each row change is a collapsible section: level 3 shows a
one-line summary, TAB expands to level 4 with per-field details.
Binds `madolt-diff--indent' to increase nesting depth since this
content appears under a table heading in the status buffer."
  (let* ((json (if staged
                   (madolt-diff-json "--staged" table)
                 (madolt-diff-json table)))
         (tables (and json (alist-get 'tables json)))
         (madolt-diff--indent "      ")
         (limit (or madolt-diff--row-limit
                    madolt-diff-section-max-rows)))
    (if (null tables)
        (insert (concat madolt-diff--indent "(no changes)\n"))
      (let ((tbl (car tables)))
        (let ((schema-diff (alist-get 'schema_diff tbl))
              (data-diff (alist-get 'data_diff tbl)))
          (when (and schema-diff (not (seq-empty-p schema-diff)))
            (magit-insert-section (schema-diff)
              (magit-insert-heading
                (propertize (concat madolt-diff--indent "Schema changes")
                            'font-lock-face 'madolt-diff-column-header))
              (let ((sql-indent (concat madolt-diff--indent "  ")))
                (dolist (stmt schema-diff)
                  (let ((indented (replace-regexp-in-string
                                   "^" sql-indent stmt)))
                    (insert (propertize (concat indented "\n")
                                        'font-lock-face 'madolt-diff-schema)))))))
          (if (null data-diff)
              (unless (and schema-diff (not (seq-empty-p schema-diff)))
                (insert (concat madolt-diff--indent "(schema change only)\n")))
            (let ((total (length data-diff))
                  (shown 0)
                  (madolt-diff--current-table table))
              (dolist (row-change data-diff)
                (when (or (null limit) (< shown limit))
                  (madolt-diff--insert-row-diff row-change)
                  (cl-incf shown)))
              (when (and limit (> total limit))
                (madolt-insert-show-more-button
                 shown total
                 'madolt-mode-map 'madolt-diff-double-limit
                 madolt-diff--indent)))))))))

;;;; Table name completion

(defun madolt--table-names ()
  "Return a list of table names in the current database.
Parses the output of `dolt ls'."
  (let ((lines (madolt-dolt-lines "ls")))
    ;; Filter out the header line "Tables in working set:"
    (cl-remove-if (lambda (line)
                    (string-match-p "^Tables" line))
                  (mapcar #'string-trim lines))))

(provide 'madolt-diff)
;;; madolt-diff.el ends here
