# Contributing to CamNexo

Thanks for helping. A few notes to keep things smooth.

## Before you start

- Open an issue to discuss larger changes first, so nobody builds something we cannot merge.
- Small fixes (typos, bugs, docs) can go straight to a pull request.

## Development

See "Build from source" in the [README](README.md). Before opening a pull request, run:

```powershell
cd core; cargo test
cd apps/mobile;  flutter analyze; flutter test
cd apps/desktop; flutter analyze; flutter test
```

## Pull requests

- Keep each pull request focused on one change.
- Match the surrounding code style and comment density.
- Add or update tests where it makes sense.
- Do not add dependencies that are not OSI-approved open source, or that need a paid license.
- Do not commit build output, keys, certificates or personal data.

## License

By contributing you agree that your contribution is licensed under the Apache License 2.0, the same
as the rest of the project (see [LICENSE](LICENSE)).
