// The Android SDK pieces and javac arguments the engine and fixture builds use. Tests take the
// javac arguments from here too, so they check exactly what the build does.
import os from 'node:os';
import path from 'node:path';

export const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT ?? path.join(os.homedir(), 'Library/Android/sdk');
export const buildTools = path.join(sdk, 'build-tools', process.env.OPENCU_ANDROID_BUILD_TOOLS ?? '36.1.0');
export const androidJar = path.join(sdk, 'platforms/android-34/android.jar');
export const lambdaStubs = path.join(buildTools, 'core-lambda-stubs.jar');

// Compile against Android's own classes, java.* included: android.jar is the boot class path, so
// a JDK API that Android lacks fails the build instead of the phone. core-lambda-stubs.jar (from
// build-tools, as the Android Gradle plugin uses it) only lets javac emit lambdas, which d8
// desugars. JDK 21 accepts a custom boot class path only at language level 8.
export const javacAndroidArgs = [
  '-source', '8', '-target', '8', '-Xlint:-options',
  '-bootclasspath', [androidJar, lambdaStubs].join(path.delimiter),
  '-extdirs', '', '-encoding', 'UTF-8',
];
