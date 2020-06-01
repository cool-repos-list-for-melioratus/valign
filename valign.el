;;; valign.el --- Visually align tables      -*- lexical-binding: t; -*-

;; Author: Yuan Fu <casouri@gmail.com>
;; URL: https://github.com/casouri/valign
;; Version: 0.1.0
;; Keywords: convenience
;; Package-Requires: ((emacs "26.0"))

;;; This file is NOT part of GNU Emacs

;;; Commentary:
;;
;; This package provides visual alignment for Org tables on GUI Emacs.
;; It can properly align tables containing variable-pitch font, CJK
;; characters and images.  In the meantime, the text-based alignment
;; generated by Org mode is left untouched.
;;
;; To use this package, load it and run M-x valign-mode RET.  And any
;; Org tables in Org mode should be automatically aligned.  If you want
;; to align a table manually, run M-x valign-table RET on a Org table.
;;
;; Valign provides two styles of separator, |-----|-----|, and
;; |           |.  Customize ‘valign-separator-row-style’ to set a
;; style.

;;; Code:
;;

(require 'cl-lib)
(require 'pcase)

(defcustom valign-lighter " valign"
  "The lighter string used by function `valign-mode'."
  :group 'valign
  :type 'string)

;;; Backstage

(define-error 'valign-bad-cell "Valign encountered a invalid table cell")
(define-error 'valign-werid-alignment
  "Valign expects one space between the cell’s content and either the left bar or the right bar, but this cell seems to violate that assumption")

(cl-defmethod valign--cell-alignment ((type (eql org-mode)) hint)
  "Return how is current cell aligned.
Return 'left if aligned left, 'right if aligned right.
Assumes point is after the left bar (“|”).
Doesn’t check if we are in a cell.
TYPE must be 'org-mode.  HINT is not used."
  (ignore type hint)
  (save-excursion
    (if (looking-at " [^ ]")
        'left
      (if (not (search-forward "|" nil t))
          (signal 'valign-bad-cell nil)
        (if (looking-back
             "[^ ] |" (max (- (point) 3) (point-min)))
            'right
          (signal 'valign-werid-alignment nil))))))

(cl-defmethod valign--cell-alignment ((type (eql markdown-mode)) hint)
  "Return how is current cell aligned.
Return 'left if aligned left, 'right if aligned right.
Assumes point is after the left bar (“|”).
Doesn’t check if we are in a cell.
TYPE must be 'markdown-mode.  Simply return HINT."
  (ignore type)
  hint)

(cl-defmethod valign--cell-alignment ((type (eql gfm-mode)) hint)
  "Return how is current cell aligned.
Return 'left if aligned left, 'right if aligned right.
Assumes point is after the left bar (“|”).
Doesn’t check if we are in a cell.
TYPE must be 'markdown-mode.  Simply return HINT."
  (ignore type)
  (valign--cell-alignment 'markdown-mode hint))

;; (if (string-match (rx (seq (* " ")
;;                            ;; e.g., “5.”, “5.4”
;;                            (or (seq (? (or "-" "+"))
;;                                     (+ digit)
;;                                     (? "\\.")
;;                                     (* digit))
;;                                ;; e.g., “.5”
;;                                (seq (? (or "-" "+"))
;;                                     "\\."
;;                                     (* digit)))
;;                            (* " ")))
;;                   (buffer-substring p (1- (point))))
;;     'right 'left)

(defun valign--cell-width ()
  "Return the pixel width of the cell at point.
Assumes point is after the left bar (“|”).
Return nil if not in a cell."
  (let (start)
    (save-excursion
      (valign--skip-space-forward)
      (setq start (point))
      (if (not (search-forward "|" nil t))
          (signal 'valign-bad-cell nil)
        ;; We are at the right “|”
        (backward-char)
        (valign--skip-space-backward)
        (valign--pixel-width-from-to start (point))))))

;; (defun valign--font-at (p)
;;   (find-font
;;    (font-spec
;;     :name (face-font (get-text-property (point) 'face)
;;                      nil
;;                      (char-after)))))

(defun valign--glyph-width-at-point (&optional point)
  "Return the pixel width of the glyph at POINT.
The buffer has to be visible.  If point is at an image, this
function doens’t return the image’s width, but the underlining
character’s glyph width."
  (let* ((p (or point (point))))
    ;; car + mapcar to translate the vector to a list.
    (aref (car (mapcar
                #'identity (font-get-glyphs
                            ;; (font-at 0 nil (buffer-substring p (1+
                            ;; p))) doesn’t work, the font is
                            ;; sometimes wrong.  (font-at p) doesn’t
                            ;; work, because it requires the buffer to
                            ;; be visible.
                            (font-at p)
                            p (1+ p))))
          4)))

(defun valign--pixel-width-from-to (from to)
  "Return the width of the glyphs from FROM (inclusive) to TO (exclusive).
The buffer has to be visible.  FROM has to be less than TO.  Unlike
‘valign--glyph-width-at-point’, this function can properly
calculate images pixel width."
  (let ((width 0))
    (save-excursion
      (goto-char from)
      (while (< (point) to)
        (let ((display (plist-get (text-properties-at (point))
                                  'display)))
          ;; 1) This is an overlay or text property image, add image
          ;; width.
          (cond ((and (setq ;; Overlay image?
                       display (or (cl-loop for ov in (overlays-at (point) t)
                                            if (overlay-get ov 'display)
                                            return (overlay-get ov 'display)
                                            finally return nil)
                                   ;; Text property image?
                                   (plist-get (text-properties-at (point))
                                              'display)))
                      (consp display)
                      (eq (car display) 'image))
                 (progn
                   (setq width (+ width (car (image-size display t))))
                   (goto-char
                    (next-single-property-change (point) 'display nil to))))
                ;; 2) Invisible text.  If text is hidden under ellipses,
                ;; (outline fold) treat it as non-invisible.
                ((eq (invisible-p (point)) t)
                 (goto-char
                  (next-single-property-change (point) 'invisible nil to)))
                ;; 3) This is a normal character, add glyph width.
                (t (setq width (+ width (valign--glyph-width-at-point)))
                   (goto-char (1+ (point))))))))
    width))

(defun valign--skip-space-backward ()
  "Like (skip-chars-forward \" \").
But we don’t skip over chars with display property."
  (while (and (eq (char-before) ?\s)
              (let ((display
                     (plist-get (text-properties-at (1- (point)))
                                'display)))
                ;; When do we stop: when there is a display property
                ;; and it’s not a stretch property.
                (not (and display
                          (consp display)
                          (not (eq (car display) 'space))))))
    (backward-char)))

(defun valign--skip-space-forward ()
  "Like (skip-chars-backward \" \").
But we don’t skip over chars with display property."
  (while (and (eq (char-after) ?\s)
              (let ((display
                     (plist-get (text-properties-at (point))
                                'display)))
                ;; When do we stop: when there is a display property
                ;; and it’s not a stretch property.
                (not (and display
                          (consp display)
                          (not (eq (car display) 'space))))))
    (forward-char)))

(defun valign--sperator-p ()
  "If the current cell is actually a separator.
Assume point is after the left bar (“|”)."
  (or (eq (char-after) ?:) ;; Markdown tables.
      (eq (char-after) ?-)))

(defun valign--alignment-from-seperator ()
  "Return the alignment of this column.
Assumes point is after the left bar (“|”) of a separator
cell.  We don’t distinguish between left and center aligned."
  (save-excursion
    (if (eq (char-after) ?:)
        'left
      (skip-chars-forward "-")
      (if (eq (char-after) ?:)
          'right
        'left))))

(defmacro valign--do-table (column-idx-sym limit &rest body)
  "Go to each cell of a table and evaluate BODY.
In each cell point stops after the left “|”.
Bind COLUMN-IDX-SYM to the column index (0-based).
Don’t go over LIMIT."
  (declare (indent 2))
  `(progn
     (setq ,column-idx-sym -1)
     (while (and (cl-incf ,column-idx-sym)
                 (search-forward "|" nil t)
                 (< (point) ,limit))
       (if (looking-at "[^|]*\n")
           ;; We are after the last “|” of a line.
           (setq ,column-idx-sym -1)
         ;; Point is after the left “|”.
         (progn ,@body)))))

(cl-defstruct valign-table-info
  "Information about the current table."
  ;; Width of each column.
  column-width-list
  ;; Alignment of each column, can be either 'left or 'right, only
  ;; used by markdown.  (Technically we can determine the alignment
  ;; from each cell’s padding spaces, but the widest cell in a
  ;; right-aligned column has one space on both side, and we can’t
  ;; determine the alignment for that cell.)
  column-alignment-list)

(defun valign--calculate-table-info (limit)
  "Return a list of column widths.
Each column width is the largest cell width of the column.
Start from point, stop at LIMIT."
  (let (column-width-alist
        column-alignment-alist
        column-idx)
    (save-excursion
      (valign--do-table column-idx limit
        ;; Point is after the left “|”.
        ;;
        ;; Calculate this column’s pixel width, record it if it
        ;; is the largest one for this column.
        (unless (valign--sperator-p)
          (let ((oldmax (alist-get column-idx column-width-alist))
                (cell-width (valign--cell-width)))
            (if (> cell-width (or oldmax 0))
                (setf (alist-get column-idx column-width-alist)
                      cell-width))))
        ;; Calculate the alignment if we are on the separator row
        ;; for markdown.
        (when (valign--sperator-p)
          (setf (alist-get column-idx column-alignment-alist)
                (valign--alignment-from-seperator)))))
    ;; Turn alist into a list.
    (let ((inc 0) return-width-list return-alignment-list)
      (while (alist-get inc column-width-alist)
        ;; Add 16 pixels of padding.
        (push (+ (alist-get inc column-width-alist) 16)
              return-width-list)
        (push (alist-get inc column-alignment-alist)
              return-alignment-list)
        (cl-incf inc))
      (make-valign-table-info
       :column-width-list (reverse return-width-list)
       :column-alignment-list (reverse return-alignment-list)))))

(defun valign--beginning-of-table ()
  "Go backward to the beginning of the table at point.
Assumes point is on a table.  Return nil if failed, point
otherwise."
  (beginning-of-line)
  (skip-chars-forward " \t")
  (if (not (eq (char-after) ?|))
      nil
    (while (eq (char-after) ?|)
      (forward-line -1)
      (beginning-of-line)
      (skip-chars-forward " \t"))
    (unless (eq (char-after) ?|)
      (search-forward "|")
      (backward-char))
    (point)))

(defun valign--end-of-table ()
  "Go forward to the end of the table at point.
Assumes point is on a table.  Return nil if failed, point
otherwise."
  (beginning-of-line)
  (skip-chars-forward " \t")
  (if (not (eq (char-after) ?|))
      nil
    (while (eq (char-after) ?|)
      (forward-line 1)
      (beginning-of-line)
      (skip-chars-forward " \t"))
    (search-backward "|")
    (forward-char)
    (point)))

(defun valign--put-text-property (beg end xpos)
  "Put text property on text from BEG to END.
The text property asks Emacs do display the text as
white space stretching to XPOS, a pixel x position."
  (with-silent-modifications
    (put-text-property
     beg end 'display
     `(space :align-to (,xpos)))))

(defun valign--clean-text-property (beg end)
  "Clean up the display text property between BEG and END."
  ;; TODO ‘text-property-search-forward’ is Emacs 27 feature.
  (if (boundp 'text-property-search-forward)
      (save-excursion
        (let (match)
          (goto-char beg)
          (while (and (setq match
                            (text-property-search-forward
                             'display nil (lambda (_ p)
                                            (and (consp p)
                                                 (eq (car p) 'space)))))
                      (< (point) end))
            (with-silent-modifications
              (put-text-property (prop-match-beginning match)
                                 (prop-match-end match)
                                 'display nil)))))
    (let (display tab-end (p beg) last-p)
      (while (not (eq p last-p))
        (setq last-p p
              p (next-single-char-property-change p 'display nil end))
        (when (and (setq display
                         (plist-get (text-properties-at p) 'display))
                   (consp display)
                   (eq (car display) 'space))
          ;; We are at the beginning of a tab, now find the end.
          (setq tab-end (next-single-char-property-change
                         p'display nil end))
          ;; Remove text property.
          (with-silent-modifications
            (put-text-property p tab-end 'display nil)))))))

(defun valign-initial-alignment (beg end &optional force)
  "Perform initial alignment for tables between BEG and END.
Supposed to be called from jit-lock.
Force align if FORCE non-nil."
  (if (or force (text-property-any beg end 'valign-init nil))
      (save-excursion
        (goto-char beg)
        (while (and (search-forward "|" nil t)
                    (< (point) end))
          (valign-table)
          (valign--end-of-table))
        (with-silent-modifications
          (put-text-property beg (point) 'valign-init t))))
  (cons 'jit-lock-bounds (cons beg end)))

(cl-defmethod valign--align-separator-row
  (type (style (eql single-column)) pos-list)
  "Align the separator row (|---+---|) as “|---------|”.
Assumes the point is after the left bar (“|”).  TYPE can be
either 'org-mode or 'markdown, it doesn’t make any difference.
STYLE is 'single-column.  POS-LIST is a list of each column’s
right bar’s position."
  (ignore type style)
  (let ((p (point))
        ;; Position of the right-most bar.
        (total-width (car (last pos-list))))
    (when (search-forward "|" nil t)
      (with-silent-modifications
        (valign--put-text-property p (1- (point)) total-width))
      ;; Why do we have to add an overlay? Because text property
      ;; doens’t work. First, font-lock overwrites what ever face
      ;; property you add; second, even if you are sneaky and added a
      ;; font-lock-face property, it is overwritten by the face
      ;; property (org-table, in this case).
      (dolist (ov (overlays-in p (1- (point))))
        (if (overlay-get ov 'valign)
            (delete-overlay ov)))
      (let ((ov (make-overlay p (1- (point)))))
        (overlay-put ov 'face '(:strike-through t))
        (overlay-put ov 'valign t)))))

(defun valign--separator-row-add-overlay (beg end right-pos)
  "Add overlay to a separator row’s “cell”.
Cell ranges from BEG to END, the pixel position RIGHT-POS marks
the position for the right bar (“|”).
Assumes point is on the right bar or plus sign."
  ;; Make “+” look like “|”
  (when (eq (char-after end) ?+)
    (with-silent-modifications
      (put-text-property end (1+ end) 'display "|")))
  ;; Markdown row
  (when (eq (char-after beg) ?:)
    (setq beg (1+ beg)))
  (when (eq (char-before end) ?:)
    (setq end (1- end)
          right-pos (- right-pos
                       (valign--glyph-width-at-point (1- end)))))
  ;; End of Markdown
  (valign--put-text-property beg end right-pos)
  ;; Why do we have to add an overlay? Because text property
  ;; doens’t work. First, font-lock overwrites what ever face
  ;; property you add; second, even if you are sneaky and added a
  ;; font-lock-face property, it is overwritten by the face
  ;; property (org-table, in this case).
  (dolist (ov (overlays-in beg end))
    (if (overlay-get ov 'valign)
        (delete-overlay ov)))
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'face '(:strike-through t))
    (overlay-put ov 'valign t)))

(cl-defmethod valign--align-separator-row
  ((type (eql org-mode)) (style (eql multi-column)) pos-list)
  "Align the separator row in multi column style.
TYPE must be 'org-mode, STYLE is 'multi-column.
POS-LIST is a list of positions for each column’s right bar."
  (ignore type style)
  (let ((p (point))
        (col-idx 0))
    (while (search-forward "+" (line-end-position) t)
      (valign--separator-row-add-overlay
       p (1- (point))
       (or (nth col-idx pos-list) 0))
      (cl-incf col-idx)
      (setq p (point)))
    ;; Last column
    (when (search-forward "|" (line-end-position) t)
      (valign--separator-row-add-overlay
       p (1- (point))
       (or (nth col-idx pos-list) 0)))))

(cl-defmethod valign--align-separator-row
  ((type (eql markdown-mode)) (style (eql multi-column)) pos-list)
  "Align the separator row in multi column style.
TYPE must be 'markdown-mode, STYLE is 'multi-column.
POS-LIST is a list of positions for each column’s right bar."
  (ignore type style)
  (let ((p (point))
        (col-idx 0))
    (while (search-forward "|" (line-end-position) t)
      (valign--separator-row-add-overlay
       p (1- (point))
       (or (nth col-idx pos-list) 0))
      (cl-incf col-idx)
      (setq p (point)))))

(cl-defmethod valign--align-separator-row
  ((type (eql gfm-mode)) (style (eql multi-column)) pos-list)
  "Align the separator row in multi column style.
TYPE must be 'gfm-mode, STYLE is 'multi-column.
POS-LIST is a list of positions for each column’s right bar."
  (ignore type)
  (valign--align-separator-row 'markdown-mode style pos-list))

;;; Userland

(defcustom valign-separator-row-style 'multi-column
  "The style of the separator row of a table.
Valign can render it as “|-----------|”
or as “|-----|-----|”.  Set this option to 'single-column
for the former, and 'multi-column for the latter."
  ;; Restart valign-mode if on.
  :set (lambda (var val) (set-default var val)
         (when (bound-and-true-p valign-mode)
           (valign-mode -1) (valign-mode)))
  :type '(choice
          (const :tag "Multiple columns" multi-column)
          (const :tag "A single column" single-column))
  :group 'valign)

(defun valign-table ()
  "Visually align the table at point."
  (interactive)
  (condition-case err
      (save-excursion
        (let (end column-width-list column-idx pos ssw bar-width
                  separator-row-point-list rev-list right-point
                  column-alignment-list info)
          ;; ‘separator-row-point-list’ marks the point for each
          ;; separator-row, so we can later come back and align them.
          ;; ‘rev-list’ is the reverse list of right positions of each
          ;; separator row cell. ‘right-point’ marks point before the
          ;; right bar for each cell.
          (if (not (valign--end-of-table))
              (user-error "Not on a table"))
          (setq end (point))
          (valign--beginning-of-table)
          (setq info (valign--calculate-table-info end))
          (setq column-width-list
                (valign-table-info-column-width-list info)
                column-alignment-list
                (valign-table-info-column-alignment-list info))
          ;; Iterate each cell and apply tab stops.
          (valign--do-table column-idx end
            ;; We don’t align the separator row yet, but will come
            ;; back to it.
            (if (valign--sperator-p)
                (when (eq column-idx 0)
                  (push (point) separator-row-point-list))
              (save-excursion
                ;; Check there is a right bar.
                (when (save-excursion
                        (setq right-point (search-forward "|" nil t)))
                  ;; We are after the left bar (“|”).
                  ;; Start aligning this cell.
                  (let* ((col-width (or (nth column-idx column-width-list)
                                        0)) ;; Pixel width of the column
                         ;; Pixel width of the cell.
                         (cell-width (valign--cell-width))
                         ;; single-space-width
                         (ssw (or ssw (valign--glyph-width-at-point)))
                         (bar-width (or bar-width
                                        (valign--glyph-width-at-point
                                         (1- (point)))))
                         tab-width tab-start tab-end)
                    ;; Initialize some numbers when we are at a new
                    ;; line. ‘pos’ is the pixel position of the
                    ;; current point, i.e., after the left bar.
                    (if (eq column-idx 0)
                        (setq pos (valign--pixel-width-from-to
                                   (line-beginning-position) (point))
                              rev-list nil))
                    ;; Clean up old tabs (i.e., stuff used for padding).
                    (valign--clean-text-property (point) (1- right-point))
                    ;; Align an empty cell.
                    (if (eq cell-width 0)
                        (progn
                          (setq tab-start (point))
                          (valign--skip-space-forward)
                          (if (< (- (point) tab-start) 2)
                              (valign--put-text-property
                               tab-start (point) (+ pos col-width ssw))
                            ;; When possible, we try to add two tabs
                            ;; and the point can appear in the middle
                            ;; of the cell, instead of on the very
                            ;; left or very right.
                            (valign--put-text-property
                             tab-start
                             (1+ tab-start)
                             (+ pos (/ col-width 2) ssw))
                            (valign--put-text-property
                             (1+ tab-start) (point)
                             (+ pos col-width ssw))))
                      ;; Align a left-aligned cell.
                      (pcase (valign--cell-alignment
                              major-mode
                              (nth column-idx column-alignment-list))
                        ('left (search-forward "|" nil t)
                               (backward-char)
                               (setq tab-end (point))
                               (valign--skip-space-backward)
                               (valign--put-text-property
                                (point) tab-end
                                (+ pos col-width ssw)))
                        ;; Align a right-aligned cell.
                        ('right (setq tab-width
                                      (- col-width cell-width))
                                (setq tab-start (point))
                                (valign--skip-space-forward)
                                (valign--put-text-property
                                 tab-start (point)
                                 (+ pos tab-width)))))
                    ;; Update ‘pos’ for the next cell.
                    (setq pos (+ pos col-width bar-width ssw))
                    (push (- pos bar-width) rev-list))))))
          ;; After aligning all rows, align the separator row.
          (dolist (row-point separator-row-point-list)
            (goto-char row-point)
            (valign--align-separator-row major-mode
                                         valign-separator-row-style
                                         (reverse rev-list)))))

    (valign-bad-cell (message (error-message-string err)))
    (valign-werid-alignment (message (error-message-string err)))))

;;; Mode intergration

(defun valign--org-mode-hook ()
  "Valign hook function used by `org-mode'."
  (jit-lock-register #'valign-initial-alignment))

(defun valign--force-align-buffer (&rest _)
  "Forcefully realign every table in the buffer."
  (valign-initial-alignment (point-min) (point-max) t))

(defun valign--realign-on-refontification (&rest _)
  "Make sure text in the buffer are realigned.
When they are fontified next time."
  (with-silent-modifications
    (put-text-property (point-min) (point-max) 'valign-init nil)))

;; When an org link is in an outline fold, it’s full length
;; is used, when the subtree is unveiled, org link only shows
;; part of it’s text, so we need to re-align.  This function
;; runs before the region is flagged. When the text
;; is shown, jit-lock will make valign realign the text.
(defun valign--org-flag-region-advice (beg end flag _)
  "Valign hook, realign table between BEG and END."
  (when (and (not flag)
             (text-property-any beg end 'invisible 'org-link))
    (with-silent-modifications
      (put-text-property beg end 'valign-init nil))))

(defun valign-reset-buffer ()
  "Remove alignment in the buffer."
  ;; TODO Use the new Emacs 27 function.
  ;; Remove text properties
  (with-silent-modifications
    (let ((p (point-min)) (pp (point-min)) display)
      (while (< p (point-max))
        (setq display (plist-get (text-properties-at p) 'display))
        (setq p (next-single-char-property-change p 'display))
        (when (and (consp display)
                   (eq (car display) 'space))
          (put-text-property pp p 'display nil))))
    ;; Remove overlays.
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'valign)
        (delete-overlay ov)))))

;;; Userland

(define-minor-mode valign-mode
  "Visually align Org tables."
  :global t
  :require 'valign
  :group 'valign
  :lighter valign-lighter
  (if (and valign-mode window-system)
      (progn
        (add-hook 'org-mode-hook #'valign--org-mode-hook 90)
        (add-hook 'markdown-mode-hook #'valign--org-mode-hook 90)
        (add-hook 'org-agenda-finalize-hook #'valign--force-align-buffer)
        (advice-add 'org-toggle-inline-images
                    :after #'valign--force-align-buffer)
        (advice-add 'org-restart-font-lock
                    :before #'valign--realign-on-refontification)
        (advice-add 'visible-mode
                    :before #'valign--realign-on-refontification)
        ;; account for hide-link, show-math, and hide markup
        (advice-add 'markdown-reload-extensions
                    :before #'valign--realign-on-refontification)
        (advice-add 'markdown-toggle-inline-images
                    :after #'valign--force-align-buffer)
        (advice-add 'org-table-next-field :after #'valign-table)
        (advice-add 'org-table-previous-field :after #'valign-table)
        (advice-add 'markdown-table-align :after #'valign-table)
        (advice-add 'org-flag-region :before #'valign--org-flag-region-advice)
        ;; Force jit-lock to refontify (and thus realign) the buffer.
        (dolist (buf (buffer-list))
          ;; If the buffer is visible, realign immediately, if not,
          ;; realign when it becomes visible.
          (with-current-buffer buf
            (when (or (derived-mode-p 'org-mode)
                      (derived-mode-p 'markdown-mode))
              (valign--org-mode-hook)
              (if (get-buffer-window buf t)
                  (with-selected-window (get-buffer-window buf t)
                    (valign-initial-alignment (point-min) (point-max) t))
                (with-silent-modifications
                  (put-text-property
                   (point-min) (point-max) 'fontified nil)
                  (put-text-property
                   (point-min) (point-max) 'valign-init nil)))))))
    (remove-hook 'org-mode-hook #'valign--org-mode-hook)
    (remove-hook 'markdown-mode-hook #'valign--org-mode-hook)
    (remove-hook 'org-agenda-finalize-hook #'valign--force-align-buffer)
    (advice-remove 'org-toggle-inline-images #'valign--force-align-buffer)
    (advice-remove 'org-restart-font-lock #'valign--realign-on-refontification)
    (advice-remove 'visible-mode #'valign--realign-on-refontification)
    (advice-remove 'org-table-next-field #'valign-table)
    (advice-remove 'org-table-previous-field #'valign-table)
    (advice-remove 'markdown-table-align #'valign-table)
    (advice-remove 'org-flag-region #'valign--org-flag-region-advice)
    (advice-remove 'markdown-reload-extensions
                   #'valign--realign-on-refontification)
    (advice-remove 'markdown-toggle-inline-images
                   #'valign--force-align-buffer)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (or (derived-mode-p 'org-mode)
                  (derived-mode-p 'markdown-mode))
          (valign-reset-buffer))))))

(provide 'valign)

;;; valign.el ends here

;; Local Variables:
;; sentence-end-double-space: t
;; End:
