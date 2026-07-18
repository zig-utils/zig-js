(module
  ;; A fixed-size shared memory keeps every engine on the same Threads proposal
  ;; surface without measuring growth or allocation. Word zero is the contended
  ;; counter; words 1..N are disjoint per-lane counters.
  (memory (export "memory") 1 1 shared)

  (func (export "clear") (param $lanes i32)
    (local $index i32)
    (i32.atomic.store (i32.const 0) (i32.const 0))
    (loop $next
      (i32.atomic.store
        (i32.shl
          (i32.add (local.get $index) (i32.const 1))
          (i32.const 2))
        (i32.const 0))
      (local.set $index (i32.add (local.get $index) (i32.const 1)))
      (br_if $next (i32.lt_u (local.get $index) (local.get $lanes))))
    (i32.atomic.store (i32.const 256) (i32.const 0)))

  (func (export "clear_lane") (param $lane i32)
    (i32.atomic.store
      (i32.shl
        (i32.add (local.get $lane) (i32.const 1))
        (i32.const 2))
      (i32.const 0)))

  (func (export "load_contended") (result i32)
    (i32.atomic.load (i32.const 0)))

  (func (export "load_lane") (param $lane i32) (result i32)
    (i32.atomic.load
      (i32.shl
        (i32.add (local.get $lane) (i32.const 1))
        (i32.const 2))))

  (func (export "load_errors") (result i32)
    (i32.atomic.load (i32.const 256)))

  (func (export "atomic_add") (param $count i32) (param $lane i32) (result i32)
    (local $index i32)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (drop (i32.atomic.rmw.add (i32.const 0) (i32.const 1)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.const 0))

  (func (export "atomic_cas") (param $count i32) (param $lane i32) (result i32)
    (local $index i32)
    (local $observed i32)
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $observed (i32.atomic.load (i32.const 0)))
        (br_if $next
          (i32.ne
            (i32.atomic.rmw.cmpxchg
              (i32.const 0)
              (local.get $observed)
              (i32.add (local.get $observed) (i32.const 1)))
            (local.get $observed)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.const 0))

  (func (export "atomic_disjoint") (param $count i32) (param $lane i32) (result i32)
    (local $index i32)
    (local $address i32)
    (local.set $address
      (i32.shl
        (i32.add (local.get $lane) (i32.const 1))
        (i32.const 2)))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (drop
          (i32.atomic.rmw.add
            (local.get $address)
            (i32.const 1)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.const 0))

  ;; Each waiter/notifier pair owns monotonic request and acknowledgement
  ;; counters. Unlike a binary flag, a delayed waiter cannot overwrite a
  ;; generation that its peer has not observed yet.
  (func (export "clear_pairs") (param $pairs i32)
    (local $index i32)
    (local $address i32)
    (loop $next
      (local.set $address
        (i32.add
          (i32.const 1024)
          (i32.shl (local.get $index) (i32.const 3))))
      (i32.atomic.store (local.get $address) (i32.const 0))
      (i32.atomic.store
        (i32.add (local.get $address) (i32.const 4))
        (i32.const 0))
      (local.set $index (i32.add (local.get $index) (i32.const 1)))
      (br_if $next (i32.lt_u (local.get $index) (local.get $pairs))))
    (i32.atomic.store (i32.const 256) (i32.const 0)))

  (func (export "verify_pairs") (param $count i32) (param $pairs i32) (result i32)
    (local $index i32)
    (local $address i32)
    (block $valid
      (loop $next
        (br_if $valid (i32.ge_u (local.get $index) (local.get $pairs)))
        (local.set $address
          (i32.add
            (i32.const 1024)
            (i32.shl (local.get $index) (i32.const 3))))
        (if
          (i32.or
            (i32.ne
              (i32.atomic.load (local.get $address))
              (local.get $count))
            (i32.ne
              (i32.atomic.load
                (i32.add (local.get $address) (i32.const 4)))
              (local.get $count)))
          (then (return (i32.const 0))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.const 1))

  (func (export "waiter") (param $count i32) (param $lane i32) (result i32)
    (local $index i32)
    (local $request i32)
    (local $ack i32)
    (local $target i32)
    (local $observed i32)
    (local $wait_result i32)
    (local.set $request
      (i32.add
        (i32.const 1024)
        (i32.shl
          (i32.shr_u (local.get $lane) (i32.const 1))
          (i32.const 3))))
    (local.set $ack (i32.add (local.get $request) (i32.const 4)))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $target
          (i32.add
            (i32.atomic.rmw.add (local.get $request) (i32.const 1))
            (i32.const 1)))
        (block $acked
          (loop $wait
            (local.set $observed (i32.atomic.load (local.get $ack)))
            (br_if $acked
              (i32.ge_u (local.get $observed) (local.get $target)))
            (local.set $wait_result
              (memory.atomic.wait32
                (local.get $ack)
                (local.get $observed)
                (i64.const 1000000000)))
            (if (i32.eq (local.get $wait_result) (i32.const 2))
              (then
                (drop
                  (i32.atomic.rmw.add
                    (i32.const 256)
                    (i32.const 1)))))
            (br $wait)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (local.get $count))

  (func (export "notifier") (param $count i32) (param $lane i32) (result i32)
    (local $index i32)
    (local $request i32)
    (local $ack i32)
    (local.set $request
      (i32.add
        (i32.const 1024)
        (i32.shl
          (i32.shr_u (local.get $lane) (i32.const 1))
          (i32.const 3))))
    (local.set $ack (i32.add (local.get $request) (i32.const 4)))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (br_if $next
          (i32.lt_u
            (i32.atomic.load (local.get $request))
            (i32.add (local.get $index) (i32.const 1))))
        (drop (i32.atomic.rmw.add (local.get $ack) (i32.const 1)))
        (drop
          (memory.atomic.notify
            (local.get $ack)
            (i32.const 1)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (local.get $count)))
