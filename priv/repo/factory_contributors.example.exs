# Copy to `factory_contributors.exs` (git-ignored — contains PII) and fill in
# the real contributor emails. Read by `mix replicant.backfill_factory`.
#
# - `contributors`: display_name (as it appears in each preset's content["author"])
#   -> the email that mints their frozen deterministic user id.
# - `system`: owns canonical/unauthored standard tunings.
# - `overrides`: preset slug (JSON filename without extension) -> contributor
#   display_name, for presets whose content["author"] is empty or wrong.
%{
  contributors: %{
    "Robert Rich" => %{email: "rr@example.invalid", display_name: "Robert Rich"},
    "Sevish" => %{email: "sean@example.invalid", display_name: "Sevish"}
  },
  system: %{email: "factory@example.invalid", display_name: "Entonal"},
  overrides: %{"7-limit-hexany" => "Sevish"}
}
