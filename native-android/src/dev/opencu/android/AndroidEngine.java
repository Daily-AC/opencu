package dev.opencu.android;

import static dev.opencu.android.Core.*;
import static dev.opencu.android.Json.*;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.*;
import android.content.*;
import android.content.pm.*;
import android.graphics.*;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.os.*;
import android.util.DisplayMetrics;
import android.view.*;
import android.view.accessibility.*;
import dev.opencu.android.Core.Window;
import java.io.*;
import java.lang.Process;
import java.lang.reflect.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Consumer;

class AndroidEngine implements Protocol.Backend, AutoCloseable {
  private final HandlerThread thread;
  // Volatile: shutdown sets closed before it changes the route, so a thread that sees the new
  // route also sees closed.
  private volatile UiAutomation automation;
  private UiAutomation mainAutomation;
  private UiAutomation desktopAutomation;
  private final Context context;
  private final ActivityManager activityManager;
  private final DisplayManager displays;
  private final PowerManager power;
  private final KeyguardManager keyguard;
  private final PersonMonitor monitor;
  private final Core.Person person;
  private final String monitorProblem;
  private final Field taskDisplay;
  private final Map<String, Object> hidden = obj();
  private volatile boolean closed;
  private Screen latest;
  private long sequence;
  private Capture coordinates;
  private final Map<Integer, AccessibilityNodeInfo> nodes = new HashMap<>();
  private String notice = "";
  /** Rows a multi-page scroll passed over, printed after the notice; reset with it. */
  private String passedOver = "";
  private boolean observationRequired;
  /** Set before anything in the current call reaches the device; a later failure needs a fresh read. */
  private boolean sent;
  private OwnedDisplay ownedDisplay;
  private volatile int activeDisplay = Display.DEFAULT_DISPLAY;
  private int desktopDisplay = -1;
  private int desktopFlags;
  private long desktopStartedAt;
  private long lastCallAt;
  private String mainForegroundBeforeDesktop;
  private final long desktopIdleMs = idleTimeout();

  private static final int FLAG_OWN_CONTENT_ONLY = 1 << 3;
  private static final int FLAG_PUBLIC = 1;
  private static final int FLAG_SUPPORTS_TOUCH = 1 << 6;
  private static final int FLAG_ROTATES_WITH_CONTENT = 1 << 7;
  private static final int FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 << 8;
  private static final int FLAG_TRUSTED = 1 << 10;
  private static final int FLAG_OWN_DISPLAY_GROUP = 1 << 11;
  private static final int FLAG_ALWAYS_UNLOCKED = 1 << 12;
  private static final int FLAG_TOUCH_FEEDBACK_DISABLED = 1 << 13;
  private static final int FLAG_OWN_FOCUS = 1 << 14;
  private static final int FLAG_STEAL_TOP_FOCUS_DISABLED = 1 << 16;

  private static final class Capture {
    final String app;
    final int display, width, height, displayWidth, displayHeight, rotation;
    final String windows;

    Capture(Screen s, int w, int h) {
      app = s.target;
      display = s.displayId;
      width = w;
      height = h;
      displayWidth = s.width;
      displayHeight = s.height;
      rotation = s.rotation;
      windows = windowIdentity(s);
    }
  }

  private static long idleTimeout() {
    String value = System.getenv("OPENCU_ANDROID_IDLE_MS");
    if (value == null) return 5 * 60 * 1000L;
    try {
      return Math.max(1000, Math.min(5 * 60 * 1000L, Long.parseLong(value)));
    } catch (NumberFormatException ignored) {
      return 5 * 60 * 1000L;
    }
  }

  AndroidEngine(Consumer<Map<String, Object>> output) throws Exception {
    if (Build.VERSION.SDK_INT < 34)
      throw fail("UNSUPPORTED_PLATFORM", "Android 14 (API 34) or later is required");
    if (android.os.Process.myUid() != 2000)
      throw fail("PERMISSION_DENIED", "Run as Android shell (uid 2000)");
    Looper.prepareMainLooper();
    Class<?> at = Class.forName("android.app.ActivityThread");
    Object activityThread = at.getMethod("systemMain").invoke(null);
    Context system = (Context) at.getMethod("getSystemContext").invoke(activityThread);
    // Services are called through this package's context.
    String ownPackage = ownPackage(system, android.os.Process.myUid());
    context = serviceContext(system, ownPackage);
    hidden.put("packageContext", ownPackage);
    hidden.put("ActivityThread.systemMain/getSystemContext", true);
    activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
    displays = (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
    power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
    keyguard = (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
    taskDisplay = ActivityManager.RunningTaskInfo.class.getField("displayId");
    hidden.put("TaskInfo.displayId", true);
    thread = new HandlerThread("opencu-uia");
    thread.start();
    try {
      Class<?> conn = Class.forName("android.app.UiAutomationConnection"),
          iconn = Class.forName("android.app.IUiAutomationConnection");
      automation =
          UiAutomation.class
              .getDeclaredConstructor(Looper.class, iconn)
              .newInstance(thread.getLooper(), conn.getDeclaredConstructor().newInstance());
      hidden.put("UiAutomation(Looper,IUiAutomationConnection)", true);
      UiAutomation.class
          .getDeclaredMethod("connect", int.class)
          .invoke(automation, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
      hidden.put("UiAutomation.connect(int)", true);
      AccessibilityServiceInfo info = automation.getServiceInfo();
      info.flags |=
          AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
              | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
              | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
      automation.setServiceInfo(info);
    } catch (Exception e) {
      Throwable cause = e instanceof InvocationTargetException && e.getCause() != null ? e.getCause() : e;
      throw fail(
          "UIAUTOMATION_UNAVAILABLE",
          cause.getClass().getName() + ": " + cause.getMessage());
    }
    mainAutomation = automation;
    PersonMonitor connectedMonitor = null;
    String problem = "";
    try {
      connectedMonitor = new PersonMonitor(output, this::lastUserActivityTime);
    } catch (Exception e) {
      problem = e.getMessage();
    }
    monitor = connectedMonitor;
    monitorProblem = problem;
    person = monitor == null ? new Core.Person(SystemClock.uptimeMillis()) : monitor.person;
  }

  /**
   * The package that owns {@code uid}. System services check the caller's package against its
   * uid; the system context names package "android", which they reject from the shell uid.
   */
  static String ownPackage(Context system, int uid) {
    String[] packages = system.getPackageManager().getPackagesForUid(uid);
    if (packages == null || packages.length != 1)
      throw fail(
          "PACKAGE_IDENTITY_UNAVAILABLE",
          "Expected exactly one package for uid " + uid + ", found "
              + (packages == null ? "none" : String.join(", ", packages)));
    return packages[0];
  }

  /** A context whose package name (as display services read it) is {@code ownPackage}. */
  static Context serviceContext(Context system, String ownPackage) {
    try {
      return system.createPackageContext(ownPackage, 0);
    } catch (PackageManager.NameNotFoundException e) {
      throw fail("PACKAGE_IDENTITY_UNAVAILABLE", "No context for package " + ownPackage);
    }
  }

  Map<String, Object> doctor() {
    Point p = size();
    return obj(
        "version",
        BuildInfo.VERSION,
        "sdk",
        Build.VERSION.SDK_INT,
        "uid",
        android.os.Process.myUid(),
        "pid",
        android.os.Process.myPid(),
        "uiAutomationConnected",
        automation.getServiceInfo() != null,
        "display",
        obj("id", 0, "width", p.x, "height", p.y, "rotation", displays.getDisplay(0).getRotation()),
        "screenOn",
        power.isInteractive(),
        "locked",
        keyguard.isKeyguardLocked(),
        "hiddenApis",
        hidden,
        "personMonitor",
        obj(
            "ready",
            monitor != null && monitor.ready(),
            "problem",
            monitorProblem,
            "devices",
            monitor == null ? Collections.emptyList() : monitor.devices,
            "source",
            "getevent -lt (kernel evdev)",
            "lastUserActivityTime",
            lastUserActivityTime()));
  }

  private long lastUserActivityTime() {
    try {
      return Core.lastUserActivityTime(command("dumpsys", "power"), SystemClock.uptimeMillis());
    } catch (Exception ignored) {
      // A conservative current timestamp keeps foreground activation fail-closed.
    }
    return SystemClock.uptimeMillis();
  }

  private Point sizeFor(int displayId) {
    Display display = displays.getDisplay(displayId);
    if (display == null) throw fail("DISPLAY_UNAVAILABLE", "Display " + displayId + " unavailable");
    Point point = new Point();
    display.getRealSize(point);
    return point;
  }

  private void configureAutomation(UiAutomation target) throws Exception {
    UiAutomation.class
        .getDeclaredMethod("connect", int.class)
        .invoke(target, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
    AccessibilityServiceInfo info = target.getServiceInfo();
    info.flags |=
        AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
    target.setServiceInfo(info);
  }

  UiAutomation createDisplayAutomation(int displayId) throws Exception {
    Class<?> conn = Class.forName("android.app.UiAutomationConnection");
    Class<?> iconn = Class.forName("android.app.IUiAutomationConnection");
    Constructor<UiAutomation> constructor =
        UiAutomation.class.getDeclaredConstructor(int.class, Looper.class, iconn);
    constructor.setAccessible(true);
    UiAutomation target = constructor.newInstance(displayId, thread.getLooper(),
        conn.getDeclaredConstructor().newInstance());
    configureAutomation(target);
    return target;
  }

  /** Keeps the agent display's keyboard on that display and reads the policy back. */
  void requireLocalIme(int displayId) {
    int policy;
    try {
      Object manager =
          Class.forName("android.view.WindowManagerGlobal")
              .getMethod("getWindowManagerService")
              .invoke(null);
      manager
          .getClass()
          .getMethod("setDisplayImePolicy", int.class, int.class)
          .invoke(manager, displayId, 0); // DISPLAY_IME_POLICY_LOCAL
      policy =
          (Integer)
              manager.getClass().getMethod("getDisplayImePolicy", int.class).invoke(manager, displayId);
    } catch (Exception e) {
      Throwable cause = e instanceof InvocationTargetException ? e.getCause() : e;
      throw fail(
          "AGENT_DESKTOP_UNAVAILABLE",
          "Could not keep the agent keyboard on its display: " + cause.getClass().getSimpleName());
    }
    if (policy != 0)
      throw fail(
          "AGENT_DESKTOP_UNAVAILABLE",
          "The agent display's keyboard policy is " + policy + ", not local; it could appear on display 0");
  }

  // Display.FLAG_* values (hidden) that isolate the person's focus from the agent display.
  private static final int DISPLAY_TRUSTED = 1 << 7;
  private static final int DISPLAY_OWN_FOCUS = 1 << 11;
  private static final int DISPLAY_STEAL_TOP_FOCUS_DISABLED = 1 << 12;

  /**
   * Starts the agent display as one transaction: a trusted display with its own focus that cannot
   * take the top focus, a verified local keyboard and its own UiAutomation connection, or nothing.
   * Every partial acquisition is released on failure and the main connection is restored.
   */
  private void startDesktop() throws Exception {
    if (desktopDisplay >= 0) return;
    if (routeLost != null) throw fail("DISPLAY_UNAVAILABLE", routeLost);
    String mainBefore = foregroundOnDisplay(Display.DEFAULT_DISPLAY);
    int requested =
        FLAG_PUBLIC
            | FLAG_OWN_CONTENT_ONLY
            | FLAG_SUPPORTS_TOUCH
            | FLAG_ROTATES_WITH_CONTENT
            | FLAG_DESTROY_CONTENT_ON_REMOVAL
            | FLAG_TOUCH_FEEDBACK_DISABLED
            | FLAG_TRUSTED
            | FLAG_OWN_DISPLAY_GROUP
            | FLAG_ALWAYS_UNLOCKED
            | FLAG_OWN_FOCUS
            | FLAG_STEAL_TOP_FOCUS_DISABLED;
    OwnedDisplay owned = null;
    UiAutomation agent = null;
    boolean mainDisconnected = false;
    try {
      try {
        owned = createOwnedDisplay(requested);
      } catch (SecurityException denied) {
        throw fail(
            "AGENT_DESKTOP_UNAVAILABLE",
            "Android refused a trusted virtual display (" + denied.getClass().getSimpleName() + ")");
      }
      List<String> missing = new ArrayList<>();
      if ((owned.displayFlags & DISPLAY_TRUSTED) == 0) missing.add("trusted");
      if ((owned.displayFlags & DISPLAY_OWN_FOCUS) == 0) missing.add("own focus");
      if ((owned.displayFlags & DISPLAY_STEAL_TOP_FOCUS_DISABLED) == 0) missing.add("no top-focus stealing");
      if (!missing.isEmpty())
        throw fail(
            "AGENT_DESKTOP_UNAVAILABLE",
            "The virtual display was created without " + String.join(", ", missing)
                + ", so it could take the person's focus");
      requireLocalIme(owned.id);
      disconnectAutomation(mainAutomation);
      mainDisconnected = true;
      agent = createDisplayAutomation(owned.id);
    } catch (Exception e) {
      if (agent != null) disconnectAutomation(agent);
      if (owned != null) owned.release();
      if (mainDisconnected) restoreMainRoute();
      throw e;
    }
    ownedDisplay = owned;
    desktopDisplay = owned.id;
    desktopAutomation = agent;
    automation = agent;
    activeDisplay = owned.id;
    desktopFlags = requested;
    mainForegroundBeforeDesktop = mainBefore;
    desktopStartedAt = SystemClock.uptimeMillis();
    lastCallAt = desktopStartedAt;
    hidden.put("virtualDisplayFlags", desktopFlags);
    hidden.put("virtualDisplayDisplayFlags", owned.displayFlags);
  }

  /** Why this connection can no longer read or act: its main connection could not be restored. */
  private String routeLost;

  private void restoreMainRoute() {
    try {
      mainAutomation = createDisplayAutomation(Display.DEFAULT_DISPLAY);
      automation = mainAutomation;
    } catch (Exception e) {
      routeLost =
          "Main-display UiAutomation could not be restored ("
              + e.getClass().getSimpleName()
              + "); start a new connection";
    }
  }

  /** How long a screenshot waits for the agent display's first frame. */
  static final long FRAME_WAIT_MS = 1500;

  /**
   * A virtual display owned by this engine, with the display flags Android actually granted. It
   * renders into an ImageReader whose newest frame is kept and every older one closed at once, so
   * the display never waits for a free buffer. These frames are the only image of this display:
   * on Android 14 UiAutomation's screenshot captures display 0 whatever display its connection is
   * bound to.
   */
  static class OwnedDisplay {
    final int id, displayFlags;
    private final VirtualDisplay display;
    private final ImageReader reader;
    private final HandlerThread frameThread;
    /** The newest frame; guarded by this. */
    private Image latest;
    /** Why the last frame could not be acquired, or null; guarded by this. */
    private String frameProblem;
    /** Set once release begins; no frame is kept or read afterwards. Guarded by this. */
    private boolean released;

    OwnedDisplay(
        VirtualDisplay display, ImageReader reader, HandlerThread frameThread, int id, int displayFlags) {
      this.display = display;
      this.reader = reader;
      this.frameThread = frameThread;
      this.id = id;
      this.displayFlags = displayFlags;
      if (reader != null) {
        Handler frames = new Handler(frameThread.getLooper());
        reader.setOnImageAvailableListener(r -> drain(), frames);
        frames.post(this::drain); // frames queued before the listener existed
      }
    }

    /** Acquires the newest queued frame, if any, and keeps it. */
    private synchronized void drain() {
      if (released || reader == null) return;
      Image next;
      try {
        next = reader.acquireLatestImage();
      } catch (RuntimeException e) {
        frameProblem = e.getClass().getSimpleName() + ": " + e.getMessage();
        return;
      }
      if (next != null) keep(next);
    }

    /** Keeps {@code next} as the newest frame and closes the one it replaces. */
    synchronized void keep(Image next) {
      if (released) {
        next.close();
        return;
      }
      if (latest != null) latest.close();
      latest = next;
      frameProblem = null;
      notifyAll();
    }

    /**
     * A copy of this display's newest frame, waiting up to {@code waitMs} for a first one. Fails
     * with SCREENSHOT_FAILED when there is none or it cannot be read; nothing else is ever
     * returned in its place.
     */
    synchronized Bitmap capture(long waitMs) {
      drain();
      long end = SystemClock.uptimeMillis() + waitMs;
      while (latest == null && !released) {
        long left = end - SystemClock.uptimeMillis();
        if (left <= 0) break;
        try {
          wait(Math.min(left, 50));
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
          break;
        }
        drain();
      }
      if (released)
        throw fail("SCREENSHOT_FAILED", "The agent display could not be captured: it was released");
      if (latest == null)
        throw fail(
            "SCREENSHOT_FAILED",
            "The agent display could not be captured: no frame within " + waitMs + " ms"
                + (frameProblem == null ? "" : " (" + frameProblem + ")"));
      try {
        return frameBitmap(latest);
      } catch (Failure e) {
        throw e;
      } catch (RuntimeException e) {
        throw fail(
            "SCREENSHOT_FAILED",
            "The agent display could not be captured: " + e.getClass().getSimpleName());
      }
    }

    void release() {
      if (display != null) display.release();
      synchronized (this) {
        released = true;
        if (latest != null) latest.close();
        latest = null;
        notifyAll();
      }
      if (reader != null) reader.close(); // also releases the display's surface
      if (frameThread != null) frameThread.quitSafely();
    }
  }

  /** Copies an RGBA_8888 frame into a bitmap of the frame's size, dropping any row padding. */
  static Bitmap frameBitmap(Image image) {
    int width = image.getWidth(), height = image.getHeight();
    Image.Plane[] planes = image.getPlanes();
    if (image.getFormat() != PixelFormat.RGBA_8888
        || planes.length != 1
        || planes[0].getPixelStride() != 4
        || planes[0].getRowStride() < width * 4)
      throw fail(
          "SCREENSHOT_FAILED",
          "The agent display could not be captured: unexpected frame format " + image.getFormat());
    int rowStride = planes[0].getRowStride(), row = width * 4;
    // A duplicate: the same frame can be read again, so its buffer's position must not move.
    ByteBuffer source = planes[0].getBuffer().duplicate();
    source.rewind();
    ByteBuffer pixels = source;
    if (rowStride != row) {
      // Padded rows; the last row may end without its padding.
      byte[] packed = new byte[row * height];
      for (int y = 0; y < height; y++) {
        source.position(y * rowStride);
        source.get(packed, y * row, row);
      }
      pixels = ByteBuffer.wrap(packed);
    }
    Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
    bitmap.copyPixelsFromBuffer(pixels);
    bitmap.setHasAlpha(false);
    return bitmap;
  }

  /** Creates a display matching display 0's size and density with the requested flags. */
  OwnedDisplay createOwnedDisplay(int requested) {
    Point main = sizeFor(Display.DEFAULT_DISPLAY);
    DisplayMetrics metrics = new DisplayMetrics();
    displays.getDisplay(Display.DEFAULT_DISPLAY).getRealMetrics(metrics);
    HandlerThread frameThread = new HandlerThread("opencu-frames");
    frameThread.start();
    ImageReader reader = null;
    VirtualDisplay display = null;
    try {
      // Three images: the kept frame plus the two acquireLatestImage needs to skip to the newest.
      reader = ImageReader.newInstance(main.x, main.y, PixelFormat.RGBA_8888, 3);
      display =
          displays.createVirtualDisplay(
              "OpenCU agent", main.x, main.y, metrics.densityDpi, reader.getSurface(), requested);
      Display created = display.getDisplay();
      return new OwnedDisplay(
          display, reader, frameThread, created.getDisplayId(), created.getFlags());
    } catch (RuntimeException e) {
      if (display != null) display.release();
      if (reader != null) reader.close();
      frameThread.quitSafely();
      throw e;
    }
  }

  void disconnectAutomation(UiAutomation target) {
    try {
      UiAutomation.class.getDeclaredMethod("disconnect").invoke(target);
    } catch (Exception ignored) {
    }
  }

  void stopDesktop() {
    if (desktopDisplay < 0) return;
    int oldDisplay = desktopDisplay;
    for (ActivityManager.RunningTaskInfo task : activityManager.getRunningTasks(50)) {
      try {
        if (taskOnDisplay(task, oldDisplay)) {
          Object taskManager = Class.forName("android.app.ActivityTaskManager")
              .getMethod("getService").invoke(null);
          Method move = taskManager.getClass().getMethod("moveTaskToBack", int.class, boolean.class);
          move.invoke(taskManager, task.id, false);
        }
      } catch (Exception ignored) {
        // Releasing the owned display remains the safe fallback; it cannot focus display 0.
      }
    }
    if (ownedDisplay != null) ownedDisplay.release();
    ownedDisplay = null;
    if (desktopAutomation != null) disconnectAutomation(desktopAutomation);
    desktopAutomation = null;
    desktopDisplay = -1;
    activeDisplay = Display.DEFAULT_DISPLAY;
    mainForegroundBeforeDesktop = null;
    latest = null;
    coordinates = null;
    observationRequired = false;
    restoreMainRoute();
    if (routeLost != null) throw fail("DISPLAY_UNAVAILABLE", routeLost);
  }

  private static final Set<Process> children = new HashSet<>();
  private static boolean commandsStopped;

  /**
   * Runs a platform client and returns its output. Throws IOException only when the process could
   * not start; once started, the child is killed and reaped on every exit path, interruption
   * included, so it cannot outlive the call.
   */
  static String command(String... args) throws Exception {
    Process p;
    synchronized (children) {
      if (commandsStopped) throw fail("ENGINE_STOPPING", "Engine is stopping; command not started");
      p = new ProcessBuilder(args).redirectErrorStream(true).start();
      children.add(p);
    }
    try {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      Thread drain =
          new Thread(
              () -> {
                try {
                  p.getInputStream().transferTo(out);
                } catch (IOException ignored) {
                }
              });
      drain.setDaemon(true);
      drain.start();
      if (!p.waitFor(5, TimeUnit.SECONDS)) throw fail("RUNTIME_ERROR", "Android command timed out");
      drain.join(1000);
      String text = new String(out.toByteArray(), StandardCharsets.UTF_8);
      if (p.exitValue() != 0) throw fail("RUNTIME_ERROR", "Android command failed: " + text.trim());
      return text;
    } finally {
      if (p.isAlive()) {
        p.destroyForcibly();
        try {
          p.waitFor(500, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
        }
      }
      synchronized (children) {
        children.remove(p);
      }
    }
  }

  /** Kills every running platform client and refuses new ones; waits up to {@code millis}. */
  static void stopCommands(long millis) {
    List<Process> running;
    synchronized (children) {
      commandsStopped = true;
      running = new ArrayList<>(children);
    }
    for (Process p : running) p.destroyForcibly();
    long end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(millis);
    for (Process p : running)
      try {
        p.waitFor(Math.max(0, end - System.nanoTime()), TimeUnit.NANOSECONDS);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        return;
      }
  }

  /** Runs a platform shell client for this engine; tests substitute the device. */
  String shell(String... args) throws Exception {
    return command(args);
  }

  boolean hasAction(AccessibilityNodeInfo n, int id) {
    for (AccessibilityNodeInfo.AccessibilityAction a : n.getActionList()) if (a.getId() == id) return true;
    return false;
  }

  private Point size() {
    return sizeFor(activeDisplay);
  }

  private boolean taskOnDisplay(ActivityManager.RunningTaskInfo task, int displayId) {
    try {
      return taskDisplay.getInt(task) == displayId;
    } catch (IllegalAccessException e) {
      throw fail("RUNTIME_ERROR", "Cannot read task display identity");
    }
  }

  String[] foreground() {
    for (ActivityManager.RunningTaskInfo task : activityManager.getRunningTasks(20))
      if (taskOnDisplay(task, activeDisplay) && task.topActivity != null)
        return new String[] {
          task.topActivity.getPackageName(), task.topActivity.flattenToShortString()
        };
    if (activeDisplay != Display.DEFAULT_DISPLAY) return new String[] {"", ""};
    throw fail("WINDOW_NOT_FOUND", "Cannot establish main-display foreground activity");
  }

  String foregroundOnDisplay(int displayId) {
    for (ActivityManager.RunningTaskInfo task : activityManager.getRunningTasks(20))
      if (taskOnDisplay(task, displayId) && task.topActivity != null)
        return task.topActivity.getPackageName();
    return "";
  }

  String resolve(String name) {
    PackageManager pm = context.getPackageManager();
    // Package identifiers are the ordinary host path. Avoid loading every installed
    // application's label/resources just to resolve a package we already know.
    if (name.indexOf('.') > 0 && pm.getLaunchIntentForPackage(name) != null) return name;
    Intent query = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
    List<ResolveInfo> apps = pm.queryIntentActivities(query, 0);
    Set<String> matches = new LinkedHashSet<>();
    for (ResolveInfo r : apps) {
      if (r.activityInfo.packageName.equals(name)) return name;
      if (r.loadLabel(pm).toString().equalsIgnoreCase(name))
        matches.add(r.activityInfo.packageName);
    }
    if (matches.size() > 1)
      throw fail(
          "AMBIGUOUS_APP",
          "Launcher label matches multiple packages: " + String.join(", ", matches));
    if (matches.isEmpty())
      throw fail("APP_NOT_FOUND", "No launchable Android package or label: " + name);
    return matches.iterator().next();
  }

  private Map<String, Object> apps() {
    String fg = foreground()[0];
    Set<String> running = new HashSet<>();
    List<ActivityManager.RunningAppProcessInfo> processes =
        activityManager.getRunningAppProcesses();
    if (processes != null)
      for (ActivityManager.RunningAppProcessInfo p : processes)
        if (p.pkgList != null) running.addAll(Arrays.asList(p.pkgList));
    Set<String> displayRunning = new HashSet<>();
    if (desktopDisplay >= 0)
      for (ActivityManager.RunningTaskInfo task : activityManager.getRunningTasks(50))
        if (taskOnDisplay(task, activeDisplay) && task.topActivity != null)
          displayRunning.add(task.topActivity.getPackageName());
    PackageManager pm = context.getPackageManager();
    Map<String, Object> result = new TreeMap<>();
    for (ResolveInfo r :
        pm.queryIntentActivities(
            new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)) {
      String pkg = r.activityInfo.packageName;
      result.put(
          pkg,
          obj(
              "label",
              r.loadLabel(pm).toString(),
              "package",
              pkg,
              "running",
              desktopDisplay >= 0 ? displayRunning.contains(pkg) : running.contains(pkg),
              "foreground",
              pkg.equals(fg)));
    }
    return Protocol.textResult(Json.write(result.values()));
  }

  void check(long token, boolean changing) {
    if (closed) throw fail("ENGINE_STOPPING", "Stdin closed");
    if (desktopDisplay >= 0) person.checkDesktop();
    else person.check(token, SystemClock.uptimeMillis(), changing);
    if (monitor == null)
      throw fail("PERSON_MONITOR_UNAVAILABLE", monitorProblem + "; no input sent");
    monitor.check(token, changing, desktopDisplay >= 0);
    if (!power.isInteractive() || keyguard.isKeyguardLocked())
      throw fail("SCREEN_LOCKED", "Phone is locked or screen off; nothing will wake or unlock it");
  }

  private void checkTarget(long token, String pkg) {
    check(token, false);
    if (!foreground()[0].equals(pkg))
      throw fail("APP_SWITCHED", "Foreground changed; no further input sent");
  }

  private void pause(long millis, long token) {
    long end = SystemClock.uptimeMillis() + millis;
    while (SystemClock.uptimeMillis() < end) {
      check(token, false);
      SystemClock.sleep(Math.max(0, Math.min(20, end - SystemClock.uptimeMillis())));
    }
    check(token, false);
  }

  private void activate(String pkg, long token) throws Exception {
    if (desktopDisplay >= 0 && pkg.equals(foregroundOnDisplay(Display.DEFAULT_DISPLAY)))
      throw fail(
          "APP_IN_USE_BY_PERSON",
          "The requested app is in front on the person's main display; nothing sent");
    boolean changing = !foreground()[0].equals(pkg);
    check(token, changing);
    if (!changing) return;
    String component = launchComponent(pkg);
    if (component == null) throw fail("LAUNCH_FAILED", "No launcher activity for " + pkg);
    // am is a platform shell client; package/component comes from PackageManager, never
    // interpolated shell text.
    check(token, true);
    int display = activeDisplay;
    ensureOpen();
    sent = true;
    shell(
        "/system/bin/am",
        "start",
        "--display",
        Integer.toString(display),
        "-n",
        component,
        "-a",
        Intent.ACTION_MAIN,
        "-c",
        Intent.CATEGORY_LAUNCHER,
        "-f",
        "0x10200000");
    long end = SystemClock.uptimeMillis() + 5000;
    while (!foreground()[0].equals(pkg) && SystemClock.uptimeMillis() < end) pause(25, token);
    checkTarget(token, pkg);
  }

  /** The launcher activity of {@code pkg} as a flattened component name, or null. */
  String launchComponent(String pkg) {
    Intent launch = context.getPackageManager().getLaunchIntentForPackage(pkg);
    return launch == null ? null : launch.getComponent().flattenToString();
  }

  private static String windowIdentity(Screen s) {
    StringBuilder b = new StringBuilder();
    for (Window w : s.windows)
      b.append(w.id).append(':').append(w.type).append(':').append(w.pkg).append(';');
    return b.toString();
  }

  Screen observe(String target) {
    automation.clearCache();
    nodes.clear();
    Screen s = new Screen();
    s.displayId = activeDisplay;
    s.target = target;
    s.id = ++sequence;
    String[] fg = foreground();
    s.foreground = fg[0];
    s.activity = fg[1];
    Point dimensions = size();
    s.width = dimensions.x;
    s.height = dimensions.y;
    s.rotation = displays.getDisplay(activeDisplay).getRotation();
    List<AccessibilityWindowInfo> windows = windowsOnActiveDisplay();
    windows.sort(Comparator.comparingInt(AccessibilityWindowInfo::getLayer));
    for (AccessibilityWindowInfo aw : windows) {
      if (aw.getDisplayId() != activeDisplay) continue;
      AccessibilityNodeInfo root = aw.getRoot();
      if (root == null) continue;
      Window w = new Window();
      w.id = aw.getId();
      w.type = aw.getType();
      w.layer = aw.getLayer();
      w.focused = aw.isFocused();
      w.active = aw.isActive();
      w.title = str(aw.getTitle());
      w.pkg = str(root.getPackageName());
      Rect windowBounds = new Rect();
      aw.getBoundsInScreen(windowBounds);
      w.left = windowBounds.left;
      w.top = windowBounds.top;
      w.right = windowBounds.right;
      w.bottom = windowBounds.bottom;
      if (w.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) s.keyboard = true;
      s.windows.add(w);
      // Persistent status/navigation bars contain notification icon labels and volatile
      // telemetry. Keep their window identity, but do not read their decorative subtree.
      int barLimit = Math.max(120, s.height / 12);
      boolean systemBar =
          w.type == AccessibilityWindowInfo.TYPE_SYSTEM
              && !w.focused
              && !w.active
              && windowBounds.width() >= s.width
              && ((windowBounds.top <= 0 && windowBounds.bottom <= barLimit)
                  || (windowBounds.bottom >= s.height && windowBounds.height() <= barLimit));
      if (!systemBar) walk(root, "", w, s, 0, new int[] {0});
    }
    return s;
  }

  @SuppressWarnings("unchecked")
  private List<AccessibilityWindowInfo> windowsOnActiveDisplay() {
    if (desktopAutomation != null) return new ArrayList<>(automation.getWindows());
    if (activeDisplay == Display.DEFAULT_DISPLAY) return new ArrayList<>(automation.getWindows());
    try {
      Object all = UiAutomation.class.getMethod("getWindowsOnAllDisplays").invoke(automation);
      List<AccessibilityWindowInfo> windows =
          ((android.util.SparseArray<List<AccessibilityWindowInfo>>) all).get(activeDisplay);
      return windows == null ? new ArrayList<>() : new ArrayList<>(windows);
    } catch (Exception e) {
      throw fail(
          "DISPLAY_UNAVAILABLE", "Android did not expose windows on display " + activeDisplay);
    }
  }

  private void walk(
      AccessibilityNodeInfo n, String path, Window w, Screen s, int depth, int[] visited) {
    if (depth > 60 || visited[0]++ > 5000) {
      s.truncated = true;
      return;
    }
    Element e = element(n, path, w.id);
    if (e.right <= 0 || e.left >= s.width || e.bottom <= 0 || e.top >= s.height) e.visible = false;
    if (e.useful()) {
      e.index = s.elements.size() + 1;
      s.elements.put(e.index, e);
      w.elements.add(e);
      nodes.put(e.index, n);
    }
    for (int i = 0; i < n.getChildCount(); i++) {
      AccessibilityNodeInfo child = n.getChild(i);
      if (child != null) walk(child, path + "/" + i, w, s, depth + 1, visited);
    }
  }

  private Element element(AccessibilityNodeInfo n, String path, int window) {
    Element e = new Element();
    e.window = window;
    e.display = activeDisplay;
    e.path = path;
    e.clazz = str(n.getClassName());
    e.text = str(n.getText());
    e.desc = str(n.getContentDescription());
    e.id = str(n.getViewIdResourceName());
    e.pkg = str(n.getPackageName());
    Rect b = new Rect();
    n.getBoundsInScreen(b);
    e.left = b.left;
    e.top = b.top;
    e.right = b.right;
    e.bottom = b.bottom;
    e.visible = n.isVisibleToUser();
    e.clickable = n.isClickable();
    e.longClickable = n.isLongClickable();
    e.editable = n.isEditable();
    e.scrollable = n.isScrollable();
    e.checkable = n.isCheckable();
    e.checked = n.isChecked();
    e.selected = n.isSelected();
    e.focused = n.isFocused();
    e.focusable = n.isFocusable();
    e.enabled = n.isEnabled();
    e.password = n.isPassword();
    for (AccessibilityNodeInfo.AccessibilityAction a : n.getActionList()) {
      int id = a.getId();
      String label = null;
      if (id == AccessibilityNodeInfo.ACTION_COLLAPSE) label = "collapse";
      else if (id == AccessibilityNodeInfo.ACTION_EXPAND) label = "expand";
      else if (id == AccessibilityNodeInfo.ACTION_DISMISS) label = "dismiss";
      else if (id == AccessibilityNodeInfo.ACTION_LONG_CLICK) label = "long_click";
      else if (id == AccessibilityNodeInfo.ACTION_SCROLL_FORWARD) label = "scroll_forward";
      else if (id == AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD) label = "scroll_backward";
      else if (id > 0x00ffffff && a.getLabel() != null) label = "action_" + id + ":" + a.getLabel();
      if (label != null) e.actions.put(label, id);
    }
    return e;
  }

  /** The live element that {@code old} (from {@code before}) still names in {@code now}. */
  private Element live(Element old, Screen before, Screen now) {
    if (old == null)
      throw fail("STALE_ELEMENT", "Element index was not in the last returned state");
    Element e = Core.live(before, old, now);
    if (e != null && nodes.get(e.index) != null) {
      if (!e.enabled) throw fail("ELEMENT_DISABLED", "Element is disabled");
      return e;
    }
    // Diagnostics name what changed with structure and geometry only, never node text.
    throw fail("STALE_ELEMENT", Core.staleReason(before, old, now));
  }

  private Screen readReady(String pkg, long token, boolean inputCall) {
    Screen s = observe(pkg);
    long end = SystemClock.uptimeMillis() + 3000;
    while (s.elements.values().stream().noneMatch(e -> e.pkg.equals(pkg))
        && s.foreground.equals(pkg)
        && SystemClock.uptimeMillis() < end) {
      if (inputCall) check(token, false);
      if (closed) throw fail("ENGINE_STOPPING", "Stdin closed");
      SystemClock.sleep(30);
      s = observe(pkg);
    }
    {
      if (inputCall) settleAfterInput(token);
      else waitIdle();
      if (inputCall) SystemClock.sleep(desktopDisplay >= 0 ? 700 : 450);
      long settleEnd = SystemClock.uptimeMillis() + (inputCall ? 700 : 300);
      String signature = s.fingerprint();
      long stableSince = SystemClock.uptimeMillis();
      while (SystemClock.uptimeMillis() < settleEnd) {
        SystemClock.sleep(25);
        Screen next = observe(pkg);
        String value = next.fingerprint();
        if (value.equals(signature)
            && SystemClock.uptimeMillis() - stableSince >= (inputCall ? 150 : 50)
            && !next.elements.isEmpty()) {
          s = next;
          break;
        }
        if (!value.equals(signature)) {
          signature = value;
          stableSince = SystemClock.uptimeMillis();
        }
        s = next;
      }
    }
    return s;
  }

  /**
   * Builds the response for {@code s}. Its indexes and screenshot grant become current only once
   * the whole response exists; a failed capture leaves the last returned state in force.
   */
  private Map<String, Object> result(Screen s, boolean screenshot) {
    Map<String, Object> r =
        Protocol.textResult((notice.isEmpty() ? "" : notice + "\n") + passedOver + s.text());
    Capture capture = null;
    if (screenshot) {
      Bitmap bitmap = screenshotOf(s);
      int ow = bitmap.getWidth(), oh = bitmap.getHeight();
      if (ow != s.width || oh != s.height) {
        bitmap.recycle();
        throw fail(
            "STALE_SCREENSHOT",
            "Display geometry changed during capture (image " + ow + "x" + oh + ", display "
                + s.width + "x" + s.height + ")");
      }
      double scale = Math.min(1, 1280.0 / Math.max(ow, oh));
      int w = (int) Math.round(ow * scale), h = (int) Math.round(oh * scale);
      Map<String, Object> text = map(list(r.get("content")).get(0));
      text.put(
          "text",
          Core.screenshotNotice(w, h, s.width, s.height)
              + "\n"
              + text.get("text"));
      Bitmap scaled = Bitmap.createScaledBitmap(bitmap, w, h, true);
      ByteArrayOutputStream data = new ByteArrayOutputStream();
      scaled.compress(Bitmap.CompressFormat.JPEG, 80, data);
      if (scaled != bitmap) scaled.recycle();
      bitmap.recycle();
      list(r.get("content"))
          .add(
              obj(
                  "type",
                  "image",
                  "mimeType",
                  "image/jpeg",
                  "data",
                  android.util.Base64.encodeToString(
                      data.toByteArray(), android.util.Base64.NO_WRAP)));
      capture = new Capture(s, w, h);
      r.put(
          "_meta",
          obj("opencu/screenshot", obj("width", w, "height", h, "display", s.displayId)));
    }
    latest = s;
    observationRequired = false;
    coordinates = capture;
    notice = "";
    passedOver = "";
    return r;
  }

  /**
   * The pixels of the display {@code s} describes. While the agent display is started, or for a
   * state read on it, only that display's own frames are used; display 0 is never captured in
   * their place, so a failure is an error.
   */
  private Bitmap screenshotOf(Screen s) {
    if (s.displayId != Display.DEFAULT_DISPLAY || desktopDisplay >= 0) {
      OwnedDisplay owned = ownedDisplay;
      if (owned == null || owned.id != s.displayId || desktopDisplay != s.displayId)
        throw fail(
            "SCREENSHOT_FAILED",
            "The agent display could not be captured: display " + s.displayId
                + " is not the started agent display; display 0 is never captured instead");
      Bitmap frame;
      try {
        frame = owned.capture(FRAME_WAIT_MS);
      } catch (Failure e) {
        throw e;
      } catch (Exception e) {
        throw fail(
            "SCREENSHOT_FAILED",
            "The agent display could not be captured: " + e.getClass().getSimpleName());
      }
      if (frame == null)
        throw fail("SCREENSHOT_FAILED", "The agent display could not be captured: no frame");
      return frame;
    }
    Bitmap bitmap;
    try {
      bitmap = mainDisplayScreenshot();
    } catch (Exception e) {
      throw fail(
          "SCREENSHOT_FAILED", "Screenshot on display 0 failed: " + e.getClass().getSimpleName());
    }
    if (bitmap == null)
      throw fail("SCREENSHOT_FAILED", "Screenshot unavailable (secure content is not bypassed)");
    return bitmap;
  }

  /** Display 0's screenshot through the main connection; tests substitute the device. */
  Bitmap mainDisplayScreenshot() {
    return automation.takeScreenshot();
  }

  private Map<String, Object> checkedResult(
      Screen s, boolean screenshot, boolean inputCall, long token) {
    try {
      if (inputCall) check(token, false);
      Map<String, Object> r = result(s, screenshot);
      if (inputCall) check(token, false);
      return r;
    } catch (Failure e) {
      coordinates = null;
      if (inputCall) observationRequired = true;
      throw e;
    }
  }

  private void actionConfirmed(boolean success) {
    if (!success) {
      observationRequired = true;
      throw fail(
          "ACTION_UNCONFIRMED",
          "The app did not confirm the action. Outcome unknown; read state and do not repeat"
              + " automatically.");
    }
  }

  private void accessibility(
      AccessibilityNodeInfo n, int action, Bundle args, String pkg, long token) {
    checkTarget(token, pkg);
    ensureOpen();
    sent = true;
    actionConfirmed(n.performAction(action, args));
    check(token, false);
  }

  private void touch(float x, float y, float tx, float ty, long duration, String pkg, long token) {
    touch(x, y, tx, ty, duration, 0, pkg, token);
  }

  /**
   * A touch that moves from (x, y) to (tx, ty) over {@code duration} ms, then stays at (tx, ty) for
   * {@code hold} ms before it lifts, so a list stops where the finger stopped instead of flinging.
   */
  private void touch(
      float x, float y, float tx, float ty, long duration, long hold, String pkg, long token) {
    checkTarget(token, pkg);
    if (!displayInputAvailable())
      throw fail("INPUT_UNAVAILABLE", "display-targeted touch injection is unavailable");
    // The whole gesture, release included, stays on the display and connection it started on.
    UiAutomation via = automation;
    int display = activeDisplay;
    ensureOpen();
    long down = SystemClock.uptimeMillis();
    boolean pressed = false;
    try {
      pressed = true;
      motion(via, display, down, MotionEvent.ACTION_DOWN, x, y);
      long end = down + duration + hold;
      while (SystemClock.uptimeMillis() < end) {
        pause(Math.min(16, end - SystemClock.uptimeMillis()), token);
        checkTarget(token, pkg);
        float f = Math.min(1, (SystemClock.uptimeMillis() - down) / (float) Math.max(1, duration));
        if (x != tx || y != ty)
          motion(via, display, down, MotionEvent.ACTION_MOVE, x + (tx - x) * f, y + (ty - y) * f);
      }
      checkTarget(token, pkg);
      motion(via, display, down, MotionEvent.ACTION_UP, tx, ty);
      pressed = false;
    } finally {
      if (pressed) motion(via, display, down, MotionEvent.ACTION_CANCEL, x, y);
    }
  }

  private void motion(UiAutomation via, int display, long down, int action, float x, float y) {
    sent = true;
    sendMotion(via, display, down, action, x, y);
  }

  /** Injects one touch event through {@code via} onto {@code display}. */
  void sendMotion(UiAutomation via, int display, long down, int action, float x, float y) {
    MotionEvent e = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0);
    e.setSource(InputDevice.SOURCE_TOUCHSCREEN);
    setEventDisplay(e, display);
    try {
      actionConfirmed(via.injectInputEvent(e, true));
    } finally {
      e.recycle();
    }
  }

  /** Injects one key event through {@code via} onto {@code display}. */
  void sendKey(UiAutomation via, int display, long down, long time, int action, int code, int flags) {
    KeyEvent event =
        new KeyEvent(
            down,
            time,
            action,
            code,
            0,
            0,
            KeyCharacterMap.VIRTUAL_KEYBOARD,
            0,
            flags,
            InputDevice.SOURCE_KEYBOARD);
    setEventDisplay(event, display);
    actionConfirmed(via.injectInputEvent(event, true));
  }

  private static final Method SET_DISPLAY_ID = displayIdSetter();

  private static Method displayIdSetter() {
    try {
      return InputEvent.class.getMethod("setDisplayId", int.class);
    } catch (Exception e) {
      return null;
    }
  }

  /** Whether events can carry a display id; checked before the first event of a gesture. */
  boolean displayInputAvailable() {
    return SET_DISPLAY_ID != null;
  }

  private void setEventDisplay(InputEvent event, int display) {
    try {
      SET_DISPLAY_ID.invoke(event, display);
    } catch (Exception e) {
      throw fail("INPUT_UNAVAILABLE", "Android did not expose display-targeted input");
    }
  }

  private float[] point(Map<String, Object> args, String x, String y, Capture cap, Screen s) {
    if (cap == null || !cap.app.equals(s.target))
      throw fail("SCREENSHOT_REQUIRED", "Request a fresh screenshot before coordinate input");
    if (cap.display != s.displayId
        || cap.displayWidth != s.width
        || cap.displayHeight != s.height
        || cap.rotation != s.rotation
        || !cap.windows.equals(windowIdentity(s)))
      throw fail("STALE_SCREENSHOT", "Display or windows changed after screenshot");
    double px = ((Number) args.get(x)).doubleValue(), py = ((Number) args.get(y)).doubleValue();
    if (px < 0 || py < 0 || px >= cap.width || py >= cap.height)
      throw fail("INVALID_ARGUMENT", "Coordinate outside latest screenshot");
    return new float[] {(float) (px * s.width / cap.width), (float) (py * s.height / cap.height)};
  }

  private float[] center(Element e, Screen s) {
    int left = Math.max(0, e.left),
        top = Math.max(0, e.top),
        right = Math.min(s.width, e.right),
        bottom = Math.min(s.height, e.bottom);
    if (right <= left || bottom <= top)
      throw fail("STALE_ELEMENT", "Element is outside the display");
    return new float[] {(left + right) / 2f, (top + bottom) / 2f};
  }

  private boolean touchPossible(Element target, Screen s) {
    float[] point;
    try {
      point = center(target, s);
    } catch (Failure e) {
      return false;
    }
    Window owner = null;
    for (Window window : s.windows) if (window.id == target.window) owner = window;
    if (owner == null) return false;
    for (Window window : s.windows) {
      if (window.layer <= owner.layer || window.id == owner.id) continue;
      if (window.left <= point[0]
          && point[0] < window.right
          && window.top <= point[1]
          && point[1] < window.bottom
          && (window.active || window.focused || window.type != AccessibilityWindowInfo.TYPE_SYSTEM))
        return false;
    }
    for (Element candidate : s.elements.values()) {
      if (candidate.index == target.index
          || candidate.window != target.window
          || !candidate.path.startsWith(target.path + "/")) continue;
      if (candidate.left <= point[0]
          && point[0] < candidate.right
          && candidate.top <= point[1]
          && point[1] < candidate.bottom
          && (candidate.clickable || candidate.editable || !candidate.desc.isEmpty())) return false;
    }
    return true;
  }

  private void clickElement(
      AccessibilityNodeInfo node, Element target, Screen state, String pkg, long token, int count, double seconds) {
    String unavailable = touchPossible(target, state) ? null : "its centre is covered or off-screen";
    if (unavailable == null) {
      float[] point = center(target, state);
      int i = 0;
      try {
        for (; i < count; i++) {
          if (count == 1 && seconds == 0) shellTap(point[0], point[1], pkg, token);
          else
            touch(
                point[0],
                point[1],
                point[0],
                point[1],
                seconds > 0 ? Math.max(600, (long) (seconds * 1000)) : 45,
                pkg,
                token);
          if (i < count - 1) pause(70, token);
        }
        if (target.editable) waitForElementFocus(target, pkg, token);
        return;
      } catch (Failure e) {
        // INPUT_UNAVAILABLE is raised only before a touch starts; a touch that may have been
        // delivered is never repeated another way.
        if (!e.code.equals("INPUT_UNAVAILABLE") || i > 0) throw e;
        unavailable = e.getMessage();
      }
    }
    if (!node.isClickable() && !hasAction(node, AccessibilityNodeInfo.ACTION_CLICK))
      throw fail(
          "INPUT_UNAVAILABLE",
          "A touch cannot reach this element (" + unavailable + ") and it has no click action");
    accessibility(node, AccessibilityNodeInfo.ACTION_CLICK, null, pkg, token);
    notice = "Touch unavailable (" + unavailable + "); used accessibility click fallback.";
  }

  private void shellTap(float x, float y, String pkg, long token) {
    checkTarget(token, pkg);
    int display = activeDisplay;
    ensureOpen();
    String[] tap =
        display == Display.DEFAULT_DISPLAY
            ? new String[] {"/system/bin/input", "tap", Integer.toString(Math.round(x)), Integer.toString(Math.round(y))}
            : new String[] {
              "/system/bin/input",
              "-d",
              String.valueOf(display),
              "tap",
              Integer.toString(Math.round(x)),
              Integer.toString(Math.round(y))
            };
    try {
      shell(tap);
      sent = true;
    } catch (IOException notStarted) {
      // The process never started, so nothing reached the phone.
      throw fail("INPUT_UNAVAILABLE", "the platform input tool could not start");
    } catch (Failure f) {
      if (f.code.equals("ENGINE_STOPPING")) throw f;
      throw unconfirmed("platform input tool: " + f.getMessage());
    } catch (Exception e) {
      throw unconfirmed("the platform input tool was interrupted");
    }
  }

  /**
   * Refuses to start input once shutdown began. Called after the route has been read and right
   * before the first injection: a check that ran earlier may have blocked while the route changed.
   */
  private void ensureOpen() {
    if (closed) throw fail("ENGINE_STOPPING", "Stdin closed; nothing sent");
  }

  /** The input may have been delivered: never repeat it, and require a fresh read. */
  private Failure unconfirmed(String why) {
    sent = true;
    observationRequired = true;
    return fail(
        "ACTION_UNCONFIRMED",
        "Input may have been delivered (" + why + "). Outcome unknown; read state and do not repeat"
            + " automatically.");
  }

  private void waitForElementFocus(Element target, String pkg, long token) {
    long deadline = SystemClock.uptimeMillis() + 1500;
    while (SystemClock.uptimeMillis() < deadline) {
      Screen current = observe(pkg);
      boolean focused =
          current.elements.values().stream()
              .anyMatch(
                  element ->
                      element.focused
                          && element.editable
                          && element.path.equals(target.path)
                          && element.id.equals(target.id));
      if (focused) return;
      pause(50, token);
    }
  }

  private AccessibilityNodeInfo focused(Screen s) {
    for (Element e : s.elements.values())
      if (e.focused && e.editable && e.pkg.equals(s.target)) return nodes.get(e.index);
    throw fail(
        "NO_FOCUSED_ELEMENT",
        "No focused editable field in target app; click the intended field first. Nothing sent");
  }

  private void setText(AccessibilityNodeInfo n, String value, String pkg, long token) {
    if (!n.isEditable() || !hasAction(n, AccessibilityNodeInfo.ACTION_SET_TEXT))
      throw fail("VALUE_NOT_SETTABLE", "Observed editor does not expose set_text");
    Bundle b = new Bundle();
    b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
    accessibility(n, AccessibilityNodeInfo.ACTION_SET_TEXT, b, pkg, token);
  }

  private void key(String key, double seconds, String pkg, long token) {
    int code;
    switch (key.toLowerCase(Locale.ROOT)) {
      case "back":
        code = KeyEvent.KEYCODE_BACK;
        break;
      case "home":
        code = KeyEvent.KEYCODE_HOME;
        break;
      case "enter":
      case "return":
        code = KeyEvent.KEYCODE_ENTER;
        break;
      case "delete":
      case "backspace":
        code = KeyEvent.KEYCODE_DEL;
        break;
      case "tab":
        code = KeyEvent.KEYCODE_TAB;
        break;
      case "recents":
      case "app_switch":
        code = KeyEvent.KEYCODE_APP_SWITCH;
        break;
      case "search":
        code = KeyEvent.KEYCODE_SEARCH;
        break;
      default:
        throw fail("INVALID_ARGUMENT", "Unsupported Android key");
    }
    checkTarget(token, pkg);
    if (!displayInputAvailable())
      throw fail("INPUT_UNAVAILABLE", "display-targeted key injection is unavailable");
    UiAutomation via = automation;
    int display = activeDisplay;
    ensureOpen();
    long down = SystemClock.uptimeMillis();
    boolean pressed = false, completed = false;
    try {
      pressed = true;
      sent = true;
      sendKey(via, display, down, down, KeyEvent.ACTION_DOWN, code, 0);
      pause((long) (seconds * 1000), token);
      checkTarget(token, pkg);
      completed = true;
    } finally {
      if (pressed)
        sendKey(
            via,
            display,
            down,
            SystemClock.uptimeMillis(),
            KeyEvent.ACTION_UP,
            code,
            completed ? 0 : KeyEvent.FLAG_CANCELED);
    }
  }

  private void addNotice(String text) {
    notice = notice.isEmpty() ? text : notice + " " + text;
  }

  /**
   * Inserts {@code value} at the focused editor's selection with accessibility set-text, then checks
   * the editor. The clipboard is never used, and nothing is sent another way.
   */
  private void insertText(AccessibilityNodeInfo n, String value, String pkg, long token) {
    if (n.isPassword()) {
      replacePassword(n, value, pkg, token);
      return;
    }
    String before = n.isShowingHintText() ? "" : str(n.getText());
    int a = n.getTextSelectionStart(), b = n.getTextSelectionEnd();
    if (a < 0 || b < 0 || a > before.length() || b > before.length()) a = b = before.length();
    int start = Math.min(a, b);
    String expected = before.substring(0, start) + value + before.substring(Math.max(a, b));
    setText(n, expected, pkg, token);
    // Set-text leaves the caret at the end; put it after the insertion so typing continues there.
    int caret = start + value.length();
    if (caret != expected.length() && !placeCaret(n, caret, pkg, token))
      addNotice(
          "The caret could not be placed after the inserted text; it may be at the end of the"
              + " field.");
    Screen after = observe(pkg);
    String actual = focusedText(after);
    boolean reacted = actual == null && after.content().contains(value);
    if (!Core.textInputSatisfied(expected, actual, reacted))
      throw fail(
          "TEXT_INPUT_FAILED",
          "Focused editable did not contain the requested text after input; no app reaction was observed");
  }

  /**
   * Android reports a password's characters masked, so its value cannot be spliced. An empty
   * password field, or one whose whole value is selected, is set to {@code value} and checked by
   * length only; any other password field is refused before anything is sent.
   */
  private void replacePassword(AccessibilityNodeInfo n, String value, String pkg, long token) {
    String shown = n.isShowingHintText() ? "" : str(n.getText());
    int a = n.getTextSelectionStart(), b = n.getTextSelectionEnd();
    boolean whole = shown.isEmpty() || (Math.min(a, b) == 0 && Math.max(a, b) == shown.length());
    if (!whole)
      throw fail(
          "PASSWORD_INSERT_UNSUPPORTED",
          "The focused password field already has text, which Android reports only masked, so"
              + " nothing can be inserted into it; use set_value to replace the whole value."
              + " Nothing sent");
    setText(n, value, pkg, token);
    String actual = focusedText(observe(pkg));
    if (actual == null || actual.length() != value.length())
      throw fail(
          "TEXT_INPUT_FAILED",
          "The password field's length after input does not match the requested text");
    addNotice("Password field: its whole value was set and checked by length only.");
  }

  /** Moves the caret to {@code at}; an unconfirmed move is reported by the caller, never repeated. */
  private boolean placeCaret(AccessibilityNodeInfo n, int at, String pkg, long token) {
    if (!hasAction(n, AccessibilityNodeInfo.ACTION_SET_SELECTION)) return false;
    Bundle b = new Bundle();
    b.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, at);
    b.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, at);
    checkTarget(token, pkg);
    ensureOpen();
    sent = true;
    boolean placed = n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, b);
    check(token, false);
    return placed;
  }

  private String focusedText(Screen s) {
    try {
      AccessibilityNodeInfo n = focused(s);
      return n.isShowingHintText() ? "" : str(n.getText());
    } catch (Failure e) {
      return null;
    }
  }

  private void perform(
      String method,
      Map<String, Object> args,
      String pkg,
      Screen base,
      Screen fence,
      Capture cap,
      long token) {
    check(token, false);
    if (method.equals("wait")) {
      pause(((Number) args.get("ms")).longValue(), token);
      return;
    }
    // Settle first, then read: the element is revalidated on the tree that receives the input.
    if (method.equals("click") && args.containsKey("element_index")) settleAfterInput(token);
    // Every step reads afresh; a fence from an earlier step can be stale by now.
    Screen now = observe(pkg);
    String unexpected = Core.stopReason(fence, now, pkg);
    if (unexpected != null)
      throw fail(
          unexpected.equals("app_switched") ? "APP_SWITCHED" : "POPUP",
          "Screen changed since observation: " + unexpected);
    AccessibilityNodeInfo n = null;
    Element old = null, target = null;
    if (args.containsKey("element_index")) {
      old = base.elements.get(((Number) args.get("element_index")).intValue());
      target = live(old, base, now);
      n = nodes.get(target.index);
    }
    checkTarget(token, pkg);
    switch (method) {
      case "click":
        {
          int count = ((Number) args.getOrDefault("click_count", 1)).intValue();
          double seconds = ((Number) args.getOrDefault("duration", 0)).doubleValue();
          if (n != null) {
            clickElement(n, target, now, pkg, token, count, seconds);
          } else {
            float[] p = point(args, "x", "y", cap, now);
            for (int i = 0; i < count; i++) {
              touch(
                  p[0],
                  p[1],
                  p[0],
                  p[1],
                  seconds > 0 ? Math.max(600, (long) (seconds * 1000)) : 45,
                  pkg,
                  token);
              if (i < count - 1) pause(70, token);
            }
          }
          break;
        }
      case "drag":
        {
          float[] f = point(args, "from_x", "from_y", cap, now),
              t = point(args, "to_x", "to_y", cap, now);
          touch(f[0], f[1], t[0], t[1], 450, pkg, token);
          break;
        }
      case "scroll":
        {
          String d = ((String) args.get("direction")).substring(0, 1);
          double pages = ((Number) args.getOrDefault("pages", 1)).doubleValue();
          int requested = (int) Math.ceil(pages), moved = 0;
          // Why the pages ended early other than at the list's end; worded as a plain fact.
          String stopped = null;
          // How the pages were sent when not by the element's own scroll action.
          String path = null;
          // Rows on the pages scrolled past, in order and distinct.
          Set<String> passed = new LinkedHashSet<>();
          Screen current = now;
          // What an indexed scroll moves, as found in current: the element when it scrolls,
          // otherwise the nearest scrolling element enclosing it. It is followed from page to
          // page even when its path, bounds or text change (a collapsing toolbar, a wheel's value).
          Element scope = null;
          if (n != null) {
            scope = scrollScope(target, now);
            if (scope == null)
              throw fail(
                  "ACTION_UNSUPPORTED",
                  "Neither the element nor an element enclosing it scrolls; nothing sent");
          }
          for (int page = 0; page < requested; page++) {
            if (page > 0
                && batchDeadline > 0
                && SystemClock.uptimeMillis() + Core.SCROLL_PAGE_MS > batchDeadline) {
              stopped = "stopped at the batch time limit";
              break;
            }
            if (page > 0) {
              Screen previous = current;
              current = observe(pkg);
              String changed = Core.stopReason(fence, current, pkg);
              if (changed != null) throw fail("POPUP", "Window changed during scroll: " + changed);
              if (scope != null) {
                scope = Core.follow(previous, scope, current);
                if (scope == null) {
                  stopped = "the scrolled element was not found on the new screen, so the rest were not sent";
                  break;
                }
              }
            }
            // Indexed: the element's own scroll action that way, else the direction's action of
            // the nearest scrolling element enclosing it, else a swipe inside its visible part.
            Element acted = scope;
            int action = 0;
            float[] swipe = null;
            if (scope != null) {
              action = scrollAction(nodes.get(scope.index), d, false);
              if (action == 0) {
                acted = scrollingAncestor(scope, current);
                if (acted != null) action = scrollAction(nodes.get(acted.index), d, true);
                if (action != 0) path = "the scroll-" + direction(d) + " action of an enclosing element";
              }
              if (action == 0) {
                swipe = swipe(scope, current, d);
                if (swipe == null) {
                  if (page == 0)
                    throw fail(
                        "ACTION_UNSUPPORTED",
                        "The element offers no scroll-" + direction(d) + " action and too little of it"
                            + " is visible to swipe; nothing sent");
                  stopped = "too little of the element is visible to swipe, so the rest were not sent";
                  break;
                }
                path = "a touch swipe inside the element (it offers no scroll-" + direction(d) + " action)";
              }
            }
            String before = Core.scrollContent(current, scope);
            List<String> rows = Core.rows(current, scope);
            checkTarget(token, pkg);
            if (action != 0) {
              ensureOpen();
              sent = true;
              // The result is not evidence either way; the list's content decides below.
              nodes.get(acted.index).performAction(action, null);
              check(token, false);
            } else if (swipe != null) {
              touch(swipe[0], swipe[1], swipe[2], swipe[3], SWIPE_MS, SWIPE_HOLD_MS, pkg, token);
            } else {
              float[] p = point(args, "x", "y", cap, now);
              float dx = d.equals("l") ? now.width * .55f : d.equals("r") ? -now.width * .55f : 0,
                  dy = d.equals("u") ? now.height * .55f : d.equals("d") ? -now.height * .55f : 0;
              float tx = Math.max(1, Math.min(now.width - 2, p[0] + dx)),
                  ty = Math.max(1, Math.min(now.height - 2, p[1] + dy));
              touch(p[0], p[1], tx, ty, 350, pkg, token);
            }
            Page result =
                scrolled(
                    before, current, scope, pkg, token,
                    action != 0 ? Core.SCROLL_QUIET_ACTION_MS : Core.SCROLL_QUIET_TOUCH_MS);
            if (!result.moved) break;
            moved++;
            passed.addAll(rows);
            if (scope != null) {
              current = result.after;
              scope = result.scope;
              if (scope == null) {
                stopped = "the scrolled element was not found on the new screen, so the rest were not sent";
                break;
              }
            }
          }
          if (moved < requested)
            addNotice(
                stopped != null
                    ? "Scrolled " + moved + " of " + requested + " pages; " + stopped
                    : Core.scrollNotice(moved, requested));
          if (path != null) addNotice("Scrolled with " + path + ".");
          if (requested > 1) passedOver += Core.passedOver(passed);
          break;
        }
      case "press_key":
        key(
            (String) args.get("key"),
            ((Number) args.getOrDefault("duration", .05)).doubleValue(),
            pkg,
            token);
        break;
      case "set_value":
        setText(n, (String) args.get("value"), pkg, token);
        break;
      case "type_text":
        insertText(focused(now), (String) args.get("text"), pkg, token);
        break;
      case "paste":
        insertText(focused(now), (String) args.get("text"), pkg, token);
        break;
      case "perform_secondary_action":
        {
          String name = (String) args.get("action");
          Integer action = old.actions.get(name);
          if (action == null)
            throw fail("ACTION_UNSUPPORTED", "Action was not listed on that element in the latest state");
          // The name carries the action's label: a reused id with a new meaning is not this action.
          if (!action.equals(target.actions.get(name)))
            throw fail("STALE_ELEMENT", "The element's secondary actions changed; nothing sent");
          if (!hasAction(n, action))
            throw fail("ACTION_UNSUPPORTED", "Action is no longer available");
          accessibility(n, action, null, pkg, token);
          break;
        }
      default:
        throw fail("METHOD_NOT_FOUND", "Unknown action");
    }
    // Standalone calls settle in afterAction; batches observe the post-action fence directly
    // to avoid paying a second idle wait for every quickly settling step.
  }

  /** Platform ids of the generic and direction-specific accessibility scroll actions. */
  private static final int FORWARD = AccessibilityNodeInfo.ACTION_SCROLL_FORWARD,
      BACKWARD = AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD,
      UP = android.R.id.accessibilityActionScrollUp,
      DOWN = android.R.id.accessibilityActionScrollDown,
      LEFT = android.R.id.accessibilityActionScrollLeft,
      RIGHT = android.R.id.accessibilityActionScrollRight;

  /** A scroll swipe moves for this long, then holds still before lifting so the list does not fling. */
  static final long SWIPE_MS = 300, SWIPE_HOLD_MS = 120;

  /** A swipe needs at least this many visible pixels along its axis. */
  static final int SWIPE_MIN_PX = 150;

  private static String direction(String d) {
    return d.equals("d") ? "down" : d.equals("u") ? "up" : d.equals("l") ? "left" : "right";
  }

  /** Whether {@code n} scrolls: it says so, or it offers a scroll action. */
  private boolean scrolls(AccessibilityNodeInfo n) {
    if (n == null) return false;
    if (n.isScrollable()) return true;
    for (int id : new int[] {FORWARD, BACKWARD, UP, DOWN, LEFT, RIGHT}) if (hasAction(n, id)) return true;
    return false;
  }

  /** The nearest element of {@code s} that encloses {@code e} in its window and scrolls, or null. */
  private Element scrollingAncestor(Element e, Screen s) {
    Element nearest = null;
    for (Element c : s.elements.values())
      if (c.window == e.window
          && e.path.startsWith(c.path + "/")
          && scrolls(nodes.get(c.index))
          && (nearest == null || c.path.length() > nearest.path.length())) nearest = c;
    return nearest;
  }

  /** What an indexed scroll moves: the element when it scrolls, else the nearest scrolling ancestor. */
  private Element scrollScope(Element e, Screen s) {
    return scrolls(nodes.get(e.index)) ? e : scrollingAncestor(e, s);
  }

  /**
   * The accessibility action that scrolls {@code n} in direction {@code d}, or 0. The
   * direction-specific action always matches. Generic forward/backward is taken as down/right and
   * up/left only on the element itself ({@code directionalOnly} false), and not when it offers
   * direction-specific actions on the other axis alone: on an enclosing element it is ambiguous,
   * since a horizontal pager's backward is left.
   */
  private int scrollAction(AccessibilityNodeInfo n, String d, boolean directionalOnly) {
    int wanted = d.equals("d") ? DOWN : d.equals("u") ? UP : d.equals("l") ? LEFT : RIGHT;
    if (hasAction(n, wanted)) return wanted;
    if (directionalOnly) return 0;
    boolean vertical = d.equals("d") || d.equals("u");
    boolean thisAxis = vertical ? hasAction(n, UP) || hasAction(n, DOWN) : hasAction(n, LEFT) || hasAction(n, RIGHT);
    boolean otherAxis = vertical ? hasAction(n, LEFT) || hasAction(n, RIGHT) : hasAction(n, UP) || hasAction(n, DOWN);
    if (otherAxis && !thisAxis) return 0;
    int generic = d.equals("d") || d.equals("r") ? FORWARD : BACKWARD;
    return hasAction(n, generic) ? generic : 0;
  }

  /**
   * A swipe {x0, y0, x1, y1} from 80% to 20% of the visible, uncovered part of {@code e} along the
   * direction's axis, through its centre, that scrolls it in direction {@code d}; or null when too
   * little of it is visible. Windows above it (keyboard, dialogs) are cut away, and the display's
   * outer strips, where system gestures start, are avoided.
   */
  private float[] swipe(Element e, Screen s, String d) {
    Window owner = null;
    for (Window w : s.windows) if (w.id == e.window) owner = w;
    if (owner == null) return null;
    int left = Math.max(Math.max(e.left, 0), owner.left),
        top = Math.max(Math.max(e.top, 0), owner.top),
        right = Math.min(Math.min(e.right, s.width), owner.right),
        bottom = Math.min(Math.min(e.bottom, s.height), owner.bottom);
    List<Window> above = new ArrayList<>();
    for (Window w : s.windows)
      if (w.layer > owner.layer
          && w.id != owner.id
          && (w.active || w.focused || w.type != AccessibilityWindowInfo.TYPE_SYSTEM)) above.add(w);
    for (Window w : above) {
      if (w.right <= left || w.left >= right || w.bottom <= top || w.top >= bottom) continue;
      if (w.left <= left && w.right >= right) {
        if (w.top > top) bottom = Math.min(bottom, w.top);
        else top = Math.max(top, w.bottom);
      } else if (w.top <= top && w.bottom >= bottom) {
        if (w.left > left) right = Math.min(right, w.left);
        else left = Math.max(left, w.right);
      }
    }
    boolean vertical = d.equals("d") || d.equals("u");
    if (vertical) {
      top = Math.max(top, Math.round(s.height * .06f));
      bottom = Math.min(bottom, Math.round(s.height * .94f));
    } else {
      left = Math.max(left, Math.round(s.width * .1f));
      right = Math.min(right, Math.round(s.width * .9f));
    }
    if (right <= left || bottom <= top || (vertical ? bottom - top : right - left) < SWIPE_MIN_PX)
      return null;
    float cx = (left + right) / 2f, cy = (top + bottom) / 2f;
    float near = vertical ? top + (bottom - top) * .2f : left + (right - left) * .2f,
        far = vertical ? top + (bottom - top) * .8f : left + (right - left) * .8f;
    // Down and right move the finger toward the start of the axis, revealing what follows.
    boolean onward = d.equals("d") || d.equals("r");
    float from = onward ? far : near, to = onward ? near : far;
    float[] p = vertical ? new float[] {cx, from, cx, to} : new float[] {from, cy, to, cy};
    for (Window w : above)
      for (int i = 0; i <= 2; i++) {
        float x = p[0] + (p[2] - p[0]) * i / 2, y = p[1] + (p[3] - p[1]) * i / 2;
        if (w.left <= x && x < w.right && w.top <= y && y < w.bottom) return null;
      }
    return p;
  }

  /** A scroll page's outcome: whether it moved, the settled screen and the scope as found in it. */
  private static final class Page {
    final boolean moved;
    final Screen after;
    final Element scope;

    Page(boolean moved, Screen after, Element scope) {
      this.moved = moved;
      this.after = after;
      this.scope = scope;
    }
  }

  /**
   * Waits for a scroll page to show and settle, and compares the settled content with {@code
   * before}, the content of {@code scope} in {@code seen} (the screen, for coordinates). The page
   * has not moved when the content ends as it was, also after a bounce. A scope that can no longer
   * be followed counts as moved; the caller ends the pages there. Unchanged content is watched for
   * {@code quietMs}; changed content until two reads {@link Core#SCROLL_SETTLED_MS} apart agree.
   * One page waits at most {@link Core#SCROLL_PAGE_MS}, and never past the batch deadline.
   */
  private Page scrolled(
      String before, Screen seen, Element scope, String pkg, long token, long quietMs) {
    long start = SystemClock.uptimeMillis(), end = start + Core.SCROLL_PAGE_MS;
    if (batchDeadline > 0) end = Math.min(end, batchDeadline);
    String last = before;
    long since = start;
    boolean changed = false;
    Screen after;
    Element followed;
    do {
      pause(40, token);
      try {
        after = observe(pkg);
      } catch (RuntimeException e) {
        throw unconfirmed("the list could not be read after scrolling");
      }
      followed = scope == null ? null : Core.follow(seen, scope, after);
      String content =
          scope == null
              ? Core.scrollContent(after, null)
              : followed == null ? "gone\n" + after.fingerprint() : Core.scrollContent(after, followed);
      long now = SystemClock.uptimeMillis();
      if (!content.equals(last)) {
        last = content;
        since = now;
        changed |= !content.equals(before);
      } else if (changed ? now - since >= Core.SCROLL_SETTLED_MS : now - start >= quietMs) break;
    } while (SystemClock.uptimeMillis() < end);
    return new Page(!last.equals(before), after, followed);
  }

  void settleAfterInput(long token) {
    check(token, false);
    waitIdle();
  }

  void waitIdle() {
    try {
      automation.waitForIdle(30, 180);
    } catch (TimeoutException ignored) {
      // The bounded fallback below still provides a stable observation without blocking input.
    }
  }

  /** Calls, idle stops and shutdown take turns; shutdown waits a bounded time for a call. */
  private final ReentrantLock callLock = new ReentrantLock();
  /** The connection's serialized execution context, where the idle timer also runs. */
  private ScheduledExecutorService serial;
  private ScheduledFuture<?> idleTimer;
  private boolean idleStopped;

  void runOn(ScheduledExecutorService serial) {
    this.serial = serial;
  }

  public Map<String, Object> call(String name, Map<String, Object> args) throws Exception {
    callLock.lock();
    try {
      if (closed) throw fail("ENGINE_STOPPING", "Stdin closed");
      if (idleTimer != null) idleTimer.cancel(false);
      boolean statusCall = name.equals("agent_desktop") && "status".equals(args.get("action"));
      if (idleExpired()) stopIdleDesktop();
      if (!name.equals("agent_desktop") && idleStopped) {
        idleStopped = false;
        throw fail(
            "AGENT_DESKTOP_IDLE_STOPPED",
            "The Android agent display stopped after five idle minutes");
      }
      if (!statusCall) lastCallAt = SystemClock.uptimeMillis();
      try {
        return dispatch(name, args);
      } finally {
        if (!statusCall) lastCallAt = SystemClock.uptimeMillis();
        armIdleTimer();
      }
    } finally {
      callLock.unlock();
    }
  }

  private boolean idleExpired() {
    return desktopDisplay >= 0 && SystemClock.uptimeMillis() - lastCallAt >= desktopIdleMs;
  }

  private void stopIdleDesktop() {
    stopDesktop();
    idleStopped = true;
  }

  /** Schedules the idle stop on the serialized context, so it never runs during a call. */
  private void armIdleTimer() {
    if (serial == null || closed || desktopDisplay < 0) return;
    long delay = Math.max(0, desktopIdleMs - (SystemClock.uptimeMillis() - lastCallAt));
    try {
      idleTimer = serial.schedule(this::idleCheck, delay, TimeUnit.MILLISECONDS);
    } catch (java.util.concurrent.RejectedExecutionException shuttingDown) {
      // The worker is gone; connection shutdown releases the display.
    }
  }

  private void idleCheck() {
    callLock.lock();
    try {
      if (closed || desktopDisplay < 0) return;
      if (idleExpired()) stopIdleDesktop();
      else armIdleTimer();
    } finally {
      callLock.unlock();
    }
  }

  private Map<String, Object> dispatch(String name, Map<String, Object> args) throws Exception {
    long callStart = SystemClock.uptimeMillis();
    batchDeadline = 0;
    if (name.equals("agent_desktop")) return desktopCall(args);
    if (routeLost != null) throw fail("DISPLAY_UNAVAILABLE", routeLost);
    if (name.equals("list_apps")) return apps();
    Capture cap = coordinates;
    coordinates = null;
    notice = "";
    passedOver = "";
    sent = false;
    long token = person.token();
    if (!name.equals("get_app_state")) check(token, false);
    String pkg = resolve((String) args.get("app"));
    boolean screenshot = Boolean.TRUE.equals(args.get("includeScreenshot"));
    if (name.equals("get_app_state") || name.equals("activate_app")) {
      boolean inputCall = name.equals("activate_app") || !foreground()[0].equals(pkg);
      if (inputCall) activate(pkg, token);
      Screen s = readReady(pkg, token, inputCall);
      if (args.containsKey("waitForText")) {
        long start = SystemClock.uptimeMillis(),
            limit = ((Number) args.getOrDefault("waitTimeoutMs", 5000)).longValue();
        while (!s.waitContent().contains((String) args.get("waitForText"))) {
          if (SystemClock.uptimeMillis() - start >= limit) {
            Map<String, Object> r = checkedResult(s, screenshot, inputCall, token);
            r.put("isError", true);
            r.put("_meta", obj("opencu/error", "WAIT_TIMEOUT"));
            map(list(r.get("content")).get(0))
                .put("text", "WAIT_TIMEOUT: Expected text did not appear\n" + s.text());
            return r;
          }
          if (inputCall) check(token, false);
          if (closed) throw fail("ENGINE_STOPPING", "Stdin closed");
          SystemClock.sleep(50);
          s = observe(pkg);
        }
      }
      return checkedResult(s, screenshot, inputCall, token);
    }
    check(token, false);
    if (latest == null || !latest.target.equals(pkg) || observationRequired)
      throw fail("OBSERVATION_REQUIRED", "Read get_app_state for this app before input");
    Screen base = latest;
    try {
      if (!foreground()[0].equals(pkg)) {
        check(token, true);
        // Revalidate retained indexes before any implicit foreground change.
        if (args.containsKey("element_index"))
          live(base.elements.get(((Number) args.get("element_index")).intValue()), base, observe(pkg));
        activate(pkg, token);
      }
      if (name.equals("run_actions")) return batch(args, pkg, base, cap, token, callStart);
      perform(name, args, pkg, base, base, cap, token);
      check(token, false);
      Map<String, Object> r =
          result(afterAction(base, pkg, token), Protocol.coordinates(name, args));
      check(token, false);
      return r;
    } catch (Failure e) {
      coordinates = null;
      e = priorityFailure(e, token);
      if (sent || e.code.equals("PERSON_ACTIVE") || e.code.equals("ACTION_UNCONFIRMED"))
        observationRequired = true;
      throw e;
    }
  }

  private Map<String, Object> desktopCall(Map<String, Object> args) {
    String action = (String) args.get("action");
    if (!action.equals("status")) idleStopped = false;
    if (action.equals("start")) {
      try {
        startDesktop();
      } catch (Failure e) {
        throw e;
      } catch (SecurityException e) {
        throw fail(
            "AGENT_DESKTOP_UNAVAILABLE",
            "Android refused virtual-display creation: " + e.getMessage());
      } catch (Exception e) {
        Throwable cause = e.getCause() == null ? e : e.getCause();
        throw fail(
            "AGENT_DESKTOP_UNAVAILABLE",
            cause.getClass().getSimpleName() + ": " + cause.getMessage());
      }
    } else if (action.equals("stop")) {
      stopDesktop();
    }
    Map<String, Object> status = new LinkedHashMap<>();
    status.put("started", desktopDisplay >= 0);
    status.put("displayId", desktopDisplay >= 0 ? desktopDisplay : null);
    if (desktopDisplay >= 0) {
      Point size = size();
      status.put("width", size.x);
      status.put("height", size.y);
      Map<String, Object> appResult = apps();
      Map<String, Object> appContent = map(list(appResult.get("content")).get(0));
      status.put("apps", Json.read((String) appContent.get("text")));
      status.put(
          "idleMsLeft", Math.max(0, desktopIdleMs - (SystemClock.uptimeMillis() - lastCallAt)));
      status.put(
          "flags",
          obj(
              "value",
              desktopFlags,
              "displayFlags",
              ownedDisplay.displayFlags,
              "trusted",
              (ownedDisplay.displayFlags & DISPLAY_TRUSTED) != 0,
              "ownFocus",
              (ownedDisplay.displayFlags & DISPLAY_OWN_FOCUS) != 0,
              "stealTopFocusDisabled",
              (ownedDisplay.displayFlags & DISPLAY_STEAL_TOP_FOCUS_DISABLED) != 0,
              "imePolicy",
              "local"));
    }
    return Protocol.textResult(Json.write(status));
  }

  private Screen afterAction(Screen before, String pkg, long token) {
    settleAfterInput(token);
    Screen current = observe(pkg);
    long end = SystemClock.uptimeMillis() + 450;
    String signature = current.fingerprint();
    long stableSince = SystemClock.uptimeMillis();
    while (SystemClock.uptimeMillis() < end) {
      SystemClock.sleep(25);
      Screen next = observe(pkg);
      String value = next.fingerprint();
      if (value.equals(signature) && SystemClock.uptimeMillis() - stableSince >= 50
          && !(next.elements.isEmpty() && next.foreground.equals(pkg))) return next;
      if (!value.equals(signature)) {
        signature = value;
        stableSince = SystemClock.uptimeMillis();
      }
      current = next;
    }
    return current;
  }

  private Failure priorityFailure(Failure original, long token) {
    try {
      check(token, false);
    } catch (Failure safety) {
      return safety;
    }
    return original;
  }

  /** When the running batch must end (uptime ms), or 0 outside a batch. */
  private long batchDeadline;

  /** The time a whole batch may take; the run_actions description states the same limit. */
  long batchLimitMs() {
    return Protocol.BATCH_LIMIT_MS;
  }

  private Map<String, Object> batch(
      Map<String, Object> args, String pkg, Screen base, Capture cap, long token, long callStart) {
    List<Object> actions = list(args.get("actions"));
    // The limit covers the whole call, including the reads before the batch.
    long batchStart = callStart;
    batchDeadline = callStart + batchLimitMs();
    String limitReached = "it could run past";
    Screen last = base;
    int step = 0, completed = 0;
    long waited = 0, started = 0;
    String activePackage = pkg;
    String reason = null;
    Failure failure = null;
    try {
      for (Object raw : actions) {
        Screen fence = last;
        step++;
        Map<String, Object> a = map(raw);
        String method = (String) a.get("method");
        if (SystemClock.uptimeMillis() - batchStart + Core.stepMaxMs(a) > batchLimitMs()) {
          // Nothing of this step is sent: it could run past the batch's time limit.
          reason = "time_limit";
          waited = 0;
          break;
        }
        Map<String, Object> until = a.containsKey("until") ? map(a.get("until")) : obj();
        String expected = until.containsKey("app") ? resolve((String) until.get("app")) : "";
        if (!expected.isEmpty()) {
          until = new LinkedHashMap<>(until);
          until.put("app", expected);
        }
        started = SystemClock.uptimeMillis();
        waited = 0;
        if (method.equals("wait")) {
          long end = SystemClock.uptimeMillis() + ((Number) a.get("ms")).longValue();
          do {
            pause(Math.min(40, Math.max(0, end - SystemClock.uptimeMillis())), token);
            last = observe(activePackage);
            reason = Core.stopReason(fence, last, expected);
            if (reason != null) break;
          } while (SystemClock.uptimeMillis() < end);
          if (reason != null) {
            waited = SystemClock.uptimeMillis() - started;
            break;
          }
      } else {
        perform(method, a, activePackage, base, fence, step == 1 ? cap : null, token);
        if (step == 1) pause(300, token);
      }
        // An until wait ends at the batch deadline at the latest.
        boolean cut = false;
        if (!until.isEmpty()) {
          long remaining = Math.max(0, batchDeadline - SystemClock.uptimeMillis());
          long timeout = ((Number) until.getOrDefault("timeoutMs", 8000)).longValue();
          if (remaining < timeout) {
            until = new LinkedHashMap<>(until);
            until.put("timeoutMs", remaining);
            cut = true;
          }
        }
        Core.Await wait = new Core.Await(fence, until, expected, SystemClock.uptimeMillis());
        while (true) {
          check(token, false);
          last = observe(activePackage);
          waited = SystemClock.uptimeMillis() - started;
          String decision = wait.poll(last, SystemClock.uptimeMillis());
          if (decision.equals("complete")) {
            completed++;
            break;
          }
          if (!decision.equals("continue")) {
            reason = decision;
            if (cut && decision.equals("timeout")) {
              reason = "time_limit";
              limitReached = "its until wait reached";
            }
            break;
          }
          pause(until.isEmpty() ? 10 : 40, token);
        }
        if (reason != null) break;
        // Only an explicit until.app can authorize the new foreground for later non-indexed input.
        if (!expected.isEmpty() && last.foreground.equals(expected)) {
          activePackage = expected;
          last.target = expected;
        }
      }
    } catch (Failure e) {
      e = priorityFailure(e, token);
      failure = e;
      reason = e.code.toLowerCase(Locale.ROOT);
      waited = started == 0 ? 0 : SystemClock.uptimeMillis() - started;
    }
    if (reason != null) {
      try {
        last = observe(activePackage);
        if (reason.equals("popup") || reason.equals("system_dialog")) {
          long end = SystemClock.uptimeMillis() + 500, unchanged = SystemClock.uptimeMillis();
          String fingerprint = last.fingerprint();
          while (SystemClock.uptimeMillis() < end && SystemClock.uptimeMillis() - unchanged < 120) {
            pause(35, token);
            Screen next = observe(activePackage);
            if (!next.fingerprint().equals(fingerprint)) {
              fingerprint = next.fingerprint();
              unchanged = SystemClock.uptimeMillis();
            }
            last = next;
          }
        }
      } catch (Failure safety) {
        failure = safety;
        reason = safety.code.toLowerCase(Locale.ROOT);
      }
      if (failure == null)
        failure =
            fail(
                reason.equals("timeout")
                    ? "WAIT_TIMEOUT"
                    : reason.equals("time_limit")
                        ? "BATCH_TIME_LIMIT"
                        : reason.equals("system_dialog")
                            ? "SYSTEM_DIALOG"
                            : reason.equals("popup") ? "POPUP" : "APP_SWITCHED",
                reason.equals("time_limit")
                    ? "Batch stopped at step " + step + ": " + limitReached + " the "
                        + batchLimitMs() / 1000 + " s batch limit; remaining steps were not sent"
                    : "Batch stopped; remaining steps were not sent");
    }
    batchDeadline = 0;
    Map<String, Object> r =
        result(last, Boolean.TRUE.equals(args.get("includeScreenshot")) && reason == null);
    try {
      check(token, false);
    } catch (Failure safety) {
      failure = safety;
      reason = safety.code.toLowerCase(Locale.ROOT);
      coordinates = null;
      list(r.get("content")).removeIf(c -> "image".equals(map(c).get("type")));
    }
    Map<String, Object> meta = r.containsKey("_meta") ? map(r.get("_meta")) : obj();
    Integer stoppedStep = reason == null ? null : step;
    if (failure != null && completed > 0 && (reason.equals("popup") || reason.equals("system_dialog")))
      stoppedStep = completed;
    meta.put(
        "opencu/batch",
        obj(
            "completed",
            completed,
            "stoppedStep",
            stoppedStep,
            "reason",
            reason,
            "waitedMs",
            waited));
    r.put("_meta", meta);
    String summary =
        "Batch: completed="
            + completed
            + " stoppedStep="
            + (reason == null ? "none" : stoppedStep)
            + " reason="
            + (reason == null ? "complete" : reason)
            + " waitedMs="
            + waited
            + "\n";
    if (failure != null) {
      summary = failure.code + ": " + failure.getMessage() + "\n" + summary;
      r.put("isError", true);
      meta.put("opencu/error", failure.code);
      if (failure.code.equals("PERSON_ACTIVE") || failure.code.equals("ACTION_UNCONFIRMED"))
        observationRequired = true;
    }
    Map<String, Object> first = map(list(r.get("content")).get(0));
    first.put("text", summary + first.get("text"));
    return r;
  }

  /**
   * Ends the connection: refuses further work, kills running platform clients, lets an in-flight
   * call unwind (bounded), then releases the displays. EOF must still finish within two seconds even
   * when a Binder call blocks.
   */
  public void close() {
    synchronized (this) {
      if (closed) return;
      closed = true;
    }
    if (monitor != null) monitor.close();
    stopCommands(300);
    boolean quiet = false;
    try {
      quiet = callLock.tryLock(1000, TimeUnit.MILLISECONDS);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
    try {
      if (idleTimer != null) idleTimer.cancel(false);
      // Display calls can block on Binder, so they run on a bounded thread. Route changes wait
      // for in-flight input; a gesture keeps its own target either way.
      Thread cleanup = new Thread(this::releaseRoutes, "opencu-close");
      cleanup.setDaemon(true);
      cleanup.start();
      try {
        cleanup.join(400);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    } finally {
      if (quiet) callLock.unlock();
    }
  }

  /** Releases the agent display and the main connection; may block on Binder. */
  void releaseRoutes() {
    stopDesktop();
    disconnectAutomation(mainAutomation);
    thread.quitSafely();
  }
}
