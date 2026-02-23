Run the full pre-merge checklist for the current branch. For each item, report PASS or FAIL with details.

## Build checks

1. Run `mix compile --warnings-as-errors` — report any warnings or errors
2. Run `mix test` — report pass/fail count
3. Run `mix format --check-formatted` — report any unformatted files
4. Run `cd apps/rlm && mix docs` — verify ExDoc builds cleanly

## Documentation checks

5. Read `CLAUDE.md` and check the **Module Map** tables — are there any new modules in `apps/rlm/lib/rlm/` or `apps/rlm_web/lib/rlm_web_web/` that are missing from the map? List them.
6. Read `CLAUDE.md` and check the **Config Fields** table — are there any new fields in `RLM.Config` that are missing? List them.
7. Read `CHANGELOG.md` — does the `[Unreleased]` section have entries covering the work on this branch? Compare against `git log --oneline origin/main..HEAD` to check.
8. Check if the public API (`RLM.run/3`, `RLM.start_session/1`, `RLM.send_message/3`) changed — if so, does `README.md` reflect the changes?

## Summary

Report a table of all 8 checks with PASS/FAIL status. For any FAILs, describe what needs to be fixed.
