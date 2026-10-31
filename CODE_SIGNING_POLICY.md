# Code signing policy

Windows releases of CamNexo are built from the source in this repository by a public GitHub Actions
workflow, and are meant to be signed with a certificate provided by the
[SignPath Foundation](https://signpath.org/) through [SignPath.io](https://about.signpath.io/).

**Status:** the application to the SignPath Foundation is pending. Until it is approved, installers are
not code-signed, and Windows and your browser may warn that the publisher is unknown. You can verify
a download with the SHA-256 shown on <https://camnexo.yantrixlab.com>.

## Roles

- **Committers and reviewers:** the maintainers of this repository.
- **Approvers:** the owners of the `yantrixlab` GitHub organization. Every release signing request is
  approved by an owner before the file is signed.

## What is signed

Only binaries built from this repository by the release workflow: the CamNexo desktop app, its helper
programs, and the installer. Third-party files that are already signed by their publishers are not re-signed.

## Privacy

CamNexo does not send any information to other networked systems unless the user asks for it. The
phone app sends its camera video to the computer the user connects it to, and the apps do not send
data to Yantrix Labs. See the [privacy policy](https://camnexo.yantrixlab.com/privacy.html).
