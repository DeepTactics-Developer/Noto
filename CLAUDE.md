# Noto

iPad app (Swift, SwiftUI, PDFKit, PencilKit). Developed on Windows: there is no local Xcode.

- Xcode project is generated from `project.yml` by XcodeGen on CI. Do not commit `*.xcodeproj`.
- Verify code by pushing and reading the GitHub Actions run (`gh run watch`, `gh run view --log-failed`).
- Repo is `DeepTactics-Developer/Noto`. Other gh accounts are logged in, so scope the token per command:
  `GH_TOKEN=$(gh auth token -u DeepTactics-Developer)`. Do not run `gh auth switch`.
- Repo is public for now. Never commit secrets (certs, .p8/.p12, profiles, API keys); use GitHub Secrets. Keep planning notes out of the repo.
- Bundle ID `com.deeptactics.noto` is a placeholder until confirmed.
- Store strokes in page coordinates, not screen coordinates (all iPad sizes, both orientations).
