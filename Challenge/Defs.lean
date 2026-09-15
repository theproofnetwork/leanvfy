/-- The definition the statement is about. A solution may import this module
(through a `require` of this repository at this commit) or restate it; the
exported kernel term must be identical either way. -/
def Challenge.f (n : Nat) : Nat := 42 + n
