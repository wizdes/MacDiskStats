# Review log

## Review rules, written before the first review

- Blocks at any rarity: data loss, security, spending, crashes, a test that cannot fail, or anything that lets the app change a file.
- Blocks if a user can reach it: wrong behavior in this change, or old code that breaks this change.
- Goes to follow-ups: style, and old code that does not affect this change.
- Reviewers report what they find. Root removes repeats and marks each finding by class, so the builder fixes every instance.
- After 3 rounds, root decides whether the approach is wrong and logs the choice. The limit never clears a blocking bug.
- Reviewer: Astra only, on the user's instruction to save Claude tokens (2026-11-04).

## Rounds

## Round 1 (Astra, 2026-11-04, on 516546e)

18 findings and 5 uncertain concerns. Root confirmed 1, 9 and 17 in the code; the fix builder verifies the rest.
