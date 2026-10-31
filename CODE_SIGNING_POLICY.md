# Code signing policy

**Status:** the Windows installer and programs of CamNexo are **not code-signed yet**. Windows and your
browser may warn that the publisher is unknown ("Windows protected your PC", "Suspicious download
blocked"). That is because the file has no known publisher and few people have downloaded it, not
because anything harmful was found. See the [support page](https://camnexo.yantrixlab.com/support.html)
for how to run it.

We applied to the [SignPath Foundation](https://signpath.org/) for free signing of open source projects.
The application was not approved for now, because the project does not yet have enough public
visibility. We plan to apply again, or to use another signing service, as the project grows.

## How to check a download

Windows releases are built from the source in this repository. The SHA-256 of each installer is
shown on <https://camnexo.yantrixlab.com> (under "Verify download"). To compare it on Windows:

```
certutil -hashfile CamNexo-Setup-0.3.0.exe SHA256
```

The two values must be identical. If they are not, do not run the file.

## Privacy

CamNexo does not send any information to other networked systems unless the user asks for it. The
phone app sends its camera video to the computer the user connects it to, and the apps do not send
data to Yantrix Labs. See the [privacy policy](https://camnexo.yantrixlab.com/privacy.html).
