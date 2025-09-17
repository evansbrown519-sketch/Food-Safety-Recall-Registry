;; recall-broadcast
;; Issues recall notices and enforces return/lock rules
;; Manages recall status and compliance tracking for food safety

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-RECALL-NOT-FOUND (err u201))
(define-constant ERR-RECALL-ALREADY-EXISTS (err u202))
(define-constant ERR-INVALID-SEVERITY (err u203))
(define-constant ERR-INVALID-STATUS (err u204))
(define-constant ERR-LOT-NOT-FOUND (err u205))
(define-constant ERR-NOTIFICATION-FAILED (err u206))
(define-constant ERR-COMPLIANCE-NOT-FOUND (err u207))

;; severity levels
(define-constant SEVERITY-LOW u1)
(define-constant SEVERITY-MEDIUM u2)
(define-constant SEVERITY-HIGH u3)
(define-constant SEVERITY-CRITICAL u4)

;; recall status constants
(define-constant RECALL-STATUS-ISSUED u1)
(define-constant RECALL-STATUS-IN-PROGRESS u2)
(define-constant RECALL-STATUS-COMPLETED u3)
(define-constant RECALL-STATUS-CANCELLED u4)

;; compliance status constants
(define-constant COMPLIANCE-PENDING u1)
(define-constant COMPLIANCE-ACKNOWLEDGED u2)
(define-constant COMPLIANCE-IN-PROGRESS u3)
(define-constant COMPLIANCE-COMPLETED u4)
(define-constant COMPLIANCE-FAILED u5)

;; data maps and vars
;; main recall registry
(define-map recalls
    { recall-id: (string-ascii 64) }
    {
        issuer: principal,
        lot-ids: (list 50 (string-ascii 64)),
        reason: (string-ascii 300),
        severity: uint,
        status: uint,
        issued-at: uint,
        updated-at: uint,
        deadline: uint,
        return-instructions: (string-ascii 500),
        contact-info: (string-ascii 200)
    }
)

;; stakeholder notification registry
(define-map stakeholder-notifications
    { recall-id: (string-ascii 64), stakeholder: principal }
    {
        notification-sent: bool,
        sent-at: (optional uint),
        acknowledged: bool,
        acknowledged-at: (optional uint),
        compliance-status: uint,
        last-updated: uint
    }
)

;; recall compliance tracking
(define-map recall-compliance
    { recall-id: (string-ascii 64), stakeholder: principal }
    {
        total-affected-quantity: uint,
        returned-quantity: uint,
        disposed-quantity: uint,
        compliance-percentage: uint,
        compliance-status: uint,
        evidence-hash: (optional (buff 32)),
        last-updated: uint
    }
)

;; recall actions history
(define-map recall-actions
    { recall-id: (string-ascii 64), sequence: uint }
    {
        action-type: (string-ascii 50),
        actor: principal,
        description: (string-ascii 300),
        timestamp: uint,
        data: (string-ascii 200)
    }
)

;; authorized recall issuers
(define-map authorized-issuers
    { issuer: principal }
    {
        name: (string-ascii 100),
        authority-level: uint,
        active: bool,
        authorized-by: principal,
        authorized-at: uint
    }
)

;; global counters and vars
(define-data-var recall-counter uint u0)
(define-data-var action-counter uint u0)
(define-data-var emergency-mode bool false)

;; private functions
(define-private (is-contract-owner (caller principal))
    (is-eq caller CONTRACT-OWNER)
)

(define-private (is-authorized-issuer (caller principal))
    (match (map-get? authorized-issuers { issuer: caller })
        issuer-data (and (get active issuer-data) (> (get authority-level issuer-data) u0))
        false
    )
)

(define-private (is-valid-severity (severity uint))
    (or 
        (is-eq severity SEVERITY-LOW)
        (or 
            (is-eq severity SEVERITY-MEDIUM)
            (or 
                (is-eq severity SEVERITY-HIGH)
                (is-eq severity SEVERITY-CRITICAL)
            )
        )
    )
)

(define-private (is-valid-recall-status (status uint))
    (or 
        (is-eq status RECALL-STATUS-ISSUED)
        (or 
            (is-eq status RECALL-STATUS-IN-PROGRESS)
            (or 
                (is-eq status RECALL-STATUS-COMPLETED)
                (is-eq status RECALL-STATUS-CANCELLED)
            )
        )
    )
)

(define-private (is-valid-compliance-status (status uint))
    (or 
        (is-eq status COMPLIANCE-PENDING)
        (or 
            (is-eq status COMPLIANCE-ACKNOWLEDGED)
            (or 
                (is-eq status COMPLIANCE-IN-PROGRESS)
                (or 
                    (is-eq status COMPLIANCE-COMPLETED)
                    (is-eq status COMPLIANCE-FAILED)
                )
            )
        )
    )
)

(define-private (record-recall-action
    (recall-id (string-ascii 64))
    (action-type (string-ascii 50))
    (actor principal)
    (description (string-ascii 300))
    (data (string-ascii 200))
)
    (let 
        (
            (current-sequence (var-get action-counter))
            (new-sequence (+ current-sequence u1))
        )
        (var-set action-counter new-sequence)
        (map-set recall-actions
            { recall-id: recall-id, sequence: new-sequence }
            {
                action-type: action-type,
                actor: actor,
                description: description,
                timestamp: stacks-block-height,
                data: data
            }
        )
        new-sequence
    )
)

(define-private (calculate-compliance-percentage (returned uint) (total uint))
    (if (is-eq total u0)
        u100
        (/ (* returned u100) total)
    )
)

;; public functions

;; authorize a recall issuer
(define-public (authorize-issuer
    (issuer principal)
    (name (string-ascii 100))
    (authority-level uint)
)
    (begin
        (asserts! (is-contract-owner tx-sender) ERR-UNAUTHORIZED)
        (asserts! (> authority-level u0) ERR-INVALID-SEVERITY)
        
        (map-set authorized-issuers
            { issuer: issuer }
            {
                name: name,
                authority-level: authority-level,
                active: true,
                authorized-by: tx-sender,
                authorized-at: stacks-block-height
            }
        )
        
        (print {
            event: "issuer-authorized",
            issuer: issuer,
            authority-level: authority-level
        })
        
        (ok issuer)
    )
)

;; issue a new recall
(define-public (issue-recall
    (recall-id (string-ascii 64))
    (lot-ids (list 50 (string-ascii 64)))
    (reason (string-ascii 300))
    (severity uint)
    (deadline uint)
    (return-instructions (string-ascii 500))
    (contact-info (string-ascii 200))
)
    (let 
        (
            (existing-recall (map-get? recalls { recall-id: recall-id }))
            (current-height stacks-block-height)
        )
        (asserts! (or (is-contract-owner tx-sender) (is-authorized-issuer tx-sender)) ERR-UNAUTHORIZED)
        (asserts! (is-none existing-recall) ERR-RECALL-ALREADY-EXISTS)
        (asserts! (is-valid-severity severity) ERR-INVALID-SEVERITY)
        (asserts! (> deadline current-height) ERR-INVALID-STATUS)
        
        ;; create recall entry
        (map-set recalls
            { recall-id: recall-id }
            {
                issuer: tx-sender,
                lot-ids: lot-ids,
                reason: reason,
                severity: severity,
                status: RECALL-STATUS-ISSUED,
                issued-at: current-height,
                updated-at: current-height,
                deadline: deadline,
                return-instructions: return-instructions,
                contact-info: contact-info
            }
        )
        
        ;; increment counter
        (var-set recall-counter (+ (var-get recall-counter) u1))
        
        ;; record action
        (record-recall-action recall-id "ISSUED" tx-sender reason "Recall officially issued")
        
        ;; emergency mode activation for critical recalls
        (if (is-eq severity SEVERITY-CRITICAL)
            (var-set emergency-mode true)
            true
        )
        
        (print {
            event: "recall-issued",
            recall-id: recall-id,
            severity: severity,
            lot-count: (len lot-ids),
            deadline: deadline
        })
        
        (ok recall-id)
    )
)

;; send notification to stakeholder
(define-public (notify-stakeholder
    (recall-id (string-ascii 64))
    (stakeholder principal)
)
    (let 
        (
            (recall-data (unwrap! (map-get? recalls { recall-id: recall-id }) ERR-RECALL-NOT-FOUND))
            (current-height stacks-block-height)
        )
        (asserts! (or (is-eq tx-sender (get issuer recall-data)) (is-contract-owner tx-sender)) ERR-UNAUTHORIZED)
        
        ;; create notification entry
        (map-set stakeholder-notifications
            { recall-id: recall-id, stakeholder: stakeholder }
            {
                notification-sent: true,
                sent-at: (some current-height),
                acknowledged: false,
                acknowledged-at: none,
                compliance-status: COMPLIANCE-PENDING,
                last-updated: current-height
            }
        )
        
        ;; record action
        (record-recall-action 
            recall-id 
            "NOTIFICATION" 
            tx-sender 
            "Stakeholder notified of recall" 
            "Notification sent"
        )
        
        (print {
            event: "stakeholder-notified",
            recall-id: recall-id,
            stakeholder: stakeholder,
            sent-at: current-height
        })
        
        (ok true)
    )
)

;; acknowledge recall notification
(define-public (acknowledge-recall
    (recall-id (string-ascii 64))
)
    (let 
        (
            (notification-data (unwrap! (map-get? stakeholder-notifications { recall-id: recall-id, stakeholder: tx-sender }) ERR-NOTIFICATION-FAILED))
            (recall-data (unwrap! (map-get? recalls { recall-id: recall-id }) ERR-RECALL-NOT-FOUND))
            (current-height stacks-block-height)
        )
        ;; update notification status
        (map-set stakeholder-notifications
            { recall-id: recall-id, stakeholder: tx-sender }
            (merge notification-data {
                acknowledged: true,
                acknowledged-at: (some current-height),
                compliance-status: COMPLIANCE-ACKNOWLEDGED,
                last-updated: current-height
            })
        )
        
        ;; record action
        (record-recall-action 
            recall-id 
            "ACKNOWLEDGED" 
            tx-sender 
            "Recall acknowledgment received" 
            "Stakeholder acknowledged"
        )
        
        (print {
            event: "recall-acknowledged",
            recall-id: recall-id,
            stakeholder: tx-sender,
            acknowledged-at: current-height
        })
        
        (ok true)
    )
)

;; update compliance status
(define-public (update-compliance
    (recall-id (string-ascii 64))
    (total-affected-quantity uint)
    (returned-quantity uint)
    (disposed-quantity uint)
    (evidence-hash (optional (buff 32)))
)
    (let 
        (
            (recall-data (unwrap! (map-get? recalls { recall-id: recall-id }) ERR-RECALL-NOT-FOUND))
            (compliance-percentage (calculate-compliance-percentage (+ returned-quantity disposed-quantity) total-affected-quantity))
            (new-compliance-status (if (>= compliance-percentage u100) COMPLIANCE-COMPLETED COMPLIANCE-IN-PROGRESS))
            (current-height stacks-block-height)
        )
        ;; update compliance tracking
        (map-set recall-compliance
            { recall-id: recall-id, stakeholder: tx-sender }
            {
                total-affected-quantity: total-affected-quantity,
                returned-quantity: returned-quantity,
                disposed-quantity: disposed-quantity,
                compliance-percentage: compliance-percentage,
                compliance-status: new-compliance-status,
                evidence-hash: evidence-hash,
                last-updated: current-height
            }
        )
        
        ;; update notification status
        (match (map-get? stakeholder-notifications { recall-id: recall-id, stakeholder: tx-sender })
            notification-data 
            (map-set stakeholder-notifications
                { recall-id: recall-id, stakeholder: tx-sender }
                (merge notification-data {
                    compliance-status: new-compliance-status,
                    last-updated: current-height
                })
            )
            false
        )
        
        ;; record action
        (record-recall-action 
            recall-id 
            "COMPLIANCE_UPDATE" 
            tx-sender 
            "Compliance status updated" 
            "Compliance status updated"
        )
        
        (print {
            event: "compliance-updated",
            recall-id: recall-id,
            stakeholder: tx-sender,
            compliance-percentage: compliance-percentage,
            status: new-compliance-status
        })
        
        (ok compliance-percentage)
    )
)

;; update recall status
(define-public (update-recall-status
    (recall-id (string-ascii 64))
    (new-status uint)
    (notes (string-ascii 300))
)
    (let 
        (
            (recall-data (unwrap! (map-get? recalls { recall-id: recall-id }) ERR-RECALL-NOT-FOUND))
            (current-height stacks-block-height)
        )
        (asserts! (is-eq tx-sender (get issuer recall-data)) ERR-UNAUTHORIZED)
        (asserts! (is-valid-recall-status new-status) ERR-INVALID-STATUS)
        
        ;; update recall status
        (map-set recalls
            { recall-id: recall-id }
            (merge recall-data { 
                status: new-status, 
                updated-at: current-height 
            })
        )
        
        ;; deactivate emergency mode if recall completed
        (if (is-eq new-status RECALL-STATUS-COMPLETED)
            (var-set emergency-mode false)
            true
        )
        
        ;; record action
        (record-recall-action 
            recall-id 
            "STATUS_UPDATE" 
            tx-sender 
            notes 
            "Status updated"
        )
        
        (print {
            event: "recall-status-updated",
            recall-id: recall-id,
            new-status: new-status,
            updated-by: tx-sender
        })
        
        (ok new-status)
    )
)

;; read-only functions

;; get recall information
(define-read-only (get-recall (recall-id (string-ascii 64)))
    (map-get? recalls { recall-id: recall-id })
)

;; get stakeholder notification status
(define-read-only (get-notification-status (recall-id (string-ascii 64)) (stakeholder principal))
    (map-get? stakeholder-notifications { recall-id: recall-id, stakeholder: stakeholder })
)

;; get compliance status
(define-read-only (get-compliance-status (recall-id (string-ascii 64)) (stakeholder principal))
    (map-get? recall-compliance { recall-id: recall-id, stakeholder: stakeholder })
)

;; get recall action
(define-read-only (get-recall-action (recall-id (string-ascii 64)) (sequence uint))
    (map-get? recall-actions { recall-id: recall-id, sequence: sequence })
)

;; get authorized issuer info
(define-read-only (get-authorized-issuer (issuer principal))
    (map-get? authorized-issuers { issuer: issuer })
)

;; get total recalls issued
(define-read-only (get-recall-count)
    (var-get recall-counter)
)

;; get action counter
(define-read-only (get-action-count)
    (var-get action-counter)
)

;; check if in emergency mode
(define-read-only (is-emergency-mode)
    (var-get emergency-mode)
)

;; check if recall exists
(define-read-only (recall-exists (recall-id (string-ascii 64)))
    (is-some (map-get? recalls { recall-id: recall-id }))
)

;; check if issuer is authorized
(define-read-only (is-issuer-authorized (issuer principal))
    (match (map-get? authorized-issuers { issuer: issuer })
        issuer-data (get active issuer-data)
        false
    )
)
