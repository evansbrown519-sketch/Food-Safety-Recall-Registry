;; lot-registry
;; Registers lots and links to downstream distributors/retailers
;; Maintains comprehensive supply chain visibility and lot tracking

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-LOT-NOT-FOUND (err u101))
(define-constant ERR-LOT-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-STATUS (err u103))
(define-constant ERR-DISTRIBUTOR-NOT-FOUND (err u104))
(define-constant ERR-INVALID-QUANTITY (err u105))

;; lot status constants
(define-constant STATUS-REGISTERED u1)
(define-constant STATUS-IN-TRANSIT u2)
(define-constant STATUS-DELIVERED u3)
(define-constant STATUS-RECALLED u4)
(define-constant STATUS-DISPOSED u5)

;; data maps and vars
;; main lot registry mapping
(define-map lots 
    { lot-id: (string-ascii 64) }
    {
        manufacturer: principal,
        product-name: (string-ascii 100),
        production-date: uint,
        expiration-date: uint,
        batch-info: (string-ascii 200),
        quantity: uint,
        status: uint,
        created-at: uint,
        updated-at: uint
    }
)

;; distributor information mapping
(define-map distributors
    { distributor-id: principal }
    {
        name: (string-ascii 100),
        contact-info: (string-ascii 200),
        certification-level: uint,
        active: bool,
        registered-at: uint
    }
)

;; lot-distributor relationship mapping
(define-map lot-distributors
    { lot-id: (string-ascii 64), distributor: principal }
    {
        assigned-quantity: uint,
        delivery-date: (optional uint),
        status: uint,
        created-at: uint
    }
)

;; lot tracking history
(define-map lot-history
    { lot-id: (string-ascii 64), sequence: uint }
    {
        action: (string-ascii 50),
        actor: principal,
        details: (string-ascii 200),
        timestamp: uint
    }
)

;; global counters
(define-data-var lot-counter uint u0)
(define-data-var history-counter uint u0)

;; private functions
(define-private (is-contract-owner (caller principal))
    (is-eq caller CONTRACT-OWNER)
)

(define-private (is-valid-status (status uint))
    (or 
        (is-eq status STATUS-REGISTERED)
        (or 
            (is-eq status STATUS-IN-TRANSIT)
            (or 
                (is-eq status STATUS-DELIVERED)
                (or 
                    (is-eq status STATUS-RECALLED)
                    (is-eq status STATUS-DISPOSED)
                )
            )
        )
    )
)

(define-private (record-lot-history 
    (lot-id (string-ascii 64)) 
    (action (string-ascii 50)) 
    (actor principal) 
    (details (string-ascii 200))
)
    (let 
        (
            (current-sequence (var-get history-counter))
            (new-sequence (+ current-sequence u1))
        )
        (var-set history-counter new-sequence)
        (map-set lot-history
            { lot-id: lot-id, sequence: new-sequence }
            {
                action: action,
                actor: actor,
                details: details,
                timestamp: stacks-block-height
            }
        )
        new-sequence
    )
)

;; public functions

;; register a new lot
(define-public (register-lot 
    (lot-id (string-ascii 64))
    (product-name (string-ascii 100))
    (production-date uint)
    (expiration-date uint)
    (batch-info (string-ascii 200))
    (quantity uint)
)
    (let 
        (
            (existing-lot (map-get? lots { lot-id: lot-id }))
            (current-height stacks-block-height)
        )
        (asserts! (is-none existing-lot) ERR-LOT-ALREADY-EXISTS)
        (asserts! (> quantity u0) ERR-INVALID-QUANTITY)
        
        ;; create the lot entry
        (map-set lots
            { lot-id: lot-id }
            {
                manufacturer: tx-sender,
                product-name: product-name,
                production-date: production-date,
                expiration-date: expiration-date,
                batch-info: batch-info,
                quantity: quantity,
                status: STATUS-REGISTERED,
                created-at: current-height,
                updated-at: current-height
            }
        )
        
        ;; increment counter
        (var-set lot-counter (+ (var-get lot-counter) u1))
        
        ;; record history
        (record-lot-history lot-id "REGISTERED" tx-sender batch-info)
        
        (print {
            event: "lot-registered",
            lot-id: lot-id,
            manufacturer: tx-sender,
            quantity: quantity
        })
        
        (ok lot-id)
    )
)

;; register a distributor
(define-public (register-distributor
    (distributor-id principal)
    (name (string-ascii 100))
    (contact-info (string-ascii 200))
    (certification-level uint)
)
    (begin
        (asserts! (is-contract-owner tx-sender) ERR-UNAUTHORIZED)
        
        (map-set distributors
            { distributor-id: distributor-id }
            {
                name: name,
                contact-info: contact-info,
                certification-level: certification-level,
                active: true,
                registered-at: stacks-block-height
            }
        )
        
        (print {
            event: "distributor-registered",
            distributor-id: distributor-id,
            name: name
        })
        
        (ok distributor-id)
    )
)

;; assign lot to distributor
(define-public (assign-lot-to-distributor
    (lot-id (string-ascii 64))
    (distributor principal)
    (assigned-quantity uint)
)
    (let 
        (
            (lot-data (unwrap! (map-get? lots { lot-id: lot-id }) ERR-LOT-NOT-FOUND))
            (distributor-data (unwrap! (map-get? distributors { distributor-id: distributor }) ERR-DISTRIBUTOR-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender (get manufacturer lot-data)) ERR-UNAUTHORIZED)
        (asserts! (> assigned-quantity u0) ERR-INVALID-QUANTITY)
        (asserts! (<= assigned-quantity (get quantity lot-data)) ERR-INVALID-QUANTITY)
        (asserts! (get active distributor-data) ERR-UNAUTHORIZED)
        
        ;; create lot-distributor relationship
        (map-set lot-distributors
            { lot-id: lot-id, distributor: distributor }
            {
                assigned-quantity: assigned-quantity,
                delivery-date: none,
                status: STATUS-IN-TRANSIT,
                created-at: stacks-block-height
            }
        )
        
        ;; update lot status
        (map-set lots
            { lot-id: lot-id }
            (merge lot-data { status: STATUS-IN-TRANSIT, updated-at: stacks-block-height })
        )
        
        ;; record history
        (record-lot-history 
            lot-id 
            "ASSIGNED" 
            tx-sender 
            "Assigned to distributor"
        )
        
        (print {
            event: "lot-assigned",
            lot-id: lot-id,
            distributor: distributor,
            quantity: assigned-quantity
        })
        
        (ok true)
    )
)

;; update lot status
(define-public (update-lot-status
    (lot-id (string-ascii 64))
    (new-status uint)
    (details (string-ascii 200))
)
    (let 
        (
            (lot-data (unwrap! (map-get? lots { lot-id: lot-id }) ERR-LOT-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender (get manufacturer lot-data)) ERR-UNAUTHORIZED)
        (asserts! (is-valid-status new-status) ERR-INVALID-STATUS)
        
        ;; update lot status
        (map-set lots
            { lot-id: lot-id }
            (merge lot-data { status: new-status, updated-at: stacks-block-height })
        )
        
        ;; record history
        (record-lot-history lot-id "STATUS_UPDATE" tx-sender details)
        
        (print {
            event: "status-updated",
            lot-id: lot-id,
            new-status: new-status,
            details: details
        })
        
        (ok new-status)
    )
)

;; mark delivery complete
(define-public (mark-delivery-complete
    (lot-id (string-ascii 64))
    (distributor principal)
)
    (let 
        (
            (lot-distributor-data (unwrap! (map-get? lot-distributors { lot-id: lot-id, distributor: distributor }) ERR-DISTRIBUTOR-NOT-FOUND))
            (lot-data (unwrap! (map-get? lots { lot-id: lot-id }) ERR-LOT-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender distributor) ERR-UNAUTHORIZED)
        
        ;; update lot-distributor relationship
        (map-set lot-distributors
            { lot-id: lot-id, distributor: distributor }
            (merge lot-distributor-data { 
                delivery-date: (some stacks-block-height),
                status: STATUS-DELIVERED
            })
        )
        
        ;; update lot status
        (map-set lots
            { lot-id: lot-id }
            (merge lot-data { status: STATUS-DELIVERED, updated-at: stacks-block-height })
        )
        
        ;; record history
        (record-lot-history lot-id "DELIVERED" distributor "Delivery confirmed by distributor")
        
        (print {
            event: "delivery-complete",
            lot-id: lot-id,
            distributor: distributor,
            delivered-at: stacks-block-height
        })
        
        (ok true)
    )
)

;; read-only functions

;; get lot information
(define-read-only (get-lot (lot-id (string-ascii 64)))
    (map-get? lots { lot-id: lot-id })
)

;; get distributor information
(define-read-only (get-distributor (distributor-id principal))
    (map-get? distributors { distributor-id: distributor-id })
)

;; get lot-distributor relationship
(define-read-only (get-lot-distributor (lot-id (string-ascii 64)) (distributor principal))
    (map-get? lot-distributors { lot-id: lot-id, distributor: distributor })
)

;; get lot history entry
(define-read-only (get-lot-history (lot-id (string-ascii 64)) (sequence uint))
    (map-get? lot-history { lot-id: lot-id, sequence: sequence })
)

;; get total lots registered
(define-read-only (get-lot-count)
    (var-get lot-counter)
)

;; get history counter
(define-read-only (get-history-count)
    (var-get history-counter)
)

;; check if lot exists
(define-read-only (lot-exists (lot-id (string-ascii 64)))
    (is-some (map-get? lots { lot-id: lot-id }))
)

;; check if distributor is active
(define-read-only (is-distributor-active (distributor-id principal))
    (match (map-get? distributors { distributor-id: distributor-id })
        distributor-data (get active distributor-data)
        false
    )
)
