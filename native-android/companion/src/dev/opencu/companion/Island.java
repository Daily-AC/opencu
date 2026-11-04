package dev.opencu.companion;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.drawable.Drawable;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;
import android.provider.Settings;
import android.view.Surface;
import java.util.HashMap;
import java.util.Map;
import org.json.JSONObject;

/**
 * Connects one engine connection to the island and the preview. The engine attaches through the
 * provider and then sends status one way; when its process ends, the windows go.
 */
final class Island implements IslandView.Listener, PreviewWindow.Listener {
  /** Must match the engine's transaction codes and interface tokens. */
  static final int STATUS = IBinder.FIRST_CALL_TRANSACTION;

  static final int PREVIEW = IBinder.FIRST_CALL_TRANSACTION, STOP = IBinder.FIRST_CALL_TRANSACTION + 1;
  static final String ENGINE = "dev.opencu.companion.Engine", PEER = "dev.opencu.companion.Peer";
  static final int SHELL_UID = 2000;

  private static Island instance;

  static synchronized Island get(Context context) {
    if (instance == null) instance = new Island(context.getApplicationContext());
    return instance;
  }

  private final Context context;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final Map<String, Drawable> icons = new HashMap<>();
  private final Map<String, String> labels = new HashMap<>();
  private IslandView island;
  private PreviewWindow preview;
  /** The attached engine and the newest status it sent; main thread. */
  private IBinder engine;
  private long seq;
  private String app = "";
  private boolean background, stopped;

  private Island(Context context) {
    this.context = context;
  }

  /** Called by the provider on a Binder thread: keeps the engine and returns this side's Binder. */
  IBinder attach(IBinder engineBinder) {
    Binder peer =
        new Binder() {
          @Override
          protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
              throws RemoteException {
            if (code != STATUS) return super.onTransact(code, data, reply, flags);
            if (Binder.getCallingUid() != SHELL_UID) throw new SecurityException("Not the engine");
            data.enforceInterface(PEER);
            String json = data.readString();
            main.post(() -> status(engineBinder, json));
            return true;
          }
        };
    try {
      engineBinder.linkToDeath(() -> main.post(() -> ended(engineBinder)), 0);
    } catch (RemoteException gone) {
      return peer;
    }
    main.post(
        () -> {
          engine = engineBinder;
          seq = 0;
          stopped = false;
          app = "";
          background = false;
          // A preview still open belonged to the connection before; it shows no new frames.
          if (preview != null && preview.isShown()) preview.close();
        });
    return peer;
  }

  private void status(IBinder from, String json) {
    if (from != engine) return;
    JSONObject s;
    try {
      s = new JSONObject(json);
    } catch (Exception e) {
      return;
    }
    long n = s.optLong("seq", 0);
    if (n <= seq) return;
    seq = n;
    String state = s.optString("state", "");
    if (state.equals("ended")) {
      ended(from);
      return;
    }
    if (!Settings.canDrawOverlays(context)) {
      android.util.Log.w("OpenCU", "No permission to draw over other apps; the island stays hidden");
      return;
    }
    if (state.equals("stopped")) stopped = true;
    if (stopped) state = "stopped";
    background = s.optBoolean("background", false);
    if (s.has("app")) app = s.optString("app");
    if (island == null) island = new IslandView(context, this);
    String step = s.has("steps") ? Words.step(s.optInt("step"), s.optInt("steps")) : "";
    String label = app.isEmpty() ? Words.phone() : label(app);
    island.setContent(
        app.isEmpty() ? null : icon(app),
        stopped ? Words.stopped() : Words.action(s),
        stopped ? Words.isStopped() : Words.using(label),
        Words.where(background),
        state.equals("acting") ? step : "",
        state,
        background);
    if (!background && preview != null && preview.isShown()) preview.close();
    island.setPreviewOpen(preview != null && preview.isShown());
  }

  private void ended(IBinder from) {
    if (from != engine) return;
    engine = null;
    if (preview != null) preview.close();
    if (island == null) return;
    if (stopped) main.postDelayed(() -> {
      if (engine == null && island != null) island.hide();
    }, 2500);
    else island.hide();
  }

  private String label(String pkg) {
    String l = labels.get(pkg);
    if (l != null) return l;
    try {
      PackageManager pm = context.getPackageManager();
      ApplicationInfo info = pm.getApplicationInfo(pkg, 0);
      l = String.valueOf(pm.getApplicationLabel(info));
    } catch (PackageManager.NameNotFoundException e) {
      l = pkg;
    }
    labels.put(pkg, l);
    return l;
  }

  private Drawable icon(String pkg) {
    if (icons.containsKey(pkg)) return icons.get(pkg);
    Drawable d;
    try {
      d = context.getPackageManager().getApplicationIcon(pkg);
    } catch (PackageManager.NameNotFoundException e) {
      d = null;
    }
    icons.put(pkg, d);
    return d;
  }

  // ---- Island --------------------------------------------------------------------------------

  @Override
  public void onStop() {
    stopped = true;
    final IBinder e = engine;
    if (e != null)
      new Thread(
              () -> {
                Parcel data = Parcel.obtain(), reply = Parcel.obtain();
                boolean confirmed = false;
                try {
                  data.writeInterfaceToken(ENGINE);
                  e.transact(STOP, data, reply, 0);
                  reply.readException();
                  confirmed = true;
                } catch (RemoteException | RuntimeException failed) {
                  // A dead engine has ended its connection; otherwise the stop did not land.
                  confirmed = !e.isBinderAlive();
                } finally {
                  data.recycle();
                  reply.recycle();
                }
                if (!confirmed) main.post(() -> stopFailed(e));
              },
              "opencu-stop")
          .start();
    if (island != null)
      island.setContent(
          app.isEmpty() ? null : icon(app),
          Words.stopped(),
          Words.isStopped(),
          Words.where(background),
          "",
          "stopped",
          background);
    if (preview != null) preview.close();
  }

  /** The engine did not take the stop: say so, and point to the volume buttons. */
  private void stopFailed(IBinder from) {
    if (from != engine || island == null) return;
    stopped = false;
    island.setContent(
        app.isEmpty() ? null : icon(app),
        Words.stopFailed(),
        Words.using(app.isEmpty() ? Words.phone() : label(app)),
        Words.where(background),
        "",
        "waiting",
        background);
  }

  @Override
  public void onTogglePreview() {
    if (preview != null && preview.isShown()) {
      preview.close();
    } else if (background && engine != null) {
      if (preview == null) preview = new PreviewWindow(context, this);
      preview.show();
      // The island's card opens over the preview, so the island's window goes back on top.
      if (island != null) island.raise();
    }
    if (island != null) island.setPreviewOpen(preview != null && preview.isShown());
  }

  @Override
  public void onHidden() {
    island = null;
  }

  // ---- Preview -------------------------------------------------------------------------------

  /** Runs on a worker thread: asks the engine to mirror its agent display into the surface. */
  @Override
  public boolean attach(Surface surface, int width, int height) {
    IBinder e = engine;
    if (e == null) return false;
    Parcel data = Parcel.obtain(), reply = Parcel.obtain();
    try {
      data.writeInterfaceToken(ENGINE);
      if (surface == null) {
        data.writeInt(0);
      } else {
        data.writeInt(1);
        surface.writeToParcel(data, 0);
      }
      data.writeInt(width);
      data.writeInt(height);
      e.transact(PREVIEW, data, reply, 0);
      reply.readException();
      return reply.readInt() == 1;
    } catch (RemoteException | RuntimeException ignored) {
      return false;
    } finally {
      data.recycle();
      reply.recycle();
    }
  }

  @Override
  public void onClosed() {
    if (island != null) island.setPreviewOpen(false);
  }
}
