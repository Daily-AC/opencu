package android.content;

import android.os.IBinder;

/** Host stand-in for the hidden IClipboard binder interface (Android 14 signatures used here). */
public interface IClipboard {
  ClipData getPrimaryClip(String callingPackage, String attributionTag, int userId, int deviceId);

  void setPrimaryClip(ClipData clip, String callingPackage, String attributionTag, int userId, int deviceId);

  void clearPrimaryClip(String callingPackage, String attributionTag, int userId, int deviceId);

  /** Hands out the binder a check installs. */
  final class Stub {
    public static volatile IClipboard installed;

    public static IClipboard asInterface(IBinder binder) {
      return installed;
    }
  }
}
