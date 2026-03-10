;;; madolt-process-tests.el --- Tests for madolt-process.el  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the process execution and logging layer.

;;; Code:

(require 'ert)
(require 'madolt-test-helpers)
(require 'madolt-process)

;;;; Process buffer

(ert-deftest test-madolt-process-buffer-created ()
  "Process buffer is created with correct name pattern."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (should (bufferp buf))
            (should (string-match-p "\\*madolt-process: " (buffer-name buf))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-process-buffer-reused ()
  "Same process buffer is returned on subsequent calls."
  (madolt-with-test-database
    (let ((buf1 (madolt-process-buffer t)))
      (unwind-protect
          (let ((buf2 (madolt-process-buffer t)))
            (should (eq buf1 buf2)))
        (kill-buffer buf1)))))

(ert-deftest test-madolt-process-buffer-per-database ()
  "Different databases get different process buffers."
  (let (buf1 buf2)
    (unwind-protect
        (progn
          (madolt-with-test-database
            (setq buf1 (madolt-process-buffer t))
            ;; Keep a reference; the test-database macro will clean the
            ;; directory but we hold the buffer
            (should (bufferp buf1)))
          (madolt-with-test-database
            (setq buf2 (madolt-process-buffer t))
            (should (bufferp buf2))
            ;; Buffer names should differ (different temp dirs)
            (should-not (equal (buffer-name buf1) (buffer-name buf2)))))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2)))))

(ert-deftest test-madolt-process-mode ()
  "Process buffer uses madolt-process-mode."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (with-current-buffer buf
            (should (derived-mode-p 'madolt-process-mode))
            (should (derived-mode-p 'magit-section-mode)))
        (kill-buffer buf)))))

;;;; madolt-call-dolt

(ert-deftest test-madolt-call-dolt-returns-exit-and-output ()
  "madolt-call-dolt returns (exit-code . output)."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (let ((result (madolt-call-dolt "status")))
            (should (consp result))
            (should (zerop (car result)))
            (should (string-match-p "On branch" (cdr result))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-call-dolt-logs-command ()
  "madolt-call-dolt logs the command string to process buffer."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "status")
            (with-current-buffer buf
              (should (string-match-p "dolt status"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-call-dolt-logs-exit-code ()
  "madolt-call-dolt logs the exit code to process buffer."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "status")
            (with-current-buffer buf
              ;; Exit code is right-justified in 3 chars, e.g. "  0 "
              (should (string-match-p "  0 dolt"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-call-dolt-logs-output ()
  "madolt-call-dolt logs command output to process buffer."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "branch" "--show-current")
            (with-current-buffer buf
              (should (string-match-p "main"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-call-dolt-error-logged ()
  "madolt-call-dolt logs errors for failing commands."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "checkout" "nonexistent-table")
            (with-current-buffer buf
              ;; Should show non-zero exit code, right-justified in 3 chars
              (should (string-match-p "^ *[1-9][0-9]* dolt"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))))
        (kill-buffer buf)))))

;;;; madolt-run-dolt

(ert-deftest test-madolt-run-dolt-calls-refresh ()
  "madolt-run-dolt calls madolt-refresh after command."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t))
          (refresh-called nil))
      (unwind-protect
          (progn
            ;; Mock madolt-refresh since madolt-mode.el isn't loaded yet
            (cl-letf (((symbol-function 'madolt-refresh)
                       (lambda () (setq refresh-called t))))
              (madolt-run-dolt "status"))
            (should refresh-called))
        (kill-buffer buf)))))

(ert-deftest test-madolt-run-dolt-returns-exit-code ()
  "madolt-run-dolt returns the exit code."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (cl-letf (((symbol-function 'madolt-refresh) #'ignore))
            (let ((exit (madolt-run-dolt "status")))
              (should (integerp exit))
              (should (zerop exit))))
        (kill-buffer buf)))))

;;;; Process sections

(ert-deftest test-madolt-process-section-type ()
  "Process entries are magit-sections of type process."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "status")
            (with-current-buffer buf
              ;; Navigate through sections to find a process section
              (goto-char (point-min))
              (let ((found nil))
                (while (and (not found) (not (eobp)))
                  (when-let ((section (magit-current-section)))
                    (when (eq (oref section type) 'process)
                      (setq found t)))
                  (forward-line 1))
                (should found))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-process-multiple-commands ()
  "Multiple commands create multiple sections in the process buffer."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "status")
            (madolt-call-dolt "branch" "--show-current")
            (with-current-buffer buf
              (let ((content (buffer-substring-no-properties
                              (point-min) (point-max))))
                (should (string-match-p "dolt status" content))
                (should (string-match-p "dolt branch" content)))))
        (kill-buffer buf)))))

;;;; Point positioning

(ert-deftest test-madolt-process-goto-last-empty ()
  "Goto-last does nothing in an empty process buffer."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (madolt--process-goto-last)
            ;; No process sections, point should stay where it is
            (should (= (point) (point-min))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-process-goto-last-single ()
  "Goto-last moves point to the only process section."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "status")
            (with-current-buffer buf
              (goto-char (point-min))
              (madolt--process-goto-last)
              ;; Point should be at the start of the process section
              (let ((section (magit-current-section)))
                (should section)
                (should (eq (oref section type) 'process)))))
        (kill-buffer buf)))))

(ert-deftest test-madolt-process-goto-last-multiple ()
  "Goto-last moves point to the last of multiple process sections."
  (madolt-with-test-database
    (let ((buf (madolt-process-buffer t)))
      (unwind-protect
          (progn
            (madolt-call-dolt "status")
            (madolt-call-dolt "branch" "--show-current")
            (with-current-buffer buf
              (goto-char (point-min))
              (madolt--process-goto-last)
              ;; Should be on the last section (branch command)
              (let ((section (magit-current-section)))
                (should section)
                (should (eq (oref section type) 'process))
                ;; The heading should contain the branch command
                (let ((heading (buffer-substring-no-properties
                                (oref section start)
                                (min (+ (oref section start) 80)
                                     (point-max)))))
                  (should (string-match-p "dolt branch" heading))))))
        (kill-buffer buf)))))

;;;; Faces

(ert-deftest test-madolt-process-faces-defined ()
  "Process faces are defined."
  (should (facep 'madolt-process-ok))
  (should (facep 'madolt-process-ng))
  (should (facep 'madolt-process-heading)))

(provide 'madolt-process-tests)
;;; madolt-process-tests.el ends here
