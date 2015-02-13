;;; simplenote.el --- Interact with simple-note.appspot.com

;; Copyright (C) 2009, 2010 Konstantinos Efstathiou <konstantinos@efstathiou.gr>

;; Author: Konstantinos Efstathiou <konstantinos@efstathiou.gr>
;; Keywords: simplenote
;; Version: 1.0

;; This program is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation; either version 2 of the License, or (at your option) any later
;; version.

;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
;; details.

;; You should have received a copy of the GNU General Public License along with
;; this program; if not, write to the Free Software Foundation, Inc., 51
;; Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.


;;; Code:



(require 'cl)
(require 'url)
(require 'json)
(require 'widget)
(require 'request-deferred)

(defcustom simplenote-directory (expand-file-name "~/.simplenote2/")
  "Simplenote directory."
  :type 'directory
  :safe 'stringp
  :group 'simplenote)

(defcustom simplenote-email nil
  "Simplenote account email."
  :type 'string
  :safe 'stringp
  :group 'simplenote)

(defcustom simplenote-password nil
  "Simplenote account password."
  :type 'string
  :safe 'stringp
  :group 'simplenote)

(defcustom simplenote-notes-mode 'text-mode
  "The mode used for editing notes opened from Simplenote.

Since notes do not have file extensions, the default mode must be
set via this option.  Individual notes can override this setting
via the usual `-*- mode: text -*-' header line."
  :type 'function
  :group 'simplenote)

(defcustom simplenote-note-head-size 78
  "Length of note headline in the notes list."
  :type 'integer
  :safe 'integerp
  :group 'simplenote)

(defcustom simplenote-show-note-file-name t
  "Show file name for each note in the note list."
  :type 'boolean
  :safe 'booleanp
  :group 'simplenote)

(defvar simplenote-mode-hook nil)

(put 'simplenote-mode 'mode-class 'special)

(defvar simplenote2-server-url "https://simple-note.appspot.com/")

(defvar simplenote-email-was-read-interactively nil)
(defvar simplenote-password-was-read-interactively nil)

(defvar simplenote2-token nil)

(defvar simplenote2-notes-info (make-hash-table :test 'equal))

(defvar simplenote2-filename-for-notes-info
  (concat (file-name-as-directory simplenote-directory) ".notes-info.el"))


;;; Unitity functions

(defun simplenote-file-mtime (path)
  (nth 5 (file-attributes path)))

(defun simplenote-parse-gmt-time (header-str)
  (apply 'encode-time (append (butlast (parse-time-string header-str)) (list "GMT"))))

(defun simplenote2-get-file-string (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun simplenote2-tag-existp (tag array)
  "Returns t if there is a string named TAG in array ARRAY, otherwise nil"
  (loop for i from 0 below (length array)
        thereis (string= tag (aref array i))))


;;; Save/Load notes information file

(defconst simplenote2-save-file-header
  ";;; Automatically generated by `simplenote2' on %s.\n"
  "Header to be written into the `simplenote2-save-notes-info'.")

(defun simplenote2-dump-variable (variable &optional limit)
  (let ((value (symbol-value variable)))
    (if (atom value)
        (insert (format "\n(setq %S '%S)\n" variable value))
      (when (and (integerp limit) (> limit 0))
        (setq value (recentf-trunc-list value limit)))
      (insert (format "\n(setq %S\n      '(" variable))
      (dolist (e value)
        (insert (format "\n        %S" e)))
      (insert "\n        ))\n"))))

(defun simplenote2-save-notes-info ()
  (condition-case error
      (with-temp-buffer
        (erase-buffer)
        (insert (format simplenote2-save-file-header (current-time-string)))
        (recentf-dump-variable 'simplenote2-notes-info)
        (write-file simplenote2-filename-for-notes-info)
        nil)
    (error (warn "Simplenote2: %s" (error-message-string error)))))

(defun simplenote2-load-notes-info ()
  (when (file-readable-p simplenote2-filename-for-notes-info)
    (load-file simplenote2-filename-for-notes-info)))

(defun simplenote2-save-note (key note)
  "Save note information and content gotten from server."
  (let ((systemtags (cdr (assq 'systemtags note)))
        (createdate (string-to-number (cdr (assq 'createdate note))))
        (modifydate (string-to-number (cdr (assq 'modifydate note))))
        (content (cdr (assq 'content note))))
    ;; Save note information to 'simplenote2-notes-info
    (puthash key (list (cdr (assq 'key note))
                       (cdr (assq 'version note))
                       createdate
                       modifydate
                       (cdr (assq 'tags note))
                       (simplenote2-tag-existp "markdown" systemtags)
                       (simplenote2-tag-existp "pinned" systemtags)
                       nil)
             simplenote2-notes-info)
    ;; Write note content to local file
    ;; "content" may not be returned from server in the case process is "update"
    ;; but content isn't changed
    (when content
      (let ((file (simplenote-filename-for-note key))
            (text (decode-coding-string content 'utf-8)))
        (write-region text nil file nil)
        (set-file-times file (seconds-to-time modifydate))))))


;;; Simplenote authentication

(defun simplenote-email ()
  (when (not simplenote-email)
    (setq simplenote-email (read-string "Simplenote email: "))
    (setq simplenote-email-was-read-interactively t))
  simplenote-email)

(defun simplenote-password ()
  (when (not simplenote-password)
    (setq simplenote-password (read-passwd "Simplenote password: "))
    (setq simplenote-password-was-read-interactively t))
  simplenote-password)

(defun simplenote2-get-token-deferred ()
  "Returns simplenote token wrapped with deferred object.

This function returns cached token if it's cached to 'simplenote2-token,\
 otherwise gets token from server using 'simplenote-email and 'simplenote-password\
 and cache it."
  (if simplenote2-token
      (deferred:next (lambda () simplenote2-token))
    (deferred:$
      (request-deferred
       (concat simplenote2-server-url "api/login")
       :type "POST"
       :data (base64-encode-string
              (format "email=%s&password=%s"
                      (url-hexify-string (simplenote-email))
                      (url-hexify-string (simplenote-password))))
       :parser 'buffer-string)
      (deferred:nextc it
        (lambda (res)
          (if (request-response-error-thrown res)
              (progn
                (if simplenote-email-was-read-interactively
                    (setq simplenote-email nil))
                (if simplenote-password-was-read-interactively
                    (setq simplenote-password nil))
                (setq simplenote2-token nil)
                (error "Simplenote authentication failed"))
            (message "Simplenote authentication succeeded")
            (setq simplenote2-token (request-response-data res))))))))


;;; API calls for index and notes

(defun simplenote2-get-index-deferred ()
  "Get note index from server and returns the list of note index.

Each element of the list consists of (KEY . MODIFY) where KEY is the note key as string \
and MODIFY is the modified date as time object.
Notes marked as deleted are not included in the list."
  (deferred:$
    (simplenote2-get-token-deferred)
    (deferred:nextc it
      (lambda (token)
        (deferred:$
          (request-deferred
           (concat simplenote2-server-url "api/index")
           :type "GET"
           :params (list (cons "auth" token)
                         (cons "email" simplenote-email))
           :parser 'json-read)
          (deferred:nextc it
            (lambda (res)
              (if (request-response-error-thrown res)
                  (error "Could not retrieve index")
                (let (index)
                  (mapc (lambda (e)
                          (unless (eq (cdr (assq 'deleted e)) t)
                            (push (cons (cdr (assq 'key e))
                                        (simplenote-parse-gmt-time
                                         (cdr (assq 'modify e))))
                                  index)))
                        (request-response-data res))
                  index)))))))))

(defun simplenote2-get-note-deferred (key)
  (lexical-let ((key key))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api2/data/" key)
             :type "GET"
             :params (list (cons "auth" token)
                           (cons "email" simplenote-email))
             :parser 'json-read)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (message "Could not retreive note %s" key)
                  (simplenote2-save-note key (request-response-data res)))
                key))))))))

(defun simplenote2-mark-note-as-deleted-deferred (key)
  (lexical-let ((key key))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api/delete")
             :type "GET"
             :params (list (cons "key" key)
                           (cons "auth" token)
                           (cons "email" simplenote-email))
             :parser 'buffer-string)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (progn (message "Could not delete note %s" key) nil)
                  (request-response-data res))))))))))

(defun simplenote2-update-note-deferred (key)
  (lexical-let ((key key)
                (note-info (gethash key simplenote2-notes-info)))
    (unless note-info
      (error "Could not find note info"))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api2/data/" (nth 0 note-info))
             :type "POST"
             :params (list (cons "auth" token)
                           (cons "email" simplenote-email))
             :data (json-encode
                    (list (cons "content" (simplenote2-get-file-string
                                           (simplenote-filename-for-note key)))
                          (cons "version" (number-to-string (nth 1 note-info)))
                          (cons "modifydate"
                                (format "%.6f"
                                        (time-to-seconds
                                         (simplenote-file-mtime
                                          (simplenote-filename-for-note key)))))))
             :headers '(("Content-Type" . "application/json"))
             :parser 'json-read)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (progn (message "Could not update note %s" key) nil)
                  (simplenote2-save-note key (request-response-data res))
                  key)))))))))

(defun simplenote2-create-note-deferred (content &optional createdate)
  (lexical-let ((content content)
                (createdate createdate))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (let ((params (list (cons "auth" token)
                              (cons "email" simplenote-email))))
            (when createdate
              (let ((date-string (format-time-string "%Y-%m-%d %H:%M:%S" createdate t)))
                (setq params (append params (list (cons "create" date-string)
                                                  (cons "modify" date-string))))))
            (deferred:$
              (request-deferred
               (concat simplenote2-server-url "api/note")
               :type "POST"
               :params params
               :data (base64-encode-string (encode-coding-string content 'utf-8 t))
               :parser 'buffer-string)
              (deferred:nextc it
                (lambda (res)
                  (if (request-response-error-thrown res)
                      (progn (message "Could not create note") nil)
                    (simplenote2-get-note-deferred (request-response-data res))))))))))))


;;; Push and pull buffer as note

(defun simplenote2-push-buffer-deferred ()
  (interactive)
  (lexical-let ((file (buffer-file-name))
                (buf (current-buffer)))
    (cond
     ;; File is located on new notes directory
     ((string-match (simplenote-new-notes-dir)
                    (file-name-directory file))
      (save-buffer)
      (deferred:$
        (simplenote2-create-note-deferred (buffer-string)
                                          (simplenote-file-mtime file))
        (deferred:nextc it
          (lambda (key)
            (when key
              (simplenote-open-note (simplenote-filename-for-note key))
              (delete-file file)
              (kill-buffer buf)
              (simplenote-browser-refresh))))))
     ;; File is located on notes directory
     ((string-match (simplenote-notes-dir)
                    (file-name-directory file))
      (lexical-let* ((key (file-name-nondirectory file))
                     (note-info (gethash key simplenote2-notes-info)))
        (save-buffer)
        (if (and note-info
                 (time-less-p (seconds-to-time (nth 3 note-info))
                              (simplenote-file-mtime file)))
            (deferred:$
              (simplenote2-update-note-deferred key)
              (deferred:nextc it
                (lambda (ret)
                  (if ret (progn
                            (message "Pushed note %s" key)
                            (when (eq buf (current-buffer))
                                  (revert-buffer nil t t))
                            (simplenote-browser-refresh))
                    (message "Failed to push note %s" key)))))
          (message "No need to push this note"))))
     (t (message "Can't push buffer which isn't simplenote note")))))

;;;###autoload
(defun simplenote2-create-note-from-buffer ()
  (interactive)
  (lexical-let ((file (buffer-file-name))
                (buf (current-buffer)))
    (if (or (string= (simplenote-notes-dir) (file-name-directory file))
            (not file))
        (message "Can't create note from this buffer")
      (save-buffer)
      (deferred:$
        (simplenote2-create-note-deferred (simplenote2-get-file-string file)
                                          (simplenote-file-mtime file))
        (deferred:nextc it
          (lambda (key)
            (if (not key)
                (message "Failed to create note")
              (message "Created note %s" key)
              (simplenote-open-note (simplenote-filename-for-note key))
              (delete-file file)
              (kill-buffer buf)
              (simplenote-browser-refresh))))))))

(defun simplenote2-pull-buffer-deferred ()
  (interactive)
  (lexical-let ((file (buffer-file-name))
                (buf (current-buffer)))
    (if (string= (simplenote-notes-dir) (file-name-directory file))
        (lexical-let* ((key (file-name-nondirectory file))
                       (note-info (gethash key simplenote2-notes-info)))
          (if (and note-info
                   (time-less-p (seconds-to-time (nth 3 note-info))
                                (simplenote-file-mtime file))
                   (y-or-n-p
                    "This note appears to have been modified. Do you push it on ahead?"))
              (simplenote2-push-buffer-deferred)
            (save-buffer)
            (deferred:$
              (simplenote2-get-note-deferred key)
              (deferred:nextc it
                (lambda (ret)
                  (when (eq buf (current-buffer))
                    (revert-buffer nil t t)))
                (simplenote-browser-refresh)))))
      (message "Can't pull buffer which isn't simplenote note"))))


;;; Browser helper functions

(defun simplenote-trash-dir ()
  (file-name-as-directory (concat (file-name-as-directory simplenote-directory) "trash")))

(defun simplenote-notes-dir ()
  (file-name-as-directory (concat (file-name-as-directory simplenote-directory) "notes")))

(defun simplenote-new-notes-dir ()
  (file-name-as-directory (concat (file-name-as-directory simplenote-directory) "new")))

;;;###autoload
(defun simplenote-setup ()
  (interactive)
  (simplenote2-load-notes-info)
  (when (not (file-exists-p simplenote-directory))
    (make-directory simplenote-directory t))
  (when (not (file-exists-p (simplenote-notes-dir)))
    (make-directory (simplenote-notes-dir) t))
  (when (not (file-exists-p (simplenote-trash-dir)))
    (make-directory (simplenote-trash-dir) t))
  (when (not (file-exists-p (simplenote-new-notes-dir)))
    (make-directory (simplenote-new-notes-dir) t)))

(defun simplenote-filename-for-note (key)
  (concat (simplenote-notes-dir) key))

(defun simplenote-filename-for-note-marked-deleted (key)
  (concat (simplenote-trash-dir) key))

(defun simplenote-note-headline (text)
  "The first non-empty line of a note."
  (let ((begin (string-match "^.+$" text)))
    (when begin
      (substring text begin (min (match-end 0)
                                 (+ begin simplenote-note-head-size))))))

(defun simplenote-note-headrest (text)
  "Text after the first non-empty line of a note, to fill in the list display."
  (let* ((headline (simplenote-note-headline text))
         (text (replace-regexp-in-string "\n" " " text))
         (begin (when headline (string-match (regexp-quote headline) text))))
    (when begin
      (truncate-string-to-width (substring text (match-end 0)) (- simplenote-note-head-size (string-width headline))))))

(defun simplenote-open-note (file)
  "Opens FILE in a new buffer, setting its mode, and returns the buffer.

The major mode of the resulting buffer will be set to
`simplenote-notes-mode' but can be overridden by a file-local
setting."
  (prog1 (find-file file)
    ;; Don't switch mode when set via file cookie
    (when (eq major-mode (default-value 'major-mode))
      (funcall simplenote-notes-mode))
    ;; Refresh notes display after save
    (add-hook 'after-save-hook
              (lambda () (save-excursion (simplenote-browser-refresh)))
              nil t)))


;; Simplenote sync

(defun simplenote-sync-notes ()
  (interactive)
  (deferred:$
    ;; Step1: Sync update on local
    (deferred:parallel
      (list
       ;; Step1-1: Delete notes locally marked as deleted.
       (deferred:$
         (deferred:parallel
           (mapcar (lambda (file)
                     (lexical-let* ((file file)
                                    (key (file-name-nondirectory file)))
                       (deferred:$
                         (simplenote2-mark-note-as-deleted-deferred key)
                         (deferred:nextc it
                           (lambda (ret) (when (string= ret key)
                                           (message "Deleted on local: %s" key)
                                           (remhash key simplenote2-notes-info)
                                           (delete-file file)))))))
                   (directory-files (simplenote-trash-dir) t "^[a-zA-Z0-9_\\-]+$")))
         (deferred:nextc it (lambda () nil)))
       ;; Step1-2: Push notes locally created
       (deferred:$
          (deferred:parallel
            (mapcar (lambda (file)
                      (lexical-let ((file file))
                        (deferred:$
                          (simplenote2-create-note-deferred (simplenote2-get-file-string file)
                                                            (simplenote-file-mtime file))
                          (deferred:nextc it
                            (lambda (key) (when key
                                            (message "Created on local: %s" key)
                                            (delete-file file)))))))
                    (directory-files (simplenote-new-notes-dir) t "^note-[0-9]+$")))
          (deferred:nextc it (lambda () nil)))
       ;; Step1-3: Push notes locally modified
       (deferred:$
         (let (keys-to-push)
           (dolist (file (directory-files
                          (simplenote-notes-dir) t "^[a-zA-Z0-9_\\-]+$"))
             (let* ((key (file-name-nondirectory file))
                    (note-info (gethash key simplenote2-notes-info)))
               (when (and note-info
                          (time-less-p (seconds-to-time (nth 3 note-info))
                                       (simplenote-file-mtime file)))
                 (push key keys-to-push))))
           (deferred:$
             (deferred:parallel
               (mapcar (lambda (key)
                         (deferred:$
                           (simplenote2-update-note-deferred key)
                           (deferred:nextc it
                             (lambda (ret) (when (eq ret key)
                                             (message "Updated on local: %s" key))))))
                       keys-to-push))
             (deferred:nextc it (lambda () nil)))))))
    ;; Step2: Sync update on server
    (deferred:nextc it
      (lambda ()
        ;; Step2-1: Get index from server and update local files.
        (deferred:$
          (simplenote2-get-index-deferred)
          (deferred:nextc it
            (lambda (index)
              ;; Step4-1: Delete notes on local which are not included in the index.
              (let ((keys-in-index (mapcar (lambda (e) (car e)) index)))
                (dolist (file (directory-files
                               (simplenote-notes-dir) t "^[a-zA-Z0-9_\\-]+$"))
                  (let ((key (file-name-nondirectory file)))
                    (unless (member key keys-in-index)
                      (message "Deleted on server: %s" key)
                      (remhash key simplenote2-notes-info)
                      (delete-file (simplenote-filename-for-note key))))))
              ;; Step2-2: Update notes on local which are older than that on server.
              (let (keys-to-update)
                (dolist (elem index)
                  (let* ((key (car elem))
                         (note-info (gethash key simplenote2-notes-info)))
                    ;; Compare modifydate on server and local data.
                    ;; If the note information isn't found, the note would be a
                    ;; newly created note on server.
                    (when (time-less-p
                           (seconds-to-time (if note-info (nth 3 note-info) 0))
                           (cdr elem))
                      (message "Updated on server: %s" key)
                      (push key keys-to-update))))
                (deferred:$
                  (deferred:parallel
                    (mapcar (lambda (key) (simplenote2-get-note-deferred key))
                            keys-to-update))
                  (deferred:nextc it
                    (lambda (notes)
                      (message "Syncing all notes done")
                      (simplenote2-save-notes-info)
                      ;; Refresh the browser
                      (save-excursion
                        (simplenote-browser-refresh)))))))))))))


;;; Simplenote browser

(defvar simplenote-mode-map
  (let ((map (copy-keymap widget-keymap)))
    (define-key map (kbd "g") 'simplenote-sync-notes)
    (define-key map (kbd "q") 'quit-window)
    map))

(defun simplenote-mode ()
  "Browse and edit Simplenote notes locally and sync with the server.

\\{simplenote-mode-map}"
  (kill-all-local-variables)
  (setq buffer-read-only t)
  (use-local-map simplenote-mode-map)
  (simplenote-menu-setup)
  (setq major-mode 'simplenote-mode
        mode-name "Simplenote")
  (run-mode-hooks 'simplenote-mode-hook))

;;;###autoload
(defun simplenote-browse ()
  (interactive)
  (when (not (file-exists-p simplenote-directory))
      (make-directory simplenote-directory t))
  (switch-to-buffer "*Simplenote*")
  (simplenote-mode)
  (goto-char 1))

(defun simplenote-browser-refresh ()
  (interactive)
  (when (get-buffer "*Simplenote*")
    (set-buffer "*Simplenote*")
    (simplenote-menu-setup)))


(defun simplenote-menu-setup ()
  (let ((inhibit-read-only t))
    (erase-buffer))
  (remove-overlays)
  ;; Buttons
  (widget-create 'link
                 :format "%[%v%]"
                 :help-echo "Synchronize with the Simplenote server"
                 :notify (lambda (widget &rest ignore)
                           (simplenote-sync-notes)
                           (simplenote-browser-refresh))
                 "Sync with server")
  (widget-insert "  ")
  (widget-create 'link
                 :format "%[%v%]"
                 :help-echo "Create a new note"
                 :notify (lambda (widget &rest ignore)
                           (let (buf)
                             (setq buf (simplenote-create-note-locally))
                             (simplenote-browser-refresh)
                             (switch-to-buffer buf)))
                 "Create new note")
  (widget-insert "\n\n")
  ;; New notes list
  (let ((new-notes (directory-files (simplenote-new-notes-dir) t "^note-[0-9]+$")))
    (when new-notes
      (widget-insert "== NEW NOTES\n\n")
      (mapc 'simplenote-new-note-widget new-notes)))
  ;; Other notes list
  (let (files)
    (setq files (append
                 (mapcar '(lambda (file) (cons file nil))
                         (directory-files (simplenote-notes-dir) t "^[a-zA-Z0-9_\\-]+$"))
                 (mapcar '(lambda (file) (cons file t))
                         (directory-files (simplenote-trash-dir) t "^[a-zA-Z0-9_\\-]+$"))))
    (when files
      (setq files (sort files '(lambda (p1 p2) (simplenote-file-newer-p (car p1) (car p2)))))
      (widget-insert "== NOTES\n\n")
      (mapc 'simplenote-other-note-widget files)))
  (use-local-map simplenote-mode-map)
  (widget-setup))

(defun simplenote-file-newer-p (file1 file2)
  (let (time1 time2)
    (setq time1 (nth 5 (file-attributes file1)))
    (setq time2 (nth 5 (file-attributes file2)))
    (time-less-p time2 time1)))

(defun simplenote-new-note-widget (file)
  (let* ((modify (nth 5 (file-attributes file)))
         (modify-string (format-time-string "%Y-%m-%d %H:%M:%S" modify))
         (note (simplenote2-get-file-string file))
         (headline (simplenote-note-headline note))
         (shorttext (simplenote-note-headrest note)))
    (widget-create 'link
                   :button-prefix ""
                   :button-suffix ""
                   :format "%[%v%]"
                   :tag file
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote-open-note (widget-get widget :tag)))
                   headline)
    (widget-insert shorttext "\n")
    (widget-insert "  " modify-string "\t                                      \t")
    (widget-create 'link
                   :tag file
                   :value "Edit"
                   :format "%[%v%]"
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote-open-note (widget-get widget :tag)))
                    "Edit")
    (widget-insert " ")
    (widget-create 'link
                   :format "%[%v%]"
                   :tag file
                   :help-echo "Permanently remove this file"
                   :notify (lambda (widget &rest ignore)
                             (delete-file (widget-get widget :tag))
                             (simplenote-browser-refresh))
                   "Remove")
    (widget-insert "\n\n")))

(defun simplenote-other-note-widget (pair)
  (let* ((file (car pair))
         (deleted (cdr pair))
         (key (file-name-nondirectory file))
         (modify (nth 5 (file-attributes file)))
         (modify-string (format-time-string "%Y-%m-%d %H:%M:%S" modify))
         (note (simplenote2-get-file-string file))
         (headline (simplenote-note-headline note))
         (shorttext (simplenote-note-headrest note)))
    (widget-create 'link
                   :button-prefix ""
                   :button-suffix ""
                   :format "%[%v%]"
                   :tag file
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote-open-note (widget-get widget :tag)))
                   headline)
    (widget-insert shorttext "\n")
    (if simplenote-show-note-file-name
      (widget-insert "  " modify-string "\t" (propertize key 'face 'shadow) "\t")
      (widget-insert "  " modify-string "\t"))
    (widget-create 'link
                   :tag file
                   :value "Edit"
                   :format "%[%v%]"
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote-open-note (widget-get widget :tag)))
                    "Edit")
    (widget-insert " ")
    (widget-create 'link
                   :format "%[%v%]"
                   :tag key
                   :help-echo (if deleted
                                  "Mark this note as not deleted"
                                "Mark this note as deleted")
                   :notify (if deleted
                               simplenote-undelete-me
                             simplenote-delete-me)
                   (if deleted
                       "Undelete"
                     "Delete"))
    (widget-insert "\n\n")))

(setq simplenote-delete-me
      (lambda (widget &rest ignore)
        (simplenote-mark-note-for-deletion (widget-get widget :tag))
        (widget-put widget :notify simplenote-undelete-me)
        (widget-value-set widget "Undelete")
        (widget-setup)))

(setq simplenote-undelete-me
  (lambda (widget &rest ignore)
    (simplenote-unmark-note-for-deletion (widget-get widget :tag))
    (widget-put widget :notify simplenote-delete-me)
    (widget-value-set widget "Delete")
    (widget-setup)))

(defun simplenote-mark-note-for-deletion (key)
  (rename-file (simplenote-filename-for-note key)
               (simplenote-filename-for-note-marked-deleted key)))

(defun simplenote-unmark-note-for-deletion (key)
  (rename-file (simplenote-filename-for-note-marked-deleted key)
               (simplenote-filename-for-note key)))

(defun simplenote-create-note-locally ()
  (let (new-filename counter)
    (setq counter 0)
    (setq new-filename (concat (simplenote-new-notes-dir) (format "note-%d" counter)))
    (while (file-exists-p new-filename)
      (setq counter (1+ counter))
      (setq new-filename (concat (simplenote-new-notes-dir) (format "note-%d" counter))))
    (write-region "New note" nil new-filename nil)
    (simplenote-browser-refresh)
    (simplenote-open-note new-filename)))


(provide 'simplenote)

;;; simplenote.el ends here
