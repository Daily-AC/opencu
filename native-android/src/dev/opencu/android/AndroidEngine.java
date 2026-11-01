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
import android.os.*;
import android.util.DisplayMetrics;
import android.view.*;
import android.view.accessibility.*;
import dev.opencu.android.Core.Window;
import java.io.*;
import java.lang.Process;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Consumer;

final class AndroidEngine implements Protocol.Backend, AutoCloseable {
  private final HandlerThread thread;
  private UiAutomation automation;
  private UiAutomation mainAutomation;
  private UiAutomation desktopAutomation;
  private final Context context;
  private final ActivityManager activityManager;
  private final DisplayManager displays;
  private final PowerManager power;
  private final KeyguardManager keyguard;
  private final PersonMonitor monitor;
  private final Core.Person person;
  private final ShellClipboard clipboard;
  private final String monitorProblem;
  private final Field taskDisplay;
  private final Map<String, Object> hidden = obj();
  private volatile boolean closed;
  private Screen latest;
  private long sequence;
  private Capture coordinates;
  private final Map<Integer, AccessibilityNodeInfo> nodes = new HashMap<>();
  private String notice = "";
  private String keyboardInputFailure = "";
  private boolean observationRequired;
  private VirtualDisplay virtualDisplay;
  private Surface virtualSurface;
  private SurfaceTexture virtualTexture;
  private int activeDisplay = Display.DEFAULT_DISPLAY;
  private int desktopDisplay = -1;
  private int desktopFlags;
  private boolean desktopTrusted;
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
    final int width, height, displayWidth, displayHeight, rotation;
    final String windows;

    Capture(Screen s, int w, int h) {
      app = s.target;
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
    context = system;
    clipboard = new ShellClipboard(context);
    hidden.put("ActivityThread.systemMain/getSystemContext", true);
    taskDisplay = ActivityManager.RunningTaskInfo.class.getField("displayId");
    hidden.put("TaskInfo.displayId", true);
    activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
    displays = (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
    power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
    keyguard = (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
    thread = new HandlerThread("opencu-uia");
    thread.start();
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
    mainAutomation = automation;
    PersonMonitor connectedMonitor = null;
    String problem = "";
    long lastActivity = lastUserActivityTime();
    try {
      connectedMonitor = new PersonMonitor(output, lastActivity);
    } catch (Exception e) {
      problem = e.getMessage();
    }
    monitor = connectedMonitor;
    monitorProblem = problem;
    person = monitor == null ? new Core.Person(SystemClock.uptimeMillis()) : monitor.person;
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

  private UiAutomation createDisplayAutomation(int displayId) throws Exception {
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

  private void setImePolicy(int displayId) {
    try {
      Object manager =
          Class.forName("android.view.WindowManagerGlobal")
              .getMethod("getWindowManagerService")
              .invoke(null);
      manager
          .getClass()
          .getMethod("setDisplayImePolicy", int.class, int.class)
          .invoke(manager, displayId, 0); // DISPLAY_IME_POLICY_LOCAL
    } catch (Exception e) {
      hidden.put("WindowManager.setDisplayImePolicy", e.getClass().getSimpleName());
    }
  }

  private void startDesktop() throws Exception {
    if (desktopDisplay >= 0) return;
    String mainBefore = foregroundOnDisplay(Display.DEFAULT_DISPLAY);
    Point main = sizeFor(Display.DEFAULT_DISPLAY);
    Display mainDisplay = displays.getDisplay(Display.DEFAULT_DISPLAY);
    DisplayMetrics metrics = new DisplayMetrics();
    mainDisplay.getRealMetrics(metrics);
    virtualTexture = new SurfaceTexture(false);
    virtualTexture.setDefaultBufferSize(main.x, main.y);
    virtualSurface = new Surface(virtualTexture);
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
    try {
      virtualDisplay =
          displays.createVirtualDisplay(
              "OpenCU agent", main.x, main.y, metrics.densityDpi, virtualSurface, requested);
      desktopTrusted = true;
      desktopFlags = requested;
    } catch (SecurityException denied) {
      int fallback =
          FLAG_PUBLIC
              | FLAG_OWN_CONTENT_ONLY
              | FLAG_SUPPORTS_TOUCH
              | FLAG_ROTATES_WITH_CONTENT
              | FLAG_DESTROY_CONTENT_ON_REMOVAL;
      virtualDisplay =
          displays.createVirtualDisplay(
              "OpenCU agent", main.x, main.y, metrics.densityDpi, virtualSurface, fallback);
      desktopTrusted = false;
      desktopFlags = fallback;
    }
    desktopDisplay = virtualDisplay.getDisplay().getDisplayId();
    setImePolicy(desktopDisplay);
    try { UiAutomation.class.getDeclaredMethod("disconnect").invoke(mainAutomation); }
    catch (Exception ignored) { }
    desktopAutomation = createDisplayAutomation(desktopDisplay);
    automation = desktopAutomation;
    activeDisplay = desktopDisplay;
    mainForegroundBeforeDesktop = mainBefore;
    desktopStartedAt = SystemClock.uptimeMillis();
    lastCallAt = desktopStartedAt;
    hidden.put("virtualDisplayFlags", desktopFlags);
    hidden.put("virtualDisplayTrusted", desktopTrusted);
    hidden.put("virtualDisplayOwnFocus", (desktopFlags & FLAG_OWN_FOCUS) != 0);
  }

  private void stopDesktop() {
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
    if (virtualDisplay != null) virtualDisplay.release();
    if (virtualSurface != null) virtualSurface.release();
    if (virtualTexture != null) virtualTexture.release();
    virtualDisplay = null;
    virtualSurface = null;
    virtualTexture = null;
    if (desktopAutomation != null) {
      try { UiAutomation.class.getDeclaredMethod("disconnect").invoke(desktopAutomation); }
      catch (Exception ignored) { }
    }
    desktopAutomation = null;
    try { mainAutomation = createDisplayAutomation(Display.DEFAULT_DISPLAY); }
    catch (Exception e) { throw fail("DISPLAY_UNAVAILABLE", "Could not restore main-display UiAutomation: " + e.getMessage()); }
    desktopDisplay = -1;
    activeDisplay = Display.DEFAULT_DISPLAY;
    automation = mainAutomation;
    mainForegroundBeforeDesktop = null;
    latest = null;
    coordinates = null;
    observationRequired = false;
  }

  static String command(String... args) throws Exception {
    Process p = new ProcessBuilder(args).redirectErrorStream(true).start();
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
    if (!p.waitFor(5, TimeUnit.SECONDS)) {
      p.destroyForcibly();
      throw fail("RUNTIME_ERROR", "Android command timed out");
    }
    drain.join(1000);
    String text = out.toString(StandardCharsets.UTF_8.name());
    if (p.exitValue() != 0) throw fail("RUNTIME_ERROR", "Android command failed: " + text.trim());
    return text;
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

  private String[] foreground() {
    for (ActivityManager.RunningTaskInfo task : activityManager.getRunningTasks(20))
      if (taskOnDisplay(task, activeDisplay) && task.topActivity != null)
        return new String[] {
          task.topActivity.getPackageName(), task.topActivity.flattenToShortString()
        };
    if (activeDisplay != Display.DEFAULT_DISPLAY) return new String[] {"", ""};
    throw fail("WINDOW_NOT_FOUND", "Cannot establish main-display foreground activity");
  }

  private String foregroundOnDisplay(int displayId) {
    for (ActivityManager.RunningTaskInfo task : activityManager.getRunningTasks(20))
      if (taskOnDisplay(task, displayId) && task.topActivity != null)
        return task.topActivity.getPackageName();
    return "";
  }

  private String resolve(String name) {
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

  private void check(long token, boolean changing) {
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
    Intent launch = context.getPackageManager().getLaunchIntentForPackage(pkg);
    if (launch == null) throw fail("LAUNCH_FAILED", "No launcher activity for " + pkg);
    // am is a platform shell client; package/component comes from PackageManager, never
    // interpolated shell text.
    check(token, true);
    command(
        "/system/bin/am",
        "start",
        "--display",
        Integer.toString(activeDisplay),
        "-n",
        launch.getComponent().flattenToString(),
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

  private static String windowIdentity(Screen s) {
    StringBuilder b = new StringBuilder();
    for (Window w : s.windows)
      b.append(w.id).append(':').append(w.type).append(':').append(w.pkg).append(';');
    return b.toString();
  }

  private Screen observe(String target) {
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

  private AccessibilityNodeInfo live(Element old, Screen now) {
    if (old == null)
      throw fail("STALE_ELEMENT", "Element index was not in the last returned state");
    for (Element e : now.elements.values())
      if (old.same(e)) {
        if (!e.enabled) throw fail("ELEMENT_DISABLED", "Element is disabled");
        return nodes.get(e.index);
      }
    String detail = "";
    if (old != null) {
      for (Element candidate : now.elements.values()) {
        if (old.id.equals(candidate.id) && old.clazz.equals(candidate.clazz)) {
          detail = " old=" + old.path + "/" + old.text + "/" + old.left + "," + old.top
              + " current=" + candidate.path + "/" + candidate.text + "/" + candidate.left + "," + candidate.top;
          break;
        }
      }
    }
    throw fail("STALE_ELEMENT", "Observed element changed class, text/id, path or bounds; nothing sent" + detail);
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
      else {
        try { automation.waitForIdle(30, 180); }
        catch (TimeoutException ignored) { }
      }
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

  private Map<String, Object> result(Screen s, boolean screenshot) {
    latest = s;
    observationRequired = false;
    coordinates = null;
    Map<String, Object> r = Protocol.textResult((notice.isEmpty() ? "" : notice + "\n") + s.text());
    notice = "";
    if (screenshot) {
      Bitmap bitmap;
      try {
        bitmap =
            activeDisplay == Display.DEFAULT_DISPLAY || desktopAutomation != null
                ? automation.takeScreenshot()
                : (Bitmap)
                    UiAutomation.class
                        .getMethod("takeScreenshot", int.class)
                        .invoke(automation, activeDisplay);
      } catch (Exception e) {
        throw fail(
            "SCREENSHOT_FAILED",
            "Screenshot on display " + activeDisplay + " failed: " + e.getClass().getSimpleName());
      }
      if (bitmap == null)
        throw fail("SCREENSHOT_FAILED", "Screenshot unavailable (secure content is not bypassed)");
      int ow = bitmap.getWidth(), oh = bitmap.getHeight();
      if (ow != s.width || oh != s.height) {
        bitmap.recycle();
        throw fail("STALE_SCREENSHOT", "Display geometry changed during capture");
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
      coordinates = new Capture(s, w, h);
      r.put(
          "_meta",
          obj("opencu/screenshot", obj("width", w, "height", h, "display", activeDisplay)));
    }
    return r;
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
    actionConfirmed(n.performAction(action, args));
    check(token, false);
  }

  private void inject(InputEvent event) {
    actionConfirmed(automation.injectInputEvent(event, true));
  }

  private void touch(float x, float y, float tx, float ty, long duration, String pkg, long token) {
    checkTarget(token, pkg);
    long down = SystemClock.uptimeMillis();
    boolean pressed = false;
    try {
      pressed = true;
      motion(down, MotionEvent.ACTION_DOWN, x, y);
      long end = down + duration;
      while (SystemClock.uptimeMillis() < end) {
        pause(Math.min(16, end - SystemClock.uptimeMillis()), token);
        checkTarget(token, pkg);
        float f = Math.min(1, (SystemClock.uptimeMillis() - down) / (float) Math.max(1, duration));
        if (x != tx || y != ty)
          motion(down, MotionEvent.ACTION_MOVE, x + (tx - x) * f, y + (ty - y) * f);
      }
      checkTarget(token, pkg);
      motion(down, MotionEvent.ACTION_UP, tx, ty);
      pressed = false;
    } finally {
      if (pressed) motion(down, MotionEvent.ACTION_CANCEL, x, y);
    }
  }

  private void motion(long down, int action, float x, float y) {
    MotionEvent e = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0);
    e.setSource(InputDevice.SOURCE_TOUCHSCREEN);
    setEventDisplay(e);
    try {
      inject(e);
    } finally {
      e.recycle();
    }
  }

  private void setEventDisplay(InputEvent event) {
    try {
      InputEvent.class.getMethod("setDisplayId", int.class).invoke(event, activeDisplay);
    } catch (Exception e) {
      throw fail("INPUT_UNAVAILABLE", "Android did not expose display-targeted input");
    }
  }

  private float[] point(Map<String, Object> args, String x, String y, Capture cap, Screen s) {
    if (cap == null || !cap.app.equals(s.target))
      throw fail("SCREENSHOT_REQUIRED", "Request a fresh screenshot before coordinate input");
    if (cap.displayWidth != s.width
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
    settleAfterInput(token);
    if (touchPossible(target, state)) {
      float[] point = center(target, state);
      try {
        for (int i = 0; i < count; i++) {
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
        if (!e.code.equals("INPUT_UNAVAILABLE")) throw e;
      }
    }
    if (!node.isClickable()
        && node.getActionList().stream()
            .noneMatch(a -> a.getId() == AccessibilityNodeInfo.ACTION_CLICK))
      throw fail("INPUT_UNAVAILABLE", "A touch cannot reach this element and it has no click action");
    accessibility(node, AccessibilityNodeInfo.ACTION_CLICK, null, pkg, token);
    notice = "Touch unavailable; used accessibility click fallback.";
  }

  private void shellTap(float x, float y, String pkg, long token) {
    checkTarget(token, pkg);
    try {
      if (activeDisplay == Display.DEFAULT_DISPLAY)
        command(
            "/system/bin/input", "tap", Integer.toString(Math.round(x)), Integer.toString(Math.round(y)));
      else
        command(
            "/system/bin/input",
            "-d",
            String.valueOf(activeDisplay),
            "tap",
            Integer.toString(Math.round(x)),
            Integer.toString(Math.round(y)));
    } catch (Exception e) {
      throw fail("INPUT_UNAVAILABLE", "Android shell tap failed: " + e.getMessage());
    }
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
    throw fail("NO_FOCUSED_ELEMENT", "No focused editable field in target app");
  }

  private AccessibilityNodeInfo focusedReady(Screen initial, String pkg, long token) {
    Screen current = initial;
    long deadline = SystemClock.uptimeMillis() + 6000;
    boolean touched = false;
    while (true) {
      try {
        return focused(current);
      } catch (Failure e) {
        if (!e.code.equals("NO_FOCUSED_ELEMENT")) throw e;
        if (SystemClock.uptimeMillis() >= deadline) {
          Element editable =
              current.elements.values().stream()
                  .filter(element -> element.editable && element.pkg.equals(pkg))
                  .findFirst()
                  .orElse(null);
          AccessibilityNodeInfo node = editable == null ? null : nodes.get(editable.index);
          if (node != null && node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)) {
            check(token, false);
            return node;
          }
          throw e;
        }
        if (!touched) {
          Element editable =
              current.elements.values().stream()
                  .filter(element -> element.editable && element.pkg.equals(pkg))
                  .findFirst()
                  .orElse(null);
          if (editable != null) {
            float[] point = center(editable, current);
            touch(point[0], point[1], point[0], point[1], 45, pkg, token);
            touched = true;
          }
        }
        pause(100, token);
        current = observe(pkg);
      }
    }
  }

  private void setText(AccessibilityNodeInfo n, String value, String pkg, long token) {
    if (!n.isEditable()
        || n.getActionList().stream()
            .noneMatch(a -> a.getId() == AccessibilityNodeInfo.ACTION_SET_TEXT))
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
    long down = SystemClock.uptimeMillis();
    boolean pressed = false, completed = false;
    try {
      pressed = true;
      KeyEvent downEvent =
          new KeyEvent(
              down,
              down,
              KeyEvent.ACTION_DOWN,
              code,
              0,
              0,
              KeyCharacterMap.VIRTUAL_KEYBOARD,
              0,
              0,
              InputDevice.SOURCE_KEYBOARD);
      setEventDisplay(downEvent);
      inject(downEvent);
      pause((long) (seconds * 1000), token);
      checkTarget(token, pkg);
      completed = true;
    } finally {
      if (pressed) {
        KeyEvent upEvent =
            new KeyEvent(
                down,
                SystemClock.uptimeMillis(),
                KeyEvent.ACTION_UP,
                code,
                0,
                0,
                KeyCharacterMap.VIRTUAL_KEYBOARD,
                0,
                completed ? 0 : KeyEvent.FLAG_CANCELED,
                InputDevice.SOURCE_KEYBOARD);
        setEventDisplay(upEvent);
        inject(upEvent);
      }
    }
  }

  private boolean tryPaste(AccessibilityNodeInfo n, String text, String pkg, long token) {
    if (!n.isEditable()) return false;
    checkTarget(token, pkg);
    ClipData old;
    try {
      old = clipboard.getPrimaryClip();
    } catch (Exception e) {
      keyboardInputFailure = "Clipboard read failed: " + e.getClass().getSimpleName();
      return false;
    }
    String marker = "OpenCU-" + UUID.randomUUID();
    ClipData clip = ClipData.newPlainText(marker, text);
    boolean changed = false;
    try {
      checkTarget(token, pkg);
      try {
        clipboard.setPrimaryClip(clip);
      } catch (Exception e) {
        keyboardInputFailure = "Clipboard write failed: " + e.getClass().getSimpleName();
        return false;
      }
      changed = true;
      if (!n.refresh()) {
        keyboardInputFailure = "Focused editor refresh failed before paste";
        return false;
      }
      checkTarget(token, pkg);
      if (!n.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
        keyboardInputFailure = "Focused editor rejected ACTION_PASTE";
        return false;
      }
      check(token, false);
      pause(80, token);
      return true;
    } finally {
      if (changed)
        try {
          ClipData current = clipboard.getPrimaryClip();
          if (current != null && marker.contentEquals(current.getDescription().getLabel())) {
            if (old != null) clipboard.setPrimaryClip(old);
            else clipboard.clearPrimaryClip();
          } else
            notice = "Clipboard changed or became unreadable; previous clipboard was not restored.";
        } catch (Exception e) {
          notice = "Previous clipboard could not be restored.";
        }
    }
  }

  private void paste(AccessibilityNodeInfo n, String text, String pkg, long token) {
    if (!tryPaste(n, text, pkg, token))
      throw fail("PASTE_UNSUPPORTED", "Focused editor does not expose paste");
  }

  private String focusedText(Screen s) {
    try {
      AccessibilityNodeInfo n = focused(s);
      return n.isShowingHintText() ? "" : str(n.getText());
    } catch (Failure e) {
      return null;
    }
  }

  private String expectedText(AccessibilityNodeInfo n, String value) {
    String before = n.isShowingHintText() ? "" : str(n.getText());
    int a = n.getTextSelectionStart(), b = n.getTextSelectionEnd();
    if (a < 0 || b < 0 || a > before.length() || b > before.length()) a = b = before.length();
    return before.substring(0, Math.min(a, b))
        + value
        + before.substring(Math.max(a, b));
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
    Screen now = fence == base ? observe(pkg) : fence;
    String unexpected = Core.stopReason(fence, now, pkg);
    if (unexpected != null)
      throw fail(
          unexpected.equals("app_switched") ? "APP_SWITCHED" : "POPUP",
          "Screen changed since observation: " + unexpected);
    AccessibilityNodeInfo n = null;
    Element old = null;
    if (args.containsKey("element_index")) {
      old = base.elements.get(((Number) args.get("element_index")).intValue());
      n = live(old, now);
    }
    checkTarget(token, pkg);
    switch (method) {
      case "click":
        {
          int count = ((Number) args.getOrDefault("click_count", 1)).intValue();
          double seconds = ((Number) args.getOrDefault("duration", 0)).doubleValue();
          if (n != null) {
            clickElement(n, old, now, pkg, token, count, seconds);
          } else {
            float[] p = n == null ? point(args, "x", "y", cap, now) : center(old, now);
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
          for (int page = 0; page < requested; page++) {
            if (page > 0) {
              Screen current = observe(pkg);
              String changed = Core.stopReason(fence, current, pkg);
              if (changed != null) throw fail("POPUP", "Window changed during scroll: " + changed);
              if (n != null) n = live(old, current);
            }
            if (n != null) {
              if (!n.isScrollable()) throw fail("ACTION_UNSUPPORTED", "Element is not scrollable");
              int action =
                  d.equals("d")
                      ? AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.getId()
                      : d.equals("u")
                          ? AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.getId()
                          : d.equals("l")
                              ? AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.getId()
                              : AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT
                                  .getId();
              boolean supported = false;
              for (AccessibilityNodeInfo.AccessibilityAction candidate : n.getActionList())
                if (candidate.getId() == action) supported = true;
              if (!supported)
                action =
                    d.equals("d") || d.equals("r")
                        ? AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                        : AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD;
              checkTarget(token, pkg);
              if (!n.performAction(action, null)) {
                notice = Core.scrollNotice(moved, requested);
                break;
              }
              check(token, false);
            } else {
              float[] p = point(args, "x", "y", cap, now);
              float dx = d.equals("l") ? now.width * .55f : d.equals("r") ? -now.width * .55f : 0,
                  dy = d.equals("u") ? now.height * .55f : d.equals("d") ? -now.height * .55f : 0;
              float tx = Math.max(1, Math.min(now.width - 2, p[0] + dx)),
                  ty = Math.max(1, Math.min(now.height - 2, p[1] + dy));
              touch(p[0], p[1], tx, ty, 350, pkg, token);
            }
            moved++;
            pause(80, token);
          }
          if (notice.isEmpty() && moved < requested) notice = Core.scrollNotice(moved, requested);
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
        {
          n = focusedReady(now, pkg, token);
          String value = (String) args.get("text");
          String expected = expectedText(n, value);
          keyboardInputFailure = "";
          boolean inputPath = tryPaste(n, value, pkg, token);
          if (!inputPath) {
            String before = n.isShowingHintText() ? "" : str(n.getText());
            int a = n.getTextSelectionStart(), b = n.getTextSelectionEnd();
            if (a < 0 || b < 0 || a > before.length() || b > before.length())
              a = b = before.length();
            setText(
                n,
                before.substring(0, Math.min(a, b))
                    + value
                    + before.substring(Math.max(a, b)),
                pkg,
                token);
            notice =
                "Keyboard-style text input unavailable; used accessibility set-text fallback.";
          }
          Screen after = observe(pkg);
          String actual = focusedText(after);
          boolean reacted = actual == null && after.content().contains(value);
          if (!Core.textInputSatisfied(expected, actual, reacted))
            throw fail(
                "TEXT_INPUT_FAILED",
                "Focused editable did not contain the requested text after input; no app reaction was observed");
          break;
        }
      case "paste":
        paste(focused(now), (String) args.get("text"), pkg, token);
        break;
      case "perform_secondary_action":
        {
          Integer action = old.actions.get(args.get("action"));
          if (action == null || n.getActionList().stream().noneMatch(a -> a.getId() == action))
            throw fail("ACTION_UNSUPPORTED", "Action was not listed or is no longer available");
          accessibility(n, action, null, pkg, token);
          break;
        }
      default:
        throw fail("METHOD_NOT_FOUND", "Unknown action");
    }
    // Standalone calls settle in afterAction; batches observe the post-action fence directly
    // to avoid paying a second idle wait for every quickly settling step.
  }

  private void settleAfterInput(long token) {
    check(token, false);
    try {
      automation.waitForIdle(30, 180);
    } catch (TimeoutException ignored) {
      // The bounded fallback below still provides a stable observation without blocking input.
    }
  }

  public Map<String, Object> call(String name, Map<String, Object> args) throws Exception {
    long now = SystemClock.uptimeMillis();
    if (desktopDisplay >= 0 && !name.equals("agent_desktop") && now - lastCallAt >= desktopIdleMs) {
      stopDesktop();
      throw fail(
          "AGENT_DESKTOP_IDLE_STOPPED",
          "The Android agent display stopped after five idle minutes");
    }
    boolean statusCall = name.equals("agent_desktop") && "status".equals(args.get("action"));
    if (!statusCall) lastCallAt = now;
    if (name.equals("agent_desktop")) return desktopCall(args);
    if (name.equals("list_apps")) return apps();
    Capture cap = coordinates;
    coordinates = null;
    notice = "";
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
        while (!s.content().contains((String) args.get("waitForText"))) {
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
    if (!foreground()[0].equals(pkg)) {
      check(token, true);
      // Revalidate retained indexes before any implicit foreground change.
      if (args.containsKey("element_index"))
        live(base.elements.get(((Number) args.get("element_index")).intValue()), observe(pkg));
      activate(pkg, token);
    }
    if (name.equals("run_actions")) return batch(args, pkg, base, cap, token);
    try {
      perform(name, args, pkg, base, base, cap, token);
      check(token, false);
      Map<String, Object> r =
          result(afterAction(base, pkg, token), Protocol.coordinates(name, args));
      check(token, false);
      return r;
    } catch (Failure e) {
      coordinates = null;
      e = priorityFailure(e, token);
      if (e.code.equals("PERSON_ACTIVE") || e.code.equals("ACTION_UNCONFIRMED"))
        observationRequired = true;
      throw e;
    }
  }

  private Map<String, Object> desktopCall(Map<String, Object> args) {
    String action = (String) args.get("action");
    if (action.equals("start")) {
      try {
        startDesktop();
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
              "trusted",
              desktopTrusted,
              "ownFocus",
              (desktopFlags & FLAG_OWN_FOCUS) != 0,
              "stealTopFocusDisabled",
              (desktopFlags & FLAG_STEAL_TOP_FOCUS_DISABLED) != 0,
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

  private Map<String, Object> batch(
      Map<String, Object> args, String pkg, Screen base, Capture cap, long token) {
    List<Object> actions = list(args.get("actions"));
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
                    : reason.equals("system_dialog")
                        ? "SYSTEM_DIALOG"
                        : reason.equals("popup") ? "POPUP" : "APP_SWITCHED",
                "Batch stopped; remaining steps were not sent");
    }
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

  public synchronized void close() {
    if (closed) return;
    closed = true;
    if (monitor != null) monitor.close();
    // disconnect can block on Binder. EOF must still terminate within two seconds.
    Thread cleanup =
        new Thread(
            () -> {
              stopDesktop();
              try {
                UiAutomation.class.getDeclaredMethod("disconnect").invoke(mainAutomation);
              } catch (Exception ignored) {
              }
            });
    cleanup.setDaemon(true);
    cleanup.start();
    try {
      cleanup.join(250);
    } catch (InterruptedException ignored) {
    }
    thread.quitSafely();
  }
}
