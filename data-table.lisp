(cl:defpackage :data-table
  (:use :cl :cl-user :iterate)
  (:shadowing-import-from #:alexandria #:when-let)
  (:export
   #:data-table
   #:column-names #:column-name #:column-types #:column-type #:column-index
   #:rows
   #:number-of-columns #:number-of-rows
   #:symbolize-column-names #:data-table-value #:overlay-region
   #:fill-in-missing-cells #:symbolize-column-names #:symbolize-column-names!
   #:coerce-data-table-of-strings-to-types
   #:coerce-value-for-output
   #:coerce-data-table-values-for-output!
   #:coerce-data-table-values-for-output
   #:add-column
   #:sql-escape-column-names! #:sql-escape-column-names #:english->mssql
   #:english->postgres #:ensure-mssql-table-for-data-table #:ensure-postgres-table-for-data-table
   #:ensure-table-for-data-table
   #:alists-to-data-table #:plists-to-data-table
   #:data-table-to-alists #:data-table-to-plists
   #:make-sub-table #:data-table-data-compare
   #:get-data-table
   #:*guessing-types-sample-size*
   #:assume-column-is-string
   #:bad-type-guess
   ;;duplicate column conditions/restarts
   #:duplicate-column-name
   #:add-numeric-suffix #:add-numeric-suffix-to-all

   ;; clsql
   #:ensure-table-for-data-table
   #:import-data-table
   #:get-data-table
   #:select-columns))

(in-package :data-table)
(cl-interpol:enable-interpol-syntax)

;; Common utils
(defparameter +common-white-space-trimbag+
  `(#\space #\newline #\return #\tab
    ,(code-char #xa0) ;; no break space
    ))

(defun trim-whitespace (s)
  (string-trim +common-white-space-trimbag+ s))

(defun trim-and-nullify (s)
  "trims the whitespace from a string returning nil
   if trimming produces an empty string or the string 'nil' "
  (typecase s
    (string (let ((s (trim-whitespace s)))
              (cond ((zerop (length s)) nil)
                    ((string-equal s "nil") nil)
                    (T s))))
    (t s)))

(defun plist-keys (pl) (iter (for (k v) on pl by #'cddr) (collect k)))
(defun plist-values (pl &optional keys)
  (iter (for k in keys) (collect (getf pl k))))
(defun alist-keys (al) (iter (for (k . v) in al) (collect k)))
(defun alist-values (al &optional keys (test #'equalp))
  (unless keys (setf keys (alist-keys al)))
  (iter
    (for key in keys)
    (collect (cdr (assoc key al :test test)))))

(defun transpose-lists (list-of-lists)
  "Transpose a matrix represented as a list of lists.
  Example: (transpose '((a b c) (d e f))) => ((a d) (b e) (c f))."
  (when list-of-lists
    (apply #'mapcar #'list list-of-lists)))

(defmethod relaxed-parse-float (str &key (type 'double-float))
  "trys to read a value we hope to be a floating point number returns nil on failure

   The goal is to allow reading strings with spaces commas and dollar signs in them correctly 
  "
  (etypecase str
    (null nil)
    (float str)
    (number (float str (ecase type
                         (single-float 0.0)
                         ((float double-float) 0.0d0))))
    ((or string symbol)
     (let* ((str (cl-ppcre:regex-replace-all #?r"\s|\$|\,|\%" (string str) ""))
            (*read-eval* nil)
            (*read-default-float-format* type))
       (ignore-errors
        (coerce (read-from-string str) type))))))

;; END UTILS

(defclass data-table ()
  ((column-names :accessor column-names :initarg :column-names :initform nil)
   (column-types :accessor column-types :initarg :column-types :initform nil)
   (rows :accessor rows :initarg :rows :initform nil))
  (:documentation "A class representing a table of data"))

(defmethod number-of-columns ((dt data-table))
  (length
   (or (column-names dt)
       (column-types dt)
       (first (rows dt)))))

(defmethod number-of-rows ((dt data-table))
  (length (rows dt)))

(defmethod symbolize-column-names ((dt data-table))
  "Turn the column names of the data table into lisp symbols"
  (mapcar #'symbol-munger:english->keyword
          (column-names dt)))

(defmethod symbolize-column-names! ((dt data-table))
  "Turn the column names of the data table into lisp symbols
   save the new column names to the data table"
  (setf (column-names dt) (symbolize-column-names dt)))

(defmethod data-table-value ((dt data-table) &key col-name col-idx row-idx row)
  "Extract a value or set of values from the data table
   can be used to pull a column of data, a row of data or a specific cell of data"
  (when (and col-name (null col-idx))
    (setf col-idx (position col-name (column-names dt) :test #'equalp)))
  (cond
    ((and col-idx row-idx) (elt (elt (rows dt) row-idx) col-idx))
    ((and col-idx row) (elt row col-idx))
    (row-idx (elt (rows dt) row-idx))
    (col-idx (iter (for row in (rows dt))
                   (collect (elt row col-idx))))))

(defun %insert-value-in-list ( row index value )
  "build a new data row by splicing a value into the existing row"
  '(cond
    ((> (length row) index)
     (nconc (subseq row 0 index) (cons value (nthcdr index row))))
    )
  (nconc (subseq row 0 index) (cons value (nthcdr index row))))

(defmethod (setf data-table-value) (new (dt data-table) &key col-name row-idx col-idx)
  "Set a specific row, column or cell of the data table"
  (when (and col-name (null col-idx))
    (setf col-idx (position col-name (column-names dt) :test #'equalp))
    (unless col-idx
      (error "~A does not contain column ~A" dt col-name)))
  (flet ((ensure-rows ()
           (when row-idx
             (unless (< row-idx (length (rows dt)))
               (setf (rows dt)
                     (iter (for i upfrom 0)
                       (for (row . rest) first (rows dt) then rest)
                       (while (or row rest (<= i row-idx)))
                       (collect row)))))))
    (cond
      ((and col-idx row-idx)
       (ensure-rows)
       (let ((row (elt (rows dt) row-idx)))
         (setf (elt (rows dt) row-idx)
               (iter (for i from 0 below (max (number-of-columns dt)))
                 (for (d . rest) first row then rest)
                 (if (eql i col-idx)
                     (collect new)
                     (collect d))))))
      (row-idx
       (ensure-rows)
       (setf (elt (rows dt) row-idx) (alexandria:ensure-list new)))
      (col-idx
       (iter (for val in (alexandria:ensure-list new))
             (for row-idx upfrom 0)
             (setf (data-table-value dt :col-idx col-idx :row-idx row-idx)
                   val))))))

(defmethod make-sub-table (parent &key
                                  (lci 0) (uci (number-of-columns parent))
                                  (lri 0) (uri (number-of-rows parent)))
  "Make a new data table from a subset of another data-table
   lci - low column index
   uci - upper column index (as per subseq 1 beyond the col you want)
   lri - low row index
   uri - upper row index (as per subseq 1 beyond the row you want)
  "
  (let ((rows (subseq (rows parent) lri uri)))
    (flet ((subs (l)
             (loop for item in l
                   for idx from 0
                   when (and (>= idx lci) (< idx uci))
                     collect item)))
      (make-instance
       'data-table
       :column-names (subs (column-names parent))
       :column-types (subs (column-types parent))
       :rows (mapcar #'subs rows)))))

(defun select-columns (table column-names)
  "returns a new data table with only the columns requested, by name"
  (let ((indices (mapcar #'(lambda (name)
			     (or
			      (position name (column-names table)
                                       :test #'string-equal)
			      (error "Cannot select column ~a; does not exist in the table"
				     name)))
                         column-names)))
    (flet ((get-indices (list)
             (iter (for idx in indices)
	       (collect (nth idx list)))))
    (make-instance 'data-table
                   :column-names (copy-list column-names)
                   :column-types (get-indices (column-types table))
                   :rows (mapcar #'get-indices (rows table))))))

(defmethod data-table-data-compare (dt1 dt2 &key (test #'equalp) (key #'identity))
  "tries to comapre the data in two data-tables"
  (and (eql (number-of-rows dt1) (number-of-rows dt2))
       (iter (for r1 in (rows dt1)) (for r2 in (rows dt2))
         (always
          (iter (for d1 in r1) (for d2 in r2)
            (always (funcall test (funcall key d1) (funcall key d2))))))))

(defmethod overlay-region ((new data-table) (dt data-table) &key (row-idx 0) (col-idx 0))
  " puts all values from new-dt into dt starting at row-idx col-idx"
  ;; square the cols
  (iter (for i from (number-of-columns dt)
         below (+ (or col-idx 0) (number-of-columns new)))
    (add-column dt nil nil 'string i))

  ;; square the rows
  (setf
   (rows dt)
   (nconc (rows dt)
          (iter (with nr = (number-of-rows dt))
            (with targ = (+ row-idx (number-of-rows new)))
            (while (< nr targ))
            (incf nr)
            (collect (make-list (number-of-columns dt))))))
  (iter (for row in (rows new))
    (for new-r first row-idx then (+ 1 new-r))
    (iter (for d in row)
      (for new-c first col-idx then (+ 1 new-c))
      (setf (data-table-value dt :col-idx new-c :row-idx new-r) d))))

(defmethod fill-in-missing-cells ((dt data-table) &optional missing-value )
  "Ensures that the data table is square and that every column has the same number of rows
   and every row has the same number of columns, filling in nil to accomplish this"
  (let ((longest-row (iter (for row in (rows dt))
                           (maximizing (length row)))))
    (setf (column-names dt)
          (nconc (column-names dt)
                 (iter
                   (for i from (length (column-names dt)) below longest-row)
                   (collect nil))))
    (setf (column-types dt)
          (nconc (column-types dt)
                 (iter
                   (for i from (length (column-types dt)) below longest-row)
                   (collect nil))))
    (setf (rows dt)
     (iter (for row in (rows dt))
           (for len = (length row))
           (if (= len longest-row)
               (collect row)
               (collect
                   (append row
                           (iter (for i from len below longest-row)
                                 (collect missing-value)))))
           ))))

(defparameter +largest-number+ (expt 2 63)
  "this is the largest number that will be considered a number for data-type purposes.")

(defun simplify-types (val &aux (complex-type (type-of val)))
  "try to get simple type definitions from complex ones"
  (cond
    ;; if we're a number, be sure we're within a range supported
    ;;by databases
    ((and (subtypep complex-type 'number)
          (not (< (* -1 +largest-number+) val +largest-number+)))
     'string)
    ((subtypep complex-type 'integer) 'integer)
    ((subtypep complex-type 'double-float) 'double-float)
    ((subtypep complex-type 'string) 'string)
    (T complex-type)))

(defun maybe-apply (fn &rest args)
  "Call a function, when it exists
   used to avoid calling clsql code if it does not exits
  "
  (let ((fn (etypecase fn
              (symbol
               (handler-case (fdefinition fn)
                 (undefined-function ()))))))
    (when fn (apply fn args))))

(defvar *guessing-types-sample-size* 1000
  "how many rows to look at when trying to guess the types for each column of a data table")

(defun sample-rows (rows &key (sample-size *guessing-types-sample-size*))
  "get a subset of the rows using reservior sampling"
  (if (< (length rows) sample-size) rows
      (iter
        (with sample = (make-array sample-size :initial-element nil))
        (for row in rows)
        (for i from 0)
        (if (< i sample-size)
            (setf (aref sample i) row)
            (let ((r (random i)))
              (if (< r sample-size)
                  (setf (aref sample r) row))))
        (finally (return (coerce sample 'list))))))

(defun guess-types-for-data-table (data-table)
  (let ((trans (transpose-lists (sample-rows (rows data-table)))))
    (iter (for i upfrom 0)
      (for col in trans)
      (let (current)
        (iter (for val in col)
          (when (and val (not (stringp val)))
            (setf current (type-of val)))
          (when (and val (stringp val) (trim-and-nullify val))
            (let* ((val (or (maybe-apply '%to-clsql-date val)
                            (ignore-errors (parse-integer val))
                            (relaxed-parse-float val)
                            val))
                   (type (simplify-types val)))
              (cond
                ((null current) (setf current type))
                ((not (subtypep type current))
                 (setf current (if (or
                                    (subtypep type 'double-float)
                                    (subtypep type 'integer))
                                   'double-float
                                   'string)))))))
        (collect (or current 'string))))))

(define-condition bad-type-guess (error)
  ((expected-type :reader expected-type :initarg :expected-type)
   (original-error :reader original-error :initarg :original-error)
   (value :reader value :initarg :value)))

(defmethod print-object ((o bad-type-guess) s)
  (print-unreadable-object (o s :type t :identity t)
    (format s "Error coercing ~a to ~a;  ~a "
            (value o)
            (column-type o)
            (original-error o))))

(defmethod data-table-coerce (d type)
  (when (or (null d) (subtypep (type-of d) type))
    (return-from data-table-coerce d))
  (handler-case
      (cond ((subtypep type 'float) (relaxed-parse-float d))
            ((subtypep type 'integer) (parse-integer d))
            ((maybe-apply 'is-clsql-date-type? type)
             (%to-clsql-date d))
            ((subtypep type 'string)
             (if (= 0 (length d)) nil d))
            (T (error "data-table-coerce doesnt support coersion of ~s to the type ~a" d type)))
    (error (e)
      (error 'bad-type-guess :value d :expected-type type :original-error e))))

(defun ensure-column-data-types (dt)
  "Given missing data types or data-types only of strings, figure out
   what the data-types for the table should be set the slot on the data-table"
  (when (or (null (column-types dt)) (some #'null (column-types dt))
            (every #'(lambda (x) (subtypep x 'string)) (column-types dt)))
    (setf
     (column-types dt)
     (iter
       (with s-types = (column-types dt))
       (with g-types = (guess-types-for-data-table dt))
       (for i from 0)
       (for gt in g-types)
       (for st = (nth i s-types))
       (collect (if (or (null st) (subtypep st 'string))
                    gt st))))))

(defun coerce-data-table-of-strings-to-types (dt)
  "Figure out what the data-table-types should be then convert
   all the data in the table to those types"
  (ensure-column-data-types dt)
  (iter
    (for row in (rows dt))
    (collect (iter (for d in row)
               (for column from 0)
               (collect
                   (restart-case
                       (data-table-coerce d (nth column (column-types dt)))
                     (assume-column-is-string ()
                       :report "assume this column is a string type and re-coerce"
                       (setf (nth column (column-types dt)) 'string)
                       (iter (for r in coerced-rows)
                         (setf (nth column r)
                               (princ-to-string (nth column r))))
                       (data-table-coerce d 'string)))))
      into coerced-rows)
    (finally
     (setf (rows dt) coerced-rows))))

(defun column-index (col dt)
  (etypecase col
    (null nil)
    (integer col)
    (string (position col (column-names dt) :test #'string-equal))))

(defun column-type (col dt)
  (alexandria:when-let ((idx (column-index col dt)))
    (nth idx (column-types dt))))

(defun (setf column-type) (new col dt)
  (or (alexandria:when-let ((idx (column-index col dt)))
        (setf (nth idx (column-types dt)) new))
      (error "col didnt identify a column ~A" col)))

(defun column-name (col dt)
  (alexandria:when-let ((idx (column-index col dt)))
    (nth idx (column-names dt))))

(defun (setf column-name) (new col dt)
  (or (alexandria:when-let ((idx (column-index col dt)))
        (setf (nth idx (column-names dt)) new))
      (error "col didnt identify a column ~A" col)))

(defvar *list-delimiter* ", "
  "What we will splice lists together with in coerce-value-for-output")

(defmethod coerce-value-for-output ((dt data-table) column-name val
                                    output-type
                                    &aux (cl-interpol:*list-delimiter* *list-delimiter*))
  "Coerce a data-tables-value to a specified output format.
   By default only strings are supported.  This method is intended to be extended in
   other applications to allow mutating to html / csv / etc
  "
  (declare (ignore output-type))
  (typecase val
    (null "")
    (string val)
    (list
     (let ((vals (iter (for v in val)
                   (collect (coerce-value-to-string dt column-name v)))))
       #?"@{vals}"))
    (integer (princ-to-string val))
    (real (format nil "~,2f" val))
    (T (princ-to-string val))))

(defun coerce-data-table-values-for-output! (dt &key output-type)
  "Coerce for output all the values in all the rows and save the result to the rows slot"
  (setf (rows dt)
        (coerce-data-table-values-for-output dt :output-type output-type)))

(defun coerce-data-table-values-for-output (dt &key output-type)
  "Coerce for output all the values in all the rows and return the new rows"
  (iter
    (for row in (rows dt))
    (collect
        (iter
          (for c in (column-names dt))
          (for d in row)
          (collect (coerce-value-for-output dt c d output-type))))))

(defun %add-column-heading/type (dt name type index)
  "this function tries to handle their not being any
   current column types or names or incomplete specification
   but will leave us with the same (+ 1 number-of-columns)
   as we started with "
  (iter
    (with type-specs = (column-types dt))
    (with nc = (number-of-columns dt))
    (with names = (column-names dt))
    (for i from 0 below (max nc (+ 1 index)))
    (for (n1 . rest-names) = names)
    (for (t1 . rest-types) = type-specs)
    (when (= index i)
      (collect name into r-cols)
      (collect type into r-types))
    (unless (>= i nc)
      (collect n1 into r-cols)
      (collect t1 into r-types))
    (setf type-specs rest-types names rest-names)
    (finally
     (setf (column-names dt) r-cols)
     (setf (column-types dt) r-types))))

(defun add-column (dt column-name &optional default (column-type 'string) (index 0))
  "Adds a new column to the data table passed in"
  (when (eql index :last) (setf index (length (column-names dt))))
  (%add-column-heading/type dt column-name column-type index)
  (iter top
    (for row in (rows dt))
    (collect (%insert-value-in-list row index default) into new-rows)
    (finally (setf (rows dt) new-rows)))
  dt)

(defun alists-to-data-table (list-of-alists &key (test #'equalp)
                                            (keys (alist-keys (first list-of-alists))))
  "given a list of alists, (all with the same keys) convert them to a data-table"
  (iter
    (with dt = (make-instance 'data-table))
    (for alist in list-of-alists)
    (collect (alist-values alist keys test) into rows)
    (finally (setf (rows dt) rows
                   (column-names dt) keys )
             (return dt))))

(defun plists-to-data-table (list-of-plists &key (keys (plist-keys (first list-of-plists))))
  (iter (with dt = (make-instance 'data-table))
    (for pl in list-of-plists)
    (collect (plist-values pl keys) into rows)
    (finally (setf (column-names dt) keys
                   (rows dt) rows)
             (return dt))))

(defun data-table-to-plists (dt)
  (iter
    (with cnames = (column-names dt))
    (for row in (rows dt))
    (collect
        (iter (for c in cnames) (for d in row)
          (collect c) (collect d)))))

(defun data-table-to-alists (dt)
  (iter
    (with cnames = (column-names dt))
    (for row in (rows dt))
    (collect
        (iter (for c in cnames) (for d in row)
          (collect (cons c d))))))
