# Contributing to BeamCam

Bug reports, fixes and features are all welcome. Open an issue first for
anything large, so you do not spend a weekend on something I was about to
delete.

## Before you start

Read the invariants in the README. Most of them cost a day each to find:
the CMIO sink must be matched by name and never by direction, the extension
bundle must be named after its bundle id, `CFBundleVersion` must be bumped on
every extension change, and `showDialog` anywhere reachable from the macOS
build crashes the AOT compiler. Breaking one of those is a regression, not a
simplification.

Run these before opening a pull request:

```sh
flutter analyze && flutter test
flutter build macos --release   # also the showDialog tripwire
```

## Licensing of contributions

BeamCam is GPL-3.0, and it stays GPL-3.0. Everyone receives it under those
terms and nothing here changes that.

**By submitting a pull request, you agree that:**

1. You wrote the contribution, or have the right to submit it.
2. Your contribution is licensed to the public under **GPL-3.0**, the same as
   the rest of the project.
3. You additionally grant **Abdul Sahil**, as the project maintainer, a
   perpetual, worldwide, non-exclusive, royalty-free and irrevocable licence
   to use, reproduce, modify and **relicense** your contribution under any
   terms, including proprietary ones.

Point 3 is what a Contributor License Agreement normally does, kept to a
paragraph. It exists for one narrow reason: some distribution channels —
notably Apple's App Store — impose terms that GPL-3.0 forbids, so a GPL-only
codebase can never ship there. As sole copyright holder I can distribute my
own work under other terms for those channels. Without point 3, one merged
pull request would permanently remove that option for the whole project.

It does **not** let me close the source. The public licence is GPL-3.0, your
contribution is published under GPL-3.0, and any fork keeps every GPL-3.0
freedom. The grant is to the maintainer only, and is not extended to anyone
else by this document or by the licence.

If you are not comfortable with point 3, open an issue describing the change
instead of a pull request, and it can be implemented independently.
