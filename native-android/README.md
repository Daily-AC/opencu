# Android main-display engine

Plain Java, no Gradle or Kotlin. The engine jar needs Android 14 / API 34+ and
**shell uid 2000**. The fixture suite has passed on the OPPO PGBM10 / API 34; other devices and
Android versions remain untested. See the committed acceptance evidence.

On this Mac:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME="$HOME/Library/Android/sdk"
npm run build:android
npm run test:android
bin/opencu android --serial SERIAL doctor
bin/opencu android --serial SERIAL
```

Build prerequisites: JDK 21, Android platform `android-34`, build-tools `36.1.0`,
platform-tools, and Node 22+. `OPENCU_ANDROID_BUILD_TOOLS` selects an installed
build-tools version. d8 34.0.0 crashed on the JDK 21 fixture anonymous class; the
installed 36.1.0 toolchain builds it. The script downloads nothing.

Outputs, all ignored:

- `.build/android/opencu-android.jar`: dex jar, entry `dev.opencu.android.Main`.
- `.build/android/opencu-fixture.apk`: disposable debuggable fixture.
- `.build/android/fixture-debug.keystore`: throwaway key generated locally.

The fixture is a separate test APK; the engine itself installs no app or service.
The key's `android` password is public test infrastructure, not a credential.

`npm run test:android` needs only the JDK and Node. It compiles the same production
JSON, framing, schema, observation, wait and physical-event logic on the host JVM.
Cases include the recorded PGBM10 fixture tree, an attributed AOSP two-finger
event sample, and clearly labelled synthetic stop-gesture/state edge cases. The
physical triple-volume-down gesture remains an owner test.

```sh
node scripts/verify-android.mjs --serial SERIAL
# Only if you deliberately want the disposable app to remain:
node scripts/verify-android.mjs --serial SERIAL --keep
```

The phone verifier requires the owner-authorized, unlocked PGBM10 with launcher
or fixture in front. OEM install confirmation is a manual step; a failed install
is never retried. It runs three rounds, checks `run-as` truth, samples each timing
ten times, and writes a fixture-only evidence JSON. It never approves an OEM
prompt, pairs, resets adb, changes keyboard/settings, or wakes/unlocks the phone.
The explicitly requested injected-volume test restores the original media volume.

See [Android behavior](../docs/android.md) for tools, safety and remaining limits.
