# Contributing to Aki

Thanks for wanting to help. Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — a one-page map of how Aki is built. A few rules keep things calm:

- **How:** people the maintainer adds as collaborators branch straight in this repository (`yourname/topic`); everyone else forks it. Either way, the change comes in as a pull request to `main`, and the maintainer decides what goes in.

- **Branch from `main`, open the pull request to `main`.** Nothing reaches people using Aki until the next release; releases are tags (`vX.Y.Z`) cut by the maintainer.
- **One topic per pull request**, small enough to review in one sitting. Say what it changes and how you tried it (a screenshot or short video for anything visible).
- **Commits:** `feat: …`, `fix: …`, `perf: …`, `docs: …`, `chore: …` — the release notes are built from them.
- **Before opening it:** `swift build`, `swift run AkiChecks` and `python3 scripts/check-translations.py` pass (CI runs the same on every pull request), and you ran the app (`scripts/install.sh`) and tried what you changed.
- **Anything people will notice** gets a line in `CHANGELOG.md` under *Unreleased*.
- **Code style:** match the code around it — names, comment density, Swift 6 (the `Aki` target is in Swift 5 mode). No formatter runs over the repo.
- **Texts in the app** go through `L10n.t("English text")` and need the eight translations (Português, Español, Français, Deutsch, 日本語, 中文, 한국어, Italiano), one table per language in `Sources/Aki/Localization/`. A repeated key crashes the app — `scripts/check-translations.py` catches it.
- **Code from other projects** only with a compatible license (MIT, BSD, Apache-2.0), and its notice goes in `THIRD_PARTY_NOTICES`. Never from Vibe Annotations after commit 8864e12c (PolyForm Shield) or from GPL/AGPL projects.
- **Never** commit keys, tokens or certificates.

## License of contributions

Aki is under the [Functional Source License](LICENSE) (FSL-1.1-ALv2): you may use, read, change and share it for anything except a product that competes with Aki; each version becomes Apache-2.0 two years after it's released.

By opening a pull request you agree that your contribution is licensed under the same terms, and that the maintainer may relicense it along with the rest of Aki in the future. You keep the credit (the commit history), and you confirm the code is yours to give.

Questions or ideas: open an issue (there are templates). Security problems: privately, see [SECURITY.md](SECURITY.md).
