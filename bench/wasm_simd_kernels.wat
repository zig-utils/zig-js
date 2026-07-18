(module
  (memory 1)

  (func (export "integer_simd") (param $count i32) (result i32)
    (local $index i32)
    (local $value v128)
    (local.set $value (v128.const i32x4 1 2 3 4))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $value
          (i32x4.mul
            (i32x4.add
              (local.get $value)
              (i32x4.splat (local.get $index)))
            (i32x4.splat (i32.const 3))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.add
      (i32.add
        (i32x4.extract_lane 0 (local.get $value))
        (i32x4.extract_lane 1 (local.get $value)))
      (i32.add
        (i32x4.extract_lane 2 (local.get $value))
        (i32x4.extract_lane 3 (local.get $value)))))

  (func (export "integer_scalar") (param $count i32) (result i32)
    (local $index i32)
    (local $a i32) (local $b i32) (local $c i32) (local $d i32)
    (local.set $a (i32.const 1))
    (local.set $b (i32.const 2))
    (local.set $c (i32.const 3))
    (local.set $d (i32.const 4))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $a (i32.mul (i32.add (local.get $a) (local.get $index)) (i32.const 3)))
        (local.set $b (i32.mul (i32.add (local.get $b) (local.get $index)) (i32.const 3)))
        (local.set $c (i32.mul (i32.add (local.get $c) (local.get $index)) (i32.const 3)))
        (local.set $d (i32.mul (i32.add (local.get $d) (local.get $index)) (i32.const 3)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.add
      (i32.add (local.get $a) (local.get $b))
      (i32.add (local.get $c) (local.get $d))))

  (func (export "float_simd") (param $count i32) (result i32)
    (local $index i32)
    (local $value v128)
    (local.set $value (v128.const f32x4 1 2 3 4))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $value
          (f32x4.mul
            (f32x4.add (local.get $value) (f32x4.splat (f32.const 0.25)))
            (f32x4.splat (f32.const 0.99975))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.add
      (i32.add
        (i32.trunc_sat_f32_s (f32x4.extract_lane 0 (local.get $value)))
        (i32.trunc_sat_f32_s (f32x4.extract_lane 1 (local.get $value))))
      (i32.add
        (i32.trunc_sat_f32_s (f32x4.extract_lane 2 (local.get $value)))
        (i32.trunc_sat_f32_s (f32x4.extract_lane 3 (local.get $value))))))

  (func (export "float_scalar") (param $count i32) (result i32)
    (local $index i32)
    (local $a f32) (local $b f32) (local $c f32) (local $d f32)
    (local.set $a (f32.const 1))
    (local.set $b (f32.const 2))
    (local.set $c (f32.const 3))
    (local.set $d (f32.const 4))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $a (f32.mul (f32.add (local.get $a) (f32.const 0.25)) (f32.const 0.99975)))
        (local.set $b (f32.mul (f32.add (local.get $b) (f32.const 0.25)) (f32.const 0.99975)))
        (local.set $c (f32.mul (f32.add (local.get $c) (f32.const 0.25)) (f32.const 0.99975)))
        (local.set $d (f32.mul (f32.add (local.get $d) (f32.const 0.25)) (f32.const 0.99975)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.add
      (i32.add (i32.trunc_sat_f32_s (local.get $a)) (i32.trunc_sat_f32_s (local.get $b)))
      (i32.add (i32.trunc_sat_f32_s (local.get $c)) (i32.trunc_sat_f32_s (local.get $d)))))

  (func (export "shuffle_simd") (param $count i32) (result i32)
    (local $index i32)
    (local $value v128)
    (local.set $value (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $value
          (i8x16.add
            (i8x16.shuffle 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 0
              (local.get $value) (local.get $value))
            (i8x16.splat (local.get $index))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.add
      (i32.add
        (i32.add
          (i32.add (i8x16.extract_lane_u 0 (local.get $value)) (i8x16.extract_lane_u 1 (local.get $value)))
          (i32.add (i8x16.extract_lane_u 2 (local.get $value)) (i8x16.extract_lane_u 3 (local.get $value))))
        (i32.add
          (i32.add (i8x16.extract_lane_u 4 (local.get $value)) (i8x16.extract_lane_u 5 (local.get $value)))
          (i32.add (i8x16.extract_lane_u 6 (local.get $value)) (i8x16.extract_lane_u 7 (local.get $value)))))
      (i32.add
        (i32.add
          (i32.add (i8x16.extract_lane_u 8 (local.get $value)) (i8x16.extract_lane_u 9 (local.get $value)))
          (i32.add (i8x16.extract_lane_u 10 (local.get $value)) (i8x16.extract_lane_u 11 (local.get $value))))
        (i32.add
          (i32.add (i8x16.extract_lane_u 12 (local.get $value)) (i8x16.extract_lane_u 13 (local.get $value)))
          (i32.add (i8x16.extract_lane_u 14 (local.get $value)) (i8x16.extract_lane_u 15 (local.get $value)))))))

  (func (export "shuffle_scalar") (param $count i32) (result i32)
    (local $index i32) (local $lane i32) (local $first i32) (local $sum i32)
    (loop $initialize
      (i32.store8 (local.get $lane) (local.get $lane))
      (local.set $lane (i32.add (local.get $lane) (i32.const 1)))
      (br_if $initialize (i32.lt_u (local.get $lane) (i32.const 16))))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (local.set $first (i32.load8_u (i32.const 0)))
        (local.set $lane (i32.const 0))
        (loop $rotate
          (i32.store8
            (local.get $lane)
            (i32.load8_u (i32.add (local.get $lane) (i32.const 1))))
          (local.set $lane (i32.add (local.get $lane) (i32.const 1)))
          (br_if $rotate (i32.lt_u (local.get $lane) (i32.const 15))))
        (i32.store8 (i32.const 15) (local.get $first))
        (local.set $lane (i32.const 0))
        (loop $add
          (i32.store8
            (local.get $lane)
            (i32.add (i32.load8_u (local.get $lane)) (local.get $index)))
          (local.set $lane (i32.add (local.get $lane) (i32.const 1)))
          (br_if $add (i32.lt_u (local.get $lane) (i32.const 16))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (local.set $lane (i32.const 0))
    (loop $total
      (local.set $sum (i32.add (local.get $sum) (i32.load8_u (local.get $lane))))
      (local.set $lane (i32.add (local.get $lane) (i32.const 1)))
      (br_if $total (i32.lt_u (local.get $lane) (i32.const 16))))
    (local.get $sum))

  (func (export "memory_simd") (param $count i32) (result i32)
    (local $index i32) (local $value v128)
    (v128.store (i32.const 32) (v128.const i32x4 1 2 3 4))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (v128.store
          (i32.const 32)
          (i32x4.add
            (v128.load (i32.const 32))
            (i32x4.splat (local.get $index))))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (local.set $value (v128.load (i32.const 32)))
    (i32.add
      (i32.add (i32x4.extract_lane 0 (local.get $value)) (i32x4.extract_lane 1 (local.get $value)))
      (i32.add (i32x4.extract_lane 2 (local.get $value)) (i32x4.extract_lane 3 (local.get $value)))))

  (func (export "memory_scalar") (param $count i32) (result i32)
    (local $index i32)
    (i32.store (i32.const 32) (i32.const 1))
    (i32.store (i32.const 36) (i32.const 2))
    (i32.store (i32.const 40) (i32.const 3))
    (i32.store (i32.const 44) (i32.const 4))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $index) (local.get $count)))
        (i32.store (i32.const 32) (i32.add (i32.load (i32.const 32)) (local.get $index)))
        (i32.store (i32.const 36) (i32.add (i32.load (i32.const 36)) (local.get $index)))
        (i32.store (i32.const 40) (i32.add (i32.load (i32.const 40)) (local.get $index)))
        (i32.store (i32.const 44) (i32.add (i32.load (i32.const 44)) (local.get $index)))
        (local.set $index (i32.add (local.get $index) (i32.const 1)))
        (br $next)))
    (i32.add
      (i32.add (i32.load (i32.const 32)) (i32.load (i32.const 36)))
      (i32.add (i32.load (i32.const 40)) (i32.load (i32.const 44)))))
)
