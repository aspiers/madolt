;;; madolt-connection.el --- SQL connection manager for Madolt  -*- lexical-binding:t -*-

;; Copyright (C) 2026  Adam Spiers

;; Author: Adam Spiers <madolt@adamspiers.org>
;; Maintainer: Adam Spiers <madolt@adamspiers.org>

;; Package-Requires: ((emacs "29.1"))

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

;; SQL connection manager for madolt.  Provides the foundation for
;; sql-server integration, enabling near-zero latency queries via
;; a persistent MySQL-protocol connection to dolt sql-server.
;;
;; Usage is opt-in via `madolt-use-sql-server'.  When enabled,
;; madolt attempts to detect or start a dolt sql-server process
;; and connect via the mysql CLI client.

;;; Code:

(require 'madolt-dolt)
(require 'transient)

;;;; Customization

(defgroup madolt-connection nil
  "SQL connection settings for madolt."
  :group 'madolt)

(define-obsolete-variable-alias 'madolt-sql-server-auto-start
  'madolt-use-sql-server "0.4.0"
  "Use `madolt-use-sql-server' instead.
The auto-start behaviour is now controlled by the value of
`madolt-use-sql-server' directly.")

(defcustom madolt-use-sql-server 'prompt
  "Whether and how to use dolt sql-server for queries.
Using a persistent SQL server is faster than spawning a dolt
subprocess for each command.  Falls back to CLI transparently
if the connection fails.

  prompt          Use a running server if detected, otherwise
                  ask the user whether to start one.
  auto-start      Use a running server if detected, otherwise
                  start one automatically.
  t               Alias for `auto-start'.
  only-if-running Use a running server if detected, but never
                  start one.
  nil             Never use SQL server; always use CLI."
  :group 'madolt-connection
  :type '(choice (const :tag "Prompt to start if needed (recommended)" prompt)
                 (const :tag "Auto-start if needed" auto-start)
                 (const :tag "Only use if already running" only-if-running)
                 (const :tag "Never use SQL server" nil)))

(defcustom madolt-sql-server-host "127.0.0.1"
  "Host for dolt sql-server connection."
  :group 'madolt-connection
  :type 'string)

(defcustom madolt-sql-server-port 3306
  "Port for dolt sql-server connection."
  :group 'madolt-connection
  :type 'integer)

(defcustom madolt-sql-server-user "root"
  "User for dolt sql-server connection."
  :group 'madolt-connection
  :type 'string)

(defcustom madolt-sql-server-password ""
  "Password for dolt sql-server connection.
Empty string means no password."
  :group 'madolt-connection
  :type 'string)

;;;; Connection state

(defvar madolt-connection--process nil
  "The mysql client process for the current SQL connection.")

(defvar madolt-connection--server-process nil
  "The dolt sql-server process if started by madolt.")

(defvar madolt-connection--db-dir nil
  "Database directory for the current connection.")

(defvar madolt-connection--port nil
  "Actual port of the connected sql-server.")

(defvar madolt-connection--output-buffer " *madolt-sql-output*"
  "Buffer name for accumulating SQL query output.")

(defvar madolt-connection--pending-callback nil
  "Callback for the current pending query.")

(defvar madolt-connection--pending-output ""
  "Accumulated output for the current query.")

(defvar madolt-connection--ready nil
  "Non-nil when the connection is ready for queries.")

;;;; Server detection and startup

(defun madolt-connection--detect-server ()
  "Detect a running dolt sql-server for the current database.
Returns a plist (:pid PID :port PORT) or nil."
  (madolt-sql-server-info))

(defun madolt-connection--maybe-start-server ()
  "Possibly start a dolt sql-server based on `madolt-use-sql-server'.
Returns the port number if a server was started, nil otherwise."
  (pcase madolt-use-sql-server
    ((or 't 'auto-start)
     (madolt-connection--start-server))
    ('prompt
     (when (y-or-n-p "No dolt sql-server detected.  Start one? ")
       (madolt-connection--start-server)))
    (_ nil)))

(defun madolt-connection--start-server ()
  "Start a dolt sql-server process in the current database directory.
Returns the port number on success, nil on failure.
Displays an error message if the server fails to start."
  (let* ((port (madolt-connection--find-free-port))
         (buf (get-buffer-create " *madolt-sql-server*"))
         (process (start-process
                   "madolt-sql-server"
                   buf
                   madolt-dolt-executable
                   "sql-server"
                   "-H" madolt-sql-server-host
                   "-P" (number-to-string port))))
    ;; Clear previous output so we can read errors from this attempt.
    (with-current-buffer buf
      (erase-buffer))
    (when process
      (set-process-query-on-exit-flag process nil)
      (setq madolt-connection--server-process process)
      ;; Wait briefly for server to start
      (let ((tries 0))
        (while (and (< tries 30)
                    (process-live-p process)
                    (not (madolt-connection--detect-server)))
          (sleep-for 0.1)
          (cl-incf tries)))
      (if (madolt-connection--detect-server)
          (progn
            (message "Started dolt sql-server on port %d" port)
            port)
        ;; Server failed — extract error message for the user.
        (let ((err (with-current-buffer buf
                     (string-trim
                      (buffer-substring-no-properties
                       (point-min) (point-max))))))
          (when (process-live-p process)
            (delete-process process))
          (setq madolt-connection--server-process nil)
          (message "Failed to start dolt sql-server: %s"
                   (if (string-empty-p err)
                       "server exited with no output"
                     (car (split-string err "\n"))))
          nil)))))

(defun madolt-connection--find-free-port ()
  "Find a free TCP port for the sql-server."
  (let ((proc (make-network-process
               :name "madolt-port-probe"
               :host "127.0.0.1"
               :service 0
               :server t
               :family 'ipv4)))
    (prog1 (process-contact proc :service)
      (delete-process proc))))

;;;; MySQL client connection

(defun madolt-connection--mysql-args (port database)
  "Build mysql CLI arguments for PORT and DATABASE."
  (let ((args (list "--host" madolt-sql-server-host
                    "--port" (number-to-string port)
                    "--user" madolt-sql-server-user
                    "--batch"        ; tab-separated output
                    "--skip-column-names")))
    (unless (string-empty-p madolt-sql-server-password)
      (push (format "--password=%s" madolt-sql-server-password) args))
    (when database
      (setq args (append args (list database))))
    args))

(defun madolt-connection--connect (port database)
  "Connect to dolt sql-server at PORT for DATABASE.
Returns non-nil on success."
  (when madolt-connection--process
    (madolt-connection-disconnect))
  (let* ((args (madolt-connection--mysql-args port database))
         (process (apply #'start-process
                         "madolt-mysql"
                         (get-buffer-create madolt-connection--output-buffer)
                         "mysql"
                         args)))
    (when process
      (set-process-query-on-exit-flag process nil)
      (set-process-sentinel process #'madolt-connection--sentinel)
      (set-process-filter process #'madolt-connection--filter)
      (setq madolt-connection--process process)
      (setq madolt-connection--port port)
      (setq madolt-connection--ready t)
      t)))

(defun madolt-connection--sentinel (_process event)
  "Handle _PROCESS state change EVENT."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (setq madolt-connection--ready nil)
    (setq madolt-connection--process nil)))

(defun madolt-connection--filter (_process output)
  "Accumulate OUTPUT from _PROCESS."
  (setq madolt-connection--pending-output
        (concat madolt-connection--pending-output output)))

;;;; Query execution

(defun madolt-connection-query (sql)
  "Execute SQL query synchronously and return results.
Returns a list of rows, where each row is a list of strings.
Returns nil on error or empty result."
  (unless (madolt-connection-active-p)
    (error "No active SQL connection"))
  (setq madolt-connection--pending-output "")
  (process-send-string madolt-connection--process
                       (concat sql "\n"))
  ;; Wait for complete output (mysql --batch ends output with newline)
  (let ((timeout 10.0)
        (start (float-time)))
    (while (and (< (- (float-time) start) timeout)
                (process-live-p madolt-connection--process)
                (not (madolt-connection--output-complete-p)))
      (accept-process-output madolt-connection--process 0.05)))
  (let ((output madolt-connection--pending-output))
    (setq madolt-connection--pending-output "")
    (madolt-connection--parse-batch-output output)))

(defun madolt-connection--output-complete-p ()
  "Check if the pending output contain a complete result."
  ;; In batch mode, mysql output ends with a newline after the last row.
  ;; We detect completion by checking for a trailing newline after content.
  (and (not (string-empty-p madolt-connection--pending-output))
       (string-suffix-p "\n" madolt-connection--pending-output)))

(defun madolt-connection--parse-batch-output (output)
  "Parse mysql batch OUTPUT into a list of rows.
Each row is a list of column values as strings."
  (when (and output (not (string-empty-p (string-trim output))))
    (let ((lines (split-string (string-trim output) "\n" t)))
      (mapcar (lambda (line)
                (split-string line "\t"))
              lines))))

(defun madolt-connection-query-json (sql)
  "Execute SQL with JSON output format.
Wraps SQL to use dolt's JSON output format via FORMAT='json'."
  (madolt-connection-query
   (format "SELECT * FROM (%s) AS t FORMAT JSON" sql)))

;;;; Connection lifecycle

(defun madolt-connection-setup ()
  "Set up the SQL connection, possibly prompting to start a server.
Call this once at the start of a refresh cycle (e.g. from
`madolt-status-refresh-buffer').  Handles server detection,
user prompting, and auto-starting based on
`madolt-use-sql-server'.  Subsequent commands in the same
refresh should use `madolt-connection-ensure' which never
prompts."
  (when (and madolt-use-sql-server
             (not (madolt-connection-active-p)))
    (let* ((info (madolt-connection--detect-server))
           (port (or (plist-get info :port)
                     (madolt-connection--maybe-start-server))))
      (when port
        (let ((db-name (file-name-nondirectory
                        (directory-file-name
                         (or (madolt-database-dir) default-directory)))))
          (setq madolt-connection--db-dir
                (or (madolt-database-dir) default-directory))
          (madolt-connection--connect port db-name))))))

(defun madolt-connection-ensure ()
  "Ensure an SQL connection is active, establishing one if needed.
Returns non-nil if a connection is active after this call.
Unlike `madolt-connection-setup', this never prompts the user or
starts a server; it only connects to an already-running one."
  (or (madolt-connection-active-p)
      (let* ((info (madolt-connection--detect-server))
             (port (plist-get info :port)))
        (when port
          (let ((db-name (file-name-nondirectory
                          (directory-file-name
                           (or (madolt-database-dir) default-directory)))))
            (setq madolt-connection--db-dir
                  (or (madolt-database-dir) default-directory))
            (madolt-connection--connect port db-name))))))

(defun madolt-connection-active-p ()
  "Return non-nil if the SQL connection is active and ready."
  (and madolt-connection--ready
       madolt-connection--process
       (process-live-p madolt-connection--process)))

(defun madolt-connection-disconnect ()
  "Disconnect from the sql-server."
  (when madolt-connection--process
    (when (process-live-p madolt-connection--process)
      (process-send-string madolt-connection--process "quit\n")
      (sit-for 0.1)
      (when (process-live-p madolt-connection--process)
        (delete-process madolt-connection--process)))
    (setq madolt-connection--process nil)
    (setq madolt-connection--ready nil)))

(defun madolt-connection-shutdown ()
  "Shut down the SQL connection and any server started by madolt."
  (madolt-connection-disconnect)
  (when (and madolt-connection--server-process
             (process-live-p madolt-connection--server-process))
    ;; Send SIGTERM first for graceful shutdown, then wait briefly
    ;; for the process to exit and clean up its info file.
    (signal-process madolt-connection--server-process 'SIGTERM)
    (let ((tries 0))
      (while (and (< tries 20)
                  (process-live-p madolt-connection--server-process))
        (sleep-for 0.1)
        (cl-incf tries)))
    ;; Force kill if it didn't exit gracefully
    (when (process-live-p madolt-connection--server-process)
      (delete-process madolt-connection--server-process))
    ;; Remove stale sql-server.info if dolt didn't clean it up
    (let ((info-file (expand-file-name
                      ".dolt/sql-server.info"
                      (or madolt-connection--db-dir default-directory))))
      (when (file-exists-p info-file)
        (delete-file info-file)))
    (setq madolt-connection--server-process nil)))

;;;; Cleanup hook

(defun madolt-connection--maybe-shutdown ()
  "Shut down SQL connection if no madolt buffers remain.
Added to `kill-buffer-hook' for graceful cleanup."
  (unless (cl-some (lambda (buf)
                     (and (not (eq buf (current-buffer)))
                          (buffer-live-p buf)
                          (with-current-buffer buf
                            (derived-mode-p 'madolt-mode))))
                   (buffer-list))
    (madolt-connection-shutdown)))

;;;; Interactive commands

;;;###autoload
(defun madolt-server-start ()
  "Start a dolt sql-server and connect to it."
  (interactive)
  (when (madolt-connection-active-p)
    (user-error "Already connected to sql-server on port %d"
                madolt-connection--port))
  (let* ((info (madolt-connection--detect-server))
         (port (plist-get info :port)))
    (if port
        ;; Server already running, just connect
        (let ((db-name (file-name-nondirectory
                        (directory-file-name
                         (or (madolt-database-dir) default-directory)))))
          (setq madolt-connection--db-dir
                (or (madolt-database-dir) default-directory))
          (if (madolt-connection--connect port db-name)
              (message "Connected to existing sql-server on port %d" port)
            (message "Failed to connect to sql-server on port %d" port)))
      ;; No server running, start one
      (let ((new-port (madolt-connection--start-server)))
        (if new-port
            (let ((db-name (file-name-nondirectory
                            (directory-file-name
                             (or (madolt-database-dir)
                                 default-directory)))))
              (setq madolt-connection--db-dir
                    (or (madolt-database-dir) default-directory))
              (madolt-connection--connect new-port db-name))
          (message "Failed to start sql-server")))))
  (when (derived-mode-p 'madolt-mode)
    (madolt-refresh)))

;;;###autoload
(defun madolt-server-stop ()
  "Stop the sql-server and disconnect."
  (interactive)
  (if (or madolt-connection--process
          madolt-connection--server-process)
      (progn
        (madolt-connection-shutdown)
        (message "SQL server stopped")
        (when (derived-mode-p 'madolt-mode)
          ;; Suppress connection-setup prompt during this refresh;
          ;; the user just explicitly stopped the server.
          (let ((madolt-use-sql-server nil))
            (madolt-refresh))))
    (message "No sql-server connection to stop")))

;;;###autoload
(defun madolt-server-status ()
  "Display the sql-server connection status."
  (interactive)
  (let ((info (madolt-connection--detect-server)))
    (cond
     ((madolt-connection-active-p)
      (message "Connected to sql-server on port %d (pid %s)"
               madolt-connection--port
               (if madolt-connection--server-process
                   (format "%d, started by madolt"
                           (process-id madolt-connection--server-process))
                 (format "%d" (plist-get info :pid)))))
     (info
      (message "sql-server running on port %d (pid %d) but not connected"
               (plist-get info :port) (plist-get info :pid)))
     (t
      (message "No sql-server running")))))

;;;; Transient menu

;;;###autoload (autoload 'madolt-server "madolt-connection" nil t)
(transient-define-prefix madolt-server ()
  "Manage the dolt sql-server."
  ["SQL Server"
   ("s" "Start / connect" madolt-server-start)
   ("k" "Stop"            madolt-server-stop)
   ("i" "Status"          madolt-server-status)])

(provide 'madolt-connection)
;;; madolt-connection.el ends here
