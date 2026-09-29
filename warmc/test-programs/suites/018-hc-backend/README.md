# C / Cool semantic regressions

These are ordinary Warm tests, also selected by `test-programs/compare-hc.py` because
both successful stdout and expected runtime stderr are recorded.

- `001`: wrap at 8/16/32/64 bits, signed extension, bitwise/arithmetic grouping,
  and signed multiplication without overflow.
- `002`: a packed record with mixed-width fields, an independent argument copy,
  record return through a function pointer, Float64 arithmetic and conversion,
  conditional expressions and side-effecting short-circuit operands.
- `003`–`005`: unsigned 64-bit addition and signed 64-bit subtraction/multiplication
  overflow, including `INT64_MIN * -1`.
- `006`: allocation, typed pointer offsets, resize preserving old bytes,
  overlapping memory movement, and deallocation.

Run all six from the repository root:

```sh
python3 warmc/test-programs/compare-hc.py --filter 018-hc-backend
```
