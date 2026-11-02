package dev.opencu.android;

import android.content.ClipData;
import android.content.Context;
import android.os.IBinder;
import android.os.Process;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * Clipboard access for app_process through the IClipboard binder. The framework wrapper's read
 * path needs a provider that app_process cannot reach, so only the binder is used; without it the
 * clipboard is treated as unreadable.
 */
final class ShellClipboard {
  /** One clipboard read. A readable clipboard may be empty ({@code clip == null}). */
  static final class Snapshot {
    final boolean readable;
    final ClipData clip;
    final String problem;

    private Snapshot(boolean readable, ClipData clip, String problem) {
      this.readable = readable;
      this.clip = clip;
      this.problem = problem;
    }

    static Snapshot unreadable(String problem) {
      return new Snapshot(false, null, problem);
    }

    /** Whether this clip carries {@code label}. */
    boolean labelled(String label) {
      return clip != null
          && clip.getDescription() != null
          && label.contentEquals(clip.getDescription().getLabel());
    }
  }

  private final String callerPackage;
  private final Object service;
  private final Method getPrimaryClip;
  private final Method setPrimaryClip;
  private final Method clearPrimaryClip;

  ShellClipboard(Context context) {
    callerPackage = context.getOpPackageName();
    Object foundService = null;
    Method read = null, set = null, clear = null;
    try {
      IBinder binder =
          (IBinder)
              Class.forName("android.os.ServiceManager")
                  .getMethod("getService", String.class)
                  .invoke(null, "clipboard");
      foundService =
          Class.forName("android.content.IClipboard$Stub")
              .getMethod("asInterface", IBinder.class)
              .invoke(null, binder);
      Class<?> type = Class.forName("android.content.IClipboard");
      read = readMethod(type, "getPrimaryClip");
      set = writeMethod(type, "setPrimaryClip", ClipData.class);
      clear = writeMethod(type, "clearPrimaryClip");
    } catch (Exception ignored) {
      foundService = null;
    }
    service = foundService;
    getPrimaryClip = read;
    setPrimaryClip = set;
    clearPrimaryClip = clear;
  }

  /**
   * Reads the primary clip. A failed or refused call is unreadable, never empty. Android also
   * answers a silently denied read with an empty clip; that case cannot be told apart here.
   */
  Snapshot read() {
    if (service == null || getPrimaryClip == null || setPrimaryClip == null || clearPrimaryClip == null)
      return Snapshot.unreadable("clipboard service unavailable");
    Object value;
    try {
      value = getPrimaryClip.invoke(service, readArguments(getPrimaryClip));
    } catch (InvocationTargetException e) {
      return Snapshot.unreadable("read refused: " + e.getCause().getClass().getSimpleName());
    } catch (Exception e) {
      return Snapshot.unreadable("read failed: " + e.getClass().getSimpleName());
    }
    if (value != null && !(value instanceof ClipData))
      return Snapshot.unreadable("unexpected clipboard reply");
    return new Snapshot(true, (ClipData) value, "");
  }

  void setPrimaryClip(ClipData clip) {
    invokeWrite(setPrimaryClip, clip);
  }

  void clearPrimaryClip() {
    invokeWrite(clearPrimaryClip, null);
  }

  private void invokeWrite(Method method, ClipData clip) {
    if (service == null || method == null) throw new IllegalStateException("IClipboard unavailable");
    int userId = Process.myUid() / 100_000;
    try {
      if (method.getParameterTypes().length == 5)
        method.invoke(service, clip, callerPackage, null, userId, 0);
      else method.invoke(service, callerPackage, null, userId, 0);
    } catch (IllegalAccessException | InvocationTargetException e) {
      Throwable cause = e instanceof InvocationTargetException ? e.getCause() : e;
      throw new IllegalStateException("IClipboard write failed: " + cause.getClass().getSimpleName(), cause);
    }
  }

  private static Method readMethod(Class<?> type, String name) {
    Class<?> string = String.class;
    Class<?> integer = Integer.TYPE;
    for (Class<?>[] parameters :
        new Class<?>[][] {
          {string, string, integer, integer},
          {string, string, integer},
          {string, string, string, string, integer, integer, Boolean.TYPE}
        }) {
      try {
        Method method = type.getMethod(name, parameters);
        method.setAccessible(true);
        return method;
      } catch (NoSuchMethodException ignored) {
      }
    }
    return null;
  }

  private static Method writeMethod(Class<?> type, String name, Class<?>... prefix) {
    Class<?>[] parameters;
    if (prefix.length == 1)
      parameters = new Class<?>[] {prefix[0], String.class, String.class, Integer.TYPE, Integer.TYPE};
    else parameters = new Class<?>[] {String.class, String.class, Integer.TYPE, Integer.TYPE};
    try {
      Method method = type.getMethod(name, parameters);
      method.setAccessible(true);
      return method;
    } catch (NoSuchMethodException ignored) {
      return null;
    }
  }

  private Object[] readArguments(Method method) {
    int userId = Process.myUid() / 100_000;
    if (method.getParameterTypes().length == 7)
      return new Object[] {callerPackage, callerPackage, "", null, userId, 0, false};
    if (method.getParameterTypes().length == 4)
      return new Object[] {callerPackage, null, userId, 0};
    return new Object[] {callerPackage, null, userId};
  }
}
