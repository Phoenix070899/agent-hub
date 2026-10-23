# The usage footer lost the plan limits when claude /usage printed a cost summary

Found: 2026-10-17
Where: crates/hub/src/daemon.rs (refresh_usage, USAGE_ATTEMPTS, USAGE_RETRY)
Fixed in: 97792a5 Retry claude /usage reads that print no plan limits; keep the last good limits

The Hub App footer now and then showed "`claude -p /usage` printed no plan limits" instead of the limits.
Cause: `claude -p /usage` sometimes prints a cost summary with no plan limits, and one such read replaced the good limits with an error until the next refresh five minutes later.
Fix: each refresh tries up to three times, keeps the last good limits on screen when all fail, and retries after one minute instead of five; the fake agent fails the first read in a test.
Lesson: treat output scraped from another CLI as flaky; retry, keep the last good value, and test the bad output with the fake agent.
