# Dialyzer warning filters.
#
# Each entry has an explanation so future-us can decide whether it is still
# load-bearing. `list_unused_filters: true` in mix.exs will flag dead entries.
#
# Format (from dialyxir): {file, warning_type} matches every warning of
# `warning_type` in `file`. More specific: {file, warning_type, line}.

[
  # Action-schema validators accept `term()` by design: they exist to
  # detect malformed user-supplied schemas. Dialyzer's success typing
  # converges on the well-formed shape because every error path raises,
  # but the contract intentionally documents that arbitrary input is
  # accepted. File-scoped (no line) because the whole validator family in
  # this file shares the rationale and line-pinned entries went stale on
  # every edit above them.
  {"lib/wymcp/tool.ex", :contract_supertype}
]
