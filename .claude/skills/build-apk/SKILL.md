---
name: build-apk
description: Build the TVM Flutter app into an APK using GitHub Actions and fetch the download link. Use when asked to build, release, publish or rebuild the TVM APK, or when a build fails.
---

# Build the TVM APK (GitHub Actions)

The sandbox has no Flutter SDK and no network for package installs, so the APK is always built in the cloud by `.github/workflows/build-apk.yml` (repo `al9yser/tvm`, public).

## Output requirement (from the user)

Deliver a single universal **APK** that works on both **phones and TV screens**. The user's chosen format is always APK. Keep these true for every app built from this template:
- Manifest declares both `LAUNCHER` and `LEANBACK_LAUNCHER`, plus `android:banner` and a PNG launcher icon (so the icon shows on the TV home).
- `touchscreen` and `leanback` features are `required="false"`.
- UI is responsive (side rail on wide screens, bottom bar on phones) and every control is reachable with a TV remote (focusable, visible focus border).

## Steps

1. Make code changes in a clone of `al9yser/tvm` (Flutter project is at the repo root; Dart code is `lib/main.dart`).
2. Commit and push to `main`. Every push to `main` starts the "Build APK" workflow (about 6-9 min). Use `[skip ci]` in the commit message for docs-only changes.
3. Poll the result without authentication (the `GH_TOKEN` in the sandbox is invalid, so `gh` does not work, but the public REST API does):
   ```bash
   curl -sS https://api.github.com/repos/al9yser/tvm/actions/runs | python3 -I -c "
   import json,sys
   r=json.load(sys.stdin)['workflow_runs'][0]; print(r['run_number'], r['status'], r['conclusion'], r['id'])"
   ```
   Repeat every ~20 s until `status` is `completed`.
4. On success, the APK is published as a release asset:
   ```bash
   curl -sS https://api.github.com/repos/al9yser/tvm/releases | python3 -I -c "
   import json,sys
   r=json.load(sys.stdin)[0]; print(r['tag_name'], [a['browser_download_url'] for a in r['assets']])"
   ```
   Link format: `https://github.com/al9yser/tvm/releases/download/apk-<run_number>/TVM.apk`. Give this link to the user.
5. On failure, find the failed step and read the log:
   ```bash
   curl -sS https://api.github.com/repos/al9yser/tvm/actions/runs/<RUN_ID>/jobs   # failed step name + job id
   curl -sSL https://api.github.com/repos/al9yser/tvm/actions/jobs/<JOB_ID>/logs > job.log
   grep -n -E "error •|error:|Error:|What went wrong|Because|e: " job.log
   ```
   Fix the cause, push again, poll again.

## Known build requirements (already fixed in the repo)

- Gradle wrapper `8.14.3` (`android/gradle/wrapper/gradle-wrapper.properties`)
- Android Gradle Plugin `8.11.1` and Kotlin `2.2.20` (`android/settings.gradle.kts`)
- `video_player: ^2.11.1` (needed for `getAudioTracks` / `selectAudioTrack`)
- CI uses Java 17 and Flutter stable via `subosito/flutter-action`.
- The release is signed with the debug key: fine for sideloading on TV/phone, not for the Play Store.

## Pitfalls

- Never write a file with `open(p,'w').write(open(p).read()...)` — it truncates the file first. Read into a variable, then write. (This once emptied `pubspec.yaml` and broke the build with "no lower-bound SDK constraint".)
- Do not put the user's email in `git -c user.email=...`; use `al9yser@users.noreply.github.com`.
- Remind the user to uninstall the old APK before installing a new one on the TV, otherwise the launcher may keep the old icon.
- The app was never run in the sandbox; always ask the user to test on the device (icon on the TV home, auto-login after restart, remote navigation, player controls).
