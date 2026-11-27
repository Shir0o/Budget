# Google Drive sign-in setup

Encrypted sync (ticket 12) reaches Google Drive's hidden app folder through each device's own Google sign-in. The repo holds no OAuth client ids or secrets: you make the clients once in your own Google Cloud project, and the builds pick them up.

| Device | How it signs in | What the build needs |
| --- | --- | --- |
| Android | Google Play services' Authorization API: Google's own account sheet | Nothing. Google recognizes the app by its package name and signing certificate. |
| Mac | Google's page in your browser, back to the app on `127.0.0.1` (OAuth for desktop apps, with PKCE) | `GOOGLE_DESKTOP_CLIENT_ID` and `GOOGLE_DESKTOP_CLIENT_SECRET` at build time |

Both ask for one scope, `https://www.googleapis.com/auth/drive.appdata`, so the app can't see your other Drive files. A build without a client shows "Google sign-in isn't set up in this build" on the Encrypted sync screen instead of failing.

## 1. The Google Cloud project

1. In the [Google Cloud console](https://console.cloud.google.com/), make a project (or pick the one you'll use for the cloud MCP server: both must be the same project, because each project gets its own hidden app folder).
2. *APIs & Services › Library*: enable the **Google Drive API**.
3. *Google Auth Platform › Branding*: app name "Budget" and your email.
4. *Data access*: add the scope `.../auth/drive.appdata`.
5. *Audience*: External. Either add your Google account as a test user, or press *Publish app*. While the app is in *Testing*, Google expires the Mac's sign-in after 7 days. A published app that only you use shows an "unverified app" warning when you sign in; that's expected.

## 2. Android

*Clients › Create client › Android*, package name `io.github.shir0o.budget`, and the SHA-1 of a signing certificate. Make one Android client for each certificate you install from:

- **Play internal testing:** Play Console › *Test and release › App integrity › App signing*, the SHA-1 of the **app signing key**.
- **The APK on the GitHub release:** the SHA-1 of the upload key that CI signs with:
  ```sh
  keytool -list -v -keystore upload-key.keystore -alias <KEY_ALIAS>
  ```
- **`flutter run` on your phone:** the debug key:
  ```sh
  keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
  ```

Nothing goes in the repo or the build.

## 3. Mac

1. *Clients › Create client › Desktop app*. Copy its client id and client secret. Google doesn't treat a desktop client's secret as secret (anyone can read it out of the app); PKCE protects the sign-in. It still stays out of the repo.
2. For release builds, in the GitHub repo's *Settings › Secrets and variables › Actions*, add the **variable** `GOOGLE_DESKTOP_CLIENT_ID` and the **secret** `GOOGLE_DESKTOP_CLIENT_SECRET`. `release.yml` passes both to `flutter build macos`.
3. For a local build:
   ```sh
   flutter run -d macos \
     --dart-define=GOOGLE_DESKTOP_CLIENT_ID=<client id> \
     --dart-define=GOOGLE_DESKTOP_CLIENT_SECRET=<client secret>
   ```

## 4. Connect the devices

1. On each device, *Settings › Encrypted sync › Connect Google Drive*, with the **same** Google account.
2. On the device with the budget, *Turn on sync*, then *Pair a device*.
3. On the other device, *Join a device's budget* and paste the code.

*Use another account* forgets the sign-in on that device. To remove the app from your Google account altogether, use [myaccount.google.com/permissions](https://myaccount.google.com/permissions).
