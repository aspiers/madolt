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

(require 'cl-lib)
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

(defcustom madolt-sql-server-port 0
  "Port for dolt sql-server connection.
When zero, a free port is chosen automatically."
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

(defvar madolt-connection--refresh-errors nil
  "List of error messages accumulated during the current refresh.
Bound dynamically by `madolt-refresh' to collect errors without
showing each one individually.  A summary is shown after refresh.")

(defun madolt-connection--log-buffer-name ()
  "Return the SQL log buffer name for the current database."
  (let ((db (file-name-nondirectory
             (directory-file-name
              (or (madolt-database-dir) default-directory)))))
    (format " *madolt-sql-log: %s*" db)))

(defun madolt-connection--log (user-message &optional detail)
  "Log USER-MESSAGE and optional DETAIL to the per-database SQL log buffer.
During a refresh cycle (when `madolt-connection--refresh-errors'
is bound), the message is accumulated for a single summary at
the end rather than shown immediately.  Outside refresh, the
message is shown in the minibuffer."
  (let ((buf (get-buffer-create (madolt-connection--log-buffer-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "[%H:%M:%S] ")
                user-message
                (if detail (concat "\n  " detail) "")
                "\n"))))
  (if (boundp 'madolt-connection--refresh-errors)
      (cl-pushnew user-message madolt-connection--refresh-errors
                  :test #'equal)
    (message "%s" user-message)))

(defvar madolt-connection--declined (make-hash-table :test 'equal)
  "Hash table of database directories where the user declined sql-server.
Keyed by `file-truename' of the database directory.  Suppresses
further prompts for that database until the user explicitly starts
a server via `madolt-server-start'.")

(defun madolt-connection--db-key ()
  "Return a canonical key for the current database directory."
  (file-truename (or (madolt-database-dir) default-directory)))

(defun madolt-connection--declined-p ()
  "Return non-nil if the user declined sql-server for the current database."
  (gethash (madolt-connection--db-key) madolt-connection--declined))

(defun madolt-connection--set-declined (value)
  "Set the declined state for the current database to VALUE."
  (if value
      (puthash (madolt-connection--db-key) t madolt-connection--declined)
    (remhash (madolt-connection--db-key) madolt-connection--declined)))

;;;; Connection state

(cl-defstruct (madolt-connection (:constructor madolt-connection--make))
  "Per-database SQL connection state."
  (process nil :documentation "The mysql client process.")
  (server-process nil :documentation "The dolt sql-server process if started by madolt.")
  (port nil :documentation "Actual port of the connected sql-server.")
  (pending-output "" :documentation "Accumulated output for the current query.")
  (ready nil :documentation "Non-nil when the connection is ready for queries."))

(defvar madolt-connection--connections (make-hash-table :test 'equal)
  "Hash table mapping database directory keys to `madolt-connection' structs.")

(defun madolt-connection--get ()
  "Return the connection struct for the current database, or nil."
  (gethash (madolt-connection--db-key) madolt-connection--connections))

(defun madolt-connection--get-or-create ()
  "Return the connection struct for the current database, creating if needed."
  (let ((key (madolt-connection--db-key)))
    (or (gethash key madolt-connection--connections)
        (puthash key (madolt-connection--make) madolt-connection--connections))))

;; Legacy variable aliases for code that hasn't been updated yet.
;; These will be removed once all code uses the struct accessors.
(defvar madolt-connection--output-buffer " *madolt-sql-output*"
  "Buffer name for accumulating SQL query output.")

;;;; Server detection and startup

(defun madolt-connection--detect-server ()
  "Detect a running dolt sql-server for the current database.
Returns a plist (:pid PID :port PORT) or nil."
  (madolt-sql-server-info))

(defun madolt-connection--maybe-start-server ()
  "Possibly start a dolt sql-server based on `madolt-use-sql-server'.
Returns the port number if a server was started, nil otherwise.
When the user declines the prompt, record the decision in
`madolt-connection--declined' to suppress further prompts for
this database."
  (pcase madolt-use-sql-server
    ((or 't 'auto-start)
     (madolt-connection--start-server))
    ('prompt
     (if (y-or-n-p "No dolt sql-server detected.  Start one? ")
         (madolt-connection--start-server)
       (madolt-connection--set-declined t)
       (let ((server-key (where-is-internal 'madolt-server nil t)))
         (run-at-time
          0 nil
          (lambda (k)
            (message "Will use dolt CLI.  Start a server any time with %s."
                     (if k
                         (concat (key-description k) " s")
                       "M-x madolt-server-start")))
          server-key))
       nil))
    (_ nil)))

(defun madolt-connection--start-server ()
  "Start a dolt sql-server process in the current database directory.
Returns the port number on success, nil on failure.
Displays an error message if the server fails to start.
Uses `madolt-sql-server-port' if non-zero, otherwise finds a free port."
  (madolt-connection--start-server-on-port
   (if (and madolt-sql-server-port (> madolt-sql-server-port 0))
       madolt-sql-server-port
     (madolt-connection--find-free-port))))

(defun madolt-connection--start-server-on-port (port)
  "Start a dolt sql-server on PORT.
Returns the port number on success, nil on failure.
Displays an error message if the server fails to start."
  (let* ((port port)
         (conn (madolt-connection--get-or-create))
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
      (setf (madolt-connection-server-process conn) process)
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
        ;; Server failed.
        (let ((err (with-current-buffer buf
                     (string-trim
                      (buffer-substring-no-properties
                       (point-min) (point-max))))))
          (when (process-live-p process)
            (delete-process process))
          (setf (madolt-connection-server-process conn) nil)
          (madolt-connection--log
           "Failed to start sql-server"
           (if (string-empty-p err)
               "server exited with no output"
             err))
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
  (let ((conn (madolt-connection--get-or-create)))
    (when (madolt-connection-process conn)
      (madolt-connection-disconnect))
    (let* ((key (madolt-connection--db-key))
           (args (madolt-connection--mysql-args port database))
           (process (apply #'start-process
                           "madolt-mysql"
                           (get-buffer-create
                            madolt-connection--output-buffer)
                           "mysql"
                           args)))
      (when process
        (set-process-query-on-exit-flag process nil)
        ;; Store db-key on the process so filter/sentinel can find
        ;; the right connection struct.
        (process-put process :madolt-db-key key)
        (set-process-sentinel process #'madolt-connection--sentinel)
        (set-process-filter process #'madolt-connection--filter)
        (setf (madolt-connection-process conn) process)
        (setf (madolt-connection-port conn) port)
        (setf (madolt-connection-ready conn) t)
        ;; Validate the connection with a test query.  If it fails
        ;; (e.g. auth error, wrong database), disconnect immediately
        ;; rather than leaving a broken connection that times out
        ;; on every subsequent query.
        (condition-case err
            (progn
              (madolt-connection-query "SELECT 1")
              t)
          (error
           (madolt-connection--log
            "SQL connection failed; using CLI"
            (format "connect %s:%d: %s"
                    madolt-sql-server-host port
                    (error-message-string err)))
           (madolt-connection-disconnect)
           nil))))))

(defun madolt-connection--sentinel (process event)
  "Handle PROCESS state change EVENT."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (when-let ((key (process-get process :madolt-db-key))
               (conn (gethash key madolt-connection--connections)))
      (setf (madolt-connection-ready conn) nil)
      (setf (madolt-connection-process conn) nil))))

(defun madolt-connection--filter (process output)
  "Accumulate OUTPUT from PROCESS, stripping warning lines.
Lines starting with \"WARNING:\" or \"ERROR \" are removed from
the query output and surfaced as Emacs warnings instead."
  (when-let ((key (process-get process :madolt-db-key))
             (conn (gethash key madolt-connection--connections)))
    (let ((lines (split-string output "\n"))
          (clean nil))
      (dolist (line lines)
        (cond
         ((string-match-p "\\`\\(WARNING\\|ERROR\\) " line)
          (madolt-connection--log "mysql warning" line))
         (t (push line clean))))
      (let ((filtered (string-join (nreverse clean) "\n")))
        (setf (madolt-connection-pending-output conn)
              (concat (madolt-connection-pending-output conn)
                      filtered))))))

;;;; Query execution

(defun madolt-connection-query (sql &optional timeout)
  "Execute SQL query synchronously and return results.
Returns a list of rows, where each row is a list of strings.
Returns nil on error or empty result.
TIMEOUT is the maximum seconds to wait (default 5)."
  (unless (madolt-connection-active-p)
    (error "No active SQL connection"))
  (let ((conn (madolt-connection--get)))
    ;; Drain any late-arriving output from a previous query
    (setf (madolt-connection-pending-output conn) "")
    (accept-process-output (madolt-connection-process conn) 0.01)
    (setf (madolt-connection-pending-output conn) "")
    (process-send-string (madolt-connection-process conn)
                         (concat sql ";\n"))
    ;; Wait for complete output (mysql --batch ends output with newline)
    (let ((timeout (or timeout 5.0))
          (start (float-time)))
      (while (and (< (- (float-time) start) timeout)
                  (process-live-p (madolt-connection-process conn))
                  (not (madolt-connection--output-complete-p conn)))
        (accept-process-output (madolt-connection-process conn) 0.05))
      (unless (madolt-connection--output-complete-p conn)
        ;; Connection is broken — disconnect so subsequent queries
        ;; fall back to CLI immediately instead of timing out again.
        (setf (madolt-connection-pending-output conn) "")
        (madolt-connection-disconnect)
        (madolt-connection--log
         "SQL query timed out; falling back to CLI"
         (format "query: %s" sql))
        (error "SQL query timed out")))
    (let ((output (madolt-connection-pending-output conn)))
      (setf (madolt-connection-pending-output conn) "")
      (madolt-connection--parse-batch-output output))))

(defun madolt-connection--output-complete-p (conn)
  "Check if CONN has complete output from the current query."
  ;; In batch mode, mysql output ends with a newline after the last row.
  (let ((output (madolt-connection-pending-output conn)))
    (and (not (string-empty-p output))
         (string-suffix-p "\n" output))))

(defun madolt-connection--parse-batch-output (output)
  "Parse mysql batch OUTPUT into a list of rows.
Each row is a list of column values as strings.
Only trailing newlines are stripped; leading whitespace is preserved
to avoid losing empty column values (e.g. empty hash from DOLT_MERGE)."
  (when (and output (not (string-empty-p (string-trim-right output))))
    (let ((lines (split-string (string-trim-right output) "\n" t)))
      (mapcar (lambda (line)
                (split-string line "\t"))
              lines))))

(defun madolt-connection-query-json (sql)
  "Execute SQL with JSON output format.
Wraps SQL to use dolt's JSON output format via FORMAT='json'."
  (madolt-connection-query
   (format "SELECT * FROM (%s) AS t FORMAT JSON" sql)))

;;;; Connection lifecycle

(defun madolt-connection--db-name ()
  "Return the database name for the current directory."
  (file-name-nondirectory
   (directory-file-name
    (or (madolt-database-dir) default-directory))))

(defun madolt-connection-setup ()
  "Set up the SQL connection, possibly prompting to start a server.
Call this once at the start of a refresh cycle (e.g. from
`madolt-status-refresh-buffer').  Handles server detection,
user prompting, and auto-starting based on
`madolt-use-sql-server'.  Subsequent commands in the same
refresh should use `madolt-connection-ensure' which never
prompts."
  (when (and madolt-use-sql-server
             (not (madolt-connection--declined-p))
             (not (madolt-connection-active-p)))
    (let* ((info (madolt-connection--detect-server))
           (port (or (plist-get info :port)
                     (madolt-connection--maybe-start-server))))
      (when port
        (madolt-connection--connect port (madolt-connection--db-name))))))

(defun madolt-connection-ensure ()
  "Ensure an SQL connection is active, establishing one if needed.
Returns non-nil if a connection is active after this call.
Unlike `madolt-connection-setup', this never prompts the user or
starts a server; it only connects to an already-running one."
  (or (madolt-connection-active-p)
      (let* ((info (madolt-connection--detect-server))
             (port (plist-get info :port)))
        (when port
          (madolt-connection--connect port (madolt-connection--db-name))))))

(defun madolt-connection-active-p ()
  "Return non-nil if the SQL connection is active for the current database."
  (when-let ((conn (madolt-connection--get)))
    (and (madolt-connection-ready conn)
         (madolt-connection-process conn)
         (process-live-p (madolt-connection-process conn)))))

(defun madolt-connection-disconnect ()
  "Disconnect the mysql client for the current database."
  (when-let ((conn (madolt-connection--get)))
    (let ((proc (madolt-connection-process conn)))
      (when proc
        (when (process-live-p proc)
          (process-send-string proc "quit\n")
          (sit-for 0.1)
          (when (process-live-p proc)
            (delete-process proc)))
        (setf (madolt-connection-process conn) nil)
        (setf (madolt-connection-ready conn) nil)))))

(defun madolt-connection-shutdown ()
  "Shut down the SQL connection and server for the current database."
  (madolt-connection-disconnect)
  (when-let ((conn (madolt-connection--get)))
    (let ((server (madolt-connection-server-process conn)))
      (when (and server (process-live-p server))
        ;; Send SIGTERM first for graceful shutdown.
        (signal-process server 'SIGTERM)
        (let ((tries 0))
          (while (and (< tries 20) (process-live-p server))
            (sleep-for 0.1)
            (cl-incf tries)))
        ;; Force kill if it didn't exit gracefully.
        (when (process-live-p server)
          (delete-process server))
        ;; Remove stale sql-server.info if dolt didn't clean it up.
        (let ((db-dir (or (madolt-database-dir) default-directory)))
          (let ((info-file (expand-file-name
                            ".dolt/sql-server.info" db-dir)))
            (when (file-exists-p info-file)
              (delete-file info-file)))))
      (setf (madolt-connection-server-process conn) nil))))

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
    ;; Shut down all connections.
    (maphash (lambda (_key conn)
               (let ((proc (madolt-connection-process conn)))
                 (when (and proc (process-live-p proc))
                   (delete-process proc)))
               (let ((server (madolt-connection-server-process conn)))
                 (when (and server (process-live-p server))
                   (delete-process server))))
             madolt-connection--connections)
    (clrhash madolt-connection--connections)))

;;;; Interactive commands

;;;###autoload
(defun madolt-server-start ()
  "Start a dolt sql-server and connect to it."
  (interactive)
  (madolt-connection--set-declined nil)
  (when (madolt-connection-active-p)
    (let ((conn (madolt-connection--get)))
      (user-error "Already connected to sql-server on port %d"
                  (madolt-connection-port conn))))
  (let* ((info (madolt-connection--detect-server))
         (port (plist-get info :port)))
    (if port
        (if (madolt-connection--connect port (madolt-connection--db-name))
            (message "Connected to existing sql-server on port %d" port)
          (message "Failed to connect to sql-server on port %d" port))
      (let ((new-port (madolt-connection--start-server)))
        (if new-port
            (madolt-connection--connect
             new-port (madolt-connection--db-name))
          (message "Failed to start sql-server")))))
  (when (derived-mode-p 'madolt-mode)
    (madolt-refresh)))

;;;###autoload
(defun madolt-server-stop ()
  "Stop the sql-server and disconnect.
If the server was started by madolt, stop it immediately.
If it was started externally, prompt for confirmation first."
  (interactive)
  (let ((conn (madolt-connection--get))
        (info (madolt-connection--detect-server)))
    (cond
     ;; We started this server — stop without prompting
     ((and conn (madolt-connection-server-process conn))
      (madolt-connection-shutdown)
      (madolt-connection--set-declined t)
      (message "SQL server stopped")
      (when (derived-mode-p 'madolt-mode)
        (madolt-refresh)))
     ;; We have a client connection but didn't start the server
     ((and conn (madolt-connection-process conn))
      (madolt-connection-disconnect)
      (if (and info
               (y-or-n-p
                (format "Kill external sql-server (pid %d, port %d)? "
                        (plist-get info :pid) (plist-get info :port))))
          (progn
            (signal-process (plist-get info :pid) 'SIGTERM)
            (message "Sent SIGTERM to sql-server pid %d"
                     (plist-get info :pid)))
        (message "Disconnected client; server still running"))
      (madolt-connection--set-declined t)
      (when (derived-mode-p 'madolt-mode)
        (madolt-refresh)))
     ;; No connection but a server is detected
     (info
      (if (y-or-n-p
           (format "Kill external sql-server (pid %d, port %d)? "
                   (plist-get info :pid) (plist-get info :port)))
          (progn
            (signal-process (plist-get info :pid) 'SIGTERM)
            (madolt-connection--set-declined t)
            (message "Sent SIGTERM to sql-server pid %d"
                     (plist-get info :pid))
            (when (derived-mode-p 'madolt-mode)
              (madolt-refresh)))
        (message "Server left running")))
     (t
      (message "No sql-server connection to stop")))))

;;;###autoload
(defun madolt-server-status ()
  "Display the sql-server connection status."
  (interactive)
  (let ((conn (madolt-connection--get))
        (info (madolt-connection--detect-server)))
    (cond
     ((madolt-connection-active-p)
      (message "Connected to sql-server on %s:%d (pid %s)"
               madolt-sql-server-host
               (madolt-connection-port conn)
               (if (madolt-connection-server-process conn)
                   (format "%d, started by madolt"
                           (process-id
                            (madolt-connection-server-process conn)))
                 (format "%d" (plist-get info :pid)))))
     (info
      (message "sql-server running on %s:%d (pid %d) but not connected"
               madolt-sql-server-host
               (plist-get info :port) (plist-get info :pid)))
     (t
      (message "No sql-server running")))))

(define-derived-mode madolt-sql-log-mode special-mode "Madolt SQL Log"
  "Mode for the madolt SQL connection log buffer.")

;;;###autoload
(defun madolt-server-log ()
  "Display the SQL connection log for the current database."
  (interactive)
  (let ((buf (get-buffer (madolt-connection--log-buffer-name))))
    (if buf
        (progn
          (pop-to-buffer buf)
          (unless (derived-mode-p 'madolt-sql-log-mode)
            (madolt-sql-log-mode))
          (goto-char (point-max))
          (forward-line -1))
      (message "No SQL log entries yet"))))

;;;; Transient menu

(defun madolt-server--current-port ()
  "Return the port of the active connection, or the configured default."
  (let ((conn (madolt-connection--get)))
    (if (and conn (madolt-connection-active-p))
        (madolt-connection-port conn)
      madolt-sql-server-port)))

(defun madolt-server--set-port (port)
  "Set the server PORT, restarting if necessary.
If a server is running on a different port, prompt to restart."
  (let ((conn (madolt-connection--get))
        (new-port (if (stringp port) (string-to-number port) port)))
    (cond
     ;; No active connection — just update the setting
     ((not (and conn (madolt-connection-active-p)))
      (setq madolt-sql-server-port new-port)
      (message "Server port set to %d" new-port))
     ;; Same port — nothing to do
     ((= new-port (madolt-connection-port conn))
      (message "Already using port %d" new-port))
     ;; Different port while running — prompt to restart
     ((y-or-n-p (format "Restart server on port %d? " new-port))
      (setq madolt-sql-server-port new-port)
      (madolt-connection-shutdown)
      (let ((started-port (madolt-connection--start-server-on-port new-port)))
        (when started-port
          (madolt-connection--connect
           started-port (madolt-connection--db-name))
          (when (derived-mode-p 'madolt-mode)
            (madolt-refresh)))))
     ;; User declined restart — keep current port
     (t
      (message "Keeping port %d" (madolt-connection-port conn))))))

(transient-define-infix madolt-server-port-infix ()
  "Set the sql-server port."
  :class 'transient-lisp-variable
  :variable 'madolt-sql-server-port
  :reader (lambda (_prompt _initial-input _history)
            (let* ((current (madolt-server--current-port))
                   (input (read-number "Port: " current)))
              (madolt-server--set-port input)
              input)))

;;;###autoload (autoload 'madolt-server "madolt-connection" nil t)
(transient-define-prefix madolt-server ()
  "Manage the dolt sql-server."
  ["SQL Server"
   [("s" "Start / connect" madolt-server-start)
    ("k" "Stop"            madolt-server-stop)
    ("i" "Status"          madolt-server-status)
    ("l" "View log"        madolt-server-log)]
   [("-p" "Port" madolt-server-port-infix)]])

(provide 'madolt-connection)
;;; madolt-connection.el ends here
