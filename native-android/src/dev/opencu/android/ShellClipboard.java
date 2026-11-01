package dev.opencu.android;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.IBinder;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/** Clipboard access for app_process: reads use IClipboard when the framework wrapper needs a provider. */
final class ShellClipboard {
  private final String callerPackage;
  private final ClipboardManager manager;
  private final Object service;
  private final Method getPrimaryClip;
  private final Method getPrimaryClipDescription;
  private final Method hasPrimaryClip;
  private final Method setPrimaryClip;
  private final Method clearPrimaryClip;

  ShellClipboard(Context context) {
    callerPackage = context.getOpPackageName();
    ClipboardManager frameworkManager;
    try {
      java.lang.reflect.Constructor<ClipboardManager> constructor =
          ClipboardManager.class.getDeclaredConstructor(Context.class, Handler.class);
      constructor.setAccessible(true);
      frameworkManager =
          constructor.newInstance(context, new Handler(Looper.getMainLooper()));
    } catch (Exception ignored) {
      frameworkManager =
          (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
    }
    manager = frameworkManager;
    Object foundService = null;
    Method clip = null, description = null, has = null, set = null, clear = null;
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
      clip = readMethod(type, "getPrimaryClip");
      description = readMethod(type, "getPrimaryClipDescription");
      has = readMethod(type, "hasPrimaryClip");
      set = writeMethod(type, "setPrimaryClip", ClipData.class);
      clear = writeMethod(type, "clearPrimaryClip");
    } catch (Exception ignored) {
      foundService = null;
    }
    service = foundService;
    getPrimaryClip = clip;
    getPrimaryClipDescription = description;
    hasPrimaryClip = has;
    setPrimaryClip = set;
    clearPrimaryClip = clear;
  }

  ClipData getPrimaryClip() {
    if (service != null && getPrimaryClip != null) {
      Object value = call(getPrimaryClip);
      return value instanceof ClipData ? (ClipData) value : null;
    }
    Object value = call(getPrimaryClip);
    return value instanceof ClipData ? (ClipData) value : manager.getPrimaryClip();
  }

  ClipDescription getPrimaryClipDescription() {
    if (service != null && getPrimaryClipDescription != null) {
      Object value = call(getPrimaryClipDescription);
      return value instanceof ClipDescription ? (ClipDescription) value : null;
    }
    Object value = call(getPrimaryClipDescription);
    return value instanceof ClipDescription
        ? (ClipDescription) value
        : manager.getPrimaryClipDescription();
  }

  boolean hasPrimaryClip() {
    Object value = call(hasPrimaryClip);
    return value instanceof Boolean ? (Boolean) value : manager.hasPrimaryClip();
  }

  void setPrimaryClip(ClipData clip) {
    if (service != null && setPrimaryClip != null) {
      invokeWrite(setPrimaryClip, clip);
      return;
    }
    manager.setPrimaryClip(clip);
  }

  void clearPrimaryClip() {
    if (service != null && clearPrimaryClip != null) {
      invokeWrite(clearPrimaryClip, null);
      return;
    }
    manager.clearPrimaryClip();
  }

  private void invokeWrite(Method method, ClipData clip) {
    int userId = Process.myUid() / 100_000;
    try {
      if (method.getParameterTypes().length == 5)
        method.invoke(service, clip, callerPackage, null, userId, 0);
      else method.invoke(service, callerPackage, null, userId, 0);
    } catch (IllegalAccessException | InvocationTargetException e) {
      Throwable cause = e instanceof InvocationTargetException ? e.getCause() : e;
      throw new IllegalStateException("IClipboard write failed: " + cause, cause);
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

  private Object call(Method method) {
    if (service == null || method == null) return null;
    int userId = Process.myUid() / 100_000;
    Object[] args;
    if (method.getParameterTypes().length == 7)
      args = new Object[] {callerPackage, callerPackage, "", null, userId, 0, false};
    else if (method.getParameterTypes().length == 4)
      args = new Object[] {callerPackage, null, userId, 0};
    else args = new Object[] {callerPackage, null, userId};
    try {
      return method.invoke(service, args);
    } catch (IllegalAccessException | InvocationTargetException ignored) {
      return null;
    }
  }
}
