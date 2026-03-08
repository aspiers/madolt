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

(defface madolt-diff-column-name
  '((t :weight bold))
  "Face for column names in row diff summaries."
  :group 'madolt-faces)

(defface madolt-diff-column-value
  '((t :inherit default))
  "Face for column values in row diff summaries."
  :group 'madolt-faces)

(defface madolt-diff-table-heading
  '((t :weight bold :height 1.1))
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
  '((t :inherit shadow))
  "Face for unchanged context in diffs."
  :group 'madolt-faces)

;;;; Indentation

(defvar madolt-diff--indent "  "
  "Current indentation prefix for row-diff and schema sections.
Dynamically bound to increase nesting depth when inserting
diffs inside an already-indented context (e.g. status buffer).")

;;;; Truncation

(defcustom madolt-diff-min-value-width 15
  "Minimum display width for truncated field values in row-diff summaries.
Values shorter than this will not be truncated further when fitting
row-diff summary lines to the window width."
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
  "Show diff of unstaged changes.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-diff)))
  (madolt-diff--show-buffer args nil nil nil nil))

(defun madolt-diff-staged (&optional args)
  "Show diff of staged changes.
ARGS are additional arguments from the transient."
  (interactive (list (transient-args 'madolt-diff)))
  (madolt-diff--show-buffer args nil nil nil t))

(defun madolt-diff-commits (rev-a rev-b &optional args)
  "Show diff between two revisions REV-A and REV-B.
ARGS are additional arguments from the transient."
  (interactive
   (list (read-string "From revision: ")
         (read-string "To revision: ")
         (transient-args 'madolt-diff)))
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

;;;; Buffer setup

(defun madolt-diff--show-buffer (args revisions table raw-mode staged)
  "Set up and display a diff buffer.
ARGS is the list of transient arguments.
REVISIONS is a cons (REV-A . REV-B) or nil.
TABLE is a single table name or nil.
RAW-MODE is non-nil for raw tabular display.
STAGED is non-nil for showing staged changes."
  (let* ((db-dir (or (madolt-database-dir)
                     (user-error "Not in a Dolt database")))
         (buf-name (madolt--buffer-name 'madolt-diff-mode db-dir))
         (buffer (or (get-buffer buf-name)
                     (generate-new-buffer buf-name))))
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
      (madolt-refresh))
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

(defun madolt-diff--insert-table-diff (table-data)
  "Insert a table-diff section for TABLE-DATA.
TABLE-DATA is an alist from the JSON `tables' array."
  (let ((name (alist-get 'name table-data))
        (schema-diff (alist-get 'schema_diff table-data))
        (data-diff (alist-get 'data_diff table-data)))
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
      ;; Data changes
      (when data-diff
        (dolist (row-change data-diff)
          (madolt-diff--insert-row-diff row-change)))
      (insert "\n"))))

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
       (let ((fields (madolt-diff--format-row-fields to-row fields-width)))
         (concat (propertize "+" 'font-lock-face 'madolt-diff-added)
                 " " fields)))
      ('deleted
       (let ((fields (madolt-diff--format-row-fields from-row fields-width)))
         (concat (propertize "-" 'font-lock-face 'madolt-diff-removed)
                 " " fields)))
      ('modified
       (let* ((changed (madolt-diff--changed-cell-count from-row to-row))
              (suffix (format " (%d cell%s changed)"
                              changed (if (= changed 1) "" "s")))
              (pk-width (- fields-width (length suffix)))
              (pk-fields (madolt-diff--pk-summary from-row to-row pk-width)))
         (concat (propertize "~" 'font-lock-face 'madolt-diff-old)
                 " " pk-fields suffix))))))

(defun madolt-diff--truncate-value (value max-len)
  "Truncate VALUE string to MAX-LEN characters, appending \"…\" if needed."
  (if (<= (length value) max-len)
      value
    (concat (substring value 0 (max 0 (1- max-len))) "…")))

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
      (while (> (madolt-diff--vec-sum widths) available)
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
                 (target (max 1 target)))
            (dotimes (i (length widths))
              (when (= (aref widths i) max-val)
                (aset widths i target))))))
      (append widths nil))))

(defun madolt-diff--format-row-fields (row &optional max-width)
  "Format ROW alist as key=value pairs with per-component faces.
Column names are bold, values use `madolt-diff-column-value',
and equals signs match column name style without bold.
When MAX-WIDTH is non-nil, truncate long values to fit within that
many characters, using \"…\" for truncation."
  (if (or (null max-width) (null row))
      ;; No width constraint or empty row
      (mapconcat (lambda (pair)
                   (concat
                    (propertize (format "%s" (car pair))
                                'font-lock-face 'madolt-diff-column-name)
                    (propertize "=" 'font-lock-face 'default)
                    (propertize (format "%s" (cdr pair))
                                'font-lock-face 'madolt-diff-column-value)))
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
                 (propertize "=" 'font-lock-face 'default)
                 (propertize tval 'font-lock-face 'madolt-diff-column-value))
                parts))
        (setq pairs (cdr pairs)
              i (1+ i)))
      (mapconcat #'identity (nreverse parts) "  "))))

(defun madolt-diff--pk-summary (from-row to-row &optional max-width)
  "Return a summary of primary key fields from FROM-ROW and TO-ROW.
Uses fields that are the same in both rows (assumed to be PK).
Column names are bold, values use `madolt-diff-column-value'.
When MAX-WIDTH is non-nil, truncate long values to fit."
  (let ((pk-row nil))
    (dolist (pair from-row)
      (let ((key (car pair))
            (val (cdr pair)))
        (when (equal val (alist-get key to-row))
          (push pair pk-row))))
    (if pk-row
        (madolt-diff--format-row-fields (nreverse pk-row) max-width)
      ;; Fallback: show first field from from-row
      (if from-row
          (madolt-diff--format-row-fields (list (car from-row)) max-width)
        "?"))))

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
        (detail-indent (concat madolt-diff--indent "    ")))
    (pcase change-type
      ('added
       (dolist (pair to-row)
         (insert (format "%s%s:  %s\n"
                         detail-indent
                         (propertize (symbol-name (car pair))
                                     'font-lock-face 'madolt-diff-column-name)
                         (propertize (format "%s" (cdr pair))
                                     'font-lock-face 'madolt-diff-added)))))
      ('deleted
       (dolist (pair from-row)
         (insert (format "%s%s:  %s\n"
                         detail-indent
                         (propertize (symbol-name (car pair))
                                     'font-lock-face 'madolt-diff-column-name)
                         (propertize (format "%s" (cdr pair))
                                     'font-lock-face 'madolt-diff-removed)))))
      ('modified
       (madolt-diff--insert-modified-details from-row to-row)))))

(defun madolt-diff--insert-modified-details (from-row to-row)
  "Insert cell-by-cell comparison for modified FROM-ROW vs TO-ROW."
  ;; Gather all keys preserving order from from-row, then add new keys
  (let ((keys (mapcar #'car from-row))
        (detail-indent (concat madolt-diff--indent "    ")))
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
                            (propertize (format "%s" old-val)
                                        'font-lock-face 'madolt-diff-context)))
          ;; Changed cell
          (insert (format "%s%s:  %s → %s\n"
                          detail-indent
                          (propertize (symbol-name key)
                                      'font-lock-face 'madolt-diff-changed-cell)
                          (propertize (format "%s" (or old-val "∅"))
                                      'font-lock-face 'madolt-diff-old)
                          (propertize (format "%s" (or new-val "∅"))
                                      'font-lock-face 'madolt-diff-new))))))))

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
  (let ((name (car block))
        (body (cdr block)))
    (magit-insert-section (table-diff name t)
      (magit-insert-heading
        (propertize (format "Table: %s" name)
                    'font-lock-face 'madolt-diff-table-heading))
      (dolist (line (split-string body "\n"))
        (insert (madolt-diff--propertize-raw-line line) "\n"))
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
         (madolt-diff--indent "      "))
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
            (dolist (row-change data-diff)
              (madolt-diff--insert-row-diff row-change))))))))

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
