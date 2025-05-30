;;; cp0.ss
;;; Copyright 1984-2017 Cisco Systems, Inc.
;;; 
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;; 
;;; http://www.apache.org/licenses/LICENSE-2.0
;;; 
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.

;; TODO:
;;   * make seq should just drop effect-free portions of e1 rather than
;;     asking if the whole of e1 is simple.
;;   * folding/specializing loops
;;   * later (much)
;;     - split up score for seqs to allow us to avoid adding in score of
;;       e2 when we encounter (seq e1 e2) for simple e2 in residualize-call-opnds
;;   * try using other than value in visit-operand in contexts where we visit the
;;     operand of a singly referenced identifier, e.g., if we see (values opnd) in
;;     test context, visit opnd in test context
;;
;; we now no longer collapse quote's into void and true quotes, but
;; rather make if suffer through a (very slightly) more expensive test for
;; record equality

;; N.B.: we use (operand-wd opnd) in cp0 singly referenced case; this is not quite
;; legitimate, since we can visit the operand more than once with the same (possibly
;; passive) watchdog.  Thus we are potentially nonlinear, but in practice it allows
;; us to integrate many harmless singly referenced procedures.

;; calls to not multiply-referenced identifiers handled as follows:
;;  * propagate multiply-referenced flag on copy propagation
;;    (let ((x e1))
;;      (let ((y x)) ; set multiply referenced flag on x
;;        (let ((z y))
;;          (z y))))
;;  * don't treat as singly referenced when id => id on env lookup, i.e., id is free
;;    (presumably outside of operator position, or we would have integrated during
;;    value-visit-operand) in procedure being integrated
;;    (let ((f e))
;;      (let ((g (lambda () f)))
;;        (g)    ; don't treat f as singly referenced
;;        (g)))
;;  * exploit as follows:
;;    - maintain singly-referenced-score in operand
;;    - if operand-exp of singly-referenced id is a lambda,
;;      run with it with operand's watchdog and passive scorer
;;    - otherwise value-visit operand, run with result-exp
;;      with alert watchdog and passive scorer
;;    - set singly-referenced to score from passive scorer in either case
;;      if integration succeeds
;;    - residualize-call-opnds uses singly-referenced-score if non-false

(define $cp0
(let ()
  (import (nanopass))
  (include "base-lang.ss")

  ;;; set to #f for monovariant filter
  (define-threaded polyvariant #t)

  ;;; set to #f to disable inlining of various primitives into code containing
  ;;; lambda expressions, e.g., for-each and record-accessor---generally not
  ;;; desirable when interpreting rather than compiling the residual code.
  (define-threaded likely-to-be-compiled?)

  ;;; score-limit determines max amount of code any integration attempt
  ;;; can result in; effort-limit determines max amount of work that can
  ;;; be done attempting to integrate
  (define-threaded score-limit 20)
  (define-threaded effort-limit 200)

  ;;; inner unrolling doesn't work, and when set nonzero, effectively
  ;;; disables outer unrolling as well
  (define-threaded inner-unroll-limit 0)

  ;;; outer-unroll-limit of 0 disables integration of recursive
  ;;; procedures.  outer-unroll-limit of 1 is probably a more
  ;;; reasonable default, except we then trash cp1's loop recognition
  (define-threaded outer-unroll-limit 0)

  ;;; used to memoize pure?, etc.
  (define-threaded cp0-info-hashtable)

  ;; use to preserve sharing with `exts` renaming
  (define-threaded exts-table)

  (module ()
    (define-syntax define-cp0-param
      (syntax-rules ()
        [(_ global-name local-name filter)
          (set! global-name
            (case-lambda
              [() local-name]
              [(x) (set! local-name (filter 'global-name x))]))]))

    (define filter-limit
      (lambda (who x)
        (unless (and (fixnum? x) (fx>= x 0))
          ($oops who "invalid limit ~s" x))
        x))

    (define filter-bool (lambda (who x) (and x #t)))

    (define-cp0-param cp0-effort-limit effort-limit filter-limit)
    (define-cp0-param cp0-score-limit score-limit filter-limit)
    (define-cp0-param cp0-outer-unroll-limit outer-unroll-limit filter-limit)

    (define-cp0-param $cp0-inner-unroll-limit inner-unroll-limit filter-limit)
    (define-cp0-param $cp0-polyvariant polyvariant filter-bool))

  (define (rappend ls1 ls2)
    (if (null? ls1)
        ls2
        (rappend (cdr ls1) (cons (car ls1) ls2))))

  ; don't use rtd-* as defined in record.ss in case we're building a patch
  ; file for cross compilation, because the offsets may be incorrect
  (define rtd-flds (csv7:record-field-accessor #!base-rtd 'flds))
  (define rtd-ancestry (csv7:record-field-accessor #!base-rtd 'ancestry))
  (define rtd-parent (lambda (x) (let ([a (rtd-ancestry x)])
                                   (vector-ref a (fx- (vector-length a) (constant ancestry-parent-offset))))))
  (define rtd-size (csv7:record-field-accessor #!base-rtd 'size))
  (define rtd-pm (csv7:record-field-accessor #!base-rtd 'pm))
  (define rtd-mpm (csv7:record-field-accessor #!base-rtd 'mpm))

  ; compile-time rtds (ctrtds)
  (define ctrtd-opaque-known #b0000001)
  (define ctrtd-sealed-known #b0000010)

  (define base-ctrtd ($make-record-type #!base-rtd #!base-rtd "ctrtd" '((immutable flags)) #t #f #f))
  (define ctrtd? (record-predicate base-ctrtd))
  (define ctrtd-flags (record-accessor base-ctrtd 0))

  (define record-type-sealed-known?
    (lambda (rtd)
      (or (not (ctrtd? rtd))
          (fxlogtest (ctrtd-flags rtd) ctrtd-sealed-known))))

  (define record-type-opaque-known?
    (lambda (rtd)
      (or (not (ctrtd? rtd))
          (fxlogtest (ctrtd-flags rtd) ctrtd-opaque-known))))

  (define rtd-all-immutable?
    (lambda (rtd)
      (let ([flds (rtd-flds rtd)])
        (cond
         [(fixnum? flds) (eqv? 0 (rtd-mpm rtd))]
         [else
          (andmap (lambda (fld) (not (fld-mutable? fld))) flds)]))))

  (define rtd-all-immutable-scheme-objects?
    (lambda (rtd)
      (let ([flds (rtd-flds rtd)])
        (cond
         [(fixnum? flds)
          (eqv? 0 (rtd-mpm rtd))]
         [else
          (andmap (lambda (fld)
                    (and (not (fld-mutable? fld))
                         (eq? (filter-foreign-type (fld-type fld)) 'scheme-object)))
                  flds)]))))

  (define rtd-immutable-field?
    (lambda (rtd index)
      (let ([flds (rtd-flds rtd)])
        (cond
         [(fixnum? flds)
          (not (bitwise-bit-set? (rtd-mpm rtd) (fx+ index 1)))]
         [else
          (not (fld-mutable? (list-ref flds index)))]))))

  (define rtd-make-fld
    (lambda (rtd index)
      (make-fld 'unknown (bitwise-bit-set? (rtd-mpm rtd) (fx+ index 1)) 'scheme-object 0)))

  (define make-cte-info
    (case-lambda
     [(e) e]
     [(e full? single-valued?)
      (if (or full? single-valued?)
          (vector e full? single-valued?)
          e)]))
  (define (cte-info-inline cte-info)
    (if (vector? cte-info)
        (vector-ref cte-info 0)
        cte-info))
  (define (cte-info-procedure-full? cte-info)
    (and (vector? cte-info)
         (vector-ref cte-info 1)))
  (define (cte-info-procedure-single-valued? cte-info)
    (and (vector? cte-info)
         (vector-ref cte-info 2)))

  (with-output-language (Lsrc Expr)
    (define void-rec `(quote ,(void)))
    (define true-rec `(quote #t))
    (define false-rec `(quote #f))
    (define null-rec `(quote ()))
    (define empty-vector-rec `(quote #()))
    (define empty-string-rec `(quote ""))
    (define empty-bytevector-rec `(quote #vu8()))
    (define empty-fxvector-rec `(quote #vfx()))
    (define empty-flvector-rec `(quote #vfl()))

    ;;; environments
    (module (empty-env with-extended-env lookup)
      (define empty-env '())

      (define-record-type env
        (nongenerative)
        (fields old-ids new-ids next))

      (define-syntax with-extended-env
        (syntax-rules ()
          [(_ ((new-env new-ids) (?old-env ?old-ids ?opnds)) e1 e2 ...)
           (let-values ([(new-env new-ids) (extend-env ?old-env ?old-ids ?opnds)])
             (let ([e (let () e1 e2 ...)])
               (deinitialize-ids! new-ids)
               e))]))

      (define extend-env
        (lambda (old-env old-ids opnds)
          (let ([new-ids (let loop ([old-ids old-ids] [opnds opnds] [rnew-ids '()])
                           (if (null? old-ids)
                               (reverse rnew-ids)
                               (loop
                                 (cdr old-ids) 
                                 (and opnds (cdr opnds))
                                 (cons
                                   (let ([old-id (car old-ids)]
                                         [opnd (and opnds (car opnds))])
                                     (let ([id (make-prelex
                                                 (prelex-name old-id)
                                                 (let ([flags (prelex-flags old-id)])
                                                   (fxlogor
                                                     (fxlogand flags (constant prelex-sticky-mask))
                                                     (fxsll (fxlogand flags (constant prelex-is-mask))
                                                       (constant prelex-was-flags-offset))))
                                                 (prelex-source old-id)
                                                 opnd)])
                                       (when (operand? opnd)
                                         (operand-name-set! opnd id))
                                       id))
                                   rnew-ids))))])
            (values (make-env (list->vector old-ids) (list->vector new-ids) old-env) new-ids))))
      
      (define deinitialize-ids!
        (lambda (ids)
          ; clear operand field (a) to release storage the operands occupy and (b) to
          ; prevent fasling of useless operands in cte-optimization-locs.  clear even
          ; if we didn't set (i.e., even if opnds or the corresponding opnd is #f), for
          ; the benefit of cp0-rec-let, which sets operand fields after creating env
          (for-each (lambda (id) (prelex-operand-set! id #f)) ids)))

      (define lookup
        (lambda (id env)
          (let loop1 ([env env])
            (if (eqv? env empty-env)
                id
                (let ([old-rib (env-old-ids env)] [new-rib (env-new-ids env)])
                  (let ([n (vector-length old-rib)])
                    (let loop2 ([i 0])
                      (if (fx= i n)
                          (loop1 (env-next env))
                          (if (eq? (vector-ref old-rib i) id)
                              (vector-ref new-rib i)
                              (let ([i (fx+ i 1)])
                                (if (fx= i n)
                                    (loop1 (env-next env))
                                    (if (eq? (vector-ref old-rib i) id)
                                        (vector-ref new-rib i)
                                        (loop2 (fx+ i 1)))))))))))))))

    (define cp0-make-temp ; returns an unassigned temporary
      (lambda (multiply-referenced?)
        (let ([t (make-prelex*)])
          (when multiply-referenced? (set-prelex-multiply-referenced! t #t))
          (set-prelex-referenced! t #t)
          t)))

    (define (name->symbol name)
      (safe-assert (or (prelex? name) (symbol? name)))
      (if (prelex? name)
          (prelex-name name)
          name))

    ;;; contexts

    ;; 'value - result used, context checks for single-value result,
    ;;          not in tail position within an enclosing function
    ;; 'test - result used as boolean, context checks for single-value result,
    ;;          not in tail position within an enclosing function
    ;; 'tail - result used, multiple values ok, in tail position
    ;;         within an enclosing function
    ;; 'effect - result not used, multiple values ok, not in tail
    ;;         position
    ;; 'ignored - result not used, must produce a single value,
    ;;         not in tail position

    ;; Beware that "ctxt" sometimes actually refers to an app context,
    ;; not one of the above contexts.

    (define (context-imposes-single-value? ctxt)
      (or (eq? ctxt 'value) (eq? ctxt 'test)))

    (define (unused-value-context? ctxt)
      (or (eq? ctxt 'effect) (eq? ctxt 'ignored)))

    ;; app context:
    ;;   opnds are the operands at the call site
    ;;   ctxt is the outer context
    ;;   convention is a symbol: call, apply2 (safe), or apply3 (unsafe)
    ;;   src is the call source
    ;;   used is set to a list of operands used (let-bound) by integrated call
    ;;   unused is set to a list of operands not used by integrated call
    (define-record-type app
      (fields opnds ctxt convention name preinfo (mutable used) (mutable unused))
      (nongenerative)
      (sealed #t)
      (protocol
        (lambda (new)
          (lambda (opnds ctxt convention name preinfo)
            (new opnds ctxt convention name preinfo #f #f)))))

    (define-syntax context-case
      (lambda (x)
        (define predicate
          (lambda (type)
            (syntax-case type (app)
              [app #'app?]
              [_ (with-syntax ([type type])
                   #'(lambda (x) (eq? x 'type)))])))
        (syntax-case x (else)
          [(_ ctxt-exp [(type ...) e1 e2 ...] more ...)
           (with-syntax (((pred ...) (map predicate #'(type ...))))
             #'(let ((ctxt ctxt-exp))
                 (if (or (pred ctxt) ...)
                     (begin e1 e2 ...)
                     (context-case ctxt more ...))))]
          [(_ ctxt-exp [else e1 e2 ...]) #'(begin e1 e2 ...)]
          [(_ ctxt-exp)
           #'($oops 'cp0-internal "unexpected context ~s" ctxt-exp)])))

    (define-syntax convention-case
      (lambda (x)
        (syntax-case x (else)
          [(_ conv-exp [(key ...) e1 e2 ...] more ...)
           #'(let ((conv conv-exp))
               (if (or (eq? conv 'key) ...)
                   (begin e1 e2 ...)
                   (convention-case conv more ...)))]
          [(_ conv-exp [else e1 e2 ...]) #'(begin e1 e2 ...)]
          [(_ conv-exp)
           #'($oops 'cp0-internal "unexpected app convention ~s" conv-exp)])))


    ;;; operands

    (define-record-type operand
      (fields
        (immutable exp)
        (immutable env)
        (immutable wd)
        (immutable moi)
        (mutable name)
        (mutable score)
        (mutable pending)
        (mutable opending)
        (mutable value)
        (mutable singly-referenced-score)
        (mutable lifted)
        (mutable can-lift?))
      (nongenerative)
      (protocol
        (lambda (new)
          (lambda (exp env wd moi)
            (new exp env wd moi #f 0 0 0 #f #f #f #f)))))

    (define-record-type lifted
      (fields (immutable seq?) (immutable ids) (immutable vals))
      (nongenerative)
      (sealed #t))

    (define build-operands
      (lambda (ivory-so-far? args env wd moi)
        (let ([opnds (map (lambda (x) (make-operand x env wd moi)) args)])
          (when (and ivory-so-far?
                     ;; since arguments are evaluated in any order, allow
                     ;; up to 1 non-ivory argument for arguments be liftable:
                     (let loop ([one-non-ivory? #f] [args args])
                       (cond
                         [(null? args) #t]
                         [(ivory? (car args)) (loop one-non-ivory? (cdr args))]
                         [one-non-ivory? #f]
                         [else (loop #t (cdr args))])))
            (for-each (lambda (opnd) (operand-can-lift?-set! opnd #t))
                      opnds))
          opnds)))

    (define build-cooked-opnd
      (lambda (e)
        (let ([o (make-operand #f #f #f #f)])
          (operand-value-set! o e)
          o)))

    ;;; cycle detection

    (define inner-cyclic?
      (lambda (opnd)
        (when (fx> (operand-pending opnd) 0)
          ; seed outer pending flag if cycle is detected
          (operand-opending-set! opnd 1))
        (fx> (operand-pending opnd) inner-unroll-limit)))

    (define outer-cyclic?
      (lambda (opnd)
        (fx> (operand-opending opnd) outer-unroll-limit)))

    (define-threaded opending-list '())

    (define unwind-pending!
      (lambda (oplist)
        (do ((ls opending-list (cdr ls)))
          ((eq? ls oplist) (set! opending-list ls))
          (operand-opending-set! (car ls)
            (fx- (operand-opending (car ls)) 1)))))

    (define-syntax pending-protect
      ; we don't need to maintain list of inner pending operands to be
      ; unwound by bug-out, since we never abort a visit to an operand
      ; that we actually need.  in other words, when we bug out of an
      ; inlining attempt, we abort the visiting of only operands created
      ; during the inlining attempt.
      (syntax-rules ()
        ((_ opnd e1 e2 ...)
         (let ((o opnd))
           (operand-pending-set! o (fx+ (operand-pending o) 1))
           (let ((t (begin e1 e2 ...)))
             (operand-pending-set! o (fx- (operand-pending o) 1))
             t)))))

    (define-syntax opending-protect
      ; dynamic wind could be used but is much slower
      (syntax-rules ()
        ((_ opnd e1 e2 ...)
         (let ((o opnd))
           (operand-opending-set! o (fx+ (operand-opending o) 1))
           (set! opending-list (cons opnd opending-list))
           (let ((t (begin e1 e2 ...)))
             (set! opending-list (cdr opending-list))
             (operand-opending-set! o (fx- (operand-opending o) 1))
             t)))))

    ;;; scorers

    (define-record-type scorer
      (fields (mutable limit) (immutable ctxt) (immutable k) (immutable oplist))
      (nongenerative)
      (sealed #t)
      (protocol
        (lambda (new)
          (lambda (limit ctxt k)
            (new limit ctxt k opending-list)))))

    (define new-scorer
      ; with no arguments, create a passive scorer with a high limit that
      ; (we assume) won't overflow; this allows us to keep a tally without
      ; ever bugging out.  with two arguments n and k, create a scorer that
      ; will bug out to if bumped n times.
      (case-lambda
        [() (make-scorer (most-positive-fixnum) #f oops-k)]
        [(n ctxt k) (make-scorer n ctxt k)]))

    (define oops-k
      (list (lambda (x)
              ($oops 'compiler-internal "bug out from passive scorer"))))

    (define scorer-score
      ; assuming we'll ask for score only of passive scorers
      (lambda (sc)
        (- (most-positive-fixnum) (scorer-limit sc))))

    (define passive-scorer?
      (lambda (sc)
        (eq? (scorer-k sc) oops-k)))

    (define new-watchdog
      (case-lambda
        [() (make-scorer (most-positive-fixnum) #f oops-k)]
        [(wd ctxt k)
         ; create a new watchdog only if the old one isn't alert
         (if (passive-scorer? wd)
             (make-scorer effort-limit ctxt k)
             wd)]))

    (define bump
      (lambda (sc amount)
        (let ((n (fx- (scorer-limit sc) amount)))
          (scorer-limit-set! sc n)
          (when (fx< n 0) (bug-out! sc)))))

    (define bug-out!
      (lambda (sc)
        (reset-integrated! (scorer-ctxt sc))
        (unwind-pending! (scorer-oplist sc))
        ((scorer-k sc) #f)))

    (define reset-integrated!
      (lambda (ctxt)
        (app-used-set! ctxt #f)
        (let ((ctxt (app-ctxt ctxt)))
          (when (app? ctxt) (reset-integrated! ctxt)))))

    ;;; visiting operands

    (define visit-operand!
      (lambda (opnd ctxt)
        ; NB: commonize with np-recognize-let
        (define extract-profile-forms
          (lambda (e)
            (define seqs-and-profiles?
              (lambda (e)
                (nanopass-case (Lsrc Expr) e
                  [(profile ,src) #t]
                  [(seq ,e1 ,e2) (and (seqs-and-profiles? e1) (seqs-and-profiles? e2))]
                  [else #f])))
            (if (eq? ($compile-profile) 'source)
                (let loop ([e e] [eprof #f])
                  (nanopass-case (Lsrc Expr) e
                    [(seq ,e1 ,e2)
                     (guard (seqs-and-profiles? e1))
                     (loop e2 (if eprof `(seq ,eprof ,e1) e1))]
                    [else (values e eprof)]))
                (values e #f))))
        (define (possible-loop? x* body)
          (and (fx= (length x*) 1)
               (nanopass-case (Lsrc Expr) body
                 [(call ,preinfo (ref ,maybe-src ,x) ,e* ...)
                  (eq? x (car x*))]
                 [else #f])))
        ; set up to assimilate nested let/letrec/letrec* bindings.
        ; lifting job is completed by cp0-call or letrec/letrec*
        (define (split-value e can-lift?)
          (nanopass-case (Lsrc Expr) e
            [(call ,preinfo0 (case-lambda ,preinfo1 (clause (,x* ...) ,interface ,body)) ,e* ...)
             (guard (fx= interface (length e*)))
             (cond
               ; when lifting all assimilated let bindings, require each RHS to be
               ; simple, since they are treated as letrec/letrec* bindings, which does
               ; not preserve let semantics wrt continuation grabs in RHS expressions.
               ; further, require each RHS to be pure unless the body is pure, since it's
               ; unsound to split apart two things that can observe a side effect or two
               ; allocation operations that can be separated by a continuation grab.
               [(or can-lift? ; => `build-operands` says it's ok to lift anything past other ivory
                    (if (ivory? body) (andmap simple/profile1? e*) (andmap ivory1? e*)))
                ; associate each lhs with cooked operand for corresponding rhs.  make-record-constructor-descriptor,
                ; at least, counts on this to allow protocols to be inlined.
                (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
                (values (make-lifted #f x* e*) body)]
               ; okay, so we don't pass that test.  if body and e* are simple, we can
               ; still lift by making a binding for body and requesting letrec* semantics.
               ; that way, we aren't splitting e* and body.  we still can't lift anything
               ; that might capture a continuation, though it's tricky to come up with
               ; example that breaks.
               ; we don't presently have any justification (benchmark results or expand/optimize
               ; mats) that establish the benefit of this, but might want to revisit/refine at
               ; some point.
               #;[(and (simple? body) (andmap simple? e*))
                (let ([t (cp0-make-temp #f)]) ; mark was-referenced?
                      (let ([x* (append x* (list t))] [e* (append e* (list body))])
                        (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
                        (values (make-lifted #t x* e*) (build-ref t))))]
               ; otherwise lift out only bindings with unasigned lhs and ivory rhs
               ; we don't presently have any justification (benchmark results or expand/optimize
               ; mats) that establish the benefit of this, but might want to revisit/refine at
               ; some point.
               #;[(ormap (lambda (x e) (and (not (prelex-assigned x)) (ivory? e))) x* e*)
                (let loop ([x* x*] [e* e*] [rx* '()] [re* '()] [rlx* '()] [rle* '()])
                  (if (null? x*)
                      (values (make-lifted #f (reverse rlx*) (reverse rle*))
                        (build-let (reverse rx*) (reverse re*) body))
                      (let ([x (car x*)] [e (car e*)])
                        (if (and (not (prelex-assigned x)) (ivory? e))
                            (begin
                              ; associate each lhs with cooked operand for corresponding rhs.  see note above.
                              (prelex-operand-set! x (build-cooked-opnd e))
                              (loop (cdr x*) (cdr e*) rx* re* (cons x rlx*) (cons e rle*)))
                            (loop (cdr x*) (cdr e*) (cons x rx*) (cons e re*) rlx* rle*)))))]
               [else (values #f e)])]
            ; for assimilated letrec/letrec* bindings, require each RHS to be
            ; pure OR body to be pure, since we can't separate non-pure
            ; RHS and body expressions
            [(letrec ([,x* ,e*] ...) ,body)
             (guard (and (or (ivory? body) (andmap ivory1? e*))
                         ;; don't break apart (potential) loops
                         (not (possible-loop? x* body))))
             ; associate each lhs with cooked operand for corresponding rhs.  see note above.
             (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
             (values (make-lifted #f x* e*) body)]
            ; force the issue by creating an extra tmp for body
            ; we don't presently have any justification (benchmark results or expand/optimize
            ; mats) that establish the benefit of this, but might want to revisit/refine at
            ; some point.
            #;[(letrec ([,x* ,e*] ...) ,body)
             (let ([x (cp0-make-temp #f)])
               (let ([x* (append x* (list x))] [e* (append e* (list body))])
                 (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
                 (values (make-lifted #t x* e*) (build-ref x))))]
            [(letrec* ([,x* ,e*] ...) ,body)
             (guard (and (or (ivory? body) (andmap ivory1? e*))
                         ;; don't break apart (potential) loops
                         (not (possible-loop? x* body))))
             ; associate each lhs with cooked operand for corresponding rhs.  see note above.
             (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
             (values (make-lifted #t x* e*) body)]
            ; force the issue by creating an extra tmp for body.
            ; we don't presently have any justification (benchmark results or expand/optimize
            ; mats) that establish the benefit of this, but might want to revisit/refine at
            ; some point.
            #;[(letrec* ([,x* ,e*] ...) ,body)
             (let ([x (cp0-make-temp #f)])
               (let ([x* (append x* (list x))] [e* (append e* (list body))])
                 (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
                 (values (make-lifted #t x* e*) (build-ref x))))]
            ; we can lift arbitrary subforms of record forms if we also lift
            ; a binding for the record form itself.  there's no worry about
            ; continuation captures: if rtd-expr or e* capture a continuation,
            ; invoking the continuation to return from a rhs is no worse than
            ; invoking the continuation to build the record and then return
            ; from a rhs.
            [(record ,rtd ,rtd-expr ,e* ...)
             (let-values ([(liftmt* liftme* e*)
                           (let ([fld* (rtd-flds rtd)]
                                 [mpm (rtd-mpm rtd)])
                             (let f ([e* e*] [fld* (and (not (fixnum? fld*)) fld*)] [idx 0])
                               (if (null? e*)
                                   (values '() '() '())
                                   (let ([e (car e*)])
                                     (let-values ([(liftmt* liftme* e*) (f (cdr e*) (and fld* (cdr fld*)) (fx+ idx 1))])
                                       (if (nanopass-case (Lsrc Expr) e
                                             [(ref ,maybe-src ,x) #f]
                                             [(quote ,d) #f]
                                             [,pr #f]
                                             [else (not (if fld*
                                                            (fld-mutable? (car fld*))
                                                            (bitwise-bit-set? mpm (fx+ idx 1))))])
                                           (let ([t (cp0-make-temp #f)])
                                             (values (cons t liftmt*) (cons e liftme*) (cons (build-ref t) e*)))
                                           (values liftmt* liftme* (cons e e*))))))))])
               (let ([e `(record ,rtd ,rtd-expr ,e* ...)])
                 (if (null? liftmt*)
                     (values #f e)
                     (let ([x (cp0-make-temp #f)])
                       (let ([x* (append liftmt* (list x))] [e* (append liftme* (list e))])
                         (for-each (lambda (x e) (prelex-operand-set! x (build-cooked-opnd e))) x* e*)
                         (values (make-lifted #t x* e*) (build-ref x)))))))]
            [else (values #f e)]))
        (or (operand-value opnd)
            (let ([sc (new-scorer)])
              (let ([e0 (pending-protect opnd
                          (cp0 (operand-exp opnd) ctxt (operand-env opnd) sc (operand-wd opnd) (operand-name opnd) (operand-moi opnd)))])
                (let-values ([(e1 eprof) (extract-profile-forms e0)])
                  (with-values (split-value e1 (operand-can-lift? opnd))
                    (lambda (lifted e)
                      (let ([e (if eprof (make-seq ctxt eprof e) e)])
                        (operand-lifted-set! opnd lifted)
                        (operand-value-set! opnd e)
                        (operand-score-set! opnd (scorer-score sc))
                        e)))))))))

    (define value-visit-operand!
      (lambda (opnd)
        (visit-operand! opnd 'value)))

    (define test-visit-operand!
      (lambda (opnd)
        (visit-operand! opnd 'test)))

    (define value-visit-operands!
      (lambda (opnds)
        (map value-visit-operand! opnds)))

    (define residualize-seq
      ; ctxt must be an app context.  set used and unused lists in context
      (lambda (used unused ctxt)
        (safe-assert (fx= (fx+ (length used) (length unused)) (length (app-opnds ctxt))))
        (app-used-set! ctxt used)
        (app-unused-set! ctxt unused)))

    (define residualize-call-opnds
      (lambda (used unused e ctxt sc)
        (let f ((used used) (n 0))
          (if (null? used)
              (let f ((unused unused) (n n) (todo '()))
                (if (null? unused)
                    (begin
                      (bump sc n)
                      (let f ((todo todo) (e e))
                        (if (null? todo)
                            e
                            (f (cdr todo)
                              (make-1seq ctxt
                                (let ((opnd (car todo)))
                                  (cp0 (operand-exp opnd) 'ignored (operand-env opnd)
                                    sc (operand-wd opnd) (operand-name opnd) (operand-moi opnd)))
                                e)))))
                    (let ((opnd (car unused)))
                      (let ((e (operand-value opnd)))
                        (if e
                            (if (simple1? e)
                                (if (operand-singly-referenced-score opnd)
                                    ; singly-referenced integration attempt in copy2 succeeded
                                    (f (cdr unused) (fx+ (operand-singly-referenced-score opnd) n) todo)
                                    (f (cdr unused) n todo))
                                ; overscoring bug: make-seq may drop e2 if e is (seq e1 e2), but
                                ; we add in the entire score here
                                ; if singly-referenced integration attempt in copy2 succeeded, but
                                ; value isn't simple, we also pay the whole price
                                (make-1seq ctxt e (f (cdr unused) (fx+ n (operand-score opnd)) todo)))
                            (if (operand-singly-referenced-score opnd)
                                ; singly-referenced integration attempt in ref-case of cp0 succeeded
                                (f (cdr unused) (fx+ (operand-singly-referenced-score opnd) n) todo)
                                (f (cdr unused) n (cons opnd todo))))))))
              (f (cdr used) (fx+ (operand-score (car used)) n))))))

    (define cp0-constant?
      (case-lambda
        [(x)
         (nanopass-case (Lsrc Expr) x
           [(quote ,d) #t]
           [else #f])]
        [(pred? x)
         (nanopass-case (Lsrc Expr) x
           [(quote ,d) (pred? d)]
           [else #f])]))

    (define-who cp0-datum
      (lambda (x)
        (nanopass-case (Lsrc Expr) x
          [(quote ,d) d]
          [else (sorry! who "~s is not a constant" x)])))

    (define (symbol->lambda-name sym)
      (let ([x ($symbol-name sym)])
        (if (pair? x) (or (cdr x) (car x)) x)))

    (define (preinfo-lambda-set-name-and-flags preinfo name flags)
      (let ([new-name (and
                       name
                       ;; Avoid replacing a name from an optimized-away `let` pattern:
                       (not (preinfo-lambda-name preinfo))
                       (symbol->lambda-name (name->symbol name)))])
        (if (or new-name
                (not (fx= flags (preinfo-lambda-flags preinfo))))
            (make-preinfo-lambda (preinfo-src preinfo) (preinfo-sexpr preinfo)
              (preinfo-lambda-libspec preinfo) (or new-name (preinfo-lambda-name preinfo)) flags)
            preinfo)))

    (define preinfo-call->preinfo-lambda
      (lambda (preinfo name)
        (make-preinfo-lambda (preinfo-src preinfo) (preinfo-sexpr preinfo)
           #f (and name (symbol->lambda-name (name->symbol name))))))

    (define build-quote
      (lambda (d)
        `(quote ,d)))

    (define build-ref
      (lambda (x)
        `(ref #f ,x)))

    (module (build-primcall)
      (define $build-primcall
        (case-lambda
          [(primref args) ($build-primcall (make-preinfo-call) primref args)]
          [(preinfo primref args) `(call ,preinfo ,primref ,args ...)]))
      (define-syntax build-primcall
        (syntax-rules ()
          [(_ level name args) ($build-primcall (lookup-primref level name) args)]
          [(_ preinfo level name args) ($build-primcall preinfo (lookup-primref level name) args)])))

    (define build-lambda
      (case-lambda
        [(ids body) (build-lambda (make-preinfo-lambda) ids body)]
        [(preinfo ids body) `(case-lambda ,preinfo (clause (,ids ...) ,(length ids) ,body))]))

    (define build-case-lambda
      (case-lambda
        [(clause*) (build-case-lambda (make-preinfo-lambda) clause*)]
        [(preinfo clause*)
         `(case-lambda ,preinfo
            ,(map (lambda (clause)
                    (with-output-language (Lsrc CaseLambdaClause)
                      (let ([x* (car clause)])
                        `(clause (,x* ...) ,(length x*) ,(cadr clause)))))
               clause*) ...)]))

    ; build-call is not very cp0-like, since it doesn't enable further
    ; optimization, but it does clean up some silly looking code.
    (define build-call
      (lambda (preinfo proc args)
        (let ([n (length args)])
          (nanopass-case (Lsrc Expr) proc
            ; eta reduce ((lambda (x ...) (prim x ...)) e ...) => (prim e ...)
            [(case-lambda ,preinfo0
               (clause (,x* ...) ,interface
                 (call ,preinfo1 ,pr ,e* ...)))
             (guard (fx= interface n) (fx= (length e*) n)
               (andmap (lambda (x e)
                         (nanopass-case (Lsrc Expr) e
                           [(ref ,maybe-src ,x1) (eq? x1 x)]
                           [else #f]))
                 x* e*))
             `(call ,preinfo1 ,pr ,args ...)]
            [else `(call ,preinfo ,proc ,args ...)]))))

    (define build-let
      (case-lambda
        [(lambda-preinfo ids exps body)
         (build-call (make-preinfo-call) (build-lambda lambda-preinfo ids body) exps)]
        [(ids exps body) (build-call (make-preinfo-call) (build-lambda ids body) exps)]))

    (define build-named-let
      (lambda (name ids exps body)
        `(call ,(make-preinfo-call)
           (letrec ([,name ,(build-lambda ids body)])
             (ref #f ,name))
           ,exps ...)))

    (define make-seq
      ; ensures that the right subtree of the output seq is not a seq if the
      ; second argument is similarly constrained, to facilitate result-exp
      (lambda (ctxt e1 e2)
        (if (simple? e1)
            e2
            (cond
             [(and (eq? ctxt 'effect) (simple? e2))
              e1]
             [(and (eq? ctxt 'ignored) (simple1? e2)
                   ;; don't move e1 into a single-value
                   ;; position unless that's ok
                   (single-valued/inspect-ok? e1))
              e1]
             [else
              (let ([e1 (nanopass-case (Lsrc Expr) e1
                          [(seq ,e11 ,e12)
                           (guard (simple? e12))
                           e11]
                          [else e1])])
                (nanopass-case (Lsrc Expr) e2
                  [(seq ,e21 ,e22) `(seq (seq ,e1 ,e21) ,e22)]
                  [else `(seq ,e1 ,e2)]))]))))

    (define make-1seq
      ;; like `make-seq`, but preserves the requirement that `e1`
      ;; produces a single value when compiling in safe mode
      (lambda (ctxt e1 e2)
        (make-seq ctxt (safe-single-value e1) e2)))

    (define (safe-single-value e1)
      (if (or (fx= (optimize-level) 3)
              (single-valued/inspect-ok? e1))
          e1
          (build-primcall 3 '$value (list e1))))

    (define make-seq* ; requires at least one operand
      (lambda (ctxt e*)
        (if (null? (cdr e*))
            (car e*)
            (make-seq ctxt (car e*) (make-seq* ctxt (cdr e*))))))

    (define make-1seq* ; requires at least one operand
      (lambda (ctxt e*)
        (if (null? (cdr e*))
            (safe-single-value (car e*))
            (make-1seq ctxt (car e*) (make-1seq* ctxt (cdr e*))))))

    (define make-if
      (lambda (ctxt sc e1 e2 e3)
        (cond
          [(record-equal? e2 e3 ctxt) (make-1seq ctxt e1 e2)]
          [(and (cp0-constant? (lambda (x) (eq? x #f)) e3)
                (record-equal? e1 e2 (if (eq? ctxt 'test) 'test 'value))
                (simple? e1))
           e1]
          [(and (cp0-constant? (lambda (x) (eq? x #f)) e3)
                (cp0-constant? (lambda (x) (eq? x #t)) e2)
                (or (boolean-valued? e1) (eq? ctxt 'test)))
           (make-nontail ctxt e1)]
          [(nanopass-case (Lsrc Expr) (result-exp e1)
             [(if ,e11 ,[result-exp : e12 -> re12] ,[result-exp : e13 -> re13])
              (if (and (cp0-constant? re12) (cp0-constant? re13))
                  (let ([d12 (cp0-datum re12)] [d13 (cp0-datum re13)])
                    (non-result-exp e1
                      (cond
                        [(and d12 d13) (make-1seq ctxt (make-if 'ignored sc e11 e12 e13) e2)]
                        [(not (or d12 d13)) (make-1seq ctxt (make-if 'ignored sc e11 e12 e13) e3)]
                        [else (let-values ([(e2 e3) (if d12 (values e2 e3) (values e3 e2))])
                                (make-if ctxt sc e11 (non-result-exp e12 e2) (non-result-exp e13 e3)))])))
                  #f)]
             [else #f])]
          [(nanopass-case (Lsrc Expr) (result-exp e1)
             [(call ,preinfo ,e10 ,e11 ,e12)
              (guard (and (primref? e10) (memq (primref-name e10) '(eq? eqv?))))
              (if (and (or (and (record-equal? e11 e2 'value) (record-equal? e12 e3 'value))
                           (and (record-equal? e11 e3 'value) (record-equal? e12 e2 'value)))
                       (simple? e2)
                       (simple? e3))
                  (non-result-exp e1 (make-1seq ctxt e2 e3))
                  #f)]
             [else #f])]
          [else
           (bump sc 1)
           `(if ,e1 ,e2 ,e3)])))

    (define make-nontail
      (lambda (ctxt e)
        (context-case ctxt
          [(tail)
           (if (single-valued? e)
               e
               (build-primcall 3 '$value (list e)))]
          ;; An 'effect, 'ignored, 'value, or 'test position will not
          ;; have any attachment on the immediate continuation.
          ;; Also, an 'ignored, 'value, or 'test position will already
          ;; enforce a single result value
          [(effect) (safe-single-value e)]
          [else e])))

    (define result-exp
      (lambda (e)
        (nanopass-case (Lsrc Expr) e
          [(seq ,e1 ,e2) e2]
          [else e])))

    (define result-exp/indirect-ref
      ; useful only when interested in non-propagatable result expressions, e.g., lambda expressions
      ; NB: to avoid code duplication, don't residualize the resulting value
      (lambda (x)
        (let ([x (result-exp x)])
          (or (nanopass-case (Lsrc Expr) x
                [(ref ,maybe-src ,x)
                 (and (not (prelex-was-assigned x))
                      (let ([opnd (prelex-operand x)])
                        (and opnd
                             (let ([x (operand-value opnd)])
                               (and x (result-exp x))))))]
                [else #f])
              x))))

    (define non-result-exp
      (lambda (e body)
        (nanopass-case (Lsrc Expr) e
          [(seq ,e1 ,e2) `(seq ,e1 ,body)]
          [else body])))

    (define (arity-okay? arity n)
      (or (not arity) ; presumably system routine w/no recorded arity
          (ormap
            (lambda (a)
              (or (fx= n a)
                  (and (fx< a 0) (fx>= n (fx- -1 a)))))
            arity)))

    (define okay-to-copy?
      (lambda (obj)
        ; okay to copy obj if (eq? (faslin (faslout x)) x) => #t or (in the case of numbers and characters)
        ; the value of (eq? x x) is unspecified
        (or (and (symbol? obj) (not (uninterned-symbol? obj)))
            (number? obj)
            (char? obj)
            (boolean? obj)
            (null? obj)
            (eqv? obj "")
            (eqv? obj (string->immutable-string ""))
            (eqv? obj '#())
            (eqv? obj (vector->immutable-vector '#()))
            (eqv? obj '#vu8())
            (eqv? obj (bytevector->immutable-bytevector '#vu8()))
            (eqv? obj '#vfx())
            ; no null-immutable-fxvector
            (eqv? obj '#vfl())
            ; no null-immutable-flvector
            (eq? obj (void))
            (eof-object? obj)
            (bwp-object? obj)
            (eq? obj '#6=#6#)
            ($unbound-object? obj)
            (record-type-descriptor? obj))))

    ;; Returns #f if the clause is not externally inlinable
    (define externally-inlinable
      (lambda (clause exts)
        (call/cc
         (lambda (exit)
            (define bump!
              (let ([size 0])
                (lambda ()
                  (set! size (fx+ size 1))
                  (when (fx> size score-limit) (exit #f)))))
            (define find-ext
              (lambda (x)
                (let loop ([exts exts])
                  (cond
                   [(null? exts) #f]
                   [(eq? (prelex-uname x) (prelex-uname (caar exts)))
                    (cdar exts)]
                   [else (loop (cdr exts))]))))
            (define (ids->do-clause ids)
              (rec do-clause
                (lambda (clause)
                  (define (ids->do-expr ids)
                    (rec do-expr
                      (lambda (e)
                        (nanopass-case (Lsrc Expr) e
                          [(quote ,d) (if (okay-to-copy? d) (begin (bump!) e) (exit #f))]
                          [(moi) (bump!) e]
                          [,pr (bump!) e]
                          [(ref ,maybe-src ,x) (cond
                                                [(memq x ids) (bump!) e]
                                                [(and (not (prelex-was-assigned x))
                                                      (find-ext x))
                                                 => (lambda (label)
                                                      (bump!)
                                                      (let ([preinfo (make-preinfo-call #f #f (preinfo-call-mask unchecked no-inline))])
                                                        (build-primcall preinfo 3 '$top-level-value (list `(quote ,label)))))]
                                                [else
                                                 (exit #f)])]
                          [(seq ,[do-expr : e1] ,[do-expr : e2]) `(seq ,e1 ,e2)]
                          [(if ,[do-expr : e1] ,[do-expr : e2] ,[do-expr : e3]) `(if ,e1 ,e2 ,e3)]
                          [(set! ,maybe-src ,x ,e)
                           (unless (memq x ids) (exit #f))
                           (bump!)
                           `(set! ,maybe-src ,x ,(do-expr e))]
                          [(call ,preinfo ,e ,e* ...)
                           ; reject calls to gensyms, since they might represent library exports,
                           ; and we have no way to set up the required invoke dependencies, unless
                           ; we're not emiting invoke dependencies anyway
                           (when (and (nanopass-case (Lsrc Expr) e
                                        [,pr (eq? (primref-name pr) '$top-level-value)]
                                        [else #f])
                                      (= (length e*) 1)
                                      (cp0-constant? gensym? (car e*))
                                      (not (expand-omit-library-invocations)))
                             (exit #f))
                           (bump!)
                           `(call ,preinfo ,(do-expr e) ,(map do-expr e*) ...)]
                          [(case-lambda ,preinfo ,cl* ...)
                           (bump!)
                           `(case-lambda ,preinfo ,(map (ids->do-clause ids) cl*) ...)]
                          [(letrec ([,x* ,e*] ...) ,body)
                           (bump!)
                           (safe-assert (andmap (lambda (x) (not (prelex-operand x))) x*))
                           (let ([do-expr (ids->do-expr (append x* ids))])
                             `(letrec ([,x* ,(map do-expr e*)] ...) ,(do-expr body)))]
                          [(letrec* ([,x* ,e*] ...) ,body)
                           (bump!)
                           (safe-assert (andmap (lambda (x) (not (prelex-operand x))) x*))
                           (let ([do-expr (ids->do-expr (append x* ids))])
                             `(letrec* ([,x* ,(map do-expr e*)] ...) ,(do-expr body)))]
                          [(record-type ,rtd ,[do-expr : e]) `(record-type ,rtd ,e)]
                          [(record-cd ,rcd ,rtd-expr ,[do-expr : e]) `(record-cd ,rcd ,rtd-expr ,e)]
                          [(record-ref ,rtd ,type ,index ,[do-expr : e])
                           (bump!)
                           `(record-ref ,rtd ,type ,index ,e)]
                          [(record-set! ,rtd ,type ,index ,[do-expr : e1] ,[do-expr : e2])
                           (bump!)
                           `(record-set! ,rtd ,type ,index ,e1 ,e2)]
                          [(record ,rtd ,[do-expr : rtd-expr] ,[do-expr : e*] ...)
                           (bump!)
                           `(record ,rtd ,rtd-expr ,e* ...)]
                          [(immutable-list (,[e*] ...) ,[e])
                           `(immutable-list (,e* ...) ,e)]
                          [(immutable-vector (,[e*] ...) ,[e])
                           `(immutable-vector (,e* ...) ,e)]
                          [(pariah) e]
                          [(profile ,src) e]
                          [else (exit #f)]))))
                  (nanopass-case (Lsrc CaseLambdaClause) clause
                    [(clause (,x* ...) ,interface ,body)
                     (safe-assert (andmap (lambda (x) (not (prelex-operand x))) x*))
                     (with-output-language (Lsrc CaseLambdaClause)
                       `(clause (,x* ...) ,interface ,((ids->do-expr (append x* ids)) body)))]))))
            ((ids->do-clause '()) clause)))))

    (module (pure? ivory? ivory1? simple? simple1? simple/profile? simple/profile1? boolean-valued?
                   single-valued? single-valued single-valued-join single-valued-reduce?
                   single-valued/inspect-ok?)

      ;; The memoization table has, for each key, either a flags integer
      ;; or a pair of a flags integer and a value. The value corresponds to
      ;; a use of `(with-memoize () ....)`, while uses of the flags integer
      ;; are `(with-memoize (flag-known flag) ....)`.

      (define-syntax make-$memoize
        (syntax-rules ()
          [(_ flag-known flag)
           (lambda (e pred?)
             (let ([a (eq-hashtable-cell cp0-info-hashtable e 0)])
               (let ([flags (let ([val (cdr a)]) (if (pair? val) (cdr val) val))])
                 (if (all-set? (cp0-info-mask flag-known) flags)
                     (all-set? (cp0-info-mask flag) flags)
                     (let ([bool (pred?)])
                       (set-cdr! (let ([val (cdr a)]) (if (pair? val) val a))
                                 (set-flags (if bool (cp0-info-mask flag-known flag) (cp0-info-mask flag-known))
                                            flags))
                       bool)))))]
          [(_)
           (lambda (e pred?)
             (let ([a (eq-hashtable-cell cp0-info-hashtable e 0)])
               (let ([val (cdr a)])
                 (if (pair? val)
                     (car val)
                     (let ([r (pred?)])
                       (let ([p (cdr a)])
                         ;; p may have been set meanwhile, but we want to update
                         ;; the cdr to handle joins around recursive calls
                         (set-cdr! a (cons r (if (pair? p) (cdr p) p))))
                       r)))))]))

      (define-syntax with-memoize
        (lambda (x)
          (syntax-case x ()
            [(k (flag-info ...) ?e e* ...)
             (with-implicit (k memoize)
               #'(let ([$memoize (make-$memoize flag-info ...)] [e ?e])
                   (define-syntax memoize
                     (syntax-rules ()
                       [(_ e1 e2 (... ...)) ($memoize e (lambda () e1 e2 (... ...)))]))
                   e* ...))])))

      (define-who pure?
        ; does not cause or observe any effects, capture or invoke a continuation,
        ; or allocate mutable data structures.  might contain profile forms, so
        ; pure forms cannot necessarily be discarded.  mostly used to determine if
        ; we can move an expression.  differs from ivory in that restricted primitives
        ; and record refs are not considered pur at optimize-level 3, which allows
        ; pure expressions to be moved in more circumstances.
        (lambda (e)
          (with-memoize (pure-known pure) e
            ; 2015/02/11 sorted by frequency
            (nanopass-case (Lsrc Expr) e
              [(ref ,maybe-src ,x) (not (prelex-was-assigned x))]
              [(call ,preinfo ,e ,e* ...)
               (let ()
                 (define pure-call?
                   (lambda (maybe-e e)
                     (nanopass-case (Lsrc Expr) e
                       [,pr
                        (and (let ([flags (primref-flags e)])
                               (all-set? (prim-mask (or pure unrestricted)) flags))
                             (arity-okay? (primref-arity e) (length e*))
                             (memoize (and (or (not maybe-e) (pure? maybe-e)) (andmap pure? e*))))]
                       [(case-lambda ,preinfo1 (clause (,x* ...) ,interface ,body))
                        (guard (fx= interface (length e*)))
                        (memoize (and (or (not maybe-e) (pure? maybe-e)) (pure? body) (andmap pure1? e*)))]
                       [else #f])))
                 (nanopass-case (Lsrc Expr) e
                   [(seq ,e1 ,e2) (pure-call? e1 e2)]
                   [else (pure-call? #f e)]))]
              [(quote ,d) #t]
              [,pr (all-set? (prim-mask proc) (primref-flags pr))]
              [(case-lambda ,preinfo ,cl* ...) #t]
              [(if ,e1 ,e2 ,e3) (memoize (and (pure1? e1) (pure? e2) (pure? e3)))]
              [(seq ,e1 ,e2) (memoize (and (pure? e1) (pure? e2)))]
              [(record-ref ,rtd ,type ,index ,e) #f]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #f]
              [(record ,rtd ,rtd-expr ,e* ...)
               (and (rtd-all-immutable-scheme-objects? rtd)
                    (memoize (and (pure1? rtd-expr) (andmap pure1? e*))))]
              [(set! ,maybe-src ,x ,e) #f]
              [(record-cd ,rcd ,rtd-expr ,e) (memoize (pure1? e))]
              [(letrec ([,x* ,e*] ...) ,body) (memoize (and (andmap pure1? e*) (pure? body)))]
              [(record-type ,rtd ,e) (memoize (pure1? e))]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) (memoize (pure? e))]
              [(letrec* ([,x* ,e*] ...) ,body) (memoize (and (andmap pure1? e*) (pure? body)))]
              [(immutable-list (,e* ...) ,e) (memoize (and (andmap pure1? e*) (pure? e)))]
              [(immutable-vector (,e* ...) ,e) (memoize (and (andmap pure1? e*) (pure? e)))]
              [(profile ,src) #t]
              [(cte-optimization-loc ,box ,e ,exts) (memoize (pure? e))]
              [(moi) #t]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) (memoize (pure1? e))]
              [(pariah) #t]
              [else ($oops who "unrecognized record ~s" e)]))))

      (define pure1?
        (lambda (e)
          (and (pure? e)
               (or (fx= (optimize-level) 3) (single-valued? e)))))

      (define-who ivory? ; 99.44% pure
        ; does not cause or observe any effects, capture or invoke a continuation,
        ; or allocate mutable data structures.  might contain profile forms, so
        ; ivory forms cannot necessarily be discarded.  mostly used to determine if
        ; we can move an expression.  differs from pure in that restricted primitives
        ; and record refs are considered ivory at optimize-level 3.
        (lambda (e)
          (with-memoize (ivory-known ivory) e
            ; 2015/02/11 sorted by frequency
            (nanopass-case (Lsrc Expr) e
              [(ref ,maybe-src ,x) (not (prelex-was-assigned x))]
              [(call ,preinfo ,e ,e* ...)
               (let ()
                 (define ivory-call?
                   (lambda (maybe-e e)
                     (nanopass-case (Lsrc Expr) e
                       [,pr
                        (and (let ([flags (primref-flags e)])
                               ; here ivory? differs from pure?
                               (if (all-set? (prim-mask unsafe) flags)
                                   (all-set? (prim-mask pure) flags)
                                   (all-set? (prim-mask (or pure unrestricted)) flags)))
                             (arity-okay? (primref-arity e) (length e*))
                             (memoize (and (or (not maybe-e) (ivory? maybe-e)) (andmap ivory1? e*))))]
                       [(case-lambda ,preinfo1 (clause (,x* ...) ,interface ,body))
                        (guard (fx= interface (length e*)))
                        (memoize (and (or (not maybe-e) (ivory? maybe-e)) (ivory? body) (andmap ivory1? e*)))]
                       [else #f])))
                 (nanopass-case (Lsrc Expr) e
                   [(seq ,e1 ,e2) (ivory-call? e1 e2)]
                   [else (ivory-call? #f e)]))]
              [(quote ,d) #t]
              [,pr (all-set? (prim-mask proc) (primref-flags pr))]
              [(case-lambda ,preinfo ,cl* ...) #t]
              [(if ,e1 ,e2 ,e3) (memoize (and (ivory1? e1) (ivory? e2) (ivory? e3)))]
              [(seq ,e1 ,e2) (memoize (and (ivory? e1) (ivory? e2)))]
              [(record-ref ,rtd ,type ,index ,e) 
               ; here ivory? differs from pure?
               (and (rtd-immutable-field? rtd index)
                    (memoize (ivory1? e)))]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #f]
              [(record ,rtd ,rtd-expr ,e* ...)
               ; here ivory? differs from pure?
               (and (rtd-all-immutable? rtd)
                    (memoize (and (ivory1? rtd-expr) (andmap ivory1? e*))))]
              [(set! ,maybe-src ,x ,e) #f]
              [(record-cd ,rcd ,rtd-expr ,e) (memoize (ivory1? e))]
              [(letrec ([,x* ,e*] ...) ,body) (memoize (and (andmap ivory1? e*) (ivory? body)))]
              [(record-type ,rtd ,e) (memoize (ivory1? e))]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) (memoize (ivory1? e))]
              [(letrec* ([,x* ,e*] ...) ,body) (memoize (and (andmap ivory1? e*) (ivory? body)))]
              [(immutable-list (,e* ...) ,e) (memoize (and (andmap ivory1? e*) (ivory? e)))]
              [(immutable-vector (,e* ...) ,e) (memoize (and (andmap ivory1? e*) (ivory? e)))]
              [(profile ,src) #t]
              [(cte-optimization-loc ,box ,e ,exts) (memoize (ivory? e))]
              [(moi) #t]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) (memoize (ivory1? e))]
              [(pariah) #t]
              [else ($oops who "unrecognized record ~s" e)]))))

      (define ivory1?
        (lambda (e)
          (and (ivory? e)
               (or (fx= (optimize-level) 3) (single-valued? e)))))

      (define-who simple?
        (lambda (e)
          (with-memoize (simple-known simple) e
            ; does not cause any effects or capture or invoke a continuation, and does not
            ; contain profile forms, but might observe effects or allocate mutable data
            ; structures.  ; mostly used to determine if we can discard an expression.
            ; 2015/02/11 sorted by frequency
            (nanopass-case (Lsrc Expr) e
              ; might be nice to have an ignorem style syntax for the nanopass-case (and passes)
              [(quote ,d) #t]
              [(call ,preinfo ,e ,e* ...)
               (nanopass-case (Lsrc Expr) e
                 [,pr (let ([flags (primref-flags pr)])
                        (and (if (all-set? (prim-mask unsafe) flags)
                                 (all-set? (prim-mask discard) flags)
                                 (all-set? (prim-mask (or discard unrestricted)) flags))
                             (arity-okay? (primref-arity pr) (length e*))
                             (memoize (andmap simple1? e*))))]
                 [(case-lambda ,preinfo1 (clause (,x* ...) ,interface ,body))
                  (guard (fx= interface (length e*)))
                  (memoize (and (simple? body) (andmap simple1? e*)))]
                 [else #f])]
              [(ref ,maybe-src ,x) #t]
              [(case-lambda ,preinfo ,cl* ...) #t]
              [(if ,e1 ,e2 ,e3) (memoize (and (simple1? e1) (simple? e2) (simple? e3)))]
              [(seq ,e1 ,e2) (memoize (and (simple? e1) (simple? e2)))]
              [(set! ,maybe-src ,x ,e) #f]
              [(immutable-list (,e* ...) ,e) (memoize (and (andmap simple1? e*) (simple? e)))]
              [(immutable-vector (,e* ...) ,e) (memoize (and (andmap simple1? e*) (simple? e)))]
              [(letrec ([,x* ,e*] ...) ,body) (memoize (and (andmap simple1? e*) (simple? body)))]
              [(letrec* ([,x* ,e*] ...) ,body) (memoize (and (andmap simple1? e*) (simple? body)))]
              [,pr #t]
              [(record-cd ,rcd ,rtd-expr ,e) (memoize (simple1? e))]
              [(record-ref ,rtd ,type ,index ,e) (memoize (simple1? e))]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #f]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) (memoize (simple1? e))]
              [(record-type ,rtd ,e) (memoize (simple1? e))]
              [(record ,rtd ,rtd-expr ,e* ...) (memoize (and (simple1? rtd-expr) (andmap simple1? e*)))]
              [(pariah) #f]
              [(profile ,src) #f]
              [(cte-optimization-loc ,box ,e ,exts) (memoize (simple? e))]
              [(moi) #t]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) (memoize (simple1? e))]
              [else ($oops who "unrecognized record ~s" e)]))))

      (define simple1?
        (lambda (e)
          (and (simple? e)
               (or (fx= (optimize-level) 3)
                   (single-valued? e)))))

      (define-who simple/profile?
        ; like simple? but allows profile forms.  used for lifting bindings.
        (lambda (e)
          (with-memoize (simple-known simple) e
            ; does not cause any effects or capture or invoke a continuation, and does not
            ; contain profile forms, but might observe effects or allocate mutable data
            ; structures.  ; mostly used to determine if we can discard an expression.
            ; 2015/02/11 sorted by frequency
            (nanopass-case (Lsrc Expr) e
              ; might be nice to have an ignorem style syntax for the nanopass-case (and passes)
              [(quote ,d) #t]
              [(call ,preinfo ,e ,e* ...)
               (nanopass-case (Lsrc Expr) e
                 [,pr (let ([flags (primref-flags pr)])
                        (and (if (all-set? (prim-mask unsafe) flags)
                                 (all-set? (prim-mask discard) flags)
                                 (all-set? (prim-mask (or discard unrestricted)) flags))
                             (arity-okay? (primref-arity pr) (length e*))
                             (memoize (andmap simple/profile1? e*))))]
                 [(case-lambda ,preinfo1 (clause (,x* ...) ,interface ,body))
                  (guard (fx= interface (length e*)))
                  (memoize (and (simple/profile? body) (andmap simple/profile1? e*)))]
                 [else #f])]
              [(ref ,maybe-src ,x) #t]
              [(case-lambda ,preinfo ,cl* ...) #t]
              [(if ,e1 ,e2 ,e3) (memoize (and (simple/profile1? e1) (simple/profile? e2) (simple/profile? e3)))]
              [(seq ,e1 ,e2) (memoize (and (simple/profile? e1) (simple/profile? e2)))]
              [(set! ,maybe-src ,x ,e) #f]
              [(immutable-list (,e* ...) ,e) (memoize (and (andmap simple/profile1? e*) (simple/profile? e)))]
              [(immutable-vector (,e* ...) ,e) (memoize (and (andmap simple/profile1? e*) (simple/profile? e)))]
              [(letrec ([,x* ,e*] ...) ,body) (memoize (and (andmap simple/profile1? e*) (simple/profile? body)))]
              [(letrec* ([,x* ,e*] ...) ,body) (memoize (and (andmap simple/profile1? e*) (simple/profile? body)))]
              [,pr #t]
              [(record-cd ,rcd ,rtd-expr ,e) (memoize (simple/profile1? e))]
              [(record-ref ,rtd ,type ,index ,e) (memoize (simple/profile1? e))]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #f]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) (memoize (simple/profile1? e))]
              [(record-type ,rtd ,e) (memoize (simple/profile1? e))]
              [(record ,rtd ,rtd-expr ,e* ...) (memoize (and (simple/profile1? rtd-expr) (andmap simple/profile1? e*)))]
              [(pariah) #t]
              [(profile ,src) #t]
              [(cte-optimization-loc ,box ,e ,exts) (memoize (simple/profile? e))]
              [(moi) #t]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) (memoize (simple/profile1? e))]
              [else ($oops who "unrecognized record ~s" e)]))))

      (define simple/profile1?
        (lambda (e)
          (and (simple/profile? e)
               (or (fx= (optimize-level) 3) (single-valued? e)))))

      (define (extract-called-procedure pr e*)
        (case (primref-name pr)
          [(call-with-values)
           (and (fx= (length e*) 2)
                (cadr e*))]
          [(r6rs:dynamic-wind)
           (and (fx= (length e*) 3)
                (cadr e*))]
          [(dynamic-wind)
           (cond
            [(fx= (length e*) 3) (cadr e*)]
            [(fx= (length e*) 4) (caddr e*)]
            [else #f])]
          [(apply $apply)
           (and (fx>= (length e*) 1)
                (car e*))]
          [else #f]))

      (define (extract-called-procedure/inspect-ok pr e*)
        (case (primref-name pr)
          [($call-setting-continuation-attachment
            $call-getting-continuation-attachment
            $call-consuming-continuation-attachment)
           (and (fx= (length e*) 2)
                (cadr e*))]
          [else #f]))

      (define-who boolean-valued?
        (lambda (e)
          (with-memoize (boolean-valued-known boolean-valued) e
            ; 2015/02/11 sorted by frequency
            (nanopass-case (Lsrc Expr) e
              [(call ,preinfo ,e ,e* ...)
               (let procedure-boolean-valued? ([e e] [e* e*])
                 (nanopass-case (Lsrc Expr) (result-exp e)
                   [,pr
                    (or (all-set? (prim-mask boolean-valued) (primref-flags pr))
                        (and e*
                             (let ([proc-e (extract-called-procedure pr e*)])
                               (and proc-e
                                    (memoize (procedure-boolean-valued? proc-e #f))))))]
                   [(case-lambda ,preinfo ,cl* ...)
                    (memoize (andmap (lambda (cl)
                                       (nanopass-case (Lsrc CaseLambdaClause) cl
                                         [(clause (,x* ...) ,interface ,body)
                                          (boolean-valued? body)]))
                                     cl*))]
                   [else #f]))]
              [(if ,e0 ,e1 ,e2) (memoize (and (boolean-valued? e1) (boolean-valued? e2)))]
              [(record-ref ,rtd ,type ,index ,e) (eq? type 'boolean)]
              [(ref ,maybe-src ,x) #f]
              [(quote ,d) (boolean? d)]
              [(seq ,e1 ,e2) (memoize (boolean-valued? e2))]
              [(case-lambda ,preinfo ,cl* ...) #f]
              [(letrec* ([,x* ,e*] ...) ,body) (memoize (boolean-valued? body))]
              [(letrec ([,x* ,e*] ...) ,body) (memoize (boolean-valued? body))]
              [,pr #f]
              [(record-type ,rtd ,e) #f]
              [(record-cd ,rcd ,rtd-expr ,e) #f]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #f]
              [(record ,rtd ,rtd-expr ,e* ...) #f]
              [(immutable-list (,e* ...) ,e) #f]
              [(immutable-vector (,e* ...) ,e) #f]
              [(cte-optimization-loc ,box ,e ,exts) (memoize (boolean-valued? e))]
              [(profile ,src) #f]
              [(set! ,maybe-src ,x ,e) #f]
              [(moi) #f]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) #f]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) #f]
              [(pariah) #f]
              [else ($oops who "unrecognized record ~s" e)]))))

      ;; Returns #t, #f, 'value/inspect (single-valued, but may
      ;; inspect continuation), or a prelex for a lambda that needs to
      ;; be single-valued to imply #t. The prelex case is useful to
      ;; detect a single-valued loop. When `debug-level` is 2 or more,
      ;; we treat aborting ops as 'value/inspect instead of #t so that
      ;; those calls are not moved into tail position (especially after
      ;; cptypes lifts them into a sequence with `(void)`).
      (define-who single-valued
        (lambda (e)
          (with-memoize () e
            ; known to produce a single value
            (nanopass-case (Lsrc Expr) e
              [(quote ,d) #t]
              [(call ,preinfo ,e ,e* ...)
               (or (and (or (and (preinfo-call-no-return? preinfo)
                                 (if (fx< (debug-level) 2)
                                     #t
                                     'value/inspect))
                            (preinfo-call-single-valued? preinfo))
                        (not (preinfo-call-check? preinfo)))
                   (let procedure-single-valued ([e e] [e* e*])
                     (nanopass-case (Lsrc Expr) (result-exp e)
                       [,pr
                        (or (and (all-set? (prim-mask abort-op) (primref-flags pr))
                                 (if (fx< (debug-level) 2)
                                     #t
                                     'value/inspect))
                            (all-set? (prim-mask single-valued) (primref-flags pr))
                            (and e*
                                 (cond
                                   [(extract-called-procedure pr e*)
                                    => (lambda (proc-e)
                                         (memoize (procedure-single-valued proc-e #f)))]
                                   [(extract-called-procedure/inspect-ok pr e*)
                                    => (lambda (proc-e)
                                         (memoize (single-valued-join 'value/inspect
                                                                      (procedure-single-valued proc-e #f))))]
                                   [else #f])))]
                       [(case-lambda ,preinfo ,cl* ...)
                        (memoize (or
                                  (all-set? (constant code-flag-single-valued)
                                            (preinfo-lambda-flags preinfo))
                                  (fold-left (lambda (r cl)
                                               (and r
                                                    (nanopass-case (Lsrc CaseLambdaClause) cl
                                                      [(clause (,x* ...) ,interface ,body)
                                                       (single-valued-join r (single-valued body))])))
                                             #t
                                             cl*)))]
                       [(ref ,maybe-src ,x)
                        (let ([v (and (not (prelex-was-assigned x))
                                      (let ([opnd (prelex-operand x)])
                                        (and opnd
                                             (operand-exp opnd))))])
                          (and v
                               (nanopass-case (Lsrc Expr) v
                                 [(case-lambda ,preinfo ,cl* ...)
                                  ;; Don't recur into the clauses, since that
                                  ;; could send us into a loop for a `letrec`
                                  ;; binding. But use the prelex as a summary
                                  ;; or a way to tie a loop:
                                  (preinfo->single-valued preinfo x)]
                                 [(call ,preinfo0 ,pr (case-lambda ,preinfo ,cl* ...) ,e ...)
                                  (or (eq? (primref-name pr) 'make-wrapper-procedure)
                                      (eq? (primref-name pr) 'make-arity-wrapper-procedure))
                                  (preinfo->single-valued preinfo x)]
                                 [else #f])))]
                       ;; Recognize call to a loop, and use the loop's prelex in that case:
                       [(letrec ([,x1 (case-lambda ,preinfo ,cl* ...)]) (ref ,maybe-src ,x2))
                        (and (eq? x1 x2)
                             (preinfo->single-valued preinfo x1))]
                       [(letrec* ([,x1 (case-lambda ,preinfo ,cl* ...)]) (ref ,maybe-src ,x2))
                        (and (eq? x1 x2)
                             (preinfo->single-valued preinfo x1))]
                       [(call ,preinfo ,pr ,e)
                        (guard (eq? (primref-name pr) '$top-level-value))
                        ;; Check for cross-module single-valued information:
                        (nanopass-case (Lsrc Expr) e
                          [(quote ,d)
                           (guard (symbol? d))
                           (let ([as (assq ($target-machine) ($cte-optimization-info d))])
                             (and as
                                  (cte-info-procedure-single-valued? (cdr as))))]
                          [else #f])]
                       [else #f])))]
              [(ref ,maybe-src ,x) #t]
              [(case-lambda ,preinfo ,cl* ...) #t]
              [(if ,e1 ,e2 ,e3) (memoize (single-valued-join (single-valued e2) (single-valued e3)))]
              [(seq ,e1 ,e2) (memoize (single-valued e2))]
              [(set! ,maybe-src ,x ,e) #t]
              [(immutable-list (,e* ...) ,e) #t]
              [(immutable-vector (,e* ...) ,e) #t]
              [(letrec ([,x* ,e*] ...) ,body) (memoize (single-valued body))]
              [(letrec* ([,x* ,e*] ...) ,body) (memoize (single-valued body))]
              [,pr #t]
              [(record-cd ,rcd ,rtd-expr ,e) #t]
              [(record-ref ,rtd ,type ,index ,e) #t]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #t]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) #t]
              [(record-type ,rtd ,e) #t]
              [(record ,rtd ,rtd-expr ,e* ...) #t]
              [(pariah) #t]
              [(profile ,src) #t]
              [(cte-optimization-loc ,box ,e ,exts) (memoize (single-valued e))]
              [(moi) #t]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) #t]
              [else ($oops who "unrecognized record ~s" e)]))))

      (define (preinfo->single-valued preinfo x)
        ;; If the single-valued flag is set, simplify to #t,
        ;; otherwise return the prelex x to mean "single-valued
        ;; if the lambda for x is single-valued".
        (or (all-set? (constant code-flag-single-valued)
                      (preinfo-lambda-flags preinfo))
            x))

      (define single-valued-join
        (lambda (a b)
          (cond
           [(eq? a b) a]
           [(eq? a #t) b]
           [(eq? b #t) a]
           [(eq? a 'value/inspect) b]
           [(eq? b 'value/inspect) a]
           ;; If `a` and `b` are different prelexes, we currently give
           ;; up, because a prelex is used only to find a
           ;; single-function fixpoint.
           [else #f])))

      (define-who single-valued/inspect-ok?
        (lambda (e)
          (let ([r (single-valued e)])
            (or (eq? r 'value/inspect) ; i.e., ok to inspect continuation
                (single-valued-reduce? r)))))

      (define single-valued-reduce?
        (lambda (r)
          (cond
           [(eq? r #t) #t]
           [(eq? r #f) #f]
           [(eq? r 'value/inspect) #f]
           ;; conservative assumption for a prelex:
           [else #f])))

      ;; Single-valued and ok to move from non-tail to tail position
      ;; (because it doesn't inspect the continuation)?
      (define-who single-valued?
        (lambda (e)
          (single-valued-reduce? (single-valued e)))))

    (define find-call-lambda-clause
      (lambda (exp opnds)
        (define rest-clause
          ; ((lambda (x1 ... xn . xr) e) a1 ... am) m >= n
          ;  => ((lambda (x1 ... xn tn+1 ... tm)
          ;        (let ((xr (list tn+1 ... tm)))
          ;          e))
          ;      a1 ... am)
          (lambda (ids opnds body)
            (with-values
              (let split ((ids ids) (opnds opnds))
                (if (null? (cdr ids))
                    (let ((temps (map (lambda (x) (cp0-make-temp #f)) opnds)))
                      (values temps temps (car ids)))
                    (with-values (split (cdr ids) (cdr opnds))
                      (lambda (new-ids temps rest-id)
                        (values (cons (car ids) new-ids) temps rest-id)))))
              (lambda (ids temps rest-id)
                (values ids
                  (build-let (list rest-id)
                    (list
                      (let* ([tref* (map build-ref temps)]
                             [e (build-primcall 3 'list tref*)])
                        ; immutable-value presently set only by record-constructor
                        (if (prelex-immutable-value rest-id)
                            `(immutable-list (,tref* ...) ,e)
                            e)))
                    body))))))
        (nanopass-case (Lsrc Expr) exp
          [(case-lambda ,preinfo ,cl* ...)
           (let ((n (length opnds)))
             (let find-clause ([cl* cl*])
               (if (null? cl*)
                   (values)
                   (nanopass-case (Lsrc CaseLambdaClause) (car cl*)
                     [(clause (,x* ...) ,interface ,body)
                      (cond
                        [(fx= interface n) (values x* body)]
                        [(and (fx< interface 0)
                              (fx>= n (fx- -1 interface)))
                         (rest-clause x* opnds body)]
                        [else (find-clause (cdr cl*))])]))))])))

    (define find-apply-lambda-clause
      (lambda (exp opnds)
        (define apply-clause
          ; (apply (lambda (x1 ... xn) e) a1 ... am ar) m <= n
          ;  => ((lambda (x1 ... xm t)
          ;       (let ((xm+1 (car t)) (t (cdr t)))
          ;         ...
          ;           (let ((xn-1 (car t)) (t (cdr t)))
          ;             (let ((xn (car t)))
          ;               e))))
          ;      a1 ... am ar)
          ; we insist on m <= n to simplify the code below.  since this
          ; optimization is performed only when optimize-level is 3, we
          ; don't otherwise concern ourselves with argument-count checks
          (lambda (ids opnds body)
            (with-values
              (let split ([ids ids] [opnds opnds])
                (if (null? (cdr opnds))
                    (let ([t (cp0-make-temp #f)])
                      (values (list t) t ids))
                    (with-values (split (cdr ids) (cdr opnds))
                      (lambda (new-ids t more-ids)
                        (values (cons (car ids) new-ids) t more-ids)))))
              (lambda (ids t more-ids)
                (values ids
                  (if (null? more-ids)
                      body
                      (let f ([ids more-ids] [t t])
                        (let ([tref (list (build-ref t))])
                          (if (null? (cdr ids))
                              (build-let ids (list (build-primcall 3 'car tref)) body)
                              (begin
                                (set-prelex-multiply-referenced! t #t)
                                (let ([t (cp0-make-temp #f)])
                                  (build-let (list (car ids) t)
                                    (list
                                      (build-primcall 3 'car tref)
                                      (build-primcall 3 'cdr tref))
                                    (f (cdr ids) t)))))))))))))
        (nanopass-case (Lsrc Expr) exp
          [(case-lambda ,preinfo ,cl* ...)
           (let ([n (length opnds)])
             (cond
               [(fx= (length cl*) 1)
                (nanopass-case (Lsrc CaseLambdaClause) (car cl*)
                  [(clause (,x* ...) ,interface ,body)
                   (if (fx>= interface (fx- (length opnds) 1))
                       (apply-clause x* opnds body)
                       (values))])]
               [else (values)]))])))

    (define find-lambda-clause
      (lambda (exp ctxt)
        (convention-case (app-convention ctxt)
          [(call) (find-call-lambda-clause exp (app-opnds ctxt))]
          [(apply2) (values)]
          [(apply3) (find-apply-lambda-clause exp (app-opnds ctxt))])))

    (define (build-let-help lambda-preinfo id* rhs* body)
      (or (and (= (length id*) 1)
               (= (length rhs*) 1)
               (nanopass-case (Lsrc Expr) (car rhs*)
                 [(seq ,e1 ,e2)
                  ; (let ((x (begin e1 e2))) e3) => (begin e1 (let ((x e2)) e3))
                  ; this can expose (immutable-vector ...) in e2 to optimization
                  `(seq ,e1 ,(build-let lambda-preinfo id* (list e2) body))]
                 [else #f]))
          (build-let lambda-preinfo id* rhs* body)))

    (define letify
      (case-lambda
        [(lambda-preinfo id* ctxt body) (letify lambda-preinfo id* ctxt '() body)]
        [(lambda-preinfo id* ctxt used body)
         (if (cp0-constant? body)
             ; don't allow conservative referenced flags prevent constant folding
             (begin
               (residualize-seq '() (app-opnds ctxt) ctxt)
               body)
             (with-values
               (let loop ([id* id*] [opnd* (app-opnds ctxt)] [rid* '()] [rrhs* '()] [used used] [unused '()])
                 (if (null? id*)
                     (begin
                       (residualize-seq used unused ctxt)
                       (values (reverse rid*) (reverse rrhs*)))
                     (let ([id (car id*)] [opnd (car opnd*)])
                       (cond
                         [(prelex-referenced id)
                          (loop (cdr id*) (cdr opnd*) (cons id rid*) (cons (operand-value opnd) rrhs*) (cons opnd used) unused)]
                         [(prelex-assigned id)
                          (loop (cdr id*) (cdr opnd*) (cons id rid*) (cons void-rec rrhs*) used (cons opnd unused))]
                         [else (loop (cdr id*) (cdr opnd*) rid* rrhs* used (cons opnd unused))]))))
               (lambda (id* rhs*)
                 (cond
                   [(null? id*) body]
                   [(and (= (length id*) 1)
                         (nanopass-case (Lsrc Expr) body
                           [(ref ,maybe-src ,x) (eq? x (car id*))]
                           [else #f]))
                    ; (let ((x e)) x) => e
                    ; x is clearly not assigned, even if flags are polluted and say it is
                    (make-nontail (app-ctxt ctxt) (car rhs*))]
                   ; we drop the RHS of a let binding into the let body when the body expression is a call 
                   ; and we can do so without violating evaluation order of bindings wrt the let body:
                   ;  * for pure, singly referenced bindings, we drop them to the variable reference site
                   ;  * for impure, singly referenced bindings, we drop them only into the most deeply
                   ;    nested call of the let body to ensure the expression is fully evaluated before 
                   ;    any body (sub-)expressions
                   ; when we drop an impure let binding, we require the other bindings at the same level
                   ; to be unassigned so the location creation for the other bindings remains in the
                   ; continuation of the impure RHS.
                   ;
                   ; dropping let bindings enables pattern-based optimizations downstream that would
                   ; otherwise be inhibited by the let binding.  An example is the optimization in
                   ; expand-primitives to eliminate unnecessary ftype-pointer creation for nested
                   ; ftype-ref expressions.  dropping let bindings can also reduce register pressure,
                   ; though it can increase it as well.
                   ;
                   ; NB. nested let expressions can result in multiple traversals of the inner let bodies
                   ; NB. via multiple calls to letify, causing O(n^2) behavior.
                   [(and (ormap (lambda (x) (not (prelex-multiply-referenced x))) id*)
                         (let ([all-unassigned? (not (ormap (lambda (x) (prelex-assigned x)) id*))])
                           (define drop-let
                             (lambda (e* build-body)
                               (let ([alist (map cons id* rhs*)])
                                 (with-values (let f ([e* e*] [pure-left? #t])
                                                (if (null? e*)
                                                    (values '() #t)
                                                    (let ([e (car e*)] [e* (cdr e*)])
                                                      (let ([pure-e? (pure? e)]) ; would cause O(n^2) behavior except pure? caches purity of calls
                                                        (let-values ([(e* pure-right?) (f e* (and pure-left? pure-e?))])
                                                          (values
                                                            (cons
                                                              (nanopass-case (Lsrc Expr) e
                                                                [(call ,preinfo ,e2 ,e2* ...)
                                                                 (let ([e2* (cons e2 e2*)])
                                                                   (let-values ([(new-e2* pure-e2*?) (f e2* (and pure-left? pure-right?))])
                                                                     (if (andmap eq? new-e2* e2*)
                                                                         e
                                                                         (build-call preinfo (car new-e2*) (cdr new-e2*)))))]
                                                                [(record-ref ,rtd ,type ,index ,e2)
                                                                 (let-values ([(new-e2* pure-e2*?) (f (list e2) (and pure-left? pure-right?))])
                                                                   (safe-assert (= (length new-e2*) 1))
                                                                   (let ([new-e2 (car new-e2*)])
                                                                     (if (eq? new-e2 e2)
                                                                         e
                                                                         `(record-ref ,rtd ,type ,index ,new-e2))))]
                                                                [(record-set! ,rtd ,type ,index ,e21 ,e22)
                                                                 (let-values ([(new-e2* pure-e2*?) (f (list e21 e22) (and pure-left? pure-right?))])
                                                                   (safe-assert (= (length new-e2*) 2))
                                                                   (let ([new-e21 (car new-e2*)] [new-e22 (cadr new-e2*)])
                                                                     (if (and (eq? new-e21 e21) (eq? new-e22 e22))
                                                                         e
                                                                         `(record-set! ,rtd ,type ,index ,new-e21 ,new-e22))))]
                                                                [(record ,rtd ,rtd-expr ,e2* ...)
                                                                 (let ([e2* (cons rtd-expr e2*)])
                                                                   (let-values ([(new-e2* pure-e2*?) (f e2* (and pure-left? pure-right?))])
                                                                     (if (andmap eq? new-e2* e2*)
                                                                         e
                                                                         `(record ,rtd ,(car new-e2*) ,(cdr new-e2*) ...))))]
                                                                [(record-type ,rtd ,e)
                                                                 (let ([e* (list e)])
                                                                   (let-values ([(new-e* pure-e*?) (f e* (and pure-left? pure-right?))])
                                                                     (safe-assert (= (length new-e*) 1))
                                                                     (if (andmap eq? new-e* e*)
                                                                         e
                                                                         `(record-type ,rtd ,(car new-e*)))))]
                                                                [(ref ,maybe-src ,x)
                                                                 (guard (not (prelex-assigned x)) (not (prelex-multiply-referenced x)))
                                                                 (let ([a (assq x alist)])
                                                                   (if a
                                                                       (let ([rhs (cdr a)])
                                                                         (safe-assert rhs)
                                                                         (if (or (and pure-left? pure-right? all-unassigned?) (pure? rhs))
                                                                             (begin (set-cdr! a #f) rhs)
                                                                             e))
                                                                       e))]
                                                                [else e])
                                                              e*)
                                                            (and pure-e? pure-right?)))))))
                                   (lambda (new-e* . ignore)
                                     (let ([body (if (andmap eq? new-e* e*) body (build-body (car new-e*) (cdr new-e*)))])
                                       (let ([alist (filter cdr alist)])
                                         (if (null? alist) body (build-let-help lambda-preinfo (map car alist) (map cdr alist) body)))))))))
                           (nanopass-case (Lsrc Expr) body
                             [(call ,preinfo ,e ,e* ...)
                              (drop-let (cons e e*) (lambda (e e*) (build-call preinfo e e*)))]
                             [(record-ref ,rtd ,type ,index ,e)
                              (drop-let (list e) (lambda (e e*) (safe-assert (null? e*)) `(record-ref ,rtd ,type ,index ,e)))]
                             [(record-set! ,rtd ,type ,index ,e1 ,e2)
                              (drop-let (list e1 e2) (lambda (e e*) (safe-assert (= (length e*) 1)) `(record-set! ,rtd ,type ,index ,e ,(car e*))))]
                             [(record ,rtd ,rtd-expr ,e* ...)
                              (drop-let (cons rtd-expr e*) (lambda (rtd-expr e*) `(record ,rtd ,rtd-expr ,e* ...)))]
                             [(record-type ,rtd ,e)
                              (drop-let (list e) (lambda (e e*) (safe-assert (null? e*)) `(record-type ,rtd ,e)))]
                             [else #f])))]
                   [else (build-let-help lambda-preinfo id* rhs* body)]))))]))

    (define cp0-let
      (lambda (lambda-preinfo ids body ctxt env sc wd name moi)
        (let ((opnds (app-opnds ctxt)))
          (with-extended-env ((env ids) (env ids opnds))
            (letify lambda-preinfo ids ctxt (cp0 body (app-ctxt ctxt) env sc wd (app-name ctxt) moi))))))

    (define cp0-call
      (lambda (preinfo e opnds ctxt env sc wd name moi)
        (define (build-wrapper b* body)
          (if (null? b*)
              body
              (let ([b (car b*)] [body (build-wrapper (cdr b*) body)])
                (if (not b)
                    body
                    (let ([ids (lifted-ids b)] [vals (lifted-vals b)])
                      (for-each (lambda (id) (prelex-operand-set! id #f)) ids)
                      (if (lifted-seq? b)
                          `(letrec* ([,ids ,vals] ...) ,body)
                          `(letrec ([,ids ,vals] ...) ,body)))))))
        (let* ((ctxt (make-app opnds ctxt 'call name preinfo))
               (e (cp0 e ctxt env sc wd #f moi)))
          (build-wrapper (map operand-lifted opnds)
            (if (app-used ctxt)
                (residualize-call-opnds (app-used ctxt) (app-unused ctxt) e (app-ctxt ctxt) sc)
                (build-call preinfo e
                  (let f ((opnds opnds) (n 0))
                    (if (null? opnds)
                        (begin (bump sc n) '())
                        (let ((opnd (car opnds)))
                          (let ((e (operand-value opnd)))
                            (if e
                                (cons e (f (cdr opnds) (fx+ n (operand-score opnd))))
                                ; do rest first to bump for previsited operands first so
                                ; that we bug out quicker if bug out we do
                                (let ((rest (f (cdr opnds) n)))
                                  (cons (cp0 (operand-exp opnd) 'value env sc wd #f moi) rest)))))))))))))

    (define cp0-rec-let
      (lambda (seq? ids vals body ctxt env sc wd name moi)
        (with-extended-env ((env ids) (env ids #f))
          (let ((opnds (build-operands #f vals env wd moi)))
            ; these operands will be cleared by with-extended-env
            (for-each (lambda (id opnd)
                        (prelex-operand-set! id opnd)
                        (operand-name-set! opnd id))
              ids opnds)
            ; for r5rs letrec semantics: prevent copy propagation of references
            ; to lhs id if rhs might invoke call/cc
            ; not needed r6rs
            #;(for-each
                (lambda (id val)
                  (unless (simple? val)
                    (set-prelex-was-assigned! id #t)))
                ids vals)
            (let ((body (cp0 body ctxt env sc wd name moi)))
              ; visit operands as necessary
              (let loop ([ids ids]
                         [opnds opnds]
                         [pending-ids '()]
                         [pending-opnds '()]
                         [change? #f])
                (if (null? ids)
                    (when change? (loop pending-ids pending-opnds '() '() #f))
                    (let ([id (car ids)] [opnd (car opnds)])
                      (if (or (prelex-referenced id)
                              (not (simple1? (operand-exp opnd))))
                          (begin
                            (value-visit-operand! opnd)
                            (loop (cdr ids) (cdr opnds) pending-ids pending-opnds
                              (not (null? pending-ids))))
                          (loop (cdr ids) (cdr opnds)
                            (cons id pending-ids)
                            (cons opnd pending-opnds)
                            change?)))))
              (let loop ([old-ids ids] [opnds opnds] [ids '()] [vals '()] [n 0] [seq? seq?])
                (if (null? old-ids)
                    (begin
                      (bump sc n)
                      (if (or (null? ids)
                              ; don't allow conservative referenced flags prevent constant folding
                              (and (cp0-constant? body) (andmap simple1? vals)))
                          body
                          (if seq?
                              `(letrec* ([,(reverse ids) ,(reverse vals)] ...) ,body)
                              `(letrec ([,ids ,vals] ...) ,body))))
                    (let ([id (car old-ids)] [opnd (car opnds)])
                      (cond
                        [(operand-value opnd) =>
                         (lambda (val)
                           ; scoring bug: we don't count size of bindings when we
                           ; drop the rest of the RHS
                           (define (f ids vals seq?)
                             (if (or (prelex-referenced id) (not (simple1? val)))
                                 (loop (cdr old-ids) (cdr opnds) (cons id ids)
                                   (cons val vals) (+ n (operand-score opnd)) seq?)
                                 (let ([n (+ (or (operand-singly-referenced-score opnd) 0) n)])
                                   (if (prelex-assigned id)
                                       (loop (cdr old-ids) (cdr opnds) (cons id ids)
                                         (cons void-rec vals) n seq?)
                                       (loop (cdr old-ids) (cdr opnds) ids vals n seq?)))))
                           (let ([b (operand-lifted opnd)])
                             (if (not b)
                                 (f ids vals seq?)
                                 (f (let ([lifted (lifted-ids b)])
                                      (for-each (lambda (id) (prelex-operand-set! id #f)) lifted)
                                      (rappend lifted ids))
                                   (rappend (lifted-vals b) vals)
                                   ; must treat outer letrec as letrec* if assimilating
                                   ; letrec* bindings
                                   (or seq? (lifted-seq? b))))))]
                        [(prelex-assigned id)
                         (loop (cdr old-ids) (cdr opnds) (cons id ids) (cons void-rec vals) n seq?)]
                        [else (loop (cdr old-ids) (cdr opnds) ids vals n seq?)])))))))))

    (define residualize-ref
      (lambda (maybe-src id sc)
        (bump sc 1)
        (when (prelex-referenced id)
          (set-prelex-multiply-referenced! id #t))
        (set-prelex-referenced! id #t)
        `(ref ,maybe-src ,id)))

    (define copy
      ; ctxt is  value, test, or app
      ; opnd has already been visited
      (lambda (maybe-src id opnd ctxt sc wd name moi)
        (let ((rhs (result-exp (operand-value opnd))))
          (nanopass-case (Lsrc Expr) rhs
            [(quote ,d) rhs]
            [(record-type ,rtd ,e)
             `(record-type ,rtd
                ,(residualize-ref maybe-src
                   (nanopass-case (Lsrc Expr) e
                     [(ref ,maybe-src ,x)
                      (guard (not (prelex-was-assigned x))
                        ; protect against (letrec ([x x]) ---)
                        (not (eq? x id)))
                      (when (prelex-was-multiply-referenced id)
                        (set-prelex-was-multiply-referenced! x #t))
                      x]
                     [else id])
                   sc))]
            [(record-cd ,rcd ,rtd-expr ,e)
             `(record-cd ,rcd ,rtd-expr
                ,(residualize-ref maybe-src
                   (nanopass-case (Lsrc Expr) e
                     [(ref ,maybe-src ,x)
                      (guard (not (prelex-was-assigned x))
                        ; protect against (letrec ([x x]) ---)
                        (not (eq? x id)))
                      (when (prelex-was-multiply-referenced id)
                        (set-prelex-was-multiply-referenced! x #t))
                      x]
                     [else id])
                   sc))]
            [(immutable-list (,e* ...) ,e)
             `(immutable-list (,e* ...)
                ,(residualize-ref maybe-src
                   (nanopass-case (Lsrc Expr) e
                     [(ref ,maybe-src ,x)
                      (guard (not (prelex-was-assigned x))
                        ; protect against (letrec ([x x]) ---)
                        (not (eq? x id)))
                      (when (prelex-was-multiply-referenced id)
                        (set-prelex-was-multiply-referenced! x #t))
                      x]
                     [else id])
                   sc))]
            [(immutable-vector (,e* ...) ,e)
             `(immutable-vector (,e* ...)
                ,(residualize-ref maybe-src
                   (nanopass-case (Lsrc Expr) e
                     [(ref ,maybe-src ,x)
                      (guard (not (prelex-was-assigned x))
                        ; protect against (letrec ([x x]) ---)
                        (not (eq? x id)))
                      (when (prelex-was-multiply-referenced id)
                        (set-prelex-was-multiply-referenced! x #t))
                      x]
                     [else id])
                   sc))]
            [(ref ,maybe-src1 ,x)
             (cond
               [(and (not (prelex-was-assigned x))
                     ; protect against (letrec ([x x]) ---)
                     (not (eq? x id)))
                (when (prelex-was-multiply-referenced id)
                  (set-prelex-was-multiply-referenced! x #t))
                (let ([opnd (prelex-operand x)])
                  (if (and opnd (operand-value opnd))
                      (copy2 maybe-src x opnd ctxt sc wd name moi)
                      (residualize-ref maybe-src x sc)))]
               [else (residualize-ref maybe-src id sc)])]
            [else (copy2 maybe-src id opnd ctxt sc wd name moi)]))))

    (define copy2
      ; ctxt is  value, test, or app
      (lambda (maybe-src id opnd ctxt sc wd name moi)
        (let loop ([rhs (result-exp (operand-value opnd))])
          (nanopass-case (Lsrc Expr) rhs
            [(case-lambda ,preinfo1 ,cl* ...)
             (context-case ctxt
               [(test) true-rec]
               [(app)
                (with-values (if (preinfo-call-can-inline? (app-preinfo ctxt))
                                 (find-lambda-clause rhs ctxt)
                                 (values))
                  (case-lambda
                    [(ids body)
                     (let ([limit (if (passive-scorer? sc)
                                      (fx+ score-limit (length (app-opnds ctxt)))
                                      (scorer-limit sc))])
                       (if (outer-cyclic? opnd)
                           (or (and polyvariant
                                    (fx= (operand-opending opnd) (fx+ outer-unroll-limit 1))
                                    ; Give it one (more) whirl, but bug out if recursive
                                    ; refs remain.  We do this by setting id's opnd to new
                                    ; scorer and bugging out when we find a scorer in place
                                    ; of an operand in decode-ref.  we don't have to worry
                                    ; about finding an assignment because we don't attempt
                                    ; to integrated assigned variables
                                    (call/1cc
                                      (lambda (k)
                                        (let ([new-sc (new-scorer limit ctxt k)]
                                              [new-wd (new-watchdog wd ctxt k)])
                                          (with-extended-env ((env ignore-ids) (empty-env (list id) (list new-sc)))
                                            (let ([x (opending-protect opnd
                                                       (cp0-let preinfo1 ids body ctxt env new-sc new-wd name moi))])
                                              (bump sc (fx- limit (scorer-limit new-sc)))
                                              x))))))
                               (residualize-ref maybe-src id sc))
                           ; the monovariant filter below is flawed because opnd sizes do
                           ; necessarily reflect integrated singly referenced items
                           (or (and (or polyvariant (fx< (operand-score opnd) limit))
                                    (call/1cc
                                      (lambda (k)
                                        (let ([new-wd (new-watchdog wd ctxt k)])
                                          (if (prelex-was-multiply-referenced id)
                                              (let ([new-sc (new-scorer limit ctxt k)])
                                                (let ([x (opending-protect opnd
                                                           (cp0-let preinfo1 ids body ctxt empty-env new-sc new-wd name moi))])
                                                  (bump sc (fx- limit (scorer-limit new-sc)))
                                                  x))
                                              (let ([new-sc (new-scorer)])
                                                (let ([x (opending-protect opnd
                                                           (cp0-let preinfo1 ids body ctxt empty-env new-sc new-wd name moi))])
                                                  (operand-singly-referenced-score-set! opnd (scorer-score new-sc))
                                                  x)))))))
                               (residualize-ref maybe-src id sc))))]
                    [() (residualize-ref maybe-src id sc)]))]
               [else (residualize-ref maybe-src id sc)])]
            [,pr
              (context-case ctxt
                [(value tail)
                 ;; formerly constrained to functions marked as `primitive`,
                 ;; which does not include `system` procedures:
                 (if (all-set? (prim-mask proc) (primref-flags pr))
                     rhs
                     (residualize-ref maybe-src id sc))]
                [(test)
                 (if (all-set? (prim-mask proc) (primref-flags pr))
                     true-rec
                     (residualize-ref maybe-src id sc))]
                [else (fold-primref rhs ctxt sc wd name moi)])]
            [else (residualize-ref maybe-src id sc)]))))

    (define fold-primref
      (lambda (pr ctxt sc wd name moi)
        (let ([opnds (app-opnds ctxt)] [outer-ctxt (app-ctxt ctxt)])
          (convention-case (app-convention ctxt)
            [(call)
             (let ([flags (primref-flags pr)])
               (cond
                 [(and (unused-value-context? outer-ctxt)
                       (if (all-set? (prim-mask unsafe) flags)
                           (all-set? (prim-mask discard) flags)
                           (and (all-set? (prim-mask (or unrestricted discard)) flags)
                                (arity-okay? (primref-arity pr) (length opnds))))
                       (or (not (eq? outer-ctxt 'ignored))
                           (fx= (optimize-level) 3)
                           (all-set? (prim-mask single-valued) flags)))
                   (residualize-seq '() opnds ctxt)
                   void-rec]
                 [(and (eq? outer-ctxt 'test)
                       (all-set?
                         (if (all-set? (prim-mask unsafe) flags)
                             (prim-mask (or discard true))
                             (prim-mask (or unrestricted discard true)))
                         flags))
                   (residualize-seq '() opnds ctxt)
                   true-rec]
                 [(and (eq? outer-ctxt 'test)
                       (all-set? (prim-mask true) flags))
                   (make-1seq outer-ctxt
                     (fold-primref2 pr (primref-name pr) opnds flags ctxt sc wd name moi)
                     true-rec)]
                 [else (fold-primref2 pr (primref-name pr) opnds flags ctxt sc wd name moi)]))]
            [(apply2 apply3)
             ; handler for apply will have turned the apply into a call if the last
             ; argument is discovered to be a list.  nothing more we can do here.
             (residualize-primcall pr #f opnds ctxt sc)]))))

    (define fold-primref2
      (lambda (pr sym opnds pflags ctxt sc wd name moi)
        (safe-assert (convention-case (app-convention ctxt) [(call) #t] [else #f]))
        (let ([handler (or (and (all-set? (prim-mask unsafe) pflags)
                                (all-set? (prim-mask cp03) pflags)
                                ($sgetprop sym 'cp03 #f))
                           (and (all-set? (prim-mask cp02) pflags)
                                ($sgetprop sym 'cp02 #f)))])
          (or (and handler
                   (let ([level (if (all-set? (prim-mask unsafe) pflags) 3 2)])
                     (handler level opnds ctxt sc wd name moi)))
              (let ([args (value-visit-operands! opnds)])
                (cond
                  [(and (all-set? (prim-mask mifoldable+) pflags)
                        (let ([objs (objs-if-constant args)])
                          (and objs (guard (c [#t #f])
                                      (call-with-values
                                        (lambda () (apply ($top-level-value sym) objs))
                                        (case-lambda
                                          [(v) `(quote ,v)]
                                          [v* `(call ,(app-preinfo ctxt) ,(lookup-primref 3 'values)
                                                 ,(map (lambda (x) `(quote ,x)) v*)
                                                 ...)])))))) =>
                   (lambda (e)
                     (residualize-seq '() opnds ctxt)
                     e)]
                  [else
                   (residualize-primcall pr args opnds ctxt sc)]))))))

    (define residualize-primcall
      (lambda (pr args opnds ctxt sc)
        (let ([args (or args (value-visit-operands! opnds))])
          (residualize-seq opnds '() ctxt)
          (bump sc 1)
          (let ([preinfo (app-preinfo ctxt)])
            (convention-case (app-convention ctxt)
              [(call) `(call ,preinfo ,pr ,args ...)]
              [(apply2) (build-primcall preinfo 2 'apply (cons pr args))]
              [(apply3) (build-primcall preinfo 3 'apply (cons pr args))])))))

    (define objs-if-constant
      (lambda (e*)
        (if (null? e*)
            '()
            (nanopass-case (Lsrc Expr) (result-exp (car e*))
              [(quote ,d)
               (let ([rest (objs-if-constant (cdr e*))])
                 (and rest (cons d rest)))]
              [else #f]))))

    (define record-equal?
      ; not very ambitious
      (lambda (e1 e2 ctxt)
        (cond
          [(eq? ctxt 'effect)
           (and (simple? e1) (simple? e2))]
          [(eq? ctxt 'ignored)
           (and (simple1? e1) (simple1? e2))]
          [else
           (nanopass-case (Lsrc Expr) e1
             [(ref ,maybe-src1 ,x1)
              (nanopass-case (Lsrc Expr) e2
                [(ref ,maybe-src2 ,x2) (eq? x1 x2)]
                [else #f])]
             [(quote ,d1)
              (nanopass-case (Lsrc Expr) e2
                [(quote ,d2)
                 (if (eq? ctxt 'test)
                     (if d1 d2 (not d2))
                     (eq? d1 d2))]
                [else #f])]
             [else #f])])))

    (module ()
      (define-syntax define-inline
        (lambda (x)
          (syntax-case x ()
            ((_key lev prim clause ...)
             (identifier? #'prim)
             #'(_key lev (prim) clause ...))
            ((_key lev (prim ...) clause ...)
             (andmap identifier? #'(prim ...))
             (with-implicit  (_key prim-name level ctxt sc wd name moi)
               (with-syntax
                 ((key (case (datum lev)
                         ((2) #'cp02)
                         ((3) #'cp03)
                         (else ($oops #f "invalid inline level ~s" (datum lev)))))
                  (body
                    (let f ((clauses #'(clause ...)))
                      (if (null? clauses)
                          #'#f
                          (with-syntax ((rest (f (cdr clauses))))
                            (syntax-case (car clauses) ()
                              (((x ...) e1 e2 ...)
                               (with-syntax ((n (length #'(x ...))))
                                 #'(if (eq? count n)
                                       (apply (lambda (x ...) e1 e2 ...) args)
                                       rest)))
                              ((r e1 e2 ...)
                               (identifier? #'r)
                               #'(apply (lambda r e1 e2 ...) args))
                              ((r e1 e2 ...)
                               (with-syntax ((n (let loop ((r #'r) (n 0))
                                                  (syntax-case r ()
                                                    ((v . r)
                                                     (identifier? #'v)
                                                     (loop #'r (+ n 1)))
                                                    (v
                                                      (identifier? #'v)
                                                      n)))))
                                 #'(if (fx>= count n)
                                       (apply (lambda r e1 e2 ...) args)
                                       rest)))))))))
                 (for-each
                   (lambda (sym-name)
                     (let ([sym-key (datum key)])
                       (if (getprop sym-name sym-key #f)
                           (warningf #f "duplicate ~s handler for ~s" sym-key sym-name)
                           (putprop sym-name sym-key #t))
                       (unless (all-set?
                                 (case (datum lev)
                                   [(2) (prim-mask cp02)]
                                   [(3) (prim-mask cp03)])
                                 ($sgetprop sym-name '*flags* 0))
                         (warningf #f "undeclared ~s handler for ~s~%" sym-key sym-name))))
                   (datum (prim ...)))
                 #'(let ((foo (lambda (prim-name)
                                (lambda (level args ctxt sc wd name moi)
                                  (let ((count (length args)))
                                    body)))))
                     ($sputprop 'prim 'key (foo 'prim)) ...)))))))

      (define generic-nan?
        (lambda (x)
          (and (flonum? x) ($nan? x))))

      (define fl-nan?
        (lambda (x)
          ($nan? x)))

      (define cfl-nan?
        (lambda (z)
          (and ($nan? (cfl-real-part z)) ($nan? (cfl-imag-part z)))))

      (define exact-zero?
        (lambda (x)
          (eq? x 0)))

      (define exact-negone?
        (lambda (x)
          (eq? x -1)))

      ;;; what to include here vs. in cp1in:
      ;;;   Include here transformations that eliminate the need to evaluate an
      ;;;   operand (for value) or that may open up opportunities for further
      ;;;   folding.  For example, memq with second argument '() doesn't need
      ;;;   the value of its first operand.   It also evaluates to #f or
      ;;;   (seq <something> #f) and thus may lead to further folding.
      ;;;
      ;;;   Don't bother with optimizations, such as strength reduction, that
      ;;;   just result in other calls.  For example, memq with a constant,
      ;;;   non-null second argument expands into calls to eq?, which we can't
      ;;;   do anything with.

      ;;; caution:
      ;;;   We must use value-visit-operand here rather than calling cp0 on
      ;;;   operand expressions.  Although at this level we may be guaranteed
      ;;;   to succeed, we may be succeeding in an outer context of an inner
      ;;;   context that will eventually fail.  For example, in:
      ;;;
      ;;;     (let ((f (lambda ()
      ;;;                (let ((x huge-a))
      ;;;                  (let ((g (lambda () x)))
      ;;;                    (g) not)))))
      ;;;       ((f) huge-b))
      ;;;
      ;;;   where huge-a and huge-b are large unreducible expressions, we
      ;;;   create an operand O1 for huge-a, process (f) in an app context
      ;;;   A1, process f in another app context A2 whose outer context is
      ;;;   A1, encounter reference to f, process the (lambda () ...) for
      ;;;   value, producing:
      ;;;
      ;;;     (lambda ()
      ;;;       (let ((x huge-a))
      ;;;         not))
      ;;;
      ;;;   then attempt to integrate the body of this lambda expression in
      ;;;   the outer app context A1, resulting in an attempt to apply not to
      ;;;   the operand O1.  Say not extracts the expression from O1 to
      ;;;   produce (if huge-b #f #t).  We would then process this if,
      ;;;   including huge-b.  when trying to rebuild (let ((x huge-a)) ...),
      ;;;   we would discover that x is not referenced, but would leave
      ;;;   behind huge-a and, because of its size, abort the attempted
      ;;;   inlining of app context A1.  We would then residualize the call
      ;;;   ((f) huge-b), processing O1's expression, huge-b, again.
      ;;;
      ;;;   Primitives that must extract the operand expression (such as
      ;;;   not and apply) should be caught in the call case of cp0 before
      ;;;   the expressions are encapsulated in operand structures.  A
      ;;;   downside to catching prims at that level is that in
      ;;;   (let ((f prim)) (f e)), the call (f e) won't be recognized as
      ;;;   a primitive application of prim.
      ;;;
      ;;;   On the other hand, this arises only while we are integrating,
      ;;;   so if we charge the first processing of huge-b to the watchdog
      ;;;   and scorer associated with the A1 integration attempt rather
      ;;;   than to the top level watchdog and scorer that we would usually
      ;;;   use for huge-b, we could be okay.

      ; okay-to-handle? should return #f only when interpreting code on a
      ; host machine with a different target-machine compiler loaded.  we
      ; try to treat the other cases the same (not cross-compiling, with
      ; no cross compiler loaded, or cross-compiling, with cross compiler
      ; loaded) so that we don't have mostly untested handler code for
      ; cross-compiled case.
      (define (okay-to-handle?) (eq? ($target-machine) (constant machine-type-name)))

      (define-syntax visit-and-maybe-extract*
        (lambda (x)
          (syntax-case x ()
            [(_ ?pred? ([x opnd] ...) e1 e2 ...)
             #`(let ([pred? ?pred?])
                 (and (okay-to-handle?)
                      #,(fold-right (lambda (x opnd e)
                                      #`(let ([xval (value-visit-operand! #,opnd)])
                                          (nanopass-case (Lsrc Expr) (result-exp xval)
                                            [(quote ,d) (and (pred? d) (let ([#,x d]) #,e))]
                                            [else #f])))
                          #'(begin e1 e2 ...) #'(x ...) #'(opnd ...))))])))

      (define handle-shift
        (lambda (level ctxt x y)
          (and (fx= level 3)
               (let ([xval (value-visit-operand! x)]
                     [yval (value-visit-operand! y)])
                 (cond
                   [(cp0-constant? (lambda (obj) (eqv? obj 0)) (result-exp yval))
                    (residualize-seq (list x) (list y) ctxt)
                    xval]
                   [else #f])))))

      ; could handle inequalities as well (returning #f), but that seems less likely to crop up
      (define handle-equality
        (lambda (ctxt arg arg*)
          (and
            (or (null? arg*)
                (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! arg))
                  [(ref ,maybe-src ,x0)
                   (and (not (prelex-was-assigned x0))
                        (andmap
                          (lambda (arg)
                            (and (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! arg))
                                   [(ref ,maybe-src ,x) (eq? x x0)]
                                   [else #f])))
                          arg*))]
                  [,pr0
                   (andmap (lambda (arg)
                             (and (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! arg))
                                    [,pr (eq? pr pr0)]
                                    [else #f])))
                           arg*)]
                  [else #f]))
            (begin
              (residualize-seq '() (cons arg arg*) ctxt)
              true-rec))))

      (define-inline 2 machine-type
        [() (begin
              (residualize-seq '() '() ctxt)
              `(quote ,($target-machine)))])

      (let ()
        (define-syntax define-inline-constant-parameter
          (syntax-rules ()
            [(_ (name ...) k)
             (define-inline 2 (name ...)
               [() (and (okay-to-handle?)
                        (begin
                          (residualize-seq '() '() ctxt)
                          `(quote ,k)))])]))
        (constant-case native-endianness
          [(unknown)
           (define-inline 2 native-endianness)]
          [else
           (define-inline-constant-parameter (native-endianness) (constant native-endianness))])
        (constant-case architecture
          [(pb)
           (define-inline 2 directory-separator)]
          [else
           (define-inline-constant-parameter (directory-separator) (if-feature windows #\\ #\/))])
        (define-inline-constant-parameter (threaded?) (if-feature pthreads #t #f))
        (define-inline-constant-parameter (most-negative-fixnum least-fixnum) (constant most-negative-fixnum))
        (define-inline-constant-parameter (most-positive-fixnum greatest-fixnum) (constant most-positive-fixnum))
        (define-inline-constant-parameter (fixnum-width) (constant fixnum-bits))
        (define-inline-constant-parameter (virtual-register-count) (constant virtual-register-count))
        (define-inline-constant-parameter (stencil-vector-mask-width) (constant stencil-vector-mask-bits)))

      (constant-case architecture
        [(pb)
         (define-inline 2 directory-separator?)]
        [else
         (define-inline 2 directory-separator?
           [(c) (visit-and-maybe-extract* char? ([dc c])
                  (residualize-seq '() (list c) ctxt)
                  `(quote ,(and (memv dc (if-feature windows '(#\\ #\/) '(#\/))) #t)))])])

      (define-inline 2 (foreign-sizeof foreign-alignof)
        [(x) (and (okay-to-handle?)
                  (let ([xval (value-visit-operand! x)])
                    (nanopass-case (Lsrc Expr) (result-exp xval)
                      [(quote ,d)
                       (let ()
                         (define-syntax size
                           (syntax-rules ()
                             [(_ type bytes pred)
                              (begin
                                (residualize-seq '() (list x) ctxt)
                                `(quote ,(cond
                                           [(eq? prim-name 'foreign-alignof)
                                            (case 'type
                                              [(double-float single-float) (gcd (constant max-float-alignment) bytes)]
                                              [(integer-64 unsigned-64) (gcd (constant max-integer-alignment) bytes)]
                                              [else bytes])]
                                           [else bytes])))]))
                         (record-datatype cases (filter-foreign-type d) size #f))]
                      [else #f])))])

      (let ([addr-int? (constant-case address-bits [(32) $integer-32?] [(64) $integer-64?])])
        (define-inline 2 $verify-ftype-address
          [(who e) (visit-and-maybe-extract* addr-int?  ([de e])
                     (residualize-seq '() (list who e) ctxt)
                     true-rec)]))

      (define-inline 2 (memq memv member assq assv assoc)
        [(x ls)
         (and (cp0-constant? null? (result-exp (value-visit-operand! ls)))
              (begin
                (residualize-seq '() (list x ls) ctxt)
                false-rec))])

      (define-inline 3 (memp assp find)
        [(pred ls)
         (and (cp0-constant? null? (result-exp (value-visit-operand! ls)))
              (begin
                (residualize-seq '() (list pred ls) ctxt)
                false-rec))])

      (define-inline 2 (remq remv remove)
        [(x ls)
         (and (cp0-constant? null? (result-exp (value-visit-operand! ls)))
              (begin
                (residualize-seq '() (list x ls) ctxt)
                null-rec))])

      (define-inline 3 (remp filter)
        [(pred ls)
         (and (cp0-constant? null? (result-exp (value-visit-operand! ls)))
              (begin
                (residualize-seq '() (list pred ls) ctxt)
                null-rec))])

      (define-inline 2 apply
        [(proc opnd1 . opnds)
         (let ([opnds (cons opnd1 opnds)])
           (let ([last-opnd (car (last-pair opnds))])
             (cond
               [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! last-opnd))
                  [(quote ,d) (guard (list? d) (<= (length d) 1000)) (map build-quote d)]
                  [(immutable-list (,e* ...) ,e) e*]
                  [(call ,preinfo ,pr ,e* ...) (guard (eq? (primref-name pr) 'list)) e*]
                  [else #f]) =>
                (lambda (e*)
                  (let ([opnds (let f ([opnds opnds])
                                 (let ([rest (cdr opnds)])
                                   (if (null? rest)
                                       '()
                                       (cons (car opnds) (f (cdr opnds))))))])
                    (let ([tproc (cp0-make-temp #f)] [t* (map (lambda (x) (cp0-make-temp #f)) opnds)])
                      (with-extended-env ((env ids) (empty-env (cons tproc t*) (cons proc opnds)))
                        (letify (make-preinfo-lambda) ids ctxt (list last-opnd)
                          (non-result-exp (operand-value last-opnd)
                            (cp0-call (app-preinfo ctxt) (build-ref tproc)
                              (fold-right
                                (lambda (t opnd*) (cons (make-operand (build-ref t) env wd moi) opnd*))
                                (map build-cooked-opnd e*)
                                t*)
                              (app-ctxt ctxt) env sc wd (app-name ctxt) moi)))))))]
               [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! last-opnd))
                  [(call ,preinfo ,pr ,e1 ,e2) (guard (eq? (primref-name pr) 'cons)) (list e1 e2)]
                  [(call ,preinfo ,pr ,e ,e* ...) (guard (memq (primref-name pr) '(list* cons*))) (cons e e*)]
                  [else #f]) =>
                (lambda (e*)
                  (let ([opnds (cons proc
                                 (let f ([opnds opnds])
                                   (let ([rest (cdr opnds)])
                                     (if (null? rest)
                                         '()
                                         (cons (car opnds) (f (cdr opnds)))))))])
                    (let ([t* (map (lambda (x) (cp0-make-temp #f)) opnds)])
                      (with-extended-env ((env ids) (empty-env t* opnds))
                        (letify (make-preinfo-lambda) ids ctxt (list last-opnd)
                          (non-result-exp (operand-value last-opnd)
                            (cp0-call (app-preinfo ctxt) (lookup-primref level 'apply)
                              (fold-right
                                (lambda (t opnd*) (cons (make-operand (build-ref t) env wd moi) opnd*))
                                (map build-cooked-opnd e*)
                                t*)
                              (app-ctxt ctxt) env sc wd (app-name ctxt) moi)))))))]
               [else
                (let ([temp (cp0-make-temp #f)]) ; N.B.: temp is singly referenced
                  (with-extended-env ((env ids) (empty-env (list temp) (list proc)))
                    (let* ([new-ctxt (make-app opnds (app-ctxt ctxt)
                                       (if (fx= level 3) 'apply3 'apply2)
                                       (app-name ctxt)
                                       (app-preinfo ctxt))]
                           [e (cp0 (build-ref temp) new-ctxt env sc wd #f moi)])
                      (and (app-used new-ctxt)
                           (begin
                             (residualize-seq (app-used new-ctxt) (cons proc (app-unused new-ctxt)) ctxt)
                             e)))))])))])

      (define-inline 2 not
        [(e)
         (let ([e-val (test-visit-operand! e)])
           (nanopass-case (Lsrc Expr) (result-exp e-val)
             [(quote ,d)
              (residualize-seq '() (list e) ctxt)
              (if d false-rec true-rec)]
             [else
              (residualize-seq (list e) '() ctxt)
              (make-if ctxt sc e-val false-rec true-rec)]))])

      (define-inline 2 call-with-values
        [(p-opnd c-opnd)
         (let ((p-temp (cp0-make-temp #f)) (c-temp (cp0-make-temp #f)))
           (with-extended-env ((env ids) (empty-env (list p-temp c-temp) (app-opnds ctxt)))
             (let ((ctxt1 (make-app '() 'tail 'call #f (app-preinfo ctxt))))
               (let ((*p-val (cp0 (build-ref p-temp) ctxt1 env sc wd #f moi)))
                 (cond
                   [(and (app-used ctxt1)
                         (let ([e (result-exp *p-val)])
                           (nanopass-case (Lsrc Expr) e
                             [(call ,preinfo ,pr ,e* ...)
                              (guard (eq? (primref-name pr) 'values))
                              e*]
                             [else (and (single-valued/inspect-ok? e)
                                        (list e))]))) =>
                    (lambda (args)
                      ; (with-values (values arg ...) c-temp) => (c-temp arg ...)
                      (letify (make-preinfo-lambda) ids ctxt
                        (non-result-exp *p-val
                          (cp0-call (app-preinfo ctxt) (build-ref c-temp)
                            (map build-cooked-opnd args)
                            (app-ctxt ctxt) env sc wd (app-name ctxt) moi))))]
                   [else
                     (call-with-values
                       (lambda ()
                         (let ((e (value-visit-operand! c-opnd)))
                           (nanopass-case (Lsrc Expr) (result-exp e)
                             [(case-lambda ,preinfo ,cl* ...)
                              (values (result-exp e) '() (list c-opnd))]
                             [,pr (values (result-exp e) '() (list c-opnd))]
                             [else (values e (list c-opnd) '())])))
                       (lambda (c-val used unused)
                         (if (app-used ctxt1)
                             (begin
                               (residualize-seq used (cons p-opnd unused) ctxt)
                               (non-result-exp *p-val
                                 (build-primcall (app-preinfo ctxt) level 'call-with-values
                                   (list
                                     (build-lambda '() (result-exp *p-val))
                                     c-val))))
                             (build-primcall (app-preinfo ctxt) level 'call-with-values
                               (list
                                 (let ((e (value-visit-operand! p-opnd)))
                                   (nanopass-case (Lsrc Expr) (result-exp e)
                                     [(case-lambda ,preinfo ,cl* ...)
                                      (residualize-seq used (cons p-opnd unused) ctxt)
                                      (result-exp e)]
                                     [,pr
                                       (residualize-seq used (cons p-opnd unused) ctxt)
                                       (result-exp e)]
                                     [else
                                       (residualize-seq (cons p-opnd used) unused ctxt)
                                       e]))
                                 c-val)))))])))))])

      (define-inline 2 (call/cc call/1cc call-with-current-continuation)
        [(body)
         (nanopass-case (Lsrc Expr) (value-visit-operand! body)
           [(case-lambda ,preinfo (clause (,x) ,interface ,e))
            (guard (not (prelex-was-referenced x)))
            (residualize-seq (list) (list body) ctxt)
            e]
           [else #f])])

      (define-inline 2 $call-setting-continuation-attachment
        [(val body)
         (nanopass-case (Lsrc Expr) (value-visit-operand! body)
           [(case-lambda ,preinfo (clause () ,interface ,e))
            (guard (simple? e))
            (residualize-seq (list val) (list body) ctxt)
            (make-1seq (app-ctxt ctxt) (value-visit-operand! val) e)]
           [else #f])])

      (define-inline 2 $call-getting-continuation-attachment
        [(def-val body)
         (nanopass-case (Lsrc Expr) (value-visit-operand! body)
           [(case-lambda ,preinfo (clause (,x) ,interface ,e))
            (guard (not (prelex-was-referenced x)))
            (residualize-seq (list def-val) (list body) ctxt)
            (make-1seq (app-ctxt ctxt) (value-visit-operand! def-val) e)]
           [else #f])])

      (define-inline 2 $call-consuming-continuation-attachment
        [(def-val body)
         (nanopass-case (Lsrc Expr) (value-visit-operand! body)
           [(case-lambda ,preinfo (clause (,x) ,interface ,e))
            (guard (not (prelex-was-referenced x)))
            (residualize-seq (list def-val) (list body) ctxt)
            (make-1seq (app-ctxt ctxt) (value-visit-operand! def-val) e)]
           [else #f])])

      (define-inline 2 continuation-marks-first
        [(set . more)
         (and
          (<= 1 (length more) 2)
          (nanopass-case (Lsrc Expr) (value-visit-operand! set)
            [(call ,preinfo ,pr)
             (guard (eq? (primref-name pr) 'current-continuation-marks))
             (let ([vals (map value-visit-operand! more)])
               (residualize-seq more (list set) ctxt)
               (build-primcall preinfo level '$continuation-marks-first vals))]
            [else #f]))])

      (define-inline 2 list
        [() (begin
              (residualize-seq '() '() ctxt)
              null-rec)]
        [args #f])

      (define-inline 2 (cons* list* values append append!)
        [(x) (begin
               (residualize-seq (list x) '() ctxt)
               (make-nontail (app-ctxt ctxt) (value-visit-operand! x)))]
        [args #f])

      (define-inline 2 $value
        [(x) (let ([v (value-visit-operand! x)])
               (and (single-valued? v)
                    (begin
                      (residualize-seq (list x) '() ctxt)
                      v)))])

      (define-inline 2 vector
        [() (begin
              (residualize-seq '() '() ctxt)
              empty-vector-rec)]
        [args #f])

      (define-inline 2 immutable-vector
        [() (begin
              (residualize-seq '() '() ctxt)
              `(quote ,(immutable-vector)))]
        [opnd*
         (or (let ([e* (objs-if-constant (value-visit-operands! opnd*))])
               (and e*
                    (begin
                      (residualize-seq '() opnd* ctxt)
                      `(quote ,(apply immutable-vector e*)))))
             (begin
               (residualize-seq opnd* '() ctxt)
               (let loop ([e* (value-visit-operands! opnd*)]
                          [lhs* '()]
                          [rhs* '()]
                          [re* '()])
                 (if (null? e*)
                     (let ([e* (reverse re*)])
                       (let ([e `(immutable-vector (,e* ...)
                                   ,(build-primcall 3 'immutable-vector e*))])
                         (if (null? lhs*)
                             e
                             (build-let lhs* rhs* e))))
                     (let ([e (car e*)] [e* (cdr e*)])
                       (if (nanopass-case (Lsrc Expr) e
                             [(quote ,d) #t]
                             [(ref ,maybe-src ,x)
                              (guard (not (prelex-was-assigned x)))
                              (unless (prelex-multiply-referenced x)
                                (set-prelex-multiply-referenced! x #t))
                              #t]
                             [else #f])
                           (loop e* lhs* rhs* (cons e re*))
                           (let ([t (cp0-make-temp #t)])
                             (loop e* (cons t lhs*) (cons e rhs*) (cons (build-ref t) re*)))))))))])

      (define-inline 2 string
        [() (begin
              (residualize-seq '() '() ctxt)
              empty-string-rec)]
        [args #f])

      (define-inline 2 bytevector
        [() (begin
              (residualize-seq '() '() ctxt)
              empty-bytevector-rec)]
        [args #f])

      (define-inline 2 fxvector
        [() (begin
              (residualize-seq '() '() ctxt)
              empty-fxvector-rec)]
        [args #f])

      (define-inline 2 flvector
        [() (begin
              (residualize-seq '() '() ctxt)
              empty-flvector-rec)]
        [args #f])

      (let ()
        (define (build-immediate-immutable-vector e ctxt)
          (let ([e-val (value-visit-operand! e)])
            (nanopass-case (Lsrc Expr) (result-exp e-val)
              [(quote ,d)
               (cond
                 [(immutable-vector? d)
                  (residualize-seq (list e) '() ctxt)
                  e-val]
                 [(eq? d '#())
                  (residualize-seq '() (list e) ctxt)
                  `(quote ,(vector->immutable-vector '#()))]
                 [else #f])]
              [(immutable-vector (,e* ...) ,e2)
               (residualize-seq (list e) '() ctxt)
               e-val]
              [(call ,preinfo ,pr ,e* ...)
               (case (primref-name pr)
                 [(vector->immutable-vector immutable-vector
                                            immutable-vector-copy immutable-vector-set/copy immutable-vector-append)
                  (residualize-seq (list e) '() ctxt)
                  e-val]
                 [(vector vector-copy vector-set/copy vector-append)
                  (residualize-seq (list e) '() ctxt)
                  (non-result-exp e-val
                                  (build-primcall 3
                                                  (case (primref-name pr)
                                                    [(vector) 'immutable-vector]
                                                    [(vector-copy) 'immutable-vector-copy]
                                                    [(vector-set/copy) 'immutable-vector-set/copy]
                                                    [(vector-append) 'immutable-vector-append]
                                                    [else ($oops #f "missing conversion")])
                                                  e*))]
                 [else #f])]
              [else #f])))
        (define (build-append-immediate-vectors prim orig-vec-e* ctxt)
          (let loop ([vec-e* orig-vec-e*] [accum '()])
            (cond
              [(null? vec-e*)
               (residualize-seq orig-vec-e* '() ctxt)
               (build-primcall 3 prim (reverse accum))]
              [else
               (let ([vec-e-val (value-visit-operand! (car vec-e*))])
                 (nanopass-case (Lsrc Expr) vec-e-val
                   [(quote ,d)
                    (guard (vector? d))
                    (loop (cdr vec-e*) (append (map (lambda (v) `(quote ,v))
                                                    (reverse (vector->list d)))
                                               accum))]
                   [(immutable-vector (,e* ...) ,e)
                    (loop (cdr vec-e*) (append (reverse e*) accum))]
                   [(call ,preinfo ,pr ,e* ...)
                    (guard (memq (primref-name pr) '(vector immutable-vector)))
                    (loop (cdr vec-e*) (append (reverse e*) accum))]
                   [else #f]))])))

        (define-inline 2 vector->immutable-vector
          [(e) (build-immediate-immutable-vector e ctxt)])
        (define-inline 2 immutable-vector-copy
          [(e) (build-immediate-immutable-vector e ctxt)])
        (define-inline 2 vector-copy
          [(e) (build-append-immediate-vectors 'vector (list e) ctxt)])
        (define-inline 2 vector-append
          [e* (build-append-immediate-vectors 'vector e* ctxt)])
        (define-inline 2 immutable-vector-append
          [(e) (build-immediate-immutable-vector e ctxt)]
          [e* (build-append-immediate-vectors 'immutable-vector e* ctxt)]))

      (define-inline 2 string->immutable-string
        [(e) (let ([e-val (value-visit-operand! e)])
               (nanopass-case (Lsrc Expr) (result-exp e-val)
                 [(quote ,d)
                  (cond
                    [(immutable-string? d)
                     (residualize-seq (list e) '() ctxt)
                      e-val]
                    [(eq? d "")
                     (residualize-seq '() (list e) ctxt)
                     `(quote ,(string->immutable-string ""))]
                    [else #f])]
                 [else #f]))])

      (define-inline 2 bytevector->immutable-bytevector
        [(e) (let ([e-val (value-visit-operand! e)])
               (nanopass-case (Lsrc Expr) (result-exp e-val)
                 [(quote ,d)
                  (cond
                    [(immutable-bytevector? d)
                     (residualize-seq (list e) '() ctxt)
                      e-val]
                    [(eq? d '#vu8())
                     (residualize-seq '() (list e) ctxt)
                     `(quote ,(bytevector->immutable-bytevector '#vu8()))]
                    [else #f])]
                 [else #f]))])

      (define-inline 2 (eq? eqv? equal?)
        [(arg1 arg2) (or (handle-equality ctxt arg1 (list arg2))
                         (let ([val1 (value-visit-operand! arg1)]
                               [val2 (value-visit-operand! arg2)])
                           (cond
                             [(cp0-constant? not (result-exp val1))
                              (residualize-seq (list arg2) (list arg1) ctxt)
                              (make-if ctxt sc val2 false-rec true-rec)]
                             [(cp0-constant? not (result-exp val2))
                              (residualize-seq (list arg1) (list arg2) ctxt)
                              (make-if ctxt sc val1 false-rec true-rec)]
                             [else #f])))])

      (define-inline 3 (bytevector=? enum-set=? bound-identifier=? free-identifier=? ftype-pointer=? literal-identifier=? time=?)
        [(arg1 arg2) (handle-equality ctxt arg1 (list arg2))])

      (define-inline 3 (char=? char-ci=? string=? string-ci=?)
        [(arg . arg*) (handle-equality ctxt arg arg*)])

      (define-inline 3 (boolean=? symbol=? r6rs:char=? r6rs:char-ci=? r6rs:string=? r6rs:string-ci=?)
        [(arg1 arg2 . arg*) (handle-equality ctxt arg1 (cons arg2 arg*))])

      (let ()
        (define (try-fold-ash-op op ctxt x y)
          (let ([xval (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! x))
                        [(quote ,d) (and (integer? d) (exact? d) d)]
                        [else #f])]
                [yval (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! y))
                        [(quote ,d) (and (fixnum? d) (fx< -1000 d 1000) d)]
                        [else #f])])
            (and xval
                 yval
                 (let ([r (guard (c [#t #f]) (op xval yval))])
                   (cond
                    [r (residualize-seq '() (list x y) ctxt)
                       `(quote ,r)]
                    [else #f])))))
        (define-syntax define-inline-ash-op
          (syntax-rules ()
            [(_ op)
             (begin
               (define-inline 2 op
                 [(x y) (try-fold-ash-op op ctxt x y)])
               (define-inline 3 op
                 [(x y) (or (try-fold-ash-op op ctxt x y)
                            (handle-shift 3 ctxt x y))]))]))
        (define-inline-ash-op ash)
        (define-inline-ash-op bitwise-arithmetic-shift)
        (define-inline-ash-op bitwise-arithmetic-shift-left)
        (define-inline-ash-op bitwise-arithmetic-shift-right))

      (define-inline 3 fxbit-field ; expose internal fx ops for partial optimization
        [(?n ?start ?end)
         (cp0
           (let ([n (cp0-make-temp #f)]
                 [start (cp0-make-temp #f)]
                 [end (cp0-make-temp #f)])
             (build-lambda (list n start end)
               (build-primcall 3 'fxsra
                 (list
                   (build-primcall 3 'fxand
                     (list
                       (build-ref n)
                       (build-primcall 3 'fxnot
                         (list
                           (build-primcall 3 'fxsll
                             (list
                               `(quote -1)
                               (build-ref end)))))))
                   (build-ref start)))))
           ctxt empty-env sc wd name moi)])

      (let ()
        (define make-fold?
          (lambda (op generic-op)
            (lambda (val a) ; returns value of (op a val) or #f
              (nanopass-case (Lsrc Expr) (result-exp val)
                [(quote ,d)
                 (guard (c [#t #f])
                   (if (eq? generic-op op)
                       (op a d)
                       (and (target-fixnum? d)
                            (let ([folded (generic-op a d)])
                              (and (target-fixnum? folded) folded)))))]
                [else #f]))))
        (define (partial-fold-plus level orig-arg* ctxt prim op generic-op ident bottom? assoc-at-level direct-result?)
          (define fold? (make-fold? op generic-op))
          (let loop ([arg* orig-arg*] [a ident] [val* '()] [used '()] [unused '()])
            (if (null? arg*)
                (let ([val* (reverse val*)])
                  (cond
                   [(bottom? a)
                     (cond
                       [(or (fx= level 3) (null? val*))
                        (residualize-seq '() orig-arg* ctxt)
                        `(quote ,a)]
                       [else
                         (residualize-seq used unused ctxt)
                         `(seq
                           ,(build-primcall (app-preinfo ctxt) level prim
                                            (if (enable-arithmetic-left-associative)
                                                ;; May need bottom to avoid overflow
                                                (cons `(quote ,a) val*)
                                                val*))
                           (quote ,a))])]
                    [else
                      (residualize-seq used unused ctxt)
                      (cond
                        [(null? val*) `(quote ,a)]
                        [(eqv? a ident)
                         (if (and (fx= level 3) (null? (cdr val*)) (direct-result? (car val*)))
                             (make-nontail (app-ctxt ctxt) (car val*))
                             (if (and (null? (cdr val*))
                                      ;; `op` may require exactly 2 arguments
                                      (eqv? (procedure-arity-mask op) 4))
                                 (build-primcall (app-preinfo ctxt) level prim (cons `(quote ,ident) val*))
                                 (build-primcall (app-preinfo ctxt) level prim val*)))]
                        [else
                          (build-primcall (app-preinfo ctxt) level prim (cons `(quote ,a) val*))])]))
                (let* ([arg (car arg*)] [val (value-visit-operand! arg)])
                  (cond
                    [(fold? val a) =>
                     (lambda (a) (loop (cdr arg*) a val* used (cons arg unused)))]
                    [(and (enable-arithmetic-left-associative)
                          (not (and assoc-at-level (fx>= level assoc-at-level))))
                     ;; preserve left-associative bahvior
                     (let ([rest-val* (reverse (map value-visit-operand! (cdr arg*)))])
                       (loop '() a (append rest-val* (cons val val*)) (append arg* used) unused))]
                    [else (loop (cdr arg*) a (cons val val*) (cons arg used) unused)])))))

        (define (partial-fold-minus level arg arg* ctxt prim op generic-op ident)
          ; ident is such that (op ident x) == (op x)
          (define fold? (make-fold? op generic-op))
          (define (finish a val* used unused)
            (residualize-seq used unused ctxt)
            (if (null? val*)
                `(quote ,a)
                (build-primcall (app-preinfo ctxt) level prim
                  (if (and (eqv? a ident) (null? (cdr val*)))
                      val*
                      (cons `(quote ,a) val*)))))
          ; to maintain left-associative behavior, stop when we get to the first non-constant arg
          (let ([val (value-visit-operand! arg)])
            (cond
              [(nanopass-case (Lsrc Expr) (result-exp val)
                 ; (op obj ident) is not necessarily the same as obj, so return obj
                 [(quote ,d) (and (guard (c [#t #f]) (op d ident)) d)]
                 [else #f]) =>
               (lambda (a)
                 (let loop ([arg* arg*] [a a] [val* '()] [unused (list arg)])
                   (if (null? arg*)
                       (finish a (reverse val*) '() unused)
                       (let* ([arg (car arg*)] [val (value-visit-operand! arg)])
                         (cond
                           [(fold? val a) => (lambda (a) (loop (cdr arg*) a val* (cons arg unused)))]
                           [else (finish a (rappend val* (map value-visit-operand! arg*)) arg* unused)])))))]
              [else #f])))

        (define (partial-fold-negate level arg ctxt prim op generic-op ident)
          (define fold? (make-fold? op generic-op))
          (let ([val (value-visit-operand! arg)])
            (cond
              [(fold? val ident) =>
               (lambda (a)
                 (residualize-seq '() (list arg) ctxt)
                 `(quote ,a))]
              [else #f])))

        (define-syntax partial-folder
          ; partial-fold-plus assumes arg* is nonempty
          (syntax-rules (plus minus)
            [(_ plus prim generic-op ident)
             (partial-folder plus prim generic-op ident (lambda (x) #f) #f)]
            [(_ plus prim generic-op ident bottom?)
             (partial-folder plus prim generic-op ident bottom? #f)]
            [(_ plus prim generic-op ident bottom? assoc-at-level)
             (partial-folder plus prim generic-op ident bottom? assoc-at-level (lambda (e) #t))]
            [(_ plus prim generic-op ident bottom? assoc-at-level direct-result?)
             (begin
               (define-inline 2 prim
                 ; (fl+) might should return -0.0, but we force it to return +0.0 per TSPL4
                 [() (residualize-seq '() '() ctxt) `(quote ,(if (eqv? ident -0.0) +0.0 ident))]
                 [arg* (partial-fold-plus 2 arg* ctxt 'prim prim generic-op ident bottom? assoc-at-level direct-result?)])
               (define-inline 3 prim
                 ; (fl+) might should return -0.0, but we force it to return +0.0 per TSPL4
                 [() (residualize-seq '() '() ctxt) `(quote ,(if (eqv? ident -0.0) +0.0 ident))]
                 [arg* (partial-fold-plus 3 arg* ctxt 'prim prim generic-op ident bottom? assoc-at-level direct-result?)]))]
            [(_ minus prim generic-op ident)
             (begin
               (define-inline 2 prim
                 [(arg) (partial-fold-negate 2 arg ctxt 'prim prim generic-op ident)]
                 [(arg . arg*) (partial-fold-minus 2 arg arg* ctxt 'prim prim generic-op ident)])
               (define-inline 3 prim
                 [(arg) (partial-fold-negate 3 arg ctxt 'prim prim generic-op ident)]
                 [(arg . arg*) (partial-fold-minus 3 arg arg* ctxt 'prim prim generic-op ident)]))]))

        (define-syntax r6rs-fixnum-partial-folder
          ; fx+ and fx* limited to exactly two args, fx- limited to one or two args
          (syntax-rules (plus minus)
            [(_ plus r6rs:prim prim generic-op ident)
             (r6rs-fixnum-partial-folder plus r6rs:prim prim generic-op ident (lambda (x) #f) #f)]
            [(_ plus r6rs:prim prim generic-op ident bottom?)
             (r6rs-fixnum-partial-folder plus r6rs:prim prim generic-op ident bottom? #f)]
            [(_ plus r6rs:prim prim generic-op ident bottom? assoc-at-level)
             (begin
               (define-inline 2 r6rs:prim
                 [(arg1 arg2) (partial-fold-plus 2 (list arg1 arg2) ctxt 'prim prim generic-op ident bottom? assoc-at-level (lambda (x) #t))])
               (define-inline 3 r6rs:prim
                 [(arg1 arg2) (partial-fold-plus 3 (list arg1 arg2) ctxt 'prim prim generic-op ident bottom? assoc-at-level (lambda (x) #t))]))]
            [(_ minus r6rs:prim prim generic-op ident)
             (begin
               (define-inline 2 r6rs:prim
                 [(arg) (partial-fold-negate 2 arg ctxt 'prim prim generic-op ident)]
                 [(arg1 arg2)
                  (partial-fold-minus 2 arg1 (list arg2) ctxt 'prim prim generic-op ident)])
               (define-inline 3 r6rs:prim
                 [(arg) (partial-fold-negate 3 arg ctxt 'prim prim generic-op ident)]
                 [(arg1 arg2)
                  (partial-fold-minus 3 arg1 (list arg2) ctxt 'prim prim generic-op ident)]))]))

        (define obviously-fl?
          ;; We keep single-argument `fl+` and `fl*` as an unboxing hint to the back end,
          ;; but the hint is not necessary if the argument is the result of a primitive that
          ;; produces fonums
          (lambda (e)
            (nanopass-case (Lsrc Expr) e
              [(quote ,d) (flonum? d)]
              [(call ,preinfo ,pr ,e* ...) (eq? 'flonum ($sgetprop (primref-name pr) '*result-type* #f))]
              [else #f])))

        ; handling nans here using the support for handling exact zero in
        ; the multiply case.  maybe shouldn't bother with nans anyway.
        (partial-folder plus + + 0 generic-nan?)
        (partial-folder plus fx+ + 0 (lambda (x) #f) 3)
        (r6rs-fixnum-partial-folder plus r6rs:fx+ fx+ + 0 (lambda (x) #f) 3)
        (r6rs-fixnum-partial-folder plus fx+/wraparound fx+/wraparound + 0 (lambda (x) #f) 3)
        (partial-folder plus fl+ fl+ -0.0 fl-nan? #f obviously-fl?)
        (partial-folder plus cfl+ cfl+ -0.0 cfl-nan?)

        (partial-folder plus * * 1 exact-zero?)   ; exact zero trumps nan
        (partial-folder plus fx* * 1 exact-zero? 3)
        (r6rs-fixnum-partial-folder plus r6rs:fx* fx* * 1 exact-zero? 3)
        (r6rs-fixnum-partial-folder plus fx*/wraparound fx*/wraparound * 1 (lambda (x) #f) 3)
        (partial-folder plus fl* fl* 1.0 fl-nan? #f obviously-fl?)
        (partial-folder plus cfl* cfl* 1.0 cfl-nan?)

        ; not handling nans here since we don't have support for the exact
        ; zero case in division.  it would be nice to reduce (/ 0 x1 x2 ...)
        ; to 0, but (/ 0 n) is only 0 if divisor turns out not to be 0.
        (partial-folder minus - - 0)
        (partial-folder minus fx- - 0)
        (r6rs-fixnum-partial-folder minus r6rs:fx- fx- - 0)
        (r6rs-fixnum-partial-folder minus fx-/wraparound fx-/wraparound - 0)
        (partial-folder minus fl- fl- -0.0)
        (partial-folder minus cfl- cfl- -0.0)

        (partial-folder minus / / 1)
        (partial-folder minus fx/ quotient 1)
        (partial-folder minus fxquotient quotient 1)
        (partial-folder minus fl/ fl/ 1.0)
        (partial-folder minus cfl/ cfl/ 1.0)

        (partial-folder plus logior logior 0 exact-negone? 2)
        (partial-folder plus logor logor 0 exact-negone? 2)
        (partial-folder plus bitwise-ior bitwise-ior 0 exact-negone? 2)
        (partial-folder plus fxlogior logor 0 exact-negone? 2)
        (partial-folder plus fxior logor 0 exact-negone? 2)
        (partial-folder plus fxlogor logor 0 exact-negone? 2)
        (partial-folder plus logxor logxor 0 (lambda (x) #f) 2)
        (partial-folder plus bitwise-xor bitwise-xor 0 (lambda (x) #f) 2)
        (partial-folder plus fxlogxor logxor 0 (lambda (x) #f) 2)
        (partial-folder plus fxxor logxor 0 (lambda (x) #f) 2)
        (partial-folder plus logand logand -1 exact-zero? 2)
        (partial-folder plus bitwise-and bitwise-and -1 exact-zero? 2)
        (partial-folder plus fxlogand logand -1 exact-zero? 2)
        (partial-folder plus fxand logand -1 exact-zero? 2)
        )

      (let ()
        (define $fold
          (lambda (generic-op orig-opnd* pred* opred level ctxt handler)
            (define cookie '(fig . newton))
            (and (okay-to-handle?)
                 (or (let loop ([opnd* orig-opnd*] [pred* pred*] [rval* '()])
                       (if (null? opnd*)
                           (let ([val (guard (c [#t cookie]) (apply generic-op (reverse rval*)))])
                             (and (not (eq? val cookie))
                                  (opred val)
                                  (begin
                                    (residualize-seq '() orig-opnd* ctxt)
                                    `(quote ,val))))
                           (let-values ([(pred pred*) (if (procedure? pred*) (values pred* pred*) (values (car pred*) (cdr pred*)))])
                             (visit-and-maybe-extract* pred ([val (car opnd*)])
                               (loop (cdr opnd*) pred* (cons val rval*))))))
                     (apply handler level ctxt orig-opnd*)))))
        (define null-handler (lambda args #f))
        (define-syntax fold
          (lambda (x)
            (syntax-case x ()
              [(_ (prim ipred ...) opred generic-op) #'(fold (prim ipred ...) opred generic-op null-handler)]
              [(_ (prim ipred ...) opred generic-op handler)
               (with-syntax ([(arg ...) (generate-temporaries #'(ipred ...))])
                 #'(define-inline 2 prim
                     [(arg ...)
                      ($fold generic-op (list arg ...) (list ipred ...) opred level ctxt handler)]))]
              [(_ (prim ipred ... . rpred) opred generic-op) #'(fold (prim ipred ... . rpred) opred generic-op null-handler)]
              [(_ (prim ipred ... . rpred) opred generic-op handler)
               (with-syntax ([(arg ...) (generate-temporaries #'(ipred ...))])
                 #'(define-inline 2 prim
                     [(arg ... . rest)
                      ($fold generic-op (cons* arg ... rest) (cons* ipred ... rpred) opred level ctxt handler)]))])))

        (define tfixnum? target-fixnum?)
        (define u<=fxwidth?
          (lambda (x)
            (and (fixnum? x)
                 (fx<= 0 x (constant fixnum-bits)))))
        (define u<fxwidth?
          (lambda (x)
            (and (fixnum? x)
                 (fx<= 0 x (- (constant fixnum-bits) 1)))))
        (define s<fxwidth?
          (lambda (x)
            (and (fixnum? x)
                 (fx<= (- 1 (constant fixnum-bits)) x (- (constant fixnum-bits) 1)))))
        (define u<fxwidth-1?
          (lambda (x)
            (and (fixnum? x)
                 (fx<= 0 x (- (constant fixnum-bits) 2)))))

        (fold (fx< tfixnum? . tfixnum?) boolean? #2%<)
        (fold (fx<= tfixnum? . tfixnum?) boolean? #2%<=)
        (fold (fx= tfixnum? . tfixnum?) boolean? #2%=
          (lambda (level ctxt arg . arg*)
            (and (fx= level 3) (handle-equality ctxt arg arg*))))
        (fold (fx> tfixnum? . tfixnum?) boolean? #2%>)
        (fold (fx>= tfixnum? . tfixnum?) boolean? #2%>=)
        (fold (fx<? tfixnum? tfixnum? . tfixnum?) boolean? #2%<)
        (fold (fx<=? tfixnum? tfixnum? . tfixnum?) boolean? #2%<=)
        (fold (fx=? tfixnum? tfixnum? . tfixnum?) boolean? #2%=
          (lambda (level ctxt arg . arg*)
            (and (fx= level 3) (handle-equality ctxt arg arg*))))
        (fold (fx>? tfixnum? tfixnum? . tfixnum?) boolean? #2%>)
        (fold (fx>=? tfixnum? tfixnum? . tfixnum?) boolean? #2%>=)
        (fold ($fxu< tfixnum? tfixnum?) boolean?
          (lambda (x y)
            (if (#2%< x 0)
                (and (#2%< y 0) (#2%< x y))
                (or (#2%< y 0) (#2%< x y))))
          (lambda (level ctxt x y)
            (let ([xval (value-visit-operand! x)]
                  [yval (value-visit-operand! y)])
              (and (cp0-constant? (lambda (obj) (eqv? obj (constant most-positive-fixnum))) (result-exp xval))
                   (begin
                     (residualize-seq (list y) (list x) ctxt)
                     (build-primcall (app-preinfo ctxt) level 'fx< (list yval `(quote 0))))))))

        (fold (fxmax tfixnum? . tfixnum?) tfixnum? #2%max)
        (fold (fxmin tfixnum? . tfixnum?) tfixnum? #2%min)
        (fold (fxabs tfixnum?) tfixnum? #2%abs)

        (fold (fxdiv tfixnum? tfixnum?) tfixnum? #2%div)
        (fold (fxmod tfixnum? tfixnum?) tfixnum? #2%mod)
        (fold (fxmodulo tfixnum? tfixnum?) tfixnum? #2%modulo)
        (fold (fxdiv0 tfixnum? tfixnum?) tfixnum? #2%div0)
        (fold (fxmod0 tfixnum? tfixnum?) tfixnum? #2%mod0)
        (fold (fxremainder tfixnum? tfixnum?) tfixnum? #2%remainder)
        (fold ((fxnot fxlognot) tfixnum?) tfixnum? #2%bitwise-not)
        (fold (fxlogtest tfixnum? tfixnum?) boolean? #2%logtest)
        (fold (fxif tfixnum? tfixnum? tfixnum?) tfixnum? #2%bitwise-if)
        (fold (fxbit-count tfixnum?) tfixnum? #2%bitwise-bit-count)
        (fold (fxlength tfixnum?) tfixnum? #2%bitwise-length)
        (fold (fxfirst-bit-set tfixnum?) tfixnum? #2%bitwise-first-bit-set)
        (fold (fx1+ tfixnum?) tfixnum? #2%1+)
        (fold (fx1- tfixnum?) tfixnum? #2%1-)

        (fold (fxbit-set? tfixnum? tfixnum?) boolean? #2%bitwise-bit-set?)
        (fold (fxcopy-bit tfixnum? u<fxwidth-1? tfixnum?) tfixnum? #2%bitwise-copy-bit)
        (fold (fxbit-field tfixnum? u<fxwidth? u<fxwidth?) tfixnum? #2%bitwise-bit-field)
        (fold (fxcopy-bit-field tfixnum? u<fxwidth? u<fxwidth? tfixnum?) tfixnum? #2%bitwise-copy-bit-field)
        (fold (fxrotate-bit-field tfixnum? u<fxwidth? u<fxwidth? u<fxwidth?) tfixnum?
          (lambda (x1 x2 x3 x4)
            (unless (fx<= x4 (fx- x3 x2)) ($oops #f "strange x4 value"))
            (#2%bitwise-rotate-bit-field x1 x2 x3 x4)))
        (fold (fxreverse-bit-field tfixnum? u<fxwidth? u<fxwidth?) tfixnum? #2%bitwise-reverse-bit-field)
        (fold (fxlogbit? tfixnum? tfixnum?) boolean? #2%logbit?)
        (fold (fxlogbit0 u<fxwidth-1? tfixnum?) tfixnum? #2%logbit0)
        (fold (fxlogbit1 u<fxwidth-1? tfixnum?) tfixnum? #2%logbit1)
        (fold (fxpopcount tfixnum?) tfixnum? #2%fxpopcount)
        (fold (fxpopcount32 tfixnum?) tfixnum? #2%fxpopcount32)
        (fold (fxpopcount16 tfixnum?) tfixnum? #2%fxpopcount16)

        (fold (fxarithmetic-shift tfixnum? s<fxwidth?) tfixnum? #2%bitwise-arithmetic-shift handle-shift)
        (fold (fxarithmetic-shift-left tfixnum? u<fxwidth?) tfixnum? #2%bitwise-arithmetic-shift-left handle-shift)
        (fold (fxarithmetic-shift-right tfixnum? u<fxwidth?) tfixnum? #2%bitwise-arithmetic-shift-right handle-shift)
        (fold (fxsll tfixnum? u<=fxwidth?) tfixnum? #2%bitwise-arithmetic-shift-left handle-shift)
        (fold (fxsll/wraparound tfixnum? u<=fxwidth?) tfixnum? #2%fxsll/wraparound handle-shift)
        (fold (fxsra tfixnum? u<=fxwidth?) tfixnum? #2%bitwise-arithmetic-shift-right handle-shift)
        (fold (fxsrl tfixnum? u<=fxwidth?) tfixnum?
          (lambda (x k)
            (if (eqv? k 0)
                x
                (#2%bitwise-arithmetic-shift-right
                  (#2%logand x (- (ash 1 (constant fixnum-bits)) 1))
                  k)))
          handle-shift)

        (fold (fixnum->flonum fixnum?) flonum? #2%inexact)
        (fold (flonum->fixnum flonum?) target-fixnum? (lambda (x) (#2%truncate (#2%exact x))))

        (fold (fxzero? tfixnum?) boolean? zero?)
        (fold (fxnegative? tfixnum?) boolean? negative?)
        (fold (fxpositive? tfixnum?) boolean? positive?)
        (fold (fxeven? tfixnum?) boolean? even?)
        (fold (fxodd? tfixnum?) boolean? odd?)
        (fold (fxnonnegative? tfixnum?) boolean? nonnegative?)
        (fold (fxnonpositive? tfixnum?) boolean? nonpositive?))

      (let ()
        (define target-wchar?
          (lambda (x)
            (and (char? x)
                 (constant-case wchar-bits
                   [(16) (< (char->integer x) #x10000)]
                   [(32) #t]))))
        ; NB: is this sufficiently tested by ftype.ms and record.ms?
        (define-inline 2 $foreign-wchar?
          [(x)
           (and (okay-to-handle?)
                (visit-and-maybe-extract* (lambda (x) #t) ([c x])
                  (residualize-seq '() (list x) ctxt)
                  `(quote ,(target-wchar? c))))]))

      (let ()
        (define $fold-bytevector-native-ref
          (lambda (native-ref generic-ref align x y ctxt)
            (and (okay-to-handle?)
                 (not (eq? (constant native-endianness) 'unknown))
                 (visit-and-maybe-extract* bytevector? ([dx x])
                   (visit-and-maybe-extract* (lambda (y)
                                               (and (integer? y)
                                                    (exact? y)
                                                    (nonnegative? y)
                                                    (= (modulo y align) 0)))
                     ([dy y])
                     (let ([val (guard (c [#t #f])
                                  (generic-ref dx dy (constant native-endianness)))])
                       (and val
                            (begin
                              (residualize-seq '() (list x y) ctxt)
                              `(quote ,val)))))))))
        (define-syntax fold-bytevector-native-ref
          (syntax-rules ()
            [(_ native-ref generic-ref align)
             (define-inline 2 native-ref
               [(x y) ($fold-bytevector-native-ref native-ref generic-ref align x y ctxt)])]))
        (fold-bytevector-native-ref bytevector-u16-native-ref bytevector-u16-ref 2)
        (fold-bytevector-native-ref bytevector-s16-native-ref bytevector-s16-ref 2)
        (fold-bytevector-native-ref bytevector-u32-native-ref bytevector-u32-ref 4)
        (fold-bytevector-native-ref bytevector-s32-native-ref bytevector-s32-ref 4)
        (fold-bytevector-native-ref bytevector-u64-native-ref bytevector-u64-ref 8)
        (fold-bytevector-native-ref bytevector-s64-native-ref bytevector-s64-ref 8))

      (define-inline 2 expt
        [(x y)
         (let ([xval (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! x))
                       [(quote ,d) (and (or (fixnum? d) (flonum? d)) d)]
                       [else #f])]
               [yval (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! y))
                       [(quote ,d) (and (or (and (fixnum? d) (fx< -1000 d 1000)) (flonum? d)) d)]
                       [else #f])])
           (and xval
                yval
                (not (and (eq? xval 0) (negative? (real-part yval))))
                (begin
                  (residualize-seq '() (list x y) ctxt)
                  `(quote ,(expt xval yval)))))])

      (define-inline 2 procedure?
        [(x) (nanopass-case (Lsrc Expr) (result-exp/indirect-ref (value-visit-operand! x))
               [(case-lambda ,preinfo ,cl ...)
                (residualize-seq '() (list x) ctxt)
                true-rec]
               [,pr
                 (residualize-seq '() (list x) ctxt)
                 (if (all-set? (prim-mask proc) (primref-flags pr)) true-rec #f)]
               [(quote ,d)
                (residualize-seq '() (list x) ctxt)
                (if (procedure? d) true-rec false-rec)]
               [else #f])])

      (define-inline 2 fixnum?
        [(x) (visit-and-maybe-extract* (lambda (x) #t) ([dx x])
               (residualize-seq '() (list x) ctxt)
               `(quote ,(target-fixnum? dx)))])

      (define-inline 2 bignum?
        [(x) (visit-and-maybe-extract* (lambda (x) #t) ([dx x])
               (residualize-seq '() (list x) ctxt)
               `(quote ,(target-bignum? dx)))])

      (let ()
        (define do-inline-carry-op
          (lambda (x y z base-op ctxt)
            (and (okay-to-handle?)
                 (visit-and-maybe-extract* target-fixnum? ([dx x] [dy y] [dz z])
                   (residualize-seq '() (list x y z) ctxt)
                   (build-primcall 3 'values
                     (let ([s (base-op dx dy dz)])
                       (list
                         `(quote ,(mod0 s (expt 2 (constant fixnum-bits))))
                         `(quote ,(div0 s (expt 2 (constant fixnum-bits)))))))))))
        (define-syntax define-inline-carry-op
          (syntax-rules ()
            [(_ op base-op)
             (define-inline 2 op
               [(x y z) (do-inline-carry-op x y z base-op ctxt)])]))
        (define-inline-carry-op fx+/carry +)
        (define-inline-carry-op fx-/carry -)
        (define-inline-carry-op fx*/carry (lambda (x y z) (+ (* x y) z))))

      (define-inline 3 fxdiv-and-mod
        [(x y)
         (and likely-to-be-compiled?
              (cp0-constant? target-fixnum-power-of-two (result-exp (value-visit-operand! y)))
              (cp0
                (let ([tx (cp0-make-temp #t)] [ty (cp0-make-temp #t)])
                  (let ([refx (build-ref tx)] [refy (build-ref ty)])
                    (build-lambda (list tx ty)
                      (build-primcall 3 'values
                        (list
                          (build-primcall 3 'fxdiv (list refx refy))
                          (build-primcall 3 'fxmod (list refx refy)))))))
                ctxt empty-env sc wd name moi))])

      (define-inline 2 $top-level-value
        [(x)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! x))
           [(quote ,d)
            (cond
              [(and (symbol? d) (okay-to-handle?)
                    (preinfo-call-can-inline? (app-preinfo ctxt)) ; $top-level-value may be marked by previous inline
                    (assq ($target-machine) ($cte-optimization-info d))) =>
               (lambda (as)
                 (let* ([opt (cte-info-inline (cdr as))]
                        [full? (cte-info-procedure-full? (cdr as))])
                   (and
                    opt
                    (nanopass-case (Lsrc Expr) opt
                      [(quote ,d)
                       (residualize-seq '() (list x) ctxt)
                       opt]
                      [,pr
                       (residualize-seq '() (list x) ctxt)
                       opt]
                      [(case-lambda ,preinfo ,cl* ...)
                       (context-case (app-ctxt ctxt)
                         [(test) (residualize-seq '() (list x) ctxt) true-rec]
                         ; reprocess to complete inlining done in the same cp0 pass and, more
                         ; importantly, to rewrite any prelexes so multiple call sites don't
                         ; result in multiple bindings for the same prelexes
                         [(app)
                          (and
                           ;; Check that enclosing call allows inlining, which is a
                           ;; separate specification from the nested `$top-level-value` call:
                           (preinfo-call-can-inline? (app-preinfo (app-ctxt ctxt)))
                           ;; The `case-lambda` form for inlining may have fewer cases
                           ;; than the actual binding, so only try to inline if there's
                           ;; a matching clause
                           ;; unless all the clauses are preserved
                           (let ([n (length (app-opnds (app-ctxt ctxt)))])
                             (cond
                              [(ormap (lambda (cl)
                                        (nanopass-case (Lsrc CaseLambdaClause) cl
                                          [(clause (,x* ...) ,interface ,body)
                                           (or (= n interface)
                                               (and full?
                                                    (fx< interface 0)
                                                    (fx>= n (fx- -1 interface))))]))
                                      cl*)
                               (residualize-seq '() (list x) ctxt)
                               (cp0 opt (app-ctxt ctxt) empty-env sc wd (app-name ctxt) moi)]
                              [else #f])))]
                         [else #f])]
                      [else #f]))))]
              [else #f])]
           [else #f])])

      (define-inline 2 $set-top-level-value!
        [(x y) ; sets y's name to x if we know what symbol x is
         (let ([x (result-exp (value-visit-operand! x))])
           (nanopass-case (Lsrc Expr) x
             [(quote ,d)
              (when (symbol? d) (operand-name-set! y d))
              #f]
             [else #f]))])

      (let ()
        (define (get-prtd ?parent k)
          (if ?parent
              (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?parent))
                [(record-type ,rtd ,e)
                 (and (not (record-type-sealed? rtd)) (k rtd))]
                [(quote ,d)
                 (and (or (eq? d #f)
                          (and (record-type-descriptor? d)
                               (not (record-type-sealed? d))))
                      (k d))]
                [else #f])
              (k #f)))
        (define (get-fields ?fields k)
          (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?fields))
            [(quote ,d) (k d)]
            [else #f]))
        (define (get-sealed x)
          (nanopass-case (Lsrc Expr) (if x (result-exp (value-visit-operand! x)) false-rec)
            [(quote ,d) (values (if d #t #f) ctrtd-sealed-known)]
            [else (values #f 0)]))
        ; for opaque, it's a bit more complicated:
        ;                 no parent    (parent #t)       (parent #f)     (parent ??)
        ; (child #t)          #t           #t                #t              #t
        ; (child #f)          #f           #t                #f              ??
        ; (child ??)          ??           #t                ??              ??
        (define (get-opaque x prtd)
          (if (and prtd (record-type-opaque? prtd))
              (values #t ctrtd-opaque-known)
              (nanopass-case (Lsrc Expr) (if x (result-exp (value-visit-operand! x)) false-rec)
                [(quote ,d)
                 (if d 
                     (values #t ctrtd-opaque-known)
                     (if (and (not d) (or (not prtd) (and (record-type-opaque-known? prtd) (not (record-type-opaque? prtd)))))
                         (values #f ctrtd-opaque-known)
                         (values #f 0)))]
                [else (values #f 0)])))
        (define (get-alt-pm x)
          (nanopass-case (Lsrc Expr) (if x (result-exp (value-visit-operand! x)) false-rec)
            [(quote ,d) d]
            [else #f]))
        (let ()
          (define (mrt ?parent ?name ?fields maybe-?sealed maybe-?opaque maybe-?alt-pm ctxt level prim primname opnd*)
            (or (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?name))
                  [(quote ,d)
                   (and (gensym? d)
                        (let ([objs (objs-if-constant (value-visit-operands! opnd*))])
                          (and objs
                               (let ([rtd (guard (c [#t #f]) (apply prim objs))])
                                 (and rtd
                                      (begin
                                        (residualize-seq '() opnd* ctxt)
                                        `(quote ,rtd)))))))]
                  [else #f])
                (get-prtd ?parent
                  (lambda (prtd)
                    (get-fields ?fields
                      (lambda (fields)
                        (let-values ([(sealed? sealed-flag) (get-sealed maybe-?sealed)]
                                     [(opaque? opaque-flag) (get-opaque maybe-?opaque prtd)]
                                     [(alt-pm) (get-alt-pm maybe-?alt-pm)])
                          (cond
                            [(guard (c [#t #f])
                               ($make-record-type base-ctrtd prtd "tmp" fields
                                  sealed? opaque? alt-pm (fxlogor sealed-flag opaque-flag))) =>
                             (lambda (ctrtd)
                               (residualize-seq opnd* '() ctxt)
                               `(record-type ,ctrtd
                                  ,(build-primcall (app-preinfo ctxt) level primname
                                     (value-visit-operands! opnd*))))]
                            [else #f]))))))))

          (define-inline 2 make-record-type
            [(?name ?fields)
             (mrt #f ?name ?fields #f #f #f ctxt level make-record-type 'make-record-type
               (list ?name ?fields))]
            [(?parent ?name ?fields)
             (mrt ?parent ?name ?fields #f #f #f ctxt level make-record-type 'make-record-type
               (list ?parent ?name ?fields))])

          (define-inline 2 $make-record-type
            [(?base-id ?parent ?name ?fields ?sealed ?opaque ?alt-pm . ?extras)
             (mrt ?parent ?name ?fields ?sealed ?opaque ?alt-pm ctxt level $make-record-type '$make-record-type
               (list* ?base-id ?parent ?name ?fields ?sealed ?opaque ?alt-pm ?extras))]))
        (let ()
          (define (mrtd ?parent ?uid ?fields ?sealed ?opaque ctxt level prim primname opnd*)
            (or (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?uid))
                  [(quote ,d)
                   (and d
                        (let ([objs (objs-if-constant (value-visit-operands! opnd*))])
                          (and objs
                               (let ([rtd (guard (c [#t #f]) (apply prim objs))])
                                 (and rtd
                                      (begin
                                        (residualize-seq '() opnd* ctxt)
                                        `(quote ,rtd)))))))]
                  [else #f])
                (get-prtd ?parent
                  (lambda (prtd)
                    (get-fields ?fields
                      (lambda (fields)
                        (let-values ([(sealed? sealed-flag) (get-sealed ?sealed)]
                                     [(opaque? opaque-flag) (get-opaque ?opaque prtd)])
                          (cond
                            [(guard (c [#t #f])
                               ($make-record-type-descriptor base-ctrtd 'tmp prtd #f
                                  sealed? opaque? fields 'cp0 (fxlogor sealed-flag opaque-flag))) =>
                             (lambda (rtd)
                               (residualize-seq opnd* '() ctxt)
                               `(record-type ,rtd
                                   ; can't use level 3 unconditionally because we're missing checks for
                                   ; ?base-rtd, ?name, ?uid, ?who, and ?extras
                                   ,(build-primcall (app-preinfo ctxt) level primname
                                      (value-visit-operands! opnd*))))]
                            [else #f]))))))))

          (define-inline 2 make-record-type-descriptor
            [(?name ?parent ?uid ?sealed ?opaque ?fields)
             (mrtd ?parent ?uid ?fields ?sealed ?opaque ctxt level
               make-record-type-descriptor 'make-record-type-descriptor
               (list ?name ?parent ?uid ?sealed ?opaque ?fields))])

          (define-inline 2 r6rs:make-record-type-descriptor
            [(?name ?parent ?uid ?sealed ?opaque ?fields)
             (mrtd ?parent ?uid ?fields ?sealed ?opaque ctxt level
               r6rs:make-record-type-descriptor 'r6rs:make-record-type-descriptor
               (list ?name ?parent ?uid ?sealed ?opaque ?fields))])

          (define-inline 2 $make-record-type-descriptor
            [(?base-rtd ?name ?parent ?uid ?sealed ?opaque ?fields ?who . ?extras)
             (mrtd ?parent ?uid ?fields ?sealed ?opaque ctxt level
               $make-record-type-descriptor '$make-record-type-descriptor
               (list* ?base-rtd ?name ?parent ?uid ?sealed ?opaque ?fields ?who ?extras))])))
      (let ()
        ; if you update this, also update duplicate in record.ss
        (define-record-type rcd
          (fields (immutable rtd) (immutable prcd) (immutable protocol))
          (nongenerative #{rcd qh0yzh5qyrxmz2l-a})
          (sealed #t))

        (define-record-type ctrcd
          (fields (immutable rtd) (immutable ctprcd) (immutable protocol-expr))
          (nongenerative)
          (sealed #t))
        (define (rcd->ctrcd rcd)
          (make-ctrcd (rcd-rtd rcd)
            (let ([prcd (rcd-prcd rcd)]) (and prcd (rcd->ctrcd prcd)))
            `(quote ,(rcd-protocol rcd))))

        (define finish
          (lambda (ctxt sc wd moi expr)
            (and expr
                 ; in app context, keep the inlining ball rolling.
                 (context-case (app-ctxt ctxt)
                   [(app) (cp0 expr (app-ctxt ctxt) empty-env sc wd (app-name ctxt) moi)]
                   [else expr]))))

        (let ()
          (define (get-rtd ?rtd k)
            (let ([expr (result-exp (value-visit-operand! ?rtd))])
              (nanopass-case (Lsrc Expr) expr
                [(quote ,d)
                 (and (record-type-descriptor? d)
                      (eqv? (rtd-pm d) -1) ; all ptrs
                      (k d expr))]
                [(record-type ,rtd (ref ,maybe-src ,x))
                 (and (eqv? (rtd-pm rtd) -1) ; all ptrs
                      (k rtd `(ref ,maybe-src ,x)))]
                [else #f])))
          (define (get-prcd ?prcd rtd k)
            (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?prcd))
              [(record-cd ,rcd ,rtd-expr ,e)
               (and (eq? (ctrcd-rtd rcd) (record-type-parent rtd))
                    (nanopass-case (Lsrc Expr) (ctrcd-protocol-expr rcd)
                      [(ref ,maybe-src ,x) #t]
                      [(quote ,d) (or (eq? d #f) (procedure? d))]
                      [else #f])
                    (k rcd))]
              [(quote ,d)
               (if (eq? d #f)
                   (k #f)
                   (and (record-constructor-descriptor? d)
                        (eq? (rcd-rtd d) (record-type-parent rtd))
                        (k (rcd->ctrcd d))))]
              [else #f]))
          ; record-cd form contains:
          ;  - compile-time rcd
          ;  - expression to access run-time rtd (quote or ref)
          ;  - expression to create run-time rcd (primcall)
          ; compile-time rcd contains:
          ;  - compile- or run-time rtd
          ;  - compile-time parent rcd or #f
          ;  - protocol expression (quote or ref)
          (define (mrcd ?rtd ?prcd ?protocol ctxt sc wd name moi level prim primname opnd*)
            (or (let ([objs (objs-if-constant (value-visit-operands! opnd*))])
                  (and objs
                       (let ([rcd (guard (c [#t #f]) (apply prim objs))])
                         (and rcd
                              (begin
                                (residualize-seq '() opnd* ctxt)
                                `(quote ,rcd))))))
                (get-rtd ?rtd
                  (lambda (rtd rtd-expr)
                    (get-prcd ?prcd rtd
                      (lambda (pctrcd)
                        (define (opnd-lambda? opnd)
                          (and opnd
                               (nanopass-case (Lsrc Expr) (if (operand-value opnd)
                                                              (result-exp (operand-value opnd))
                                                              (operand-exp opnd))
                                 [(case-lambda ,preinfo ,cl* ...) #t]
                                 [(seq (profile ,src) (case-lambda ,preinfo ,cl* ...)) #t]
                                 [else #f])))
                        (define (protocol-ok?-or-level d pctrcd)
                          (or (procedure? d)
                              (and (eq? d #f)
                                   (or (not pctrcd)
                                       (nanopass-case (Lsrc Expr) (ctrcd-protocol-expr pctrcd)
                                         [(quote ,d) (eq? d #f)]
                                         [else level])))))
                        (let* ([whole-protocol-expr (value-visit-operand! ?protocol)]
                               [result-protocol-expr (result-exp whole-protocol-expr)])
                          (cond
                            [(nanopass-case (Lsrc Expr) result-protocol-expr
                               [(quote ,d)
                                (let ([lvl (protocol-ok?-or-level d pctrcd)])
                                  (if (eq? lvl #t) 3 lvl))]
                               [(ref ,maybe-src ,x)
                                (and (not (prelex-was-assigned x))
                                     (if (opnd-lambda? (prelex-operand x)) 3 level))]
                               [else #f]) =>
                             (lambda (level)
                               (residualize-seq opnd* '() ctxt)
                               `(record-cd
                                  ,(make-ctrcd rtd pctrcd result-protocol-expr)
                                  ,rtd-expr
                                  ,(build-primcall (app-preinfo ctxt) level primname
                                     (value-visit-operands! opnd*))))]
                            [(nanopass-case (Lsrc Expr) result-protocol-expr
                               [(case-lambda ,preinfo ,cl* ...) #t]
                               [else #f])
                             ; if the protocol expression is a lambda expression, we
                             ; pull it out into an enclosing let, which can then be
                             ; assimilated outward, by value-visit-operand!, into
                             ; the form binding a variable to the rcd, if any, making
                             ; it visible and available for inlining wherever the rcd
                             ; is used.
                             (residualize-seq opnd* '() ctxt)
                             (let ([t (cp0-make-temp #t)])
                               (build-let (list t) (list whole-protocol-expr)
                                 `(record-cd
                                    ,(make-ctrcd rtd pctrcd (build-ref t))
                                    ,rtd-expr
                                    ,(build-primcall (app-preinfo ctxt) 3 primname
                                       (map
                                         (lambda (opnd) (if (eq? opnd ?protocol) (build-ref t) (value-visit-operand! opnd)))
                                         opnd*)))))]
                            [else #f]))))))))

          (define-inline 2 make-record-constructor-descriptor
            [(?rtd ?prcd ?protocol)
             (mrcd ?rtd ?prcd ?protocol ctxt sc wd name moi level
               make-record-constructor-descriptor 'make-record-constructor-descriptor
               (list ?rtd ?prcd ?protocol))])

          (define-inline 2 $make-record-constructor-descriptor
            [(?rtd ?prcd ?protocol ?who)
             (mrcd ?rtd ?prcd ?protocol ctxt sc wd name moi level
               $make-record-constructor-descriptor '$make-record-constructor-descriptor
               (list ?rtd ?prcd ?protocol ?who))]))

        (let ()
          (define (get-rtd ?rtd k1 k2)
            (let ([expr (result-exp (value-visit-operand! ?rtd))])
              (nanopass-case (Lsrc Expr) expr
                [(quote ,d) (and (record-type-descriptor? d) (k1 d expr))]
                [(record-type ,rtd ,e)
                 (nanopass-case (Lsrc Expr) e
                   [(ref ,maybe-src ,x) (k1 rtd e)]
                   [else (k2 rtd e)])]
                [else #f])))
          (define-inline 2 record-predicate
            [(?rtd)
             (and likely-to-be-compiled?
                  (get-rtd ?rtd
                    ; k1: no let needed
                    (lambda (rtd rtd-expr)
                      (residualize-seq '() (list ?rtd) ctxt)
                      (finish ctxt sc wd moi
                        (let ([t (cp0-make-temp #f)])
                          (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt)) (list t)
                            (build-primcall 3
                              (if (record-type-sealed? rtd) '$sealed-record? 'record?)
                              (list (build-ref t) rtd-expr))))))
                    ; k2: let needed
                    (lambda (rtd rtd-expr)
                      (residualize-seq (list ?rtd) '() ctxt)
                      (finish ctxt sc wd moi
                        (let ([rtd-t (cp0-make-temp #f)] [t (cp0-make-temp #f)])
                          (build-let (list rtd-t) (list (operand-value ?rtd))
                            (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt)) (list t)
                              (build-primcall 3
                                (if (record-type-sealed? rtd) '$sealed-record? 'record?)
                                (list (build-ref t) (build-ref rtd-t))))))))))]))

        (let ()
          (define type->pred
            (lambda (who real-type val-t)
              (define-syntax pred
                (lambda (x)
                  (syntax-case x ()
                    [(_ type bytes pred)
                     (if (memq (datum type) '(scheme-object boolean stdbool))
                         #'($oops who "unexpected type ~s" 'type)
                         #'(build-primcall 3 'pred
                             (list (build-ref val-t))))])))
              (record-datatype cases real-type pred
                ($oops who "unrecognized type ~s" real-type))))

          (let ()
            (define (go safe? rtd rtd-e ctxt)
              (let* ([fld* (let ([flds (rtd-flds rtd)])
                             (cond
                              [(fixnum? flds)
                               (let loop ([i flds])
                                 (if (fx= i 0)
                                     '()
                                     (cons (rtd-make-fld rtd i) (loop (fx- i 1)))))]
                              [else flds]))]
                     [t* (map (lambda (x) (cp0-make-temp #t)) fld*)]
                     [check* (if safe?
                                 (fold-right
                                   (lambda (fld t check*)
                                     (let* ([type (fld-type fld)]
                                            [real-type (filter-foreign-type type)])
                                       (if (memq real-type '(scheme-object boolean stdbool))
                                           check*
                                           (cons
                                             `(if ,(type->pred 'record-constructor real-type t)
                                                  ,void-rec
                                                  ,(build-primcall 3 'assertion-violationf
                                                     (list `(moi)
                                                       `(quote ,(format "invalid value ~~s for foreign type ~s" type))
                                                       (build-ref t))))
                                             check*))))
                                   '() fld* t*)
                                 '())])
                (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt)) t*
                  (let ([expr `(record ,rtd ,rtd-e ,(map build-ref t*) ...)])
                    (if (null? check*)
                        expr
                        (make-seq 'value (make-seq* 'effect check*) expr))))))

            (let ()
              ; When the record type is a base type, r6rs:record-constructor produces:
              ;   (prot ; protocol
              ;     (lambda (X1 ... Xn) ; n = # fields
              ;       (record rtd X1 ... Xn)))
              ; This presents no problems for the inliner.  When the record type is a not
              ; a base type (no parent), however, it produces:
              ;   (cprot ; child protocol
              ;     (lambda pp-args ; number of pp-args is unknown, hence rest interface ...
              ;       (lambda (C1 ... Cc) ; c = #child fields
              ;         (apply ; ... and apply
              ;           (pprot
              ;             (lambda (P1 ... Pp) ; p = #parent fields
              ;               (record rtd P1 ... Pp C1 ... Cc)))
              ;           pp-args))))
              ; with the inner part replicated for the grandparent, great-grandparent, etc.
              ;
              ; We could try to analyze pprot to figure out how many arguments the
              ; procedure returned by pprot takes.  We might not be able to do so, and it
              ; might turn out it's a case-lambda with several interfaces.  Even if we do
              ; determine the exact number(s) of arguments, the (lambda pp-args ---)
              ; procedure must still accept any number of arguments, since an
              ; argument-count error signaled by the (lambda pp-args ---) procedure would
              ; come too early.  Similarly, we could try to figure out how many arguments
              ; cprot passes to the (lambda pp-args ---) procedure, but this would also be
              ; difficult and possibly not helpful.  Instead, we mark pp-args as
              ; containing an immutable value.  If (as is typical) the call to (lambda
              ; pp-args procedure) becomes evident during inlining, the operand of pp-args
              ; becomes an "immutable list" record (in find-call-lambda-clause).  If (as
              ; again is typical) the apply of the procedure returned by pprot also
              ; becomes evident during inlining, it is expanded as usual into a series of
              ; car/cdr calls, which are folded when car and cdr see that the argument is
              ; an immutable list record.
              (define (try-rcd level ?rcd ctxt sc wd name moi)
                (define (get-rcd ?rcd k)
                  (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rcd))
                    [(record-cd ,rcd ,rtd-expr ,e) (k rcd rtd-expr)]
                    [(quote ,d)
                     (and (record-constructor-descriptor? d)
                          (k (rcd->ctrcd d) `(quote ,(rcd-rtd d))))]
                    [else #f]))
                (get-rcd ?rcd
                  (lambda (ctrcd rtd-e)
                    ; Convert call to r6rs:record-constructor into a call to a lambda
                    ; expression that ignores its argument...this causes the code we
                    ; generate to be processed before it is set up as a potential
                    ; operand value for inlining.  In particular, if the protocol
                    ; expr is a variable bound to a procedure, this allows the protocol
                    ; call we generate to be inlined, exposing the lambda expression
                    ; within it for use in inlining calls to the resulting constructor.
                    (cp0
                      (build-lambda (list (make-prelex*)) ; unreferenced temp
                        (let ([rtd (ctrcd-rtd ctrcd)]
                              [protocol-expr (ctrcd-protocol-expr ctrcd)])
                          (if (cp0-constant? (lambda (x) (eq? x #f)) protocol-expr)
                              (go (< level 3) rtd rtd-e ctxt)
                              `(call ,(app-preinfo ctxt) ,protocol-expr
                                 ,(cond
                                    [(record-type-parent rtd) =>
                                     (lambda (prtd)
                                       (let f ([ctprcd (ctrcd-ctprcd ctrcd)] [crtd rtd] [prtd prtd] [vars '()])
                                         (let ([pp-args (cp0-make-temp #f)]
                                               [new-vars (map (lambda (x) (cp0-make-temp #f))
                                                           (vector->list (record-type-field-names crtd)))])
                                           (set-prelex-immutable-value! pp-args #t)
                                           `(case-lambda ,(make-preinfo-lambda)
                                              (clause (,pp-args) -1
                                                ,(build-lambda new-vars
                                                   (let ([vars (append new-vars vars)])
                                                     (build-primcall level 'apply
                                                       (list
                                                         (cond
                                                           [(and ctprcd
                                                                 (let ([protocol-expr (ctrcd-protocol-expr ctprcd)])
                                                                   (and (not (cp0-constant?
                                                                               (lambda (x) (eq? x #f))
                                                                               protocol-expr))
                                                                        protocol-expr))) =>
                                                            (lambda (protocol-expr)
                                                              `(call ,(app-preinfo ctxt) ,protocol-expr
                                                                 ,(cond
                                                                    [(rtd-parent prtd) =>
                                                                     (lambda (pprtd)
                                                                       (f (ctrcd-ctprcd ctprcd) prtd pprtd vars))]
                                                                    [else
                                                                     (let ([new-vars (map (lambda (x) (cp0-make-temp #f))
                                                                                       (csv7:record-type-field-names prtd))])
                                                                       (build-lambda new-vars
                                                                         `(call ,(app-preinfo ctxt) ,(go (< level 3) rtd rtd-e ctxt)
                                                                            ,(map build-ref (append new-vars vars))
                                                                            ...)))])))]
                                                           [else
                                                            (let ([new-vars (map (lambda (x) (cp0-make-temp #f))
                                                                              (csv7:record-type-field-names prtd))])
                                                              (build-lambda new-vars
                                                                `(call ,(app-preinfo ctxt) ,(go (< level 3) rtd rtd-e ctxt)
                                                                   ,(map build-ref (append new-vars vars)) ...)))])
                                                         (build-ref pp-args))))))))))]
                                    [else (go (< level 3) rtd rtd-e ctxt)])))))
                      ctxt empty-env sc wd name moi))))

              (define-inline 2 record-constructor
                [(?rtd/rcd)
                 (and likely-to-be-compiled?
                      (cond
                        [(let ([x (result-exp (value-visit-operand! ?rtd/rcd))])
                           (nanopass-case (Lsrc Expr) x
                             [(quote ,d) (and (record-type-descriptor? d) (cons d x))]
                             [(record-type ,rtd (ref ,maybe-src ,x)) (cons rtd `(ref ,maybe-src ,x))]
                             [else #f])) =>
                         (lambda (rtd.rtd-e)
                           (residualize-seq '() (list ?rtd/rcd) ctxt)
                           (finish ctxt sc wd moi (go (< level 3) (car rtd.rtd-e) (cdr rtd.rtd-e) ctxt)))]
                        [(nanopass-case (Lsrc Expr) (result-exp (operand-value ?rtd/rcd))
                           [(record-type ,rtd ,e) rtd]
                           [else #f]) =>
                         (lambda (rtd)
                           (residualize-seq (list ?rtd/rcd) '() ctxt)
                           (let ([rtd-t (cp0-make-temp #f)])
                             (build-let (list rtd-t) (list (operand-value ?rtd/rcd))
                               (finish ctxt sc wd moi (go (< level 3) rtd (build-ref rtd-t) ctxt)))))]
                        [else (try-rcd level ?rtd/rcd ctxt sc wd name moi)]))])

              (define-inline 2 r6rs:record-constructor
                [(?rcd)
                 (and likely-to-be-compiled?
                      (try-rcd level ?rcd ctxt sc wd name moi))])))

          (let ()
            (define (find-fld ?field rtd-e rtd k)
              (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?field))
                [(quote ,d)
                 (cond
                   [(and (symbol? d) (not (fixnum? (rtd-flds rtd))))
                    ; reverse order to check child's fields first
                    (let loop ([flds (reverse (rtd-flds rtd))] [index (length (rtd-flds rtd))])
                      (let ([index (fx- index 1)])
                        (and (not (null? flds))
                             (let ([fld (car flds)])
                               (if (eq? d (fld-name fld))
                                   (k rtd-e rtd fld index)
                                   (loop (cdr flds) index))))))]
                   [(fixnum? d)
                    (let ((flds (rtd-flds rtd)))
                      (cond
                       [(fixnum? flds)
                        (and ($fxu< d flds)
                             (k rtd-e rtd (rtd-make-fld rtd d) d))]
                       [else
                        (and ($fxu< d (length flds))
                             (k rtd-e rtd (list-ref flds d) d))]))]
                   [else #f])]
                [else #f]))

            (define (r6rs:find-fld ?field rtd-e rtd k)
              (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?field))
                [(quote ,d)
                 (let ([flds (rtd-flds rtd)] [prtd (rtd-parent rtd)])
                   (let ([p-flds (and prtd (rtd-flds prtd))])
                     (let ([index (if prtd (+ d (if (fixnum? p-flds) p-flds (length p-flds))) d)])
                       (cond
                        [(fixnum? flds)
                         (and ($fxu< index flds)
                              (k rtd-e rtd (rtd-make-fld rtd index) index))]
                        [else
                         (and ($fxu< index (length flds))
                              (k rtd-e rtd (list-ref flds index) index))]))))]
                [else #f]))

            (define (find-rtd-and-field ?rtd ?field find-fld k)
              (let ([x (result-exp (value-visit-operand! ?rtd))])
                (nanopass-case (Lsrc Expr) x
                  [(quote ,d)
                   (and (record-type-descriptor? d) (find-fld ?field x d k))]
                  [(record-type ,rtd ,e)
                   (find-fld ?field e rtd k)]
                  [else #f])))

            (let ()
              (define (rfa ?rtd ?field level ctxt find-fld)
                (and likely-to-be-compiled?
                     (find-rtd-and-field ?rtd ?field find-fld
                       (lambda (rtd-e rtd fld index)
                         ; assuming all fields are accessible
                         (let ([rec-t (cp0-make-temp #t)])
                           (let ([expr `(record-ref ,rtd ,(fld-type fld) ,index (ref #f ,rec-t))])
                             (cond
                               [(fx= level 3)
                                (residualize-seq '() (list ?rtd ?field) ctxt)
                                (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt)) (list rec-t) expr)]
                               [(nanopass-case (Lsrc Expr) rtd-e
                                  [(quote ,d) #t]
                                  [(ref ,maybe-src ,x) #t]
                                  [else #f])
                                (residualize-seq '() (list ?rtd ?field) ctxt)
                                (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt)) (list rec-t)
                                  `(seq
                                     (if ,(build-primcall 3 'record?
                                            (list (build-ref rec-t) rtd-e))
                                         ,void-rec
                                         ,(build-primcall 3 '$record-oops
                                            (list (let ([name (app-name ctxt)])
                                                    (if name `(quote ,(name->symbol name)) `(moi)))
                                              (build-ref rec-t)
                                              rtd-e)))
                                     ,expr))]
                               [else
                                (let ([rtd-t (cp0-make-temp #t)])
                                  (residualize-seq (list ?rtd) (list ?field) ctxt)
                                  (build-let (list rtd-t) (list (operand-value ?rtd))
                                    (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt)) (list rec-t)
                                      `(seq
                                         (if ,(build-primcall 3 'record?
                                                (list (build-ref rec-t) (build-ref rtd-t)))
                                             ,void-rec
                                             ,(build-primcall 3 '$record-oops
                                                (list (let ([name (app-name ctxt)])
                                                        (if name `(quote ,(name->symbol name)) `(moi)))
                                                  (build-ref rec-t)
                                                  (build-ref rtd-t))))
                                         ,expr))))])))))))
              (define-inline 2 csv7:record-field-accessor
                [(?rtd ?field) (finish ctxt sc wd moi (rfa ?rtd ?field level ctxt find-fld))])
              (define-inline 2 record-accessor
                [(?rtd ?field) (finish ctxt sc wd moi (rfa ?rtd ?field level ctxt r6rs:find-fld))]))

            (let ()
              (define (rfm ?rtd ?field level ctxt who find-fld)
                (and likely-to-be-compiled?
                     (find-rtd-and-field ?rtd ?field find-fld
                       (lambda (rtd-e rtd fld index)
                         (and (fld-mutable? fld)
                              (let* ([type (fld-type fld)]
                                     [real-type (filter-foreign-type type)]
                                     [rec-t (cp0-make-temp #t)]
                                     [val-t (cp0-make-temp #t)])
                                (let ([expr `(record-set! ,rtd ,type ,index (ref #f ,rec-t) (ref #f ,val-t))]
                                      [pred (and (not (memq real-type '(scheme-object boolean stdbool)))
                                                 (type->pred who real-type val-t))])
                                  (cond
                                    [(fx= level 3)
                                     (residualize-seq '() (list ?rtd ?field) ctxt)
                                     (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                                       (list rec-t val-t)
                                       expr)]
                                    [(nanopass-case (Lsrc Expr) rtd-e
                                       [(quote ,d) #t]
                                       [(ref ,maybe-src ,x) #t]
                                       [else #f])
                                     (residualize-seq '() (list ?rtd ?field) ctxt)
                                     (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                                       (list rec-t val-t)
                                       (make-seq 'value
                                         `(if ,(build-primcall 3 'record?
                                                 (list (build-ref rec-t) rtd-e))
                                              ,void-rec
                                              ,(build-primcall 3 '$record-oops
                                                 (list (let ([name (app-name ctxt)])
                                                         (if name `(quote ,(name->symbol name)) `(moi)))
                                                   (build-ref rec-t)
                                                   rtd-e)))
                                         (if pred
                                             (make-seq 'value
                                               `(if ,pred ,void-rec
                                                    ,(build-primcall 3 'assertion-violationf
                                                       (list (let ([name (app-name ctxt)])
                                                               (if name `(quote ,(name->symbol name)) `(moi)))
                                                         `(quote ,(format "invalid value ~~s for foreign type ~s" type))
                                                         (build-ref val-t))))
                                               expr)
                                             expr)))]
                                    [else
                                      (let ([rtd-t (cp0-make-temp #t)])
                                        (residualize-seq (list ?rtd) (list ?field) ctxt)
                                        (build-let (list rtd-t) (list (operand-value ?rtd))
                                          (build-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                                            (list rec-t val-t)
                                            (make-seq 'value
                                              `(if ,(build-primcall 3 'record?
                                                      (list (build-ref rec-t) (build-ref rtd-t)))
                                                   ,void-rec
                                                   ,(build-primcall 3 '$record-oops
                                                      (list (let ([name (app-name ctxt)])
                                                              (if name `(quote ,(name->symbol name)) `(moi)))
                                                        (build-ref rec-t)
                                                        (build-ref rtd-t))))
                                              (if pred
                                                  (make-seq 'value
                                                    `(if ,pred ,void-rec
                                                         ,(build-primcall 3 'assertion-violationf
                                                            (list (let ([name (app-name ctxt)])
                                                                    (if name `(quote ,(name->symbol name)) `(moi)))
                                                              `(quote ,(format "invalid value ~~s for foreign type ~s" type))
                                                              (build-ref val-t))))
                                                    expr)
                                                  expr)))))]))))))))
              (define-inline 2 csv7:record-field-mutator
                [(?rtd ?field) (finish ctxt sc wd moi (rfm ?rtd ?field level ctxt 'record-field-mutator find-fld))])
              (define-inline 2 record-mutator
                [(?rtd ?field) (finish ctxt sc wd moi (rfm ?rtd ?field level ctxt 'record-mutator r6rs:find-fld))]))

            (define-inline 2 csv7:record-field-accessible?
              [(?rtd ?field)
               ; always true, but first verify that rtd & field are valid to avoid suppressing run-time errors
               (find-rtd-and-field ?rtd ?field find-fld
                 (lambda (rtd-e rtd fld index)
                   (residualize-seq '() (list ?rtd ?field) ctxt)
                   true-rec))])

            (let ()
              (define (rfm? ?rtd ?field ctxt find-fld)
                (find-rtd-and-field ?rtd ?field find-fld
                  (lambda (rtd-e rtd fld index)
                    (residualize-seq '() (list ?rtd ?field) ctxt)
                    `(quote ,(fld-mutable? fld)))))
              (define-inline 2 csv7:record-field-mutable?
                [(?rtd ?field) (rfm? ?rtd ?field ctxt find-fld)])
              (define-inline 2 record-field-mutable?
                [(?rtd ?field) (rfm? ?rtd ?field ctxt r6rs:find-fld)]))))
        )

      (define-inline 2 (csv7:record-type-descriptor record-rtd)
        [(?record)
         (let ([x (value-visit-operand! ?record)])
           (nanopass-case (Lsrc Expr) (result-exp/indirect-ref x)
             ; could handle record-type forms if ctrtd recorded rtdrtd (a ctrtd's rtd is always base-ctrtd)
             [(record ,rtd ,rtd-expr ,e* ...)
              (and (not (record-type-opaque? rtd))
                   (if (ctrtd? rtd)
                       (begin
                         (residualize-seq (list ?record) '() ctxt)
                         `(record-type ,rtd
                            ,(build-primcall (app-preinfo ctxt) level prim-name
                               (list x))))
                       (begin
                         (residualize-seq '() (list ?record) ctxt)
                         `(quote ,rtd))))]
             [(quote ,d)
              (and (record? d)
                   (begin
                     (residualize-seq '() (list ?record) ctxt)
                     `(quote ,(record-rtd d))))]
             [else #f]))])

      (define-inline 2 record-type-descriptor?
        [(?x)
         (let ([?x-val (value-visit-operand! ?x)])
           (cond
             [(nanopass-case (Lsrc Expr) (result-exp ?x-val)
                [(record-type ,rtd ,e) #t]
                [(quote ,d) (record-type-descriptor? d)]
                [else #f])
              (residualize-seq '() (list ?x) ctxt)
              true-rec]
             [else
              (residualize-seq (list ?x) '() ctxt)
              (build-primcall (app-preinfo ctxt) 3 'record?
                              (list ?x-val `(quote ,#!base-rtd)))]))])

      (define-inline 2 record-constructor-descriptor?
        [(?x)
         (cond
           [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
              [(record-cd ,rcd ,rtd-expr ,e) #t]
              [(quote ,d) (record-constructor-descriptor? d)]
              [else #f])
            (residualize-seq '() (list ?x) ctxt)
            true-rec]
           [else #f])])

      (define-inline 2 record-type-sealed?
        [(?rtd)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
           [(record-type ,rtd ,e)
            (and (record-type-sealed-known? rtd)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   (if (record-type-sealed? rtd) true-rec false-rec)))]
           [(quote ,d)
            (and (record-type-descriptor? d)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   `(quote ,(record-type-sealed? d))))]
           [else #f])])

      (define-inline 2 record-type-opaque?
        [(?rtd)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
           [(record-type ,rtd ,e)
            (and (record-type-opaque-known? rtd)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   (if (record-type-opaque? rtd) true-rec false-rec)))]
           [(quote ,d)
            (and (record-type-descriptor? d)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   `(quote ,(record-type-opaque? d))))]
           [else #f])])

      (let ()
        (define definitely-not-a-record?
          (lambda (xres)
            (nanopass-case (Lsrc Expr) xres
              [(case-lambda ,preinfo ,cl ...) #t]
              [,pr (all-set? (prim-mask proc) (primref-flags pr))]
              [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type) #t]
              [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type) #t]
              [(record-set! ,rtd ,type ,index ,e1 ,e2) #t]
              [(immutable-list (,e* ...) ,e) #t]
              [(immutable-vector (,e* ...) ,e) #t]
              [else #f])))
        (define one-arg-case
          (lambda (?x ctxt)
            (let ([xres (result-exp/indirect-ref (value-visit-operand! ?x))])
              (nanopass-case (Lsrc Expr) xres
                [(quote ,d)
                 (residualize-seq '() (list ?x) ctxt)
                 (if (record? d) true-rec false-rec)]
                ; could handle record-type forms if ctrtd recorded rtdrtd so we can check opacity (a ctrtd's rtd is always base-ctrtd)
                [(record ,rtd ,rtd-expr ,e* ...)
                 (and (record-type-opaque-known? rtd)
                      (begin
                        (residualize-seq '() (list ?x) ctxt)
                        (if (record-type-opaque? rtd) false-rec true-rec)))]
                [else (and (definitely-not-a-record? xres)
                           (begin
                             (residualize-seq '() (list ?x) ctxt)
                             false-rec))]))))
        (define two-arg-case
          (lambda (?x ?rtd level ctxt needs-record?)
           (let ([rtdval (value-visit-operand! ?rtd)])
             (define abandon-ship
               (lambda (xval xres maybe-rtd)
                 (if (definitely-not-a-record? xres)
                     (cond
                       [needs-record? #f]
                       [else
                        (residualize-seq '() (list ?x ?rtd) ctxt)
                        false-rec])
                     (and maybe-rtd
                          (not needs-record?)
                          (begin
                            (residualize-seq (list ?x ?rtd) '() ctxt)
                            (build-primcall (app-preinfo ctxt) 3
                              (if (record-type-sealed? maybe-rtd)
                                  '$sealed-record?
                                  'record?)
                              (list xval rtdval)))))))
             (define obviously-incompatible?
               (lambda (instance-rtd rtd)
                 (let ([flds1 (rtd-flds instance-rtd)]
                       [flds2 (rtd-flds rtd)])
                   (or (cond
                         [(or (fixnum? flds1) (fixnum? flds2))
                          (or (not (fixnum? flds1))
                              (not (fixnum? flds2))
                              (fx< flds1 flds2)
                              (not (= (rtd-mpm rtd)
                                      (bitwise-and (rtd-mpm instance-rtd)
                                                   (sub1 (bitwise-arithmetic-shift-left 1 (fx+ 1 flds2)))))))]
                         [else
                          (let f ([ls1 flds1] [ls2 flds2])
                            (if (null? ls2)
                                (and (not (record-type-parent instance-rtd))
                                     (not (null? ls1)))
                                (or (null? ls1)
                                    (not (equal? (car ls1) (car ls2)))
                                    (f (cdr ls1) (cdr ls2)))))])
                       (if (record-type-parent instance-rtd)
                           ;; could work harder here, though it gets trickier (so not obvious)...
                           #f
                           ;; instance has no parent, so rtds are compatible only if they are the same modulo
                           ;; incomplete info if one or both are ctrtds
                           (or (and (record-type-parent rtd) #t)
                               (and (and (record-type-sealed-known? rtd) (record-type-sealed-known? instance-rtd))
                                    (not (eq? (record-type-sealed? instance-rtd) (record-type-sealed? rtd))))
                               (and (and (record-type-opaque-known? rtd) (record-type-opaque-known? instance-rtd))
                                    (not (eq? (record-type-opaque? instance-rtd) (record-type-opaque? rtd))))))))))
             (nanopass-case (Lsrc Expr) (result-exp rtdval)
               [(quote ,d0)
                (and (record-type-descriptor? d0)
                     (let ([xval (value-visit-operand! ?x)])
                       (let ([xres (result-exp/indirect-ref xval)])
                         (nanopass-case (Lsrc Expr) xres
                           [(quote ,d1)
                            ; could also return #f here and let folding happen
                            (residualize-seq '() (list ?x ?rtd) ctxt)
                            (cond
                              [(and needs-record? (not (record? d1))) #f]
                              [else (if (record? d1 d0) true-rec false-rec)])]
                           ; could handle record-type forms if ctrtd recorded rtdrtd (a ctrtd's rtd is always base-ctrtd)
                           [(record ,rtd ,rtd-expr ,e* ...)
                            (guard (let f ([rtd rtd])
                                     (or (eq? rtd d0)
                                         (let ([rtd (record-type-parent rtd)])
                                           (and rtd (f rtd))))))
                            (residualize-seq '() (list ?x ?rtd) ctxt)
                            true-rec]
                           [(record ,rtd ,rtd-expr ,e* ...)
                            (obviously-incompatible? rtd d0)
                            (residualize-seq '() (list ?x ?rtd) ctxt)
                            false-rec]
                           [else (abandon-ship xval xres d0)]))))]
               [(record-type ,rtd ,e)
                (cond
                  [(nanopass-case (Lsrc Expr) (result-exp/indirect-ref (value-visit-operand! ?x))
                     [(record ,rtd2 ,rtd-expr ,e* ...)
                      (let f ([rtd2 rtd2])
                        (or (eq? rtd2 rtd)
                            (let ([rtd2 (record-type-parent rtd2)])
                              (and rtd2 (f rtd2)))))]
                     [else #f])
                   (residualize-seq '() (list ?x ?rtd) ctxt)
                   true-rec]
                  [(nanopass-case (Lsrc Expr) (result-exp/indirect-ref (value-visit-operand! ?x))
                     [(quote ,d1)
                      (and (record? d1) (obviously-incompatible? (record-rtd d1) rtd))]
                     ; could handle record-type forms if ctrtd recorded rtdrtd (a ctrtd's rtd is always base-ctrtd)
                     [(record ,rtd2 ,rtd-expr ,e* ...)
                      (obviously-incompatible? rtd2 rtd)]
                     [else #f])
                   (residualize-seq '() (list ?x ?rtd) ctxt)
                   false-rec]
                  [else
                   (let ([xval (value-visit-operand! ?x)])
                     (abandon-ship xval (result-exp/indirect-ref xval) rtd))])]
               [else
                (and (fx= level 3)
                     (let ([xval (value-visit-operand! ?x)])
                       (abandon-ship xval (result-exp/indirect-ref xval) #f)))]))))
        (define-inline 2 r6rs:record?
          [(?x) (one-arg-case ?x ctxt)])
        (define-inline 2 record?
          [(?x) (one-arg-case ?x ctxt)]
          [(?x ?rtd) (two-arg-case ?x ?rtd level ctxt #f)])
        (define-inline 2 record-instance?
          [(?x ?rtd) (two-arg-case ?x ?rtd level ctxt #t)]))

      (define-inline 2 csv7:record-type-field-names
        [(?rtd)
         (cond
           [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
              [(record-type ,rtd ,e) rtd]
              [(quote ,d) (and (record-type-descriptor? d) d)]
              [else #f]) =>
            (lambda (rtd)
              (residualize-seq '() (list ?rtd) ctxt)
              `(quote ,(csv7:record-type-field-names rtd)))]
           [else #f])])

      (define-inline 2 record-type-field-names
        [(?rtd)
         (cond
           [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
              [(record-type ,rtd ,e) rtd]
              [(quote ,d) (and (record-type-descriptor? d) d)]
              [else #f]) =>
            (lambda (rtd)
              (residualize-seq '() (list ?rtd) ctxt)
              `(quote ,(record-type-field-names rtd)))]
           [else #f])])

      (define-inline 2 csv7:record-type-field-decls
        [(?rtd)
         (cond
           [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
              [(record-type ,rtd ,e) rtd]
              [(quote ,d) (and (record-type-descriptor? d) d)]
              [else #f]) =>
            (lambda (rtd)
              (residualize-seq '() (list ?rtd) ctxt)
              `(quote ,(csv7:record-type-field-decls rtd)))]
           [else #f])])

      (define-inline 2 csv7:record-type-name
        ; don't look for record-type case, since rtd may be a temporary
        ; rtd cons'd up by cp0
        [(?rtd)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
           [(quote ,d)
            (and (record-type-descriptor? d)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   `(quote ,(csv7:record-type-name d))))]
           [else #f])])

      (define-inline 2 record-type-name
        ; don't look for record-type case, since rtd may be a temporary
        ; rtd cons'd up by cp0
        [(?rtd)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
           [(quote ,d)
            (and (record-type-descriptor? d)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   `(quote ,(record-type-name d))))]
           [else #f])])

      (define-inline 2 record-type-parent
        ; don't look for record-type case, since parent may be a temporary
        ; rtd cons'd up by cp0
        [(?rtd)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
           [(quote ,d)
            (and (record-type-descriptor? d)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   `(quote ,(record-type-parent d))))]
           [else #f])])

      (define-inline 2 (csv7:record-type-symbol record-type-uid)
        ; don't look for record-type case, since rtd may be a temporary
        ; rtd cons'd up by cp0
        [(?rtd)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?rtd))
           [(quote ,d)
            (and (record-type-descriptor? d)
                 (begin
                   (residualize-seq '() (list ?rtd) ctxt)
                   `(quote ,(record-type-uid d))))]
           [else #f])])

      (define-inline 2 $record
        [(?rtd . ?e*)
         (let ([rtd-expr (value-visit-operand! ?rtd)])
           (nanopass-case (Lsrc Expr) (result-exp rtd-expr)
             [(quote ,d)
              (and (record-type-descriptor? d)
                   (if (rtd-all-immutable? d)
                       (let ([e* (objs-if-constant (value-visit-operands! ?e*))])
                         (and e*
                              (begin
                                (residualize-seq '() (cons ?rtd ?e*) ctxt)
                                `(quote ,(apply $record d e*)))))
                       (begin
                         (residualize-seq (cons ?rtd ?e*) '() ctxt)
                         `(record ,d ,rtd-expr ,(map value-visit-operand! ?e*) ...))))]
             [(record-type ,rtd ,e)
              (begin
                (residualize-seq (cons ?rtd ?e*) '() ctxt)
                `(record ,rtd ,rtd-expr ,(map value-visit-operand! ?e*) ...))]
             [else #f]))])

      (define-inline 3 $record-ref
        [(?r ?i)
         (let ([i-expr (value-visit-operand! ?i)])
           (nanopass-case (Lsrc Expr) (result-exp i-expr)
             [(quote ,d)
              (guard (and (fixnum? d) (fx>= d 0)))
              (let ([r-expr (value-visit-operand! ?r)])
                (nanopass-case (Lsrc Expr) (result-exp r-expr)
                  [(record ,rtd1 ,rtd-expr1 ,e* ...)
                   (let loop ([e* e*] [re* '()] [index d])
                     (and (not (null? e*))
                          (if (fx= index 0)
                              (let ([e (car e*)] [e* (rappend re* (cdr e*))])
                                (define main (if (null? e*)
                                                 (make-nontail ctxt e)
                                                 (make-1seq ctxt
                                                   (make-seq* 'ignored e*)
                                                   (make-nontail ctxt e))))
                                (residualize-seq (list ?r ?i) '() ctxt)
                                (non-result-exp i-expr
                                  (non-result-exp r-expr
                                    main)))
                              (loop (cdr e*) (cons (car e*) re*) (fx- index 1)))))]
                  [else
                   (nanopass-case (Lsrc Expr) (result-exp/indirect-ref r-expr)
                     [(record ,rtd1 ,rtd-expr1 ,e* ...)
                      (guard (< d (length e*))
                        (rtd-immutable-field? rtd1 d))
                      (let* ([e (list-ref e* d)]
                             [new-e (nanopass-case (Lsrc Expr) e
                                      [(quote ,d) e]
                                      [(ref ,maybe-src ,x)
                                       (and (not (prelex-assigned x))
                                            (residualize-ref maybe-src x sc))]
                                      [,pr (and (all-set? (prim-mask proc) (primref-flags pr))
                                                e)]
                                      [else #f])])
                        (and new-e
                             (begin
                               (residualize-seq (list ?r ?i) '() ctxt)
                               (non-result-exp i-expr (non-result-exp r-expr new-e)))))]
                     [else #f])]))]
              [else #f]))])

      (let ()
        (define null-rec?
          (lambda (?ls)
            (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?ls))
              [(quote ,d) (null? d)]
              [(call ,preinfo ,e ,e* ...)
               ; check also for `(list)`. It should have been reduced to `(quote ())` before,
               ; but cp0 isn't guaranteed to reach a fixed point.
               (and (primref? e) (eq? (primref-name e) 'list) (null? e*))]
              [else #f])))
        (define inline-lists
          (lambda (?p ?ls ?ls* lvl map? ctxt sc wd name moi)
            ; (map/for-each proc (list a11 a12 ... a1m) (list a21 a22 ... a2m) ... (list an1 an2 ... anm)) =>
            ;   (let ([p proc])
            ;     (if (procedure? p)
            ;         (void)
            ;         ($oops 'map/for-each "~s is not a procedure" p))
            ;     (let ([t11 a11] ... [t1m a1m])
            ;       ...
            ;         (let ([tn1 an1] ... [tnm anm])
            ;           (list/begin (p t11 ... tn1)
            ;                       (p t12 ... tn2)
            ;                        ...
            ;                       (p t1m ... tnm)))))
            (let loop ([ls* (cons ?ls ?ls*)] [e** '()] [all-quoted? #t])
              (if (null? ls*)
                  (and (apply = (map length e**))
                       (or (not all-quoted?) (fx<= (length (car e**)) 4))
                       (let ([p (cp0-make-temp (or (fx= lvl 2) (fx> (length (car e**)) 1)))]
                             [temp** (map (lambda (e*)
                                            (map (lambda (x) (cp0-make-temp #f)) e*))
                                       e**)])
                         (residualize-seq (list* ?p ?ls ?ls*) '() ctxt)
                         (build-let (list p) (list (value-visit-operand! ?p))
                           (let ([main
                                  (let f ([t** temp**] [e** (reverse e**)] [ls* (cons ?ls ?ls*)])
                                    (if (null? t**)
                                        (let ([results 
                                               (let ([preinfo (app-preinfo ctxt)])
                                                 (let g ([t** temp**])
                                                   (if (null? (car t**))
                                                       '()
                                                       (cons `(call ,preinfo (ref #f ,p)
                                                                ,(map (lambda (t*) (build-ref (car t*))) t**) ...)
                                                             (g (map cdr t**))))))])
                                          (if (and map? (not (unused-value-context? (app-ctxt ctxt))))
                                              (if (null? results)
                                                  null-rec
                                                  (build-primcall lvl 'list results))
                                              (if (null? results)
                                                  void-rec
                                                  (make-seq* (app-ctxt ctxt) results))))
                                        (non-result-exp (value-visit-operand! (car ls*))
                                          (build-let (car t**) (car e**)
                                            (f (cdr t**) (cdr e**) (cdr ls*))))))]) 
                             (if (fx= lvl 2)
                               (make-seq (app-ctxt ctxt)
                                 `(if ,(build-primcall 2 'procedure? (list `(ref #f ,p)))
                                      ,void-rec
                                      ,(build-primcall 3 '$oops (list `(quote ,(if map? 'map 'for-each))
                                                                      `(quote  "~s is not a procedure")
                                                                      `(ref #f ,p))))
                                 main)
                               main)))))
                  (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! (car ls*)))
                    [(quote ,d)
                     (and (list? d) (loop (cdr ls*) (cons (map (lambda (x) `(quote ,x)) d) e**) all-quoted?))]
                    [(call ,preinfo ,e ,e* ...)
                     (and (primref? e) (eq? (primref-name e) 'list) (loop (cdr ls*) (cons e* e**) #f))]
                    [else #f])))))
        (define-inline 2 map
          [(?p ?ls . ?ls*)
           (inline-lists ?p ?ls ?ls* 2 #t ctxt sc wd name moi)])
        (define-inline 3 map
          [(?p ?ls . ?ls*)
            (cond
              [(ormap null-rec? (cons ?ls ?ls*))
               (residualize-seq '() (list* ?p ?ls ?ls*) ctxt)
                null-rec]
              ; could treat map in effect context as for-each, but don't because (our)
              ; map is guaranteed (even at optimization level 3) not to get sick if an
              ; input list is mutated, while for-each is not.
              [(and (unused-value-context? (app-ctxt ctxt))
                    (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?p))
                      [,pr (let ([flags (primref-flags pr)])
                              (and (if (all-set? (prim-mask unsafe) flags)
                                       (all-set? (prim-mask discard) flags)
                                       (all-set? (prim-mask (or discard unrestricted)) flags))
                                   (arity-okay? (primref-arity pr) (fx+ (length ?ls*) 1))))]
                      [else #f]))
                ; discard effect-free calls to map in effect context
                (residualize-seq '() (list* ?p ?ls ?ls*) ctxt)
                void-rec]
              [(inline-lists ?p ?ls ?ls* 3 #t ctxt sc wd name moi)]
              [(ormap (lambda (?ls)
                        (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?ls))
                          [(quote ,d)
                           (and (list? d) (let ([n (length d)]) (and (fx<= n 4) n)))]
                          [(call ,preinfo ,e ,e* ...)
                           (and (primref? e) (eq? (primref-name e) 'list) (let ([n (length e*)]) (and (fx<= n 4) n)))]
                          [else #f]))
                 (cons ?ls ?ls*)) =>
                (lambda (n)
                  (safe-assert (not (= n 0))) ; guaranteed before we get here
                  ; (map proc e1 ... (begin e2 ... '(a b c d)) e3 ...) =>
                  ;   ((lambda (p ls ...)
                  ;     ; do all cdrs first to avoid mutation sickness
                  ;      (let ([t1 (cdr ls)] ...)
                  ;        (let ([t2 (cdr t1)] ...)
                  ;          (let ([t3 (cdr t2)] ...)
                  ;            (list (p (car ls) ...)
                  ;                  (p (car t1) ...)
                  ;                  (p (car t2) ...)
                  ;                  (p (car t3) ...))))))
                  ;    proc e1 ... (begin e2 ... '(a b c d)) e3 ...)
                  (cp0
                    (let ([p (cp0-make-temp (fx> n 1))]
                           [ls* (cons (cp0-make-temp #t)
                                  (map (lambda (x) (cp0-make-temp #t)) ?ls*))])
                      (build-lambda (cons p ls*)
                        (let f ([n n] [ls* ls*] [ropnd* '()])
                          (if (fx= n 1)
                              (let ([opnd*
                                     (reverse
                                       (cons
                                         `(call ,(app-preinfo ctxt) (ref #f ,p)
                                            ,(map (lambda (x)
                                                    (build-primcall 3 'car
                                                      (list (build-ref x))))
                                               ls*) ...)
                                         ropnd*))])
                                (if (unused-value-context? ctxt)
                                    (make-1seq* ctxt opnd*)
                                    (build-primcall 3 'list opnd*)))
                              (let ([tls* (map (lambda (x) (cp0-make-temp #t)) ls*)])
                                (build-let tls*
                                  (map (lambda (x)
                                         (build-primcall 3 'cdr
                                           (list (build-ref x))))
                                    ls*)
                                  (f (fx- n 1) tls*
                                    (cons `(call ,(app-preinfo ctxt) (ref #f ,p)
                                             ,(map (lambda (x)
                                                     (build-primcall 3 'car (list (build-ref x))))
                                                ls*) ...)
                                      ropnd*))))))))
                    ctxt empty-env sc wd name moi))]
              [else #f])])

        (define-inline 2 for-each
          [(?p ?ls . ?ls*)
           (inline-lists ?p ?ls ?ls* 2 #f ctxt sc wd name moi)])
        (define-inline 3 for-each
          [(?p ?ls . ?ls*)
           (cond
              [(ormap null-rec? (cons ?ls ?ls*))
                 ; (for-each proc e1 ... (begin e2 ... '()) e3 ...) =>
                 ;   (begin e1 ... (begin e2 ... '()) e3 ... (void))
                (begin
                  (residualize-seq '() (list* ?p ?ls ?ls*) ctxt)
                  void-rec)]
             [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?p))
                [,pr (let ([flags (primref-flags pr)])
                       (and (if (all-set? (prim-mask unsafe) flags)
                                (all-set? (prim-mask discard) flags)
                                (all-set? (prim-mask (or discard unrestricted)) flags))
                            (arity-okay? (primref-arity pr) (fx+ (length ?ls*) 1))))]
                [else #f])
              (residualize-seq '() (list* ?p ?ls ?ls*) ctxt)
              void-rec]
             [(inline-lists ?p ?ls ?ls* 3 #f ctxt sc wd name moi)]
             [(ormap (lambda (?ls)
                       (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?ls))
                         [(quote ,d)
                          (and (list? d) (let ([n (length d)]) (and (fx<= n 4) n)))]
                         [(call ,preinfo ,e ,e* ...)
                          (and (primref? e) (eq? (primref-name e) 'list) (let ([n (length e*)]) (and (fx<= n 4) n)))]
                         [else #f]))
                (cons ?ls ?ls*)) =>
              (lambda (n)
                (safe-assert (not (= n 0))) ; guaranteed before we get here
                ; (for-each proc e1 ... (begin e2 ... '(a b c d)) e3 ...)
                ;   ((lambda (p ls ...)
                ;      (proc (car ls) ...)
                ;      (let ([t1 (cdr ls)] ...)
                ;        (proc (car t1) ...)
                ;        (let ([t2 (cdr t1)] ...)
                ;          (proc (car t2) ...)
                ;          (proc (cadr t2) ...))))
                ;    proc e1 ... (begin e2 ... '(a b c d)) e3 ...)
                (cp0
                  (let ([p (cp0-make-temp (fx> n 1))]
                        [ls* (cons (cp0-make-temp #t)
                               (map (lambda (x) (cp0-make-temp #t)) ?ls*))])
                    (build-lambda (cons p ls*)
                      (cond
                        [(fx= n 1)
                         `(call ,(app-preinfo ctxt) (ref #f ,p)
                            ,(map (lambda (x)
                                    (build-primcall 3 'car (list (build-ref x))))
                               ls*) ...)]
                        [else
                          (let f ([n n] [ls* ls*])
                            (if (fx= n 2)
                                (make-seq 'value
                                  `(call ,(app-preinfo ctxt) (ref #f ,p)
                                     ,(map (lambda (x)
                                             (build-primcall 3 'car (list (build-ref x))))
                                        ls*) ...)
                                  `(call ,(app-preinfo ctxt) (ref #f ,p)
                                     ,(map (lambda (x)
                                             (build-primcall 3 'cadr (list (build-ref x))))
                                        ls*) ...))
                                (make-seq 'value
                                  `(call ,(app-preinfo ctxt) (ref #f ,p)
                                     ,(map (lambda (x)
                                             (build-primcall 3 'car (list (build-ref x))))
                                        ls*) ...)
                                  (let ([tls* (map (lambda (x) (cp0-make-temp #t)) ls*)])
                                    (build-let tls*
                                      (map (lambda (x)
                                             (build-primcall 3 'cdr (list (build-ref x))))
                                        ls*)
                                      (f (fx- n 1) tls*))))))])))
                  ctxt empty-env sc wd name moi))]
             [else
               (and likely-to-be-compiled?
                    (cp0
                      (let ([?ls* (cons ?ls ?ls*)])
                        (let ([p (cp0-make-temp #t)]
                              [r (cp0-make-temp #t)]
                              [do (cp0-make-temp #t)]
                              [tls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)]
                              [ls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)])
                          (build-lambda (cons p tls*)
                            `(if ,(build-primcall 3 'null?
                                    (list (build-ref (car tls*))))
                                 ,void-rec
                                 ,(build-named-let do ls*
                                    (map build-ref tls*)
                                    (build-let (list r)
                                      (list (build-primcall 3 'cdr (list (build-ref (car ls*)))))
                                      `(if ,(build-primcall 3 'null?  (list (build-ref r)))
                                           (call ,(app-preinfo ctxt) (ref #f ,p)
                                             ,(map (lambda (x)
                                                     (build-primcall 3 'car (list (build-ref x))))
                                                ls*) ...)
                                           ,(make-seq 'value
                                              `(call ,(app-preinfo ctxt) (ref #f ,p)
                                                 ,(map (lambda (x)
                                                         (build-primcall 3 'car (list (build-ref x))))
                                                    ls*) ...)
                                              `(call ,(make-preinfo-call) (ref #f ,do) (ref #f ,r)
                                                 ,(map (lambda (x)
                                                         (build-primcall 3 'cdr (list (build-ref x))))
                                                    (cdr ls*)) ...)))))))))
                      ctxt empty-env sc wd name moi))])])
      )

      (define-inline 3 vector-map
        [(?p ?v . ?v*)
         (cond
           [(unused-value-context? (app-ctxt ctxt))
            ; treat vector-map in effect context as vector-for-each
            (cp0 (lookup-primref 3 'vector-for-each) ctxt empty-env sc wd name moi)]
           [(ormap (lambda (?v)
                     (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?v))
                       [(quote ,d)
                        (and (vector? d)
                             (let ([n (vector-length d)]) (and (fx<= n 4) n)))]
                       [else #f]))
              (cons ?v ?v*)) =>
            (lambda (n)
              (cond
                [(fx= n 0)
                 ; (vector-map proc e1 ... (begin e2 ... '#()) e3 ...) =>
                 ;   (begin proc e1 ... (begin e2 ...'#()) e3 ... '#())
                 (residualize-seq '() (list* ?p ?v ?v*) ctxt)
                 `(quote #())]
                [else
                  ; (vector-map proc (begin e1 ... '#(a b c d)) e2 ...)
                  ;   ((lambda (p v1 v2 ...)
                  ;      (vector (proc 'a (vector-ref v2 0) ...)
                  ;              (proc 'b (vector-ref v2 1) ...)
                  ;              (proc 'c (vector-ref v2 2) ...)
                  ;              (proc 'd (vector-ref v2 3) ...)))
                  ;    proc (begin e1 ... '#(a b c d)) e2 ...)
                  (cp0
                    (let ([p (cp0-make-temp (fx> n 1))]
                          [v* (cons (cp0-make-temp #t)
                                (map (lambda (x) (cp0-make-temp #t)) ?v*))])
                      (build-lambda (cons p v*)
                        (build-primcall 3 'vector
                          (map (lambda (i)
                                 `(call ,(app-preinfo ctxt) (ref #f ,p)
                                    ,(map (lambda (x)
                                            (build-primcall 3 'vector-ref
                                              (list (build-ref x) `(quote ,i))))
                                       v*) ...))
                            (iota n)))))
                    ctxt empty-env sc wd name moi)]))]
           [else #f])])

      (define-inline 3 vector-for-each
        [(?p ?v . ?v*)
         (cond
           [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?p))
              [,pr (all-set? (prim-mask discard) (primref-flags pr))]
              [else #f])
            (residualize-seq '() (list* ?p ?v ?v*) ctxt)
            void-rec]
           [(ormap (lambda (?v)
                     (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?v))
                       [(quote ,d)
                        (and (vector? d)
                             (let ([n (vector-length d)]) (and (fx<= n 4) n)))]
                       [else #f]))
              (cons ?v ?v*)) =>
            (lambda (n)
              (cond
                [(fx= n 0)
                 ; (for-each proc (begin e1 ... '()) e2 ...) =>
                 ;   (begin (begin e1 ... '()) e2 ... (void))
                 (residualize-seq '() (list* ?p ?v ?v*) ctxt)
                 void-rec]
                [else
                  ; (for-each proc (begin e1 ... '#(a b c d)) e2 ...)
                  ;   ((lambda (p ls1 ls2 ...)
                  ;      (proc 'a (vector-ref ls2 0) ...)
                  ;      (proc 'b (vector-ref ls2 1) ...)
                  ;      (proc 'c (vector-ref ls2 2) ...)
                  ;      (proc 'd (vector-ref ls2 3) ...))
                  ;    proc (begin e1 ... '(a b c d)) e2 ...)
                  (cp0
                    (let ([p (cp0-make-temp (fx> n 1))]
                          [v* (cons (cp0-make-temp #t)
                                (map (lambda (x) (cp0-make-temp #t)) ?v*))])
                      (build-lambda (cons p v*)
                        (make-seq* 'value
                          (map (lambda (i)
                                 `(call ,(app-preinfo ctxt) (ref #f ,p)
                                    ,(map (lambda (x)
                                            (build-primcall 3 'vector-ref
                                              (list (build-ref x) `(quote ,i))))
                                       v*) ...))
                            (iota n)))))
                    ctxt empty-env sc wd name moi)]))]
           [else
             (and likely-to-be-compiled?
                  (cp0
                    (let ([p (cp0-make-temp #t)]
                          [n (cp0-make-temp #t)]
                          [i (cp0-make-temp #t)]
                          [j (cp0-make-temp #t)]
                          [do (cp0-make-temp #t)]
                          [v (cp0-make-temp #t)]
                          [v* (map (lambda (x) (cp0-make-temp #f)) ?v*)])
                      (build-lambda (cons* p v v*)
                        (build-let (list n) (list (build-primcall 3 'vector-length (list (build-ref v))))
                          `(if ,(build-primcall 3 'fx= (list (build-ref n) `(quote 0)))
                               ,void-rec
                               ,(build-named-let do (list i) (list `(quote 0))
                                  (build-let (list j) (list (build-primcall 3 'fx1+ (list (build-ref i))))
                                    `(if ,(build-primcall 3 'fx= (list (build-ref j) (build-ref n)))
                                         (call ,(app-preinfo ctxt) (ref #f ,p)
                                           ,(map (lambda (x)
                                                   (build-primcall 3 'vector-ref
                                                     (list (build-ref x) (build-ref i))))
                                              (cons v v*)) ...)
                                         ,(make-seq 'value
                                            `(call ,(app-preinfo ctxt) (ref #f ,p)
                                               ,(map (lambda (x)
                                                       (build-primcall 3 'vector-ref
                                                         (list (build-ref x) (build-ref i))))
                                                  (cons v v*)) ...)
                                            `(call ,(make-preinfo-call) (ref #f ,do) (ref #f ,j))))))))))
                    ctxt empty-env sc wd name moi))])])

      (define-inline 3 string-for-each ; should combine with vector-for-each
        [(?p ?s . ?s*)
         (cond
           [(nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?p))
              [,pr (all-set? (prim-mask discard) (primref-flags pr))]
              [else #f])
            (residualize-seq '() (list* ?p ?s ?s*) ctxt)
            void-rec]
           [(ormap (lambda (?s)
                     (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?s))
                       [(quote ,d)
                        (and (string? d)
                             (let ([n (string-length d)]) (and (fx<= n 4) n)))]
                       [else #f]))
              (cons ?s ?s*)) =>
            (lambda (n)
              (cond
                [(fx= n 0)
                 ; (for-each proc (begin e1 ... '()) e2 ...) =>
                 ;   (begin (begin e1 ... '()) e2 ... (void))
                 (residualize-seq '() (list* ?p ?s ?s*) ctxt)
                 void-rec]
                [else
                  ; (for-each proc (begin e1 ... '#(a b c d)) e2 ...)
                  ;   ((lambda (p ls1 ls2 ...)
                  ;      (proc 'a (string-ref ls2 0) ...)
                  ;      (proc 'b (string-ref ls2 1) ...)
                  ;      (proc 'c (string-ref ls2 2) ...)
                  ;      (proc 'd (string-ref ls2 3) ...))
                  ;    proc (begin e1 ... '(a b c d)) e2 ...)
                  (cp0
                    (let ([p (cp0-make-temp (fx> n 1))]
                          [s* (cons (cp0-make-temp #t)
                                (map (lambda (x) (cp0-make-temp #t)) ?s*))])
                      (build-lambda (cons p s*)
                        (make-seq* 'value
                          (map (lambda (i)
                                 `(call ,(app-preinfo ctxt) (ref #f ,p)
                                    ,(map (lambda (x)
                                            (build-primcall 3 'string-ref
                                              (list (build-ref x) `(quote ,i))))
                                       s*) ...))
                            (iota n)))))
                    ctxt empty-env sc wd name moi)]))]
           [else
             (and likely-to-be-compiled?
                  (cp0
                    (let ([p (cp0-make-temp #t)]
                          [n (cp0-make-temp #t)]
                          [i (cp0-make-temp #t)]
                          [j (cp0-make-temp #t)]
                          [do (cp0-make-temp #t)]
                          [s (cp0-make-temp #t)]
                          [s* (map (lambda (x) (cp0-make-temp #f)) ?s*)])
                      (build-lambda (cons* p s s*)
                        (build-let (list n) (list (build-primcall 3 'string-length (list (build-ref s))))
                          `(if ,(build-primcall 3 'fx= (list (build-ref n) `(quote 0)))
                               ,void-rec
                               ,(build-named-let do (list i) (list `(quote 0))
                                  (build-let (list j) (list (build-primcall 3 'fx1+ (list (build-ref i))))
                                    `(if ,(build-primcall 3 'fx= (list (build-ref j) (build-ref n)))
                                         (call ,(app-preinfo ctxt) (ref #f ,p)
                                           ,(map (lambda (x)
                                                   (build-primcall 3 'string-ref
                                                     (list (build-ref x) (build-ref i))))
                                              (cons s s*)) ...)
                                         ,(make-seq 'value
                                            `(call ,(app-preinfo ctxt) (ref #f ,p)
                                               ,(map (lambda (x)
                                                       (build-primcall 3 'string-ref
                                                         (list (build-ref x) (build-ref i))))
                                                  (cons s s*)) ...)
                                            `(call ,(make-preinfo-call) (ref #f ,do) (ref #f ,j))))))))))
                    ctxt empty-env sc wd name moi))])])

      (define-inline 3 fold-right
        [(?combine ?nil ?ls . ?ls*)
         (and (ormap
                (lambda (?ls) (cp0-constant? null? (result-exp (value-visit-operand! ?ls))))
                (cons ?ls ?ls*))
              (let ([nilval (value-visit-operand! ?nil)])
                (residualize-seq (list ?nil) (list* ?combine ?ls ?ls*) ctxt)
                nilval))])

      (define-inline 3 fold-left
        [(?combine ?nil ?ls . ?ls*)
         (if (ormap
               (lambda (?ls) (cp0-constant? null? (result-exp (value-visit-operand! ?ls))))
               (cons ?ls ?ls*))
             (let ([nilval (value-visit-operand! ?nil)])
               (residualize-seq (list ?nil) (list* ?combine ?ls ?ls*) ctxt)
               nilval)
             (and likely-to-be-compiled?
                  (cp0
                    (let ([?ls* (cons ?ls ?ls*)])
                      (let ([p (cp0-make-temp #t)]
                            [nil (cp0-make-temp #t)]
                            [tls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)]
                            [do (cp0-make-temp #t)]
                            [acc (cp0-make-temp #t)]
                            [ls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)]
                            [r (cp0-make-temp #t)]
                            [carls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)])
                        (build-lambda (cons* p nil tls*)
                          `(if ,(build-primcall 3 'null? (list (build-ref (car tls*))))
                               (ref #f ,nil)
                               ,(build-named-let do (cons acc ls*)
                                  (map build-ref (cons nil tls*))
                                  (build-let (cons r carls*)
                                    (cons
                                      (build-primcall 3 'cdr (list (build-ref (car ls*))))
                                      (map (lambda (x) (build-primcall 3 'car (list (build-ref x)))) ls*))
                                    `(if ,(build-primcall 3 'null? (list (build-ref r)))
                                         (call ,(app-preinfo ctxt) (ref #f ,p)
                                           (ref #f ,acc)
                                           ,(map build-ref carls*)
                                           ...)
                                         (call ,(make-preinfo-call) (ref #f ,do)
                                           (call ,(app-preinfo ctxt) (ref #f ,p)
                                             (ref #f ,acc)
                                             ,(map build-ref carls*)
                                             ...)
                                           (ref #f ,r)
                                           ,(map (lambda (x) (build-primcall 3 'cdr (list (build-ref x)))) (cdr ls*))
                                           ...))))))))
                    ctxt empty-env sc wd name moi)))])

      (define-inline 3 (andmap for-all)
        [(?p ?ls . ?ls*)
         (if (ormap
               (lambda (?ls) (cp0-constant? null? (result-exp (value-visit-operand! ?ls))))
               (cons ?ls ?ls*))
             (begin
               (residualize-seq '() (list* ?p ?ls ?ls*) ctxt)
               true-rec)
             (and likely-to-be-compiled?
                  (cp0
                    (let ([?ls* (cons ?ls ?ls*)])
                      (let ([p (cp0-make-temp #t)]
                            [r (cp0-make-temp #t)]
                            [do (cp0-make-temp #t)]
                            [tls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)]
                            [ls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)])
                        (build-lambda (cons p tls*)
                          `(if ,(build-primcall 3 'null?
                                  (list (build-ref (car tls*))))
                               ,true-rec
                               ,(build-named-let do ls*
                                  (map build-ref tls*)
                                  (build-let (list r)
                                    (list (build-primcall 3 'cdr
                                            (list (build-ref (car ls*)))))
                                    `(if ,(build-primcall 3 'null?
                                            (list (build-ref r)))
                                         (call ,(app-preinfo ctxt) (ref #f ,p)
                                           ,(map (lambda (x)
                                                   (build-primcall 3 'car
                                                     (list (build-ref x))))
                                              ls*) ...)
                                         (if (call ,(app-preinfo ctxt) (ref #f ,p)
                                               ,(map (lambda (x)
                                                       (build-primcall 3 'car
                                                         (list (build-ref x))))
                                                  ls*) ...)
                                             (call ,(make-preinfo-call) (ref #f ,do) (ref #f ,r)
                                               ,(map (lambda (x)
                                                       (build-primcall 3 'cdr
                                                         (list (build-ref x))))
                                                  (cdr ls*)) ...)
                                             ,false-rec))))))))
                    ctxt empty-env sc wd name moi)))])

      (define-inline 3 (ormap exists)
        [(?p ?ls . ?ls*)
         (if (ormap
               (lambda (?ls) (cp0-constant? null? (result-exp (value-visit-operand! ?ls))))
               (cons ?ls ?ls*))
             (begin
               (residualize-seq '() (list* ?p ?ls ?ls*) ctxt)
               false-rec)
             (and likely-to-be-compiled?
                  (cp0
                    (let ([?ls* (cons ?ls ?ls*)])
                      (let ([p (cp0-make-temp #t)]
                            [r (cp0-make-temp #t)]
                            [t (cp0-make-temp #t)]
                            [do (cp0-make-temp #t)]
                            [tls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)]
                            [ls* (map (lambda (x) (cp0-make-temp #t)) ?ls*)])
                        (build-lambda (cons p tls*)
                          `(if ,(build-primcall 3 'null?
                                  (list (build-ref (car tls*))))
                               ,false-rec
                               ,(build-named-let do ls*
                                  (map build-ref tls*)
                                  (build-let (list r)
                                    (list (build-primcall 3 'cdr
                                            (list (build-ref (car ls*)))))
                                    `(if ,(build-primcall 3 'null?
                                            (list (build-ref r)))
                                         (call ,(app-preinfo ctxt) (ref #f ,p)
                                           ,(map (lambda (x)
                                                   (build-primcall 3 'car
                                                     (list (build-ref x))))
                                              ls*) ...)
                                         ,(build-let (list t)
                                            (list `(call ,(app-preinfo ctxt) (ref #f ,p)
                                                     ,(map (lambda (x)
                                                             (build-primcall 3 'car
                                                               (list (build-ref x))))
                                                        ls*) ...))
                                            `(if (ref #f ,t)
                                                 (ref #f ,t)
                                                 (call ,(make-preinfo-call) (ref #f ,do) (ref #f ,r)
                                                   ,(map (lambda (x)
                                                           (build-primcall 3 'cdr
                                                             (list (build-ref x))))
                                                      (cdr ls*)) ...))))))))))
                    ctxt empty-env sc wd name moi)))])

      (define-inline 2 car
        [(?x)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
           [(immutable-list (,e* ...) ,e)
            (and (not (null? e*))
                 (begin
                   (residualize-seq '() (list ?x) ctxt)
                   (make-nontail (app-ctxt ctxt) (car e*))))]
           [(call ,preinfo ,pr ,e1 ,e2)
            (guard (memq (primref-name pr) '(cons weak-cons ephemeron-cons)))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (make-1seq (app-ctxt ctxt) e2 (make-nontail (app-ctxt ctxt) e1)))]
           [(call ,preinfo ,pr ,e* ...)
            (guard (memq (primref-name pr) '(list list* cons*)) (not (null? e*)))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (fold-right
                (lambda (e1 e2) (make-1seq (app-ctxt ctxt) e1 e2))
                (make-nontail (app-ctxt ctxt) (car e*))
                (cdr e*)))]
           [else #f])])

      (define-inline 2 cdr
        [(?x)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
           [(immutable-list (,e* ...) ,e)
            (and (not (null? e*))
                 (begin
                   (residualize-seq '() (list ?x) ctxt)
                   `(immutable-list (,(cdr e*) ...)
                      ,(build-primcall (app-preinfo ctxt) 3 'cdr
                         (list e)))))]
           [(call ,preinfo ,pr ,e1 ,e2)
            (guard (memq (primref-name pr) '(cons weak-cons ephemeron-cons)))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (make-1seq (app-ctxt ctxt) e1 (make-nontail (app-ctxt ctxt) e2)))]
           [(call ,preinfo ,pr ,e* ...)
            (guard (eq? (primref-name pr) 'list) (not (null? e*)))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (make-1seq (app-ctxt ctxt) (car e*)
                (build-call (app-preinfo ctxt) pr (cdr e*))))]
           [(call ,preinfo ,pr ,e* ...)
            (guard (memq (primref-name pr) '(list* cons*)) (>= (length e*) 2))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (make-1seq (app-ctxt ctxt) (car e*)
                (build-call (app-preinfo ctxt) pr (cdr e*))))]
           [else #f])])

      (define-inline 2 cadr
        [(?x)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
           [(immutable-list (,e* ...) ,e)
            (and (>= (length e*) 2))
                 (begin
                   (residualize-seq '() (list ?x) ctxt)
                   (make-nontail (app-ctxt ctxt) (cadr e*)))]
           [(call ,preinfo ,pr ,e* ...)
            (guard (eq? (primref-name pr) 'list) (>= (length e*) 2))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (fold-right
                (lambda (e1 e2) (make-1seq (app-ctxt ctxt) e1 e2))
                (make-nontail (app-ctxt ctxt) (cadr e*))
                (cons (car e*) (cddr e*))))]
           [(call ,preinfo ,pr ,e* ...)
            (guard (memq (primref-name pr) '(list list* cons*)) (> (length e*) 2))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (fold-right
                (lambda (e1 e2) (make-1seq (app-ctxt ctxt) e1 e2))
                (make-nontail (app-ctxt ctxt) (cadr e*))
                (cons (car e*) (cddr e*))))]
           [else #f])])

      (define-inline 2 unbox
        [(?x)
         (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
           [(call ,preinfo ,pr ,e)
            (guard (memq (primref-name pr) '(box box-immobile box-immutable)))
            (residualize-seq (list ?x) '() ctxt)
            (non-result-exp (operand-value ?x)
              (make-nontail (app-ctxt ctxt) e))]
           [else #f])])

      (let ()
        (define doref
          (lambda (ctxt ?x ?i e* d edok?)
            (let ([e (let f ([e* e*] [d d] [ed #f])
                       (if (null? e*)
                           ed
                           (if (fx= d 0)
                               (let ([ed (car e*)])
                                 (and (edok? (result-exp ed)) (f (cdr e*) (fx- d 1) ed)))
                               (let ([e (f (cdr e*) (fx- d 1) ed)])
                                 (and e (edok? (result-exp (car e*))) (make-1seq (app-ctxt ctxt) (car e*) e))))))])
              (and e (begin
                       (residualize-seq (list ?x ?i) '() ctxt)
                       (non-result-exp (operand-value ?i) ; do first ...
                         (non-result-exp (operand-value ?x) ; ... so we keep ?x related side effects together
                           (make-nontail (app-ctxt ctxt) e))))))))

        (define tryref
          (lambda (ctxt ?x ?i seqprim maybe-pred)
            (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
              [(call ,preinfo ,pr ,e* ...)
               (guard (eq? (primref-name pr) seqprim))
               (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?i))
                 [(quote ,d)
                  (guard (fixnum? d) (#%$fxu< d (length e*)))
                  (doref ctxt ?x ?i e* d
                    (if (and maybe-pred (not (all-set? (prim-mask unsafe) (primref-flags pr))))
                        (lambda (x) (cp0-constant? maybe-pred x))
                        true))]
                 [else #f])]
              [else #f])))

        (define true (lambda (x) #t))

        (define-inline 2 vector-ref
          [(?x ?i)
           (or (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
                 [(immutable-vector (,e* ...) ,e)
                  (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?i))
                    [(quote ,d)
                     (guard (fixnum? d) (#%$fxu< d (length e*)))
                     (residualize-seq '() (app-opnds ctxt) ctxt)
                     (list-ref e* d)]
                    [else #f])]
                 [else #f])
               (tryref ctxt ?x ?i 'vector #f))])

        (define-inline 2 vector-length
          [(?x)
           (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
             [(immutable-vector (,e* ...) ,e)
              (residualize-seq '() (app-opnds ctxt) ctxt)
              `(quote ,(length e*))]
             [else #f])])

        (define-inline 2 string-ref
          [(?x ?i) (tryref ctxt ?x ?i 'string char?)])

        (define-inline 2 fxvector-ref
          [(?x ?i) (tryref ctxt ?x ?i 'fxvector target-fixnum?)])

        (define-inline 2 flvector-ref
          [(?x ?i) (tryref ctxt ?x ?i 'flvector flonum?)])

        ; skipping bytevector-u8-ref and bytevector-s8-ref, which generally need to adjust the result.

        (define-inline 2 list-ref
          [(?x ?i)
           (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?x))
             [(call ,preinfo ,pr ,e* ...)
              (guard (memq (primref-name pr) '(list list* cons*)))
              (nanopass-case (Lsrc Expr) (result-exp (value-visit-operand! ?i))
                [(quote ,d)
                 (guard (fixnum? d)
                   (and (fx>= d 0)
                        (let ([n (length e*)])
                          (if (eq? pr 'list) (fx< d n) (fx< d (fx- n 1))))))
                 (doref ctxt ?x ?i e* d true)]
                [else #f])]
             [else #f])]))

      (let ()
        (define maybe-add-procedure-check
          (lambda (?p level who p e)
            (define (opnd-proc? opnd)
              (nanopass-case (Lsrc Expr) (result-exp/indirect-ref (value-visit-operand! opnd))
                [(case-lambda ,preinfo ,cl ...) #t]
                [,pr (all-set? (prim-mask proc) (primref-flags pr))]
                [(quote ,d) (procedure? d)]
                [else #f]))
            (if (or (fx= level 3) (opnd-proc? ?p))
                e
                `(seq
                   (if ,(build-primcall 3 'procedure? (list (build-ref p)))
                       ,void-rec
                       ,(build-primcall 2 '$oops
                          (list
                            `(quote ,who)
                            `(quote "~s is not a procedure")
                            (build-ref p))))
                   ,e))))

        (let ()
          (define mp
            (lambda (ctxt empty-env sc wd name moi ?p level)
              (and likely-to-be-compiled?
                   (cp0
                     (let ([x (cp0-make-temp #f)] [v (cp0-make-temp #f)])
                       (set-prelex-assigned! x #t)
                       (if ?p
                           (let ([orig-x (cp0-make-temp #f)] [p (cp0-make-temp #t)])
                             (build-lambda (list orig-x p)
                               (maybe-add-procedure-check ?p level "make-parameter" p
                                 (build-let (list x) (list `(call ,(make-preinfo-call) (ref #f ,p) (ref #f ,orig-x)))
                                   (build-case-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                                     (list
                                       (list '() (build-ref x))
                                       (list (list v) `(set! #f ,x (call ,(make-preinfo-call) (ref #f ,p) (ref #f ,v))))))))))
                           (build-lambda (list x)
                             (build-case-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                               (list
                                 (list '() (build-ref x))
                                 (list (list v) `(set! #f ,x (ref #f ,v))))))))
                     ctxt empty-env sc wd name moi))))
          (define-inline 2 make-parameter
            [(?x) (mp ctxt empty-env sc wd name moi #f 2)]
            [(?x ?p) (mp ctxt empty-env sc wd name moi ?p 2)])
          (define-inline 3 make-parameter
            [(?x) (mp ctxt empty-env sc wd name moi #f 3)]
            [(?x ?p) (mp ctxt empty-env sc wd name moi ?p 3)]))

        (when-feature pthreads
          (let ()
            (define (mtp-ref x)
              (build-primcall 3 'vector-ref
                (list
                  (build-primcall 3 '$tc-field
                    (list
                      `(quote parameters)
                      (build-primcall 3 '$tc '())))
                  (build-primcall 3 'car
                    (list (build-ref x))))))
            (define (mtp-set x e)
              (build-primcall 3 '$set-thread-parameter!
                (list (build-ref x) e)))
            (define mtp
              (lambda (ctxt empty-env sc wd name moi ?p level)
                (and likely-to-be-compiled?
                     (cp0
                       (let ([orig-x (cp0-make-temp #f)] [x (cp0-make-temp #t)] [v (cp0-make-temp #f)])
                         (if ?p
                             (let ([p (cp0-make-temp #t)])
                               (build-lambda (list orig-x p)
                                 (maybe-add-procedure-check ?p level "make-thread-parameter" p
                                   (build-let (list x)
                                     (list (build-primcall 3 '$allocate-thread-parameter
                                             (list `(call ,(make-preinfo-call) (ref #f ,p) (ref #f ,orig-x)))))
                                     (build-case-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                                       (list
                                         (list '() (mtp-ref x))
                                         (list (list v) (mtp-set x `(call ,(make-preinfo-call) (ref #f ,p) (ref #f ,v))))))))))
                             (build-lambda (list orig-x)
                               (build-let (list x)
                                 (list (build-primcall 3 '$allocate-thread-parameter
                                         (list (build-ref orig-x))))
                                 (build-case-lambda (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))
                                   (list
                                     (list '() (mtp-ref x))
                                     (list (list v) (mtp-set x (build-ref v)))))))))
                       ctxt empty-env sc wd name moi))))
            (define-inline 2 make-thread-parameter
              [(?x) (mtp ctxt empty-env sc wd name moi #f 2)]
              [(?x ?p) (mtp ctxt empty-env sc wd name moi ?p 2)])
            (define-inline 3 make-thread-parameter
              [(?x) (mtp ctxt empty-env sc wd name moi #f 3)]
              [(?x ?p) (mtp ctxt empty-env sc wd name moi ?p 3)]))))

      (let ()
        (define inline-make-guardian
          (lambda (ctxt empty-env sc wd name moi formal* make-setter-clauses)
            (and likely-to-be-compiled?
                 (cp0
                   (let* ([tc (cp0-make-temp #t)] [ref-tc (build-ref tc)])
                     ; if the free variables of the closure created for a guardian changes, the code
                     ; for unregister-guardian in prims.ss might also need to be updated
                     (build-lambda formal*
                       (build-let (list tc)
                         (list (let* ([x (cp0-make-temp #t)] [ref-x (build-ref x)])
                                 (let ([zero `(quote 0)])
                                   (build-let (list x) (list (build-primcall 3 'cons (list zero zero)))
                                     (build-primcall 3 'cons (list ref-x ref-x))))))
                         (build-case-lambda (let ([preinfo (preinfo-call->preinfo-lambda (app-preinfo ctxt) (app-name ctxt))])
                                              (make-preinfo-lambda (preinfo-src preinfo) (preinfo-sexpr preinfo)
                                                #f (preinfo-lambda-name preinfo) (constant code-flag-guardian)))
                           (cons
                             (list '()
                               (let* ([x (cp0-make-temp #t)] [ref-x (build-ref x)])
                                 (let ([y (cp0-make-temp #f)])
                                   (build-let (list x) (list (build-primcall 3 'car (list ref-tc)))
                                     `(if ,(build-primcall 3 'eq?
                                             (list ref-x
                                               (build-primcall 3 'cdr (list ref-tc))))
                                          ,false-rec
                                          ,(build-let (list y) (list (build-primcall 3 'car (list ref-x)))
                                             `(seq
                                                (seq
                                                  (seq
                                                    ,(build-primcall 3 'set-car! (list ref-tc
                                                                                   (build-primcall 3 'cdr (list ref-x))))
                                                    ,(build-primcall 3 'set-car! (list ref-x false-rec)))
                                                  ,(build-primcall 3 'set-cdr! (list ref-x false-rec)))
                                                (ref #f ,y))))))))
                             (make-setter-clauses ref-tc))))))
                   ctxt empty-env sc wd name moi))))

        (define (build-make-guardian formal* ordered?-bool ctxt empty-env sc wd name moi)
          (inline-make-guardian ctxt empty-env sc wd name moi
                formal*
                (lambda (ref-tc)
                  (list 
                    (let* ([obj (cp0-make-temp #t)] [ref-obj (build-ref obj)])
                      (list (list obj)
                        (build-primcall 3 '$install-guardian
                          (list ref-obj ref-obj ref-tc ordered?-bool))))
                    (let ([obj (cp0-make-temp #f)] [rep (cp0-make-temp #f)])
                      (list (list obj rep)
                        (build-primcall 3 '$install-guardian
                          (list (build-ref obj) (build-ref rep) ref-tc ordered?-bool))))))))
      
        (define-inline 2 make-guardian
          [() (build-make-guardian '() false-rec ctxt empty-env sc wd name moi)]
          [(?ordered?)
           (let* ([ordered? (cp0-make-temp #f)]
                  [ordered?-bool `(if ,(build-ref ordered?) ,true-rec ,false-rec)])
             (build-make-guardian (list ordered?) ordered?-bool ctxt empty-env sc wd name moi))])

        (define-inline 2 $make-ftype-guardian
          [(?ftd)
           (let ([ftd (cp0-make-temp #f)])
             (inline-make-guardian ctxt empty-env sc wd name moi
               (list ftd)
               (lambda (ref-tc)
                 (list
                   (let* ([obj (cp0-make-temp #t)] [ref-obj (build-ref obj)])
                     (list (list obj)
                       (let ([e (build-primcall 3 '$install-ftype-guardian
                                  (list ref-obj ref-tc))])
                         (if (fx= level 3)
                             e
                             (let ([ref-ftd (build-ref ftd)])
                               `(seq
                                  (if ,(build-primcall 3 'record? (list ref-obj ref-ftd))
                                      ,void-rec
                                      ,(build-primcall 3 '$ftype-guardian-oops (list ref-ftd ref-obj)))
                                  ,e))))))))))])))
    ) ; with-output-language

  (define-pass cp0 : Lsrc (ir ctxt env sc wd name moi) -> Lsrc ()
    (Expr : Expr (ir ctxt env sc wd name moi) -> Expr ()
      [(quote ,d) ir]
      [(ref ,maybe-src ,x)
       (context-case ctxt
         [(effect ignored) void-rec]
         [else
          (let ((new-id (lookup x env)))
            (when (eq? new-id x)
              ; id is a free variable of a lambda we're attempting to integrate,
              ; so we conservatively set it multiply-referenced in case we try to
              ; integrate the lambda more than once.
              (set-prelex-multiply-referenced! new-id #t))
            (let ((opnd (prelex-operand new-id)))
              ; a scorer in place of an operand means that we've found a
              ; recursive reference that we're not permitted to residualize
              (if (scorer? opnd)
                  (bug-out! opnd)
                  (if (and opnd (not (inner-cyclic? opnd)))
                      (cond
                        [(and (app? ctxt)
                              ; find a lambda expression starting with (operand-exp opnd) and
                              ; following along through singly referenced unassigned variable
                              ; references---a sort of source-level copy propagation.  we should
                              ; traverse a chain of references at most once here since we only
                              ; propagate along singly referenced identifiers
                              (let loop ((new-id new-id) (opnd opnd))
                                (and (not (operand-value opnd))
                                     (not (prelex-was-assigned new-id))
                                     (not (prelex-was-multiply-referenced new-id))
                                     (nanopass-case (Lsrc Expr) (operand-exp opnd)
                                       [(case-lambda ,preinfo ,cl* ...) opnd]
                                       [(ref ,maybe-src ,x)
                                        (let ((new-rhs-id (lookup x (operand-env opnd))))
                                          (and (not (eq? new-rhs-id x))
                                               (let ((opnd (prelex-operand new-rhs-id)))
                                                 (and (operand? opnd)
                                                      (loop new-rhs-id opnd)))))]
                                       [else #f])))) =>
                          (lambda (x-opnd)
                            ; yea-raw, singly referenced id with rhs a lambda
                            ; skip value-visit operand and, therefore, don't alert the watchdog
                            (with-values (find-lambda-clause (operand-exp x-opnd) ctxt)
                              (case-lambda
                                [(ids body)
                                 (let ((sc (new-scorer)))
                                   (let ((e (cp0-let
                                              (nanopass-case (Lsrc Expr) (operand-exp x-opnd)
                                                [(case-lambda ,preinfo ,cl* ...) preinfo])
                                              ids body ctxt (operand-env x-opnd) sc (operand-wd x-opnd) name moi)))
                                     (operand-singly-referenced-score-set! x-opnd (scorer-score sc))
                                     e))]
                                [()
                                 ; had been visiting x-opnd, leaving intermediate
                                 ; opnds in chain unvisited
                                 (value-visit-operand! opnd)
                                 ; could call copy here, as below, but this
                                 ; leads to more misleading incorrect argument
                                 ; count errors
                                 #;(copy maybe-src new-id opnd ctxt sc wd)
                                 (residualize-ref maybe-src new-id sc)])))]
                        [else
                         (value-visit-operand! opnd)
                         (if (prelex-was-assigned new-id)
                             (residualize-ref maybe-src new-id sc)
                             (copy maybe-src new-id opnd ctxt sc wd name moi))])
                      (residualize-ref maybe-src new-id sc)))))])]
      [(seq ,[cp0 : e1 'effect env sc wd #f moi -> e1] ,e2)
       (make-seq ctxt e1 (cp0 e2 ctxt env sc wd name moi))]
      [(if ,[cp0 : e1 'test env sc wd #f moi -> e1] ,e2 ,e3)
       (nanopass-case (Lsrc Expr) (result-exp e1)
         [(quote ,d)
          (make-1seq ctxt e1 (cp0 (if d e2 e3) ctxt env sc wd name moi))]
         [else
          (let ((noappctxt (if (app? ctxt) 'value ctxt)))
            (let ([e2 (cp0 e2 noappctxt env sc wd name moi)]
                  [e3 (cp0 e3 noappctxt env sc wd name moi)])
              (make-if ctxt sc e1 e2 e3)))])]
      [(set! ,maybe-src ,x ,e)
       (let ((new-id (lookup x env)))
         (if (prelex-was-referenced new-id)
             (begin
               (bump sc 1)
               (let ((e (cp0 e 'value env sc wd (prelex-name x) moi)))
                 (set-prelex-assigned! new-id #t)
                 `(set! ,maybe-src ,new-id ,e)))
             (make-1seq ctxt (cp0 e 'ignored env sc wd x moi) void-rec)))]
      [(call ,preinfo ,pr (seq ,e1 ,e2))
       (guard (eq? (primref-name pr) '$value))
       ;; This simplication probably doesn't enable optimizations, but
       ;; it cleans up and normalizes output, which is at least helpful
       ;; for testing
       (cp0 `(seq ,e1 (call ,preinfo ,pr ,e2)) ctxt env sc wd name moi)]
      [(call ,preinfo ,pr ,e ,e* ...)
       (guard (eq? (primref-name pr) '$app))
       (let ([preinfo (make-preinfo-call (preinfo-src preinfo) (preinfo-sexpr preinfo)
                                         (if (all-set? (prim-mask unsafe) (primref-flags pr))
                                             (preinfo-call-mask unchecked)
                                             (preinfo-call-mask)))])
         (cp0 `(call ,preinfo ,e ,e* ...) ctxt env sc wd name moi))]
      [(call ,preinfo ,pr ,e ,e* ...)
       (guard (eq? (primref-name pr) '$app/no-inline))
       (let ([preinfo (make-preinfo-call (preinfo-src preinfo) (preinfo-sexpr preinfo)
                                         (set-flags (if (all-set? (prim-mask unsafe) (primref-flags pr))
                                                        (preinfo-call-mask unchecked)
                                                        (preinfo-call-mask))
                                                    (preinfo-call-mask no-inline)))])
         (cp0 `(call ,preinfo ,e ,e* ...) ctxt env sc wd name moi))]
      [(call ,preinfo ,pr ,e ,e* ...)
       (guard (eq? (primref-name pr) '$app/no-return))
       (let ([preinfo (make-preinfo-call (preinfo-src preinfo) (preinfo-sexpr preinfo)
                                         (set-flags (if (all-set? (prim-mask unsafe) (primref-flags pr))
                                                        (preinfo-call-mask unchecked)
                                                        (preinfo-call-mask))
                                                    (preinfo-call-mask no-inline no-return single-valued)))])
         (cp0 `(call ,preinfo ,e ,e* ...) ctxt env sc wd name moi))]
      [(call ,preinfo ,pr ,e ,e* ...)
       (guard (eq? (primref-name pr) '$app/value))
       (let ([preinfo (make-preinfo-call (preinfo-src preinfo) (preinfo-sexpr preinfo)
                                         (set-flags (if (all-set? (prim-mask unsafe) (primref-flags pr))
                                                        (preinfo-call-mask unchecked)
                                                        (preinfo-call-mask))
                                                    (preinfo-call-mask single-valued)))])
         (cp0 `(call ,preinfo ,e ,e* ...) ctxt env sc wd name moi))]
      [(call ,preinfo ,pr ,e1 ,e2 ,e3)
       ;; remove wrapper for immediately applied
       (guard (app? ctxt)
              (or (eq? (primref-name pr) 'make-wrapper-procedure)
                  (eq? (primref-name pr) 'make-arity-wrapper-procedure))
              (nanopass-case (Lsrc Expr) e2
                [(quote ,d)
                 (and (exact? d) (integer? d)
                      (bitwise-bit-set? d (length (app-opnds ctxt))))]
                [else #f]))
       (let ([e1 (cp0 e1 ctxt env sc wd name moi)])
         (if (app-used ctxt)
             (make-1seq ctxt (make-seq* 'ignored (list e2 e3)) e1)
             (let ([e2 (cp0 e2 'value env sc wd #f moi)]
                   [e3 (cp0 e2 'value env sc wd #f moi)])
               `(call ,preinfo ,pr ,e1 ,e2 ,e3))))]
      [(call ,preinfo ,pr ,e1 ,e2 ,e3)
       ;; discard unused, non-error wrapper construction
       (guard (or (eq? (primref-name pr) 'make-wrapper-procedure)
                  (eq? (primref-name pr) 'make-arity-wrapper-procedure))
              (unused-value-context? ctxt))
       (let ([e1 (cp0 e1 'value env sc wd name moi)]
             [e2 (cp0 e2 'value env sc wd #f moi)]
             [e3 (cp0 e3 'value env sc wd #f moi)])
         (cond
           [(nanopass-case (Lsrc Expr) e2
              [(quote ,d)
               (and (exact? d) (integer? d)
                    (nanopass-case (Lsrc Expr) e1
                      [(case-lambda ,preinfo (clause (,x* ...) ,interface ,body) ...) #t]
                      [else #f]))]
              [else #f])
            ;; can drop call
            (make-1seq* 'ignored (list e1 e3))]
           [else
            `(call ,preinfo ,pr ,e1 ,e2 ,e3)]))]
      [(call ,preinfo ,pr ,e)
       (guard (eq? (primref-name pr) '$fixmediate))
       (context-case ctxt
         [(ignored) (cp0 e ctxt env sc wd name moi)]
         [else
          (let ([e (cp0 e 'value env sc wd name moi)])
            (nanopass-case (Lsrc Expr) e
              [(quote ,d) e]
              [else `(call ,preinfo ,pr ,e)]))])]
      [(call ,preinfo ,e ,e* ...)
       (let ()
         (define lift-let
           (lambda (e args)
             (nanopass-case (Lsrc Expr) e
               [(case-lambda ,preinfo0 (clause (,x* ...) ,interface ,body))
                (guard (fx= interface (length args)))
                (let loop ([ids x*] [args args] [new-ids '()] [new-args '()] [xids '()] [xargs '()])
                  (if (null? ids)
                      (if (null? xids)
                          (values
                            (build-lambda preinfo0 (reverse new-ids) body)
                            (reverse new-args))
                          (values
                            (build-lambda preinfo0 (reverse xids)
                              (build-let (reverse new-ids) (reverse new-args) body))
                            (reverse xargs)))
                      (nanopass-case (Lsrc Expr) (car args)
                        [(call ,preinfo1
                           (case-lambda ,preinfo2
                             (clause (,x2* ...) ,interface2
                               (case-lambda ,preinfo3 ,cl3* ...)))
                           ,e1* ...)
                         (guard (fx= (length e1*) 1) (fx= interface2 1)
                           (not (prelex-assigned (car x*))))
                         (loop (cdr ids) (cdr args) (cons (car ids) new-ids)
                           (cons `(case-lambda ,preinfo3 ,cl3* ...) new-args) (cons (car x2*) xids)
                           (cons (car e1*) xargs))]
                        [else (loop (cdr ids)
                                (cdr args)
                                (cons (car ids) new-ids)
                                (cons (car args) new-args)
                                xids xargs)])))]
               [else (values e args)])))
         (let-values ([(e args) (lift-let e e*)])
           (cp0-call preinfo e (build-operands (ivory? e) args env wd moi) ctxt env sc wd name moi)))]
      [(case-lambda ,preinfo ,cl* ...)
       (context-case ctxt
         [(value tail)
          (bump sc 1)
          (let f ([cl* cl*] [mask 0] [rcl* '()] [known-single-valued #t])
            (if (null? cl*)
                (let ([flags (fxior (preinfo-lambda-flags preinfo)
                               (if (or (single-valued-reduce? known-single-valued)
                                       ;; Detect a simple loop:
                                       (and (prelex? name)
                                            (eq? known-single-valued name)))
                                   (constant code-flag-single-valued)
                                   0))])
                  `(case-lambda ,(preinfo-lambda-set-name-and-flags preinfo name flags)
                     ,(reverse rcl*) ...))
                (nanopass-case (Lsrc CaseLambdaClause) (car cl*)
                  [(clause (,x* ...) ,interface ,body)
                   (let ([new-mask (logor mask (if (fx< interface 0) (ash -1 (fx- -1 interface)) (ash 1 interface)))])
                     (if (= new-mask mask)
                         (f (cdr cl*) new-mask rcl* known-single-valued)
                         (with-extended-env ((env x*) (env x* #f))
                           (let ([body (cp0 body 'tail env sc wd #f name)])
                             (f (cdr cl*) new-mask
                                (cons (with-output-language (Lsrc CaseLambdaClause)
                                        `(clause (,x* ...) ,interface ,body))
                                      rcl*)
                                (and known-single-valued
                                     (single-valued-join known-single-valued
                                                         (single-valued body))))))))])))]
         [(effect ignored) void-rec]
         [(test) true-rec]
         [(app)
          (with-values (find-lambda-clause ir ctxt)
            (case-lambda
              [(ids body)
               ; looking for or pattern first
               (or (and (fx= (length ids) 1)
                        (nanopass-case (Lsrc Expr) body
                          [(if (ref ,maybe-src1 ,x1) (ref ,maybe-src2 ,x2) ,e3)
                           (guard (let ([id (car ids)]) (and (eq? x1 id) (eq? x2 id))))
                           (let ()
                             (define (finish e1)
                               (define (do-e3)
                                 (with-extended-env ((env ids) (env ids (list (make-operand false-rec env wd moi))))
                                   (let ([e3 (cp0 e3 (app-ctxt ctxt) env sc wd (app-name ctxt) moi)])
                                     (if (or (prelex-referenced (car ids)) (prelex-assigned (car ids)))
                                         (build-let ids (list false-rec) e3)
                                         e3))))
                               (nanopass-case (Lsrc Expr) (result-exp e1)
                                 [(quote ,d)
                                  (residualize-seq '() (app-opnds ctxt) ctxt)
                                  (if d true-rec (do-e3))]
                                 [else
                                  ; converting (let ([x e1]) (if x x e3)) => (if e1 #t (let ([x #f]) e3))
                                  ; i.e., handling or pattern.
                                  (residualize-seq (app-opnds ctxt) '() ctxt)
                                  (make-if ctxt sc e1
                                    true-rec
                                    (do-e3))]))
                             (let ([r-ctxt (app-ctxt ctxt)])
                               (if (or (eq? r-ctxt 'value)
                                       (eq? r-ctxt 'tail))
                                   (let ([e1 (visit-operand! (car (app-opnds ctxt)) r-ctxt)])
                                     (and (boolean-valued? e1) (finish e1)))
                                   (and (eq? (app-ctxt ctxt) 'test)
                                        (finish (test-visit-operand! (car (app-opnds ctxt))))))))]
                          [else #f]))
                   (cp0-let preinfo ids body ctxt env sc wd name moi))]
              [() (cp0 ir 'value env sc wd name moi)]))])]
      [(letrec ([,x* ,e*] ...) ,body)
       (cp0-rec-let #f x* e* body ctxt env sc wd name moi)]
      [(letrec* ([,x* ,e*] ...) ,body)
       (cp0-rec-let #t x* e* body ctxt env sc wd name moi)]
      [,pr (context-case ctxt
             [(value tail) (bump sc 1) pr]
             [(effect ignored) void-rec]
             [(test)
              (if (all-set? (prim-mask proc) (primref-flags pr))
                  true-rec
                  (begin (bump sc 1) pr))]
             [(app) (fold-primref pr ctxt sc wd name moi)])]
      [(foreign (,conv* ...) ,name ,e (,arg-type* ...) ,result-type)
       (context-case ctxt
         [(value tail app) (bump sc 1) `(foreign (,conv* ...) ,name ,(cp0 e 'value env sc wd #f moi) (,arg-type* ...) ,result-type)]
         [(effect ignored) (make-nontail ctxt (cp0 e 'ignored env sc wd #f moi))]
         [(test) (make-1seq ctxt (cp0 e 'ignored env sc wd #f moi) true-rec)])]
      [(fcallable (,conv* ...) ,e (,arg-type* ...) ,result-type)
       (context-case ctxt
         [(value tail app) (bump sc 1) `(fcallable (,conv* ...) ,(cp0 e 'value env sc wd #f moi) (,arg-type* ...) ,result-type)]
         [(effect ignored) (make-nontail ctxt (cp0 e 'ignored env sc wd #f moi))]
         [(test) (make-1seq ctxt (cp0 e 'ignored env sc wd #f moi) true-rec)])]
      [(record ,rtd ,rtd-expr ,e* ...)
       (context-case ctxt
         [(value tail app)
          (let ([rtd-expr (cp0 rtd-expr 'value env sc wd #f moi)]
                [e* (map (lambda (e) (cp0 e 'value env sc wd #f moi)) e*)])
            (or (nanopass-case (Lsrc Expr) (result-exp rtd-expr)
                  [(quote ,d)
                   (and (record-type-descriptor? d)
                        (rtd-all-immutable-scheme-objects? d)
                        (let ([d* (objs-if-constant e*)])
                          (and d*
                               (make-1seq ctxt
                                 (make-1seq* 'ignored (cons rtd-expr e*))
                                 `(quote ,(apply $record d d*))))))]
                  [else #f])
                `(record ,rtd ,rtd-expr ,e* ...)))]
         [(effect ignored)
          (make-1seq* ctxt
            (cons
              (cp0 rtd-expr 'ignored env sc wd #f moi)
              (map (lambda (e) (cp0 e 'ignored env sc wd #f moi)) e*)))]
         [(test)
          (make-1seq ctxt
            (make-seq* 'ignored
              (cons
                (cp0 rtd-expr 'ignored env sc wd #f moi)
                (map (lambda (e) (cp0 e 'ignored env sc wd #f moi)) e*)))
            true-rec)])]
      [(record-ref ,rtd ,type ,index ,e0)
       (context-case ctxt
         [(effect ignored) (make-nontail ctxt (cp0 e0 'ignored env sc wd name moi))]
         [else
          (let ([e0 (cp0 e0 'value env sc wd name moi)])
            (or (nanopass-case (Lsrc Expr) (result-exp e0)
                  [(quote ,d)
                   (and (record? d rtd)
                        (not (csv7:record-field-mutable? rtd index))
                        (make-seq ctxt e0 `(quote ,((csv7:record-field-accessor rtd index) d))))]
                  [(record ,rtd1 ,rtd-expr ,e* ...)
                   (let loop ([e* e*] [re* '()] [index index])
                     (and (not (null? e*))
                          (if (fx= index 0)
                              (let ([e (car e*)] [e* (rappend re* (cdr e*))])
                                (non-result-exp e0
                                 (if (null? e*)
                                     (make-nontail ctxt e)
                                     (make-1seq ctxt (make-seq* 'ignored e*) (make-nontail ctxt e)))))
                              (loop (cdr e*) (cons (car e*) re*) (fx- index 1)))))]
                  [else #f])
                (nanopass-case (Lsrc Expr) (result-exp/indirect-ref e0)
                  [(record ,rtd1 ,rtd-expr ,e* ...)
                   (and (> (length e*) index)
                        (rtd-immutable-field? rtd index)
                        (let ([e (list-ref e* index)])
                          (and (nanopass-case (Lsrc Expr) e
                                 [(quote ,d) #t]
                                 [(ref ,maybe-src ,x) (not (prelex-assigned x))]
                                 [,pr (all-set? (prim-mask proc) (primref-flags pr))]
                                 [else #f])
                               ; recur to cp0 to get inlining, folding, etc.
                               (non-result-exp e0 (cp0 e ctxt env sc wd name moi)))))]
                  [else #f])
                (begin (bump sc 1) `(record-ref ,rtd ,type ,index ,e0))))])]
      [(record-set! ,rtd ,type ,index ,[cp0 : e1 'value env sc wd #f moi -> e1] ,[cp0 : e2 'value env sc wd #f moi -> e2])
       `(record-set! ,rtd ,type ,index ,e1 ,e2)]
      [(record-type ,rtd ,e) (cp0 e ctxt env sc wd name moi)]
      [(record-cd ,rcd ,rtd-expr ,e) (cp0 e ctxt env sc wd name moi)]
      [(immutable-list (,[cp0 : e* 'value env sc wd #f moi -> e*] ...) ,[cp0 : e ctxt env sc wd name moi -> e])
       (context-case ctxt
         [(effect) (make-seq ctxt e void-rec)]
         [(test) (make-seq ctxt e true-rec)]
         [else `(immutable-list (,e*  ...) ,e)])]
      [(immutable-vector (,[cp0 : e* 'value env sc wd #f moi -> e*] ...) ,[cp0 : e ctxt env sc wd name moi -> e])
       (context-case ctxt
         [(effect) (make-seq ctxt e void-rec)]
         [(test) (make-seq ctxt e true-rec)]
         [else `(immutable-vector (,e*  ...) ,e)])]
      [(moi) (if moi `(quote ,moi) ir)]
      [(pariah) ir]
      [(cte-optimization-loc ,box ,[cp0 : e ctxt env sc wd name moi -> e] ,exts)
       (define new-exts (or (hashtable-ref exts-table exts #f)
                            (let ([new-exts (map (lambda (p)
                                                   (cons (lookup (car p) env) (cdr p)))
                                                 exts)])
                              (hashtable-set! exts-table exts new-exts)
                              new-exts)))
       (when (enable-cross-library-optimization)
         (let ()
           (define update-box!
             (lambda (box cte-info)
               (set-box! box
                 (cons
                   (cons ($target-machine) cte-info)
                   (remp (lambda (as) (eq? (car as) ($target-machine))) (unbox box))))))
           (nanopass-case (Lsrc Expr) e
             [(quote ,d) (and (okay-to-copy? d) (update-box! box (make-cte-info e)))]
             [,pr (update-box! box (make-cte-info pr))]
             [(ref ,maybe-src ,x)
              (and (not (prelex-was-assigned x))
                   (let ([rhs (result-exp (operand-value (prelex-operand x)))])
                     (nanopass-case (Lsrc Expr) rhs
                       [(case-lambda ,preinfo ,cl* ...)
                        ;; Function registered for inlining may report fewer clauses
                        ;; than supported by the original, since only inlinable clauses
                        ;; are kept
                        (let ([new-cl* (fold-right (lambda (cl cl*)
                                                     (let ([cl (externally-inlinable cl new-exts)])
                                                       (if cl
                                                           (cons cl cl*)
                                                           cl*)))
                                                   '()
                                                   cl*)]
                              [sv? (andmap (lambda (cl)
                                             (nanopass-case (Lsrc CaseLambdaClause) cl
                                               [(clause (,x* ...) ,interface ,body)
                                                (single-valued/inspect-ok? body)]))
                                           cl*)])
                          (when (or (pair? new-cl*) sv?)
                            (update-box! box (make-cte-info
                                              `(case-lambda ,preinfo ,new-cl* ...)
                                              (= (length cl*) (length new-cl*))
                                              sv?))))]
                       [else #f])))]
             [else (void)])))
       `(cte-optimization-loc ,box ,e ,new-exts)]
      [(cpvalid-defer ,e) (sorry! who "cpvalid leaked a cpvalid-defer form ~s" ir)]
      [(profile ,src) ir]
      [else ($oops who "unrecognized record ~s" ir)])
    (begin
      (bump wd 1)
      (Expr ir ctxt env sc wd name moi)))

  (rec $cp0
    (case-lambda
      [(x) ($cp0 x #t)]
      [(x ltbc?)
       (fluid-let ([likely-to-be-compiled? ltbc?]
                   [opending-list '()]
                   [cp0-info-hashtable (make-weak-eq-hashtable)]
                   [exts-table (make-weak-eq-hashtable)])
         (cp0 x 'tail empty-env (new-scorer) (new-watchdog) #f #f))]))))

; check to make sure all required handlers were seen, after expansion of the
; expression above has been completed
(let-syntax ([a (lambda (x)
                  (for-each
                    (lambda (sym)
                      (let ([flags ($sgetprop sym '*flags* 0)])
                        (when (all-set? (prim-mask cp02) flags)
                          (if (getprop sym 'cp02 #f)
                              (remprop sym 'cp02)
                              ($oops #f "no cp02 handler for ~s" sym)))
                        (when (all-set? (prim-mask cp03) flags)
                          (if (getprop sym 'cp03 #f)
                              (remprop sym 'cp03)
                              ($oops #f "no cp03 handler for ~s" sym)))))
                    (oblist))
                  #'(void))])
  a)
