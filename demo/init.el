;; Demo init file for madolt VHS recording
;; Loads madolt and opens status buffer

;; Add madolt to load path
(add-to-list 'load-path (getenv "MADOLT_DIR"))

;; Load straight.el packages for dependencies
(let ((straight-dir (or (getenv "STRAIGHT_DIR")
                        (expand-file-name "~/.emacs.d/straight/build/"))))
  (when (file-directory-p straight-dir)
    (dolist (pkg '("magit-section" "transient" "with-editor" "compat"
                   "dash" "seq" "cond-let" "llama"))
      (let ((pkg-dir (expand-file-name pkg straight-dir)))
        (when (file-directory-p pkg-dir)
          (add-to-list 'load-path pkg-dir))))))

;; Minimal UI settings for a clean demo
(setq inhibit-startup-screen t
      inhibit-startup-message t
      inhibit-startup-echo-area-message (user-login-name)
      initial-scratch-message nil
      ring-bell-function #'ignore
      visible-bell nil)

;; Disable unnecessary UI elements
(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))

;; Use a dark theme that looks good in terminal
(load-theme 'modus-vivendi t)

;; Load madolt
(require 'madolt)

;; Open status buffer after Emacs finishes initializing
;; Use emacs-startup-hook to ensure we have a frame/window
(add-hook 'emacs-startup-hook
          (lambda ()
            (madolt-status (getenv "DEMO_DB"))
            ;; Ensure only the status buffer is visible (full frame)
            (delete-other-windows)
            (let ((buf (get-buffer
                        (format "*madolt-status: %s*"
                                (file-name-nondirectory
                                 (getenv "DEMO_DB"))))))
              (when buf
                (switch-to-buffer buf)))
            (delete-other-windows)))
