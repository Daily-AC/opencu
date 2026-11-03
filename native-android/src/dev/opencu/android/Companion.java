package dev.opencu.android;

import static dev.opencu.android.Json.*;

import android.content.AttributionSource;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.UserHandle;
import android.view.Surface;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * The optional OpenCU companion app: a status island, a read-only live view of the agent display
 * and a Stop button on the phone. The engine still never listens. Once per connection it looks for
 * the app and, only when it is installed with the signing certificate this build pins, calls the
 * app's provider to hand it a Binder; status then goes to the app one way. Through that Binder the
 * app can only attach or detach a preview surface while the agent display runs, and stop the
 * connection as the person. Without the app nothing changes.
 */
final class Companion {
  static final String PACKAGE = "dev.opencu.companion";
  static final String AUTHORITY = PACKAGE + ".engine";
  /** Interface tokens: calls into the engine, and status calls into the app. */
  static final String ENGINE = "dev.opencu.companion.Engine", PEER = "dev.opencu.companion.Peer";
  /** App to engine: attach (a surface) or detach (none) the preview; the person's stop. */
  static final int PREVIEW = IBinder.FIRST_CALL_TRANSACTION, STOP = IBinder.FIRST_CALL_TRANSACTION + 1;
  /** Engine to app, one way: a status JSON object. */
  static final int STATUS = IBinder.FIRST_CALL_TRANSACTION;

  interface Host {
    /** The agent display's id, or -1 while the engine works on the main display. */
    int agentDisplay();

    /** The person pressed Stop in the app. */
    void personStop();

    /** Whether the person stopped this connection, by any means. */
    boolean stopped();
  }

  private final Context context;
  private final Host host;
  private final String pin;
  /** Why the app is or is not attached, for doctor. */
  private volatile String state = "not checked";
  /** The verified app's uid, or -1; every call into the engine must come from it. */
  private volatile int uid = -1;
  private IBinder peer;
  private Map<String, Object> last = obj("state", "waiting");
  private long seq;
  /** When the last attach began (uptime ms), and whether one is running; guarded by this. */
  private long attachedAt;
  private boolean attaching;
  private VirtualDisplay mirror;
  private Surface previewSurface;
  private boolean closed;

  private final Binder engine =
      new Binder() {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
            throws RemoteException {
          if (code != PREVIEW && code != STOP) return super.onTransact(code, data, reply, flags);
          if (uid < 0 || Binder.getCallingUid() != uid)
            throw new SecurityException("Only the verified OpenCU companion may call the engine");
          data.enforceInterface(ENGINE);
          if (code == STOP) {
            host.personStop();
            if (reply != null) reply.writeNoException();
            return true;
          }
          Surface surface = data.readInt() != 0 ? Surface.CREATOR.createFromParcel(data) : null;
          int width = data.readInt(), height = data.readInt();
          boolean shown = preview(surface, width, height);
          if (reply != null) {
            reply.writeNoException();
            reply.writeInt(shown ? 1 : 0);
          }
          return true;
        }
      };

  Companion(Context context, Host host, String pin) {
    this.context = context;
    this.host = host;
    this.pin = pin == null ? "" : pin;
  }

  String state() {
    return state;
  }

  /** Whether {@code pkg} is the verified companion, whose windows are not app state. */
  boolean owns(String pkg) {
    return uid >= 0 && PACKAGE.equals(pkg);
  }

  /** Verifies the installed app against the pinned certificate; true when it may be attached. */
  boolean verify() {
    uid = -1;
    if (pin.isEmpty()) {
      state = "not pinned by this build";
      return false;
    }
    PackageInfo info;
    try {
      info = context.getPackageManager().getPackageInfo(PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES);
    } catch (PackageManager.NameNotFoundException e) {
      state = "not installed";
      return false;
    }
    if (!pin.equals(certificate(info.signingInfo))) {
      state = "installed with another signing certificate; not used";
      return false;
    }
    uid = info.applicationInfo.uid;
    state = "installed";
    return true;
  }

  /** SHA-256 of the single signing certificate in lowercase hex, or "" for none or several. */
  static String certificate(SigningInfo signing) {
    if (signing == null || signing.hasMultipleSigners()) return "";
    Signature[] signers = signing.getApkContentsSigners();
    if (signers == null || signers.length != 1) return "";
    try {
      StringBuilder b = new StringBuilder();
      for (byte x : MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray()))
        b.append(String.format("%02x", x & 0xff));
      return b.toString();
    } catch (Exception e) {
      return "";
    }
  }

  /** Verifies and attaches the app on its own thread; the connection never waits for it. */
  void start() {
    synchronized (this) {
      if (attaching || closed) return;
      attaching = true;
      attachedAt = android.os.SystemClock.uptimeMillis();
    }
    Thread t = new Thread(this::attach, "opencu-companion");
    t.setDaemon(true);
    t.start();
  }

  private void attach() {
    try {
      attachOnce();
    } finally {
      synchronized (this) {
        attaching = false;
      }
    }
  }

  private void attachOnce() {
    try {
      if (!verify()) return;
      Bundle extras = new Bundle();
      extras.putBinder("engine", engine);
      Bundle reply = callProvider("attach", extras);
      IBinder p = reply == null ? null : reply.getBinder("peer");
      if (p == null) {
        state = "installed; it did not answer";
        return;
      }
      p.linkToDeath(() -> lost(p), 0);
      synchronized (this) {
        if (closed) {
          send(p, obj("seq", ++seq, "state", "ended"));
          return;
        }
        peer = p;
      }
      state = "attached";
      push();
    } catch (Throwable e) {
      Throwable cause = e.getCause() != null ? e.getCause() : e;
      state = "installed; attach failed (" + cause.getClass().getSimpleName() + ")";
      android.util.Log.w("OpenCU", "Companion attach failed", cause);
    }
  }

  /** Calls the app's provider as shell, starting its process if needed. */
  private Bundle callProvider(String method, Bundle extras) throws Exception {
    Object am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
    int user = (Integer) UserHandle.class.getMethod("myUserId").invoke(null);
    IBinder token = new Binder();
    Object holder =
        am.getClass()
            .getMethod("getContentProviderExternal", String.class, int.class, IBinder.class, String.class)
            .invoke(am, AUTHORITY, user, token, "opencu");
    if (holder == null) throw new IllegalStateException("No provider " + AUTHORITY);
    try {
      android.content.pm.ProviderInfo info =
          (android.content.pm.ProviderInfo) holder.getClass().getField("info").get(holder);
      if (info == null || info.applicationInfo == null || info.applicationInfo.uid != uid)
        throw new SecurityException("The provider " + AUTHORITY + " is not the verified app's");
      Object provider = holder.getClass().getField("provider").get(holder);
      Method call =
          provider.getClass()
              .getMethod("call", AttributionSource.class, String.class, String.class, String.class, Bundle.class);
      return (Bundle) call.invoke(provider, context.getAttributionSource(), AUTHORITY, method, null, extras);
    } finally {
      am.getClass()
          .getMethod("removeContentProviderExternalAsUser", String.class, IBinder.class, int.class)
          .invoke(am, AUTHORITY, token, user);
    }
  }

  /** The current activity (a call or batch step is running). */
  void acting(Map<String, Object> activity) {
    Map<String, Object> s = new LinkedHashMap<>(activity);
    s.put("state", "acting");
    update(s);
    reattach();
  }

  /**
   * Not attached although the verified app is installed (its process went away, or an attach
   * failed): try again, at most every 5 seconds. A missing or differently signed app is not retried.
   */
  private void reattach() {
    synchronized (this) {
      if (peer != null || uid < 0 || attaching || closed) return;
      if (android.os.SystemClock.uptimeMillis() - attachedAt < 5000) return;
    }
    start();
  }

  /** Between calls: the last activity stays, marked as waiting for the agent. */
  void waiting() {
    Map<String, Object> s;
    synchronized (this) {
      s = new LinkedHashMap<>(last);
    }
    s.put("state", "waiting");
    s.remove("step");
    s.remove("steps");
    update(s);
  }

  void stopped() {
    update(obj("state", "stopped"));
  }

  /** Removes the preview before the agent display it mirrors goes away. */
  synchronized void releasePreview() {
    releaseMirror();
  }

  /** The agent display started or stopped; a preview attached while it stopped goes too. */
  void desktopChanged() {
    Map<String, Object> s;
    synchronized (this) {
      if (host.agentDisplay() < 0) releaseMirror();
      s = new LinkedHashMap<>(last);
    }
    update(s);
  }

  private void update(Map<String, Object> s) {
    synchronized (this) {
      if (closed) return;
      // A stop is final for the connection: nothing later shows it as working again.
      if (host.stopped()) s.put("state", "stopped");
      s.put("seq", ++seq);
      s.put("background", host.agentDisplay() >= 0);
      last = s;
    }
    push();
  }

  private void push() {
    IBinder p;
    Map<String, Object> s;
    synchronized (this) {
      p = peer;
      s = last;
    }
    if (p != null && !send(p, s)) lost(p);
  }

  /** One-way, so the engine never waits for the app; seq lets the app drop a reordered update. */
  private static boolean send(IBinder p, Map<String, Object> s) {
    Parcel data = Parcel.obtain();
    try {
      data.writeInterfaceToken(PEER);
      data.writeString(Json.write(s));
      return p.transact(STATUS, data, null, IBinder.FLAG_ONEWAY);
    } catch (RemoteException | RuntimeException e) {
      return false;
    } finally {
      data.recycle();
    }
  }

  private synchronized void lost(IBinder p) {
    if (peer != p) return;
    peer = null;
    releaseMirror();
    state = "detached";
  }

  /**
   * Mirrors the agent display into the app's surface, or removes the mirror for none. Only while
   * the agent display runs; the mirror shows what that display shows and takes no input.
   */
  synchronized boolean preview(Surface surface, int width, int height) {
    releaseMirror();
    if (surface == null) return true;
    int display = host.agentDisplay();
    if (closed || display < 0 || width <= 0 || height <= 0 || width > 4096 || height > 4096) {
      surface.release();
      return false;
    }
    try {
      // Hidden since Android 14: an auto-mirror display of displayIdToMirror into the surface.
      Method create =
          DisplayManager.class.getMethod(
              "createVirtualDisplay", String.class, int.class, int.class, int.class, Surface.class);
      mirror = (VirtualDisplay) create.invoke(null, "OpenCU preview", width, height, display, surface);
      previewSurface = surface;
      return mirror != null;
    } catch (Exception e) {
      surface.release();
      return false;
    }
  }

  private void releaseMirror() {
    if (mirror != null) mirror.release();
    mirror = null;
    if (previewSurface != null) previewSurface.release();
    previewSurface = null;
  }

  /** The connection ended: the app hides its windows. */
  void close() {
    IBinder p;
    Map<String, Object> s;
    synchronized (this) {
      if (closed) return;
      closed = true;
      releaseMirror();
      p = peer;
      peer = null;
      s = obj("seq", ++seq, "state", "ended");
    }
    if (p != null) send(p, s);
  }
}
