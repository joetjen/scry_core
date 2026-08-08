[
  # Scry.Core.TypeCheck's own flow-sensitive null-safety narrowing
  # threads a `proven`-fields MapSet.t() accumulator through several
  # private helpers, with @specs naming MapSet.t() explicitly. This
  # toolchain (Elixir 1.19.4 / OTP 28, this project's own dialyxir/PLT
  # setup) reports a MapSet opacity violation for that -- confirmed a
  # genuine toolchain false positive, not specific to this module's own
  # logic: a from-scratch throwaway module doing nothing but
  # `MapSet.new/0,1` + `MapSet.union/2` behind an equivalent `@spec`
  # reproduces the identical `contract_with_opaque`/`call_without_opaque`
  # warnings. Tracked here rather than "fixed" by removing the specs,
  # since the specs themselves are correct and valuable documentation of
  # a real invariant (`proven` is always a set of already-guarded field
  # names).
  {"lib/scry/core/type_check.ex", :contract_with_opaque},
  {"lib/scry/core/type_check.ex", :call_without_opaque}
]
