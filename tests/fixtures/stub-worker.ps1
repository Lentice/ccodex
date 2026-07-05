# tests/fixtures/stub-worker.ps1
#
# Intentionally does nothing: used only by SubmitCommand.tests.ps1 to force a
# deterministic startup-sentinel timeout (exit 23) without depending on a race
# against a real worker process actually starting. It is launched with the same
# `worker --job-id <id> --state-root <root> --codex-path <fixture>` argument
# shape a real detached worker would receive (all landing in the automatic
# $args array since this is a plain, param-less script), but it ignores them
# entirely and exits immediately without ever touching the job directory, so
# the job is left in its initial 'created' state for the sentinel to time out
# against.
exit 0
