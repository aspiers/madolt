;; Demo init file for madolt VHS recording
;; Loads madolt and opens status buffer

;; Add madolt to load path
(add-to-list 'load-path (getenv "MADOLT_DIR"))

;; Load straight.el packages for dependencies
(let ((straight-dir (or (getenv "STRAIGHT_DIR")
                        (expand-file-name "~/.emacs.d/straight/build/"))))
  (when (file-directory-p straight-dir)
    (dolist (pkg '("magit-section" "transient" "with-editor" "compat"
                   "dash" "seq" "cond-let" "llama" "keycast"))
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

;; Use catppuccin mocha theme (cloned by launch.sh)
(let ((catppuccin-dir (getenv "CATPPUCCIN_DIR")))
  (when (and catppuccin-dir (file-directory-p catppuccin-dir))
    (add-to-list 'load-path catppuccin-dir)
    (add-to-list 'custom-theme-load-path catppuccin-dir)
    (setq catppuccin-flavor 'mocha)
    (load-theme 'catppuccin t)))

;; Load madolt
(require 'madolt)



;; Display madolt buffers in the same window (full-frame).
;; The default falls back to display-buffer which splits.
;; TODO: add a proper madolt-display-buffer-function defcustom.
(defun madolt-display-buffer (buffer)
  "Display BUFFER in the current window."
  (let ((window (display-buffer buffer '(display-buffer-same-window))))
    (when window
      (select-window window))))

;; Enable keycast to show keystrokes in the mode line during the demo
(require 'keycast)
(keycast-mode-line-mode 1)
;; Make keycast key face high-contrast for the recording
(set-face-attribute 'keycast-key nil
                    :foreground "#1e1e2e"
                    :background "#f5c2e7"
                    :weight 'bold
                    :box '(:line-width -3 :style released-button))
(set-face-attribute 'keycast-command nil
                    :foreground "#cdd6f4"
                    :weight 'bold)

;; Open status buffer after Emacs finishes initializing
;; Use emacs-startup-hook to ensure we have a frame/window
(add-hook 'emacs-startup-hook
          (lambda ()
            (madolt-status (getenv "DEMO_DB"))
            ;; Ensure only the status buffer is visible (full frame)
            (delete-other-windows)
            (let ((buf (get-buffer
                        (format "madolt-status: %s"
                                (file-name-nondirectory
                                 (getenv "DEMO_DB"))))))
              (when buf
                (switch-to-buffer buf)))
            (delete-other-windows)))
