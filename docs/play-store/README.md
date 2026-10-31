# Publishing CamNexo on Google Play

Everything to copy into Play Console. The signed bundle is `release/CamNexo-1.0.0+3-release.aab`
(package `com.camnexo.webcam`, signed with the `upload` key). Rebuild it with
`cd apps/mobile && flutter build appbundle --release`; raise the build number in `apps/mobile/pubspec.yaml`
(`version: 1.0.0+N`) for every new upload, because Play rejects a build number it has already seen.

## 1. Account (one time)

- Create a Play Console developer account at <https://play.google.com/console> (one-time registration fee,
  identity verification with a government ID; organization accounts also need a D-U-N-S number).
- A **personal** account created recently has to run a **closed test** first (Google has required a
  minimum number of testers, opted in for a minimum number of days, before production can be requested).
  Check the current numbers in Play Console under Testing, Closed testing. Organization accounts are exempt.

## 2. Create the app

- App name: **CamNexo: Phone as PC Webcam** (27 of 30 characters)
- Default language: English (United States)
- App or game: **App**. Free or paid: **Free** (pricing can be added later).
- Declarations: follow the Developer Program Policies and US export laws.

## 3. Store listing

**Short description** (76 of 80):

> Use your phone as a wireless HD webcam for PC. Works with Zoom, Meet, Teams.

**Full description** (copy as is):

```
Turn your phone into a sharp, wireless webcam for your computer.

CamNexo sends your phone's camera to your PC over your own Wi-Fi. On the PC it shows up as a normal camera called CamNexo, so Zoom, Google Meet, Microsoft Teams, OBS, Discord and your browser can use it. No account, no cloud and no ads.

HOW IT WORKS
1. Install the free CamNexo desktop app on your Windows 11 PC (camnexo.yantrixlab.com).
2. Open this app on your phone, on the same Wi-Fi.
3. Tap your computer in the "Computers nearby" list. Next time it connects by itself.
4. Pick "CamNexo" as the camera in your video app.

FEATURES
- Finds your computer automatically and reconnects when you come back
- Sizes from 360p up to 4K, as far as your phone's camera and encoder go. Choose from the PC, change it live, or leave it on Auto
- Keeps streaming when you switch to another app, with a notification and a Stop button
- Switch between the front and back camera while you stream
- Torch and zoom controls
- Connect several phones to one PC and arrange them in layouts (desktop app)
- Blur or replace your background and apply colour looks on the PC, so every app gets them
- Portrait and landscape layouts for the phone app
- Hardware video encoding keeps the phone cool and the picture smooth

PRIVACY
Your video goes straight from your phone to your computer across your own network. It is not sent to us or to any server, and CamNexo has no account, ads or analytics. The connection is not encrypted yet, so use it on a network you trust, such as your home or office Wi-Fi. Camera access is used only while you stream, and a notification shows when it is on.

YOU NEED
- A Windows 11 PC with the free CamNexo desktop app (macOS and Linux are planned)
- Your phone and PC on the same Wi-Fi network

CamNexo is open source (Apache-2.0): github.com/yantrixlab/CamNexo
Help: camnexo.yantrixlab.com/support.html
```

- App icon: `graphics/app-icon-512.png` (512 x 512)
- Feature graphic: `graphics/feature-graphic-1024x500.png`
- **Phone screenshots (2 to 8, you take these):** use real screenshots from your phone so they match the app exactly:
  1. the main screen with the camera preview and "Computers nearby"
  2. the streaming screen (green rings with size, rate and speed)
  3. the landscape view of the streaming screen
  4. (optional) the notification with the Stop button, with the app in the background
  Take them with the power and volume-down buttons, or `adb exec-out screencap -p > shot.png`. Do not show other people's faces or private messages.
- Category: **Tools**. Tags: webcam, camera, video calls.
- Contact email: yantrixlab@gmail.com. Website: https://camnexo.yantrixlab.com
- **Privacy policy URL: https://camnexo.yantrixlab.com/privacy.html**

## 4. App content (Policy section)

| Form | Answer |
|---|---|
| Privacy policy | https://camnexo.yantrixlab.com/privacy.html |
| Ads | No ads |
| App access | All functionality is available without login |
| Content rating (IARC questionnaire) | Category "Utility, productivity, communication or other". Answer No to violence, sexual content, language, drugs, gambling and user-generated content. Expected rating: Everyone |
| Target audience | 18 and over, or 13 and over. Not designed for children, so choose no age group under 13 |
| News app | No |
| Government app | No |
| Financial features | None |
| Health | None |

### Data safety form

Google asks what data leaves the device. CamNexo sends nothing to the developer or to a third party;
video goes only to the computer the user chooses, on the local network. Answers I suggest (check the
wording of each question against what the form says on the day):

- Does your app collect or share any of the required user data types? **No**, because nothing is sent to us or to any other company. If the form treats the transfer to the user's own computer as "collected", declare **Photos and videos** under *App functionality*, *not shared*, *processed ephemerally*, *collection is required*.
- Is all of the user data encrypted in transit? **No** (the local stream is not encrypted yet). Answer honestly; update it when pairing and encryption ship.
- Do you provide a way for users to request that their data is deleted? Not applicable (no data is stored by us).

### Permissions declarations

- **Camera**: captures the picture that is sent to the user's computer.
- **Foreground service (camera type)**: required to keep streaming while the user switches to other apps. Play asks for a short video showing it. Record 20 to 30 seconds on your phone: open CamNexo, connect to your PC, start streaming, press Home, open another app, pull down the notification shade to show "CamNexo is streaming" with its Stop button, and show the picture still moving on the PC. Upload it as an unlisted YouTube video and paste the link.
- **Notifications**: shows the streaming notification and its Stop button.
- Other normal permissions (internet, network state, Wi-Fi state, multicast, wake lock) need no declaration.

## 5. Release

1. Testing, Closed testing (or Internal testing first, to try the install quickly): create a release, upload `release/CamNexo-1.0.0+3-release.aab`.
2. **Play App Signing**: accept it when asked. Google keeps the app signing key; your `upload` key only proves the upload is yours.
3. Release notes (500 characters or less):

```
First release. Use your phone as a wireless webcam for your Windows PC: automatic discovery, 360p to 4K, front and back camera, keeps streaming in the background. Install the free desktop app from camnexo.yantrixlab.com.
```

4. Testers: add the emails of your testers as an email list, share the opt-in link, and have them install from Play.
5. When the test requirements are met, apply for production, then roll out (start with a staged rollout of 20 percent).

## 6. After publishing

- Put the Play Store link in `web/assets/config.js` (`downloads.android.url`) and in the README, then redeploy the site.
- Keep the upload key and `key.properties` backed up outside the project.
- Each new version: raise the build number in `pubspec.yaml`, rebuild the bundle, upload, add release notes.
