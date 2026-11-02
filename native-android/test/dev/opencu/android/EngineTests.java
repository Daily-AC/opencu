package dev.opencu.android;

import static dev.opencu.android.Json.*;

import android.app.UiAutomation;
import android.os.Bundle;
import android.view.accessibility.AccessibilityNodeInfo;
import dev.opencu.android.Core.Element;
import dev.opencu.android.Core.Failure;
import dev.opencu.android.Core.Person;
import dev.opencu.android.Core.Screen;
import dev.opencu.android.Core.Window;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.IntConsumer;
import sun.misc.Unsafe;

/**
 * Host-JVM checks that run the engine's own decision code. Only the device is scripted: the
 * accessibility tree, foreground, shell clients and event injection. Each check runs on its own
 * and reports {@code ok}/{@code not ok}, so a run against an older engine shows exactly which
 * behaviours differ.
 */
public final class EngineTests {
  interface Body {
    void run() throws Exception;
  }

  interface ShellHook {
    String run(String[] args) throws Exception;
  }

  static final String PKG = "example.host";
  static final int DOWN = android.R.id.accessibilityActionScrollDown;
  static final List<String> failures = new ArrayList<>();
  static int passed;
  static String only;

  static void test(String name, Body body) {
    if (only != null && !name.contains(only)) return;
    try {
      body.run();
      passed++;
      System.out.println("ok - " + name);
    } catch (Throwable t) {
      if (System.getenv("OPENCU_TEST_TRACE") != null) t.printStackTrace(System.out);
      failures.add(name);
      System.out.println("not ok - " + name + ": " + describe(t));
    }
  }

  static String describe(Throwable t) {
    String text = t instanceof AssertionError ? String.valueOf(t.getMessage()) : t.toString();
    if (t instanceof Failure) text = ((Failure) t).code + ": " + t.getMessage();
    return text.replace('\n', ' ');
  }

  static void require(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }

  /** Runs {@code body} and returns the tool failure it raised. */
  static Failure failure(Body body) {
    try {
      body.run();
    } catch (Failure f) {
      return f;
    } catch (Exception e) {
      throw new AssertionError("Expected a tool failure, got " + e, e);
    }
    throw new AssertionError("Expected a tool failure, but the call succeeded");
  }

  static final Unsafe UNSAFE;

  static {
    try {
      Field f = Unsafe.class.getDeclaredField("theUnsafe");
      f.setAccessible(true);
      UNSAFE = (Unsafe) f.get(null);
    } catch (ReflectiveOperationException e) {
      throw new ExceptionInInitializerError(e);
    }
  }

  /** Allocates without running constructors that need a phone. */
  static <T> T allocate(Class<T> type) {
    try {
      return type.cast(UNSAFE.allocateInstance(type));
    } catch (InstantiationException e) {
      throw new AssertionError(e);
    }
  }

  static Field field(Class<?> type, String name) {
    for (Class<?> c = type; c != null; c = c.getSuperclass())
      try {
        Field f = c.getDeclaredField(name);
        f.setAccessible(true);
        return f;
      } catch (NoSuchFieldException ignored) {
      }
    throw new AssertionError("No field " + name + " on " + type.getName());
  }

  static boolean hasField(Class<?> type, String name) {
    for (Class<?> c = type; c != null; c = c.getSuperclass())
      for (Field f : c.getDeclaredFields()) if (f.getName().equals(name)) return true;
    return false;
  }

  static void set(Object target, String name, Object value) {
    try {
      field(target.getClass(), name).set(target, value);
    } catch (IllegalAccessException e) {
      throw new AssertionError(e);
    }
  }

  static Object get(Object target, String name) {
    try {
      return field(target.getClass(), name).get(target);
    } catch (IllegalAccessException e) {
      throw new AssertionError(e);
    }
  }

  static Object invoke(Object target, String name, Class<?>[] types, Object... args)
      throws Exception {
    for (Class<?> c = target.getClass(); c != null; c = c.getSuperclass())
      try {
        Method m = c.getDeclaredMethod(name, types);
        m.setAccessible(true);
        try {
          return m.invoke(target, args);
        } catch (InvocationTargetException e) {
          if (e.getCause() instanceof Exception) throw (Exception) e.getCause();
          throw new RuntimeException(e.getCause());
        }
      } catch (NoSuchMethodException ignored) {
      }
    throw new AssertionError("No method " + name + " on " + target.getClass().getName());
  }

  static String text(Map<String, Object> result) {
    return (String) map(list(result.get("content")).get(0)).get("text");
  }

  /** An accessibility node whose answers and effects are scripted by the test. */
  static class FakeNode extends AccessibilityNodeInfo {
    boolean editable, clickable, scrollable, hint, refreshes, password;
    String text;
    int selectionStart, selectionEnd;
    Set<Integer> actions;
    Map<Integer, Boolean> results;
    Map<Integer, Runnable> effects;
    List<Integer> performed;
    List<String> setTexts;
    List<Float> progress;

    static FakeNode create() {
      FakeNode n = allocate(FakeNode.class);
      n.text = "";
      n.refreshes = true;
      n.selectionStart = n.selectionEnd = -1;
      n.actions = new HashSet<>();
      n.results = new HashMap<>();
      n.effects = new HashMap<>();
      n.performed = Collections.synchronizedList(new ArrayList<>());
      n.setTexts = Collections.synchronizedList(new ArrayList<>());
      n.progress = Collections.synchronizedList(new ArrayList<>());
      return n;
    }

    boolean offers(int id) {
      return actions.contains(id);
    }

    FakeNode with(int... ids) {
      for (int id : ids) actions.add(id);
      return this;
    }

    @Override
    public boolean performAction(int action) {
      return performAction(action, null);
    }

    @Override
    public boolean performAction(int action, Bundle arguments) {
      performed.add(action);
      if (!offers(action)) return false; // Android ignores actions a node does not list.
      if (action == ACTION_SET_SELECTION && arguments != null && results.getOrDefault(action, true)) {
        selectionStart = arguments.getInt(ACTION_ARGUMENT_SELECTION_START_INT);
        selectionEnd = arguments.getInt(ACTION_ARGUMENT_SELECTION_END_INT);
      }
      if (action == ACTION_SET_TEXT && arguments != null) {
        CharSequence value = arguments.getCharSequence(ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE);
        setTexts.add(String.valueOf(value));
        text = String.valueOf(value);
        selectionStart = selectionEnd = text.length(); // as TextView does after ACTION_SET_TEXT
      }
      if (action == android.R.id.accessibilityActionSetProgress && arguments != null)
        progress.add(arguments.getFloat(ACTION_ARGUMENT_PROGRESS_VALUE));
      Runnable effect = effects.get(action);
      if (effect != null) effect.run();
      return results.getOrDefault(action, true);
    }

    @Override
    public boolean isEditable() {
      return editable;
    }

    @Override
    public boolean isClickable() {
      return clickable;
    }

    @Override
    public boolean isScrollable() {
      return scrollable;
    }

    @Override
    public CharSequence getText() {
      return password ? mask(text) : text; // as TextView reports a password without "speak passwords"
    }

    @Override
    public boolean isPassword() {
      return password;
    }

    @Override
    public boolean isShowingHintText() {
      return hint;
    }

    @Override
    public int getTextSelectionStart() {
      return selectionStart;
    }

    @Override
    public int getTextSelectionEnd() {
      return selectionEnd;
    }

    @Override
    public boolean refresh() {
      return refreshes;
    }
  }

  /** A scripted screen: element specs plus the node behind each one. */
  static final class Scene {
    final List<Element> specs = new ArrayList<>();
    final List<FakeNode> nodes = new ArrayList<>();
    final List<Window> extraWindows = new ArrayList<>();
    String foreground = PKG, activity = PKG + "/.Main";
    int display, width = 1080, height = 2400, window = 7;

    Element add(String path, String clazz, String id, String text, int l, int t, int r, int b) {
      Element e = new Element();
      e.window = window;
      e.path = path;
      e.pkg = PKG;
      e.clazz = clazz;
      e.id = id.isEmpty() ? "" : PKG + ":id/" + id;
      e.text = text;
      e.left = l;
      e.top = t;
      e.right = r;
      e.bottom = b;
      specs.add(e);
      nodes.add(FakeNode.create());
      return e;
    }

    FakeNode node(Element spec) {
      return nodes.get(specs.indexOf(spec));
    }

    Screen screen() {
      Screen s = new Screen();
      s.target = PKG;
      s.foreground = foreground;
      s.activity = activity;
      s.width = width;
      s.height = height;
      s.displayId = display;
      Window w = new Window();
      w.id = window;
      w.type = 1;
      w.pkg = PKG;
      w.right = width;
      w.bottom = height;
      w.focused = w.active = true;
      s.windows.add(w);
      s.windows.addAll(extraWindows);
      for (Element spec : specs) {
        Element e = copy(spec);
        e.index = s.elements.size() + 1;
        e.window = spec.window;
        if (hasField(Element.class, "display"))
          try {
            Element.class.getField("display").setInt(e, display);
          } catch (ReflectiveOperationException ex) {
            throw new AssertionError(ex);
          }
        s.elements.put(e.index, e);
        for (Window candidate : s.windows) if (candidate.id == e.window) candidate.elements.add(e);
      }
      return s;
    }
  }

  static Element copy(Element from) {
    Element e = new Element();
    for (Field f : Element.class.getFields())
      try {
        if (java.lang.reflect.Modifier.isFinal(f.getModifiers())) continue;
        f.set(e, f.get(from));
      } catch (IllegalAccessException ex) {
        throw new AssertionError(ex);
      }
    e.actions.putAll(from.actions);
    return e;
  }

  static final class Event {
    final String kind;
    final UiAutomation via;
    final int display, action;

    Event(String kind, UiAutomation via, int display, int action) {
      this.kind = kind;
      this.via = via;
      this.display = display;
      this.action = action;
    }
  }

  /** The production engine with only the phone replaced. */
  static class ScriptedEngine extends AndroidEngine {
    Scene scene;
    int observations;
    IntConsumer onObserve;
    Body checkHook, resolveHook, beforeInjectHook;
    List<String> trace;
    ShellHook shellHook;
    String mainForeground;
    List<String> log;
    List<Event> events;

    ScriptedEngine() throws Exception {
      super(null);
    }

    static ScriptedEngine create(Scene scene) {
      ScriptedEngine e = allocate(ScriptedEngine.class);
      set(e, "nodes", new HashMap<Integer, AccessibilityNodeInfo>());
      set(e, "hidden", obj());
      set(e, "notice", "");
      // Field initialisers do not run for an allocated instance; mirror the ones the engine has.
      if (hasField(AndroidEngine.class, "keyboardInputFailure")) set(e, "keyboardInputFailure", "");
      if (hasField(AndroidEngine.class, "passedOver")) set(e, "passedOver", "");
      if (hasField(AndroidEngine.class, "callLock"))
        set(e, "callLock", new java.util.concurrent.locks.ReentrantLock());
      set(e, "desktopDisplay", -1);
      set(e, "activeDisplay", 0);
      set(e, "desktopIdleMs", 300_000L);
      set(e, "person", new Person(0));
      set(e, "monitorProblem", "");
      e.scene = scene;
      e.mainForeground = "";
      e.log = Collections.synchronizedList(new ArrayList<>());
      e.events = Collections.synchronizedList(new ArrayList<>());
      e.trace = Collections.synchronizedList(new ArrayList<>());
      e.requestedFlags = new ArrayList<>();
      e.disconnected = new ArrayList<>();
      return e;
    }

    /** Publishes the scene as the state the caller last read. */
    Screen read() {
      Screen s = observe(PKG);
      set(this, "latest", s);
      return s;
    }

    @Override
    @SuppressWarnings("unchecked")
    Screen observe(String target) {
      observations++;
      trace.add("observe");
      if (onObserve != null) onObserve.accept(observations);
      Screen s = scene.screen();
      s.target = target;
      s.id = observations;
      Map<Integer, AccessibilityNodeInfo> nodes =
          (Map<Integer, AccessibilityNodeInfo>) get(this, "nodes");
      nodes.clear();
      for (int i = 0; i < scene.specs.size(); i++) nodes.put(i + 1, scene.nodes.get(i));
      return s;
    }

    @Override
    String[] foreground() {
      return new String[] {scene.foreground, scene.activity};
    }

    @Override
    String foregroundOnDisplay(int displayId) {
      return displayId == 0 ? mainForeground : "";
    }

    /** Stalls the {@code stallOccurrence}-th check made on behalf of {@code stallCaller}. */
    String stallCaller;
    int stallOccurrence, stallSeen;
    CountDownLatch stalled, resume;

    static String checkCaller() {
      StackTraceElement[] stack = Thread.currentThread().getStackTrace();
      // [0] getStackTrace, [1] checkCaller, [2] check, [3] checkTarget or the method checking.
      String name = stack[3].getMethodName();
      return name.equals("checkTarget") ? stack[4].getMethodName() : name;
    }

    // Not annotated: older engines start activities without this hook.
    String launchComponent(String pkg) {
      return pkg + "/.Main";
    }

    @Override
    void check(long token, boolean changing) {
      if ((Boolean) get(this, "closed")) throw Core.fail("ENGINE_STOPPING", "Stdin closed");
      if (stallCaller != null && stallCaller.equals(checkCaller()) && ++stallSeen == stallOccurrence) {
        // A platform call after this check blocks past shutdown's bounded wait.
        stalled.countDown();
        try {
          resume.await(10, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
        }
      }
      if (checkHook != null)
        try {
          checkHook.run();
        } catch (RuntimeException e) {
          throw e;
        } catch (Exception e) {
          throw new RuntimeException(e);
        }
    }

    @Override
    void waitIdle() {
      trace.add("idle");
    }

    @Override
    String resolve(String name) {
      if (resolveHook != null)
        try {
          resolveHook.run();
        } catch (Exception e) {
          throw new RuntimeException(e);
        }
      return name;
    }

    @Override
    String shell(String... args) throws Exception {
      log.add("shell " + String.join(" ", args));
      trace.add("shell");
      return shellHook == null ? "" : shellHook.run(args);
    }

    /** A shorter batch limit for one check; zero keeps the engine's own. */
    long batchLimit;

    // Not annotated: older engines kept the limit in a field instead.
    long batchLimitMs() {
      return batchLimit > 0 ? batchLimit : super.batchLimitMs();
    }

    // Not annotated: older engines lack this hook and simply never call it.
    boolean displayInputAvailable() {
      if (beforeInjectHook != null)
        try {
          beforeInjectHook.run();
        } catch (Exception e) {
          throw new RuntimeException(e);
        }
      return true;
    }

    @Override
    boolean hasAction(AccessibilityNodeInfo n, int id) {
      return ((FakeNode) n).offers(id);
    }

    @Override
    void sendMotion(UiAutomation via, int display, long down, int action, float x, float y) {
      events.add(new Event("motion", via, display, action));
      log.add("motion " + action + " " + Math.round(x) + "," + Math.round(y) + " display " + display);
    }

    @Override
    void sendKey(UiAutomation via, int display, long down, long time, int action, int code, int flags) {
      events.add(new Event("key", via, display, action));
      log.add("key " + action + " code " + code + " flags " + flags + " display " + display);
    }

    interface DisplayScript {
      AndroidEngine.OwnedDisplay create(int requested);
    }

    interface ConnectScript {
      UiAutomation connect(int displayId) throws Exception;
    }

    DisplayScript displayScript;
    ConnectScript connectScript;
    Body imeScript;
    List<Integer> requestedFlags;
    List<UiAutomation> disconnected;

    @Override
    AndroidEngine.OwnedDisplay createOwnedDisplay(int requested) {
      requestedFlags.add(requested);
      return displayScript.create(requested);
    }

    @Override
    UiAutomation createDisplayAutomation(int displayId) throws Exception {
      return connectScript.connect(displayId);
    }

    @Override
    void disconnectAutomation(UiAutomation target) {
      disconnected.add(target);
    }

    // Not annotated: older engines set the policy without reading it back.
    void requireLocalIme(int displayId) {
      if (imeScript != null)
        try {
          imeScript.run();
        } catch (RuntimeException e) {
          throw e;
        } catch (Exception e) {
          throw new RuntimeException(e);
        }
    }

    // Not annotated: the platform release is replaced by the stop the test records.
    void releaseRoutes() {
      stopDesktop();
    }

    /** Display 0's image when a check supplies one; otherwise the platform stub's failure. */
    android.graphics.Bitmap mainShot;
    /** Every request for display 0's image, whatever display was active. */
    int mainShots;

    // Not annotated: older engines take display 0's screenshot without this hook.
    android.graphics.Bitmap mainDisplayScreenshot() {
      mainShots++;
      if (mainShot == null) throw new RuntimeException("Stub!"); // as android.jar's UiAutomation
      return mainShot;
    }

    @Override
    void stopDesktop() {
      log.add("stopDesktop");
      set(this, "desktopDisplay", -1);
      set(this, "activeDisplay", 0);
      set(this, "automation", get(this, "mainAutomation"));
    }
  }

  static String mask(String text) {
    return "\u2022".repeat(text.length());
  }

  /** A focused password field holding {@code value}, reported masked like the platform does. */
  static FakeNode passwordEditor(Scene scene, String value) {
    Element field = scene.add("/0", "android.widget.EditText", "pin", mask(value), 0, 100, 1080, 200);
    field.editable = true;
    field.focused = true;
    field.password = true;
    FakeNode node = scene.node(field).with(AccessibilityNodeInfo.ACTION_SET_TEXT);
    node.editable = true;
    node.password = true;
    node.text = value;
    node.selectionStart = node.selectionEnd = value.length();
    node.effects.put(AccessibilityNodeInfo.ACTION_SET_TEXT, () -> field.text = mask(node.text));
    return node;
  }

  /** A focused editor whose set-text shows up in the next read, as an app's editor does. */
  static FakeNode focusedEditor(Scene scene, int... actions) {
    Element field = scene.add("/0", "android.widget.EditText", "query", "", 0, 100, 1080, 200);
    field.editable = true;
    field.focused = true;
    FakeNode node = scene.node(field).with(actions);
    node.editable = true;
    node.effects.put(AccessibilityNodeInfo.ACTION_SET_TEXT, () -> field.text = node.text);
    return node;
  }

  static final int SET_PROGRESS = android.R.id.accessibilityActionSetProgress;

  /** A slider from 0 to 100 at 40 that offers set-progress, as SeekBar does. */
  static Element slider(Scene scene) {
    Element slider = scene.add("/0", "android.widget.SeekBar", "brightness", "", 0, 300, 1080, 400);
    slider.focusable = true;
    slider.actions.put("scroll_forward", FORWARD);
    slider.actions.put("scroll_backward", BACKWARD);
    if (hasField(Element.class, "ranged")) { // older engines did not read RangeInfo
      set(slider, "ranged", true);
      set(slider, "min", 0f);
      set(slider, "max", 100f);
      set(slider, "current", 40f);
    }
    scene.node(slider).with(FORWARD, BACKWARD, SET_PROGRESS);
    return slider;
  }

  /** A scrollable list showing rows {@code offset+1} and {@code offset+2}; scrolling shifts the offset. */
  static final class ListScene {
    final Scene scene = new Scene();
    final Element list = scene.add("/0", "androidx.recyclerview.widget.RecyclerView", "rows", "", 0, 100, 1080, 2000);
    final Element first = scene.add("/0/0", "android.widget.TextView", "", "", 0, 100, 1080, 300);
    final Element second = scene.add("/0/1", "android.widget.TextView", "", "", 0, 300, 1080, 500);
    final FakeNode node;
    int offset;

    ListScene(int... actions) {
      list.scrollable = true;
      node = scene.node(list).with(actions);
      node.scrollable = true;
      show(0);
    }

    void show(int offset) {
      this.offset = offset;
      first.text = "Row " + (offset + 1);
      second.text = "Row " + (offset + 2);
    }
  }

  static final int FORWARD = AccessibilityNodeInfo.ACTION_SCROLL_FORWARD,
      BACKWARD = AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD,
      UP = android.R.id.accessibilityActionScrollUp,
      RIGHT = android.R.id.accessibilityActionScrollRight;

  /**
   * A list that offers only scroll-forward, as ColorOS lists were seen to do even part-way down,
   * inside an enclosing element at "/0" that does not say it scrolls; the check decides which
   * actions the enclosing element offers. The list starts at row 5.
   */
  static final class NestedListScene {
    final ListScene rows;
    final Element outer;
    final FakeNode outerNode;

    NestedListScene() {
      ListScene inner = new ListScene();
      // Re-root the list under an enclosing element: the enclosing element comes first.
      Scene scene = inner.scene;
      outer = new Element();
      outer.window = scene.window;
      outer.path = "/0";
      outer.pkg = PKG;
      outer.clazz = "androidx.coordinatorlayout.widget.CoordinatorLayout";
      outer.left = 0;
      outer.top = 0;
      outer.right = 1080;
      outer.bottom = 2000;
      outer.actions.put("scroll_backward", BACKWARD);
      scene.specs.add(0, outer);
      outerNode = FakeNode.create();
      scene.nodes.add(0, outerNode);
      inner.list.path = "/0/0";
      inner.list.top = 300;
      inner.first.path = "/0/0/0";
      inner.second.path = "/0/0/1";
      inner.first.top = 300;
      inner.first.bottom = 500;
      inner.second.top = 500;
      inner.second.bottom = 700;
      inner.node.with(FORWARD);
      inner.list.actions.put("scroll_forward", FORWARD);
      inner.show(4);
      rows = inner;
    }
  }

  /**
   * A calculator-like screen: tapping "=" starts an animation that moves the result row on every
   * frame for {@code animationMs}, after which it rests at 0,600 showing 21 (20 while it moves).
   */
  static final class AnimatedScene {
    final Scene scene = new Scene();
    final Element key = scene.add("/0", "android.widget.Button", "equals", "=", 100, 1900, 300, 2100);
    final Element result = scene.add("/1", "android.widget.TextView", "result", "20", 0, 600, 1080, 800);
    final long animationMs;
    long tappedAt;

    AnimatedScene(long animationMs) {
      this.animationMs = animationMs;
      key.clickable = true;
    }

    ScriptedEngine engine() {
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.shellHook = tap -> {
        tappedAt = android.os.SystemClock.uptimeMillis();
        return "";
      };
      engine.onObserve = n -> {
        long elapsed = tappedAt == 0 ? Long.MAX_VALUE : android.os.SystemClock.uptimeMillis() - tappedAt;
        boolean moving = elapsed < animationMs;
        result.left = moving ? 1 + (int) (elapsed / 10 % 49) : 0;
        result.text = moving ? "20" : "21";
      };
      return engine;
    }
  }

  /** The touch points sent so far: {action, x, y, display}. */
  static List<int[]> motions(ScriptedEngine engine) {
    List<int[]> points = new ArrayList<>();
    synchronized (engine.log) {
      for (String line : engine.log) {
        if (!line.startsWith("motion ")) continue;
        String[] parts = line.split(" "), xy = parts[2].split(",");
        points.add(new int[] {Integer.parseInt(parts[1]), Integer.parseInt(xy[0]), Integer.parseInt(xy[1]), Integer.parseInt(parts[4])});
      }
    }
    return points;
  }

  /**
   * A wheel picker that shows its value as its own text, as time pickers do, with a decoration
   * child that never changes. It offers only the generic scroll actions.
   */
  static final class PickerScene {
    final Scene scene = new Scene();
    final Element wheel = scene.add("/0", "android.widget.NumberPicker", "minute", "20", 600, 900, 900, 1500);
    final Element decoration = scene.add("/0/0", "android.widget.ImageView", "", "", 600, 900, 900, 1000);
    final FakeNode node;

    PickerScene() {
      wheel.scrollable = true;
      wheel.actions.put("scroll_forward", FORWARD);
      wheel.actions.put("scroll_backward", BACKWARD);
      decoration.desc = "Wheel edge";
      node = scene.node(wheel).with(FORWARD, BACKWARD);
      node.scrollable = true;
    }
  }

  /** Starts a harmless child JVM that records its pid and sleeps. */
  static String[] sleeper(java.nio.file.Path pidFile) {
    return new String[] {
      System.getProperty("java.home") + "/bin/java",
      "-cp",
      System.getProperty("java.class.path"),
      EngineTests.class.getName(),
      "child",
      pidFile.toString()
    };
  }

  static ProcessHandle awaitChild(java.nio.file.Path pidFile) throws Exception {
    long limit = System.nanoTime() + 5_000_000_000L;
    while (!java.nio.file.Files.exists(pidFile) || java.nio.file.Files.readString(pidFile).isEmpty()) {
      require(System.nanoTime() < limit, "child did not start");
      Thread.sleep(10);
    }
    return ProcessHandle.of(Long.parseLong(java.nio.file.Files.readString(pidFile).trim())).orElseThrow();
  }

  static boolean exits(ProcessHandle child, long millis) throws Exception {
    try {
      child.onExit().get(millis, TimeUnit.MILLISECONDS);
      return true;
    } catch (TimeoutException e) {
      return false;
    }
  }

  static void reopenCommands() throws Exception {
    if (hasField(AndroidEngine.class, "commandsStopped")) {
      Field f = field(AndroidEngine.class, "commandsStopped");
      f.set(null, false);
    }
  }

  /** An engine on owned virtual display 5 with distinct main and agent connections. */
  static ScriptedEngine onAgentDisplay(Scene scene) {
    scene.display = 5;
    ScriptedEngine engine = ScriptedEngine.create(scene);
    set(engine, "mainAutomation", allocate(UiAutomation.class));
    set(engine, "automation", allocate(UiAutomation.class));
    set(engine, "desktopAutomation", get(engine, "automation"));
    set(engine, "activeDisplay", 5);
    set(engine, "desktopDisplay", 5);
    set(engine, "lastCallAt", android.os.SystemClock.uptimeMillis());
    return engine;
  }

  static final int ISOLATED = (1 << 7) | (1 << 11) | (1 << 12); // trusted, own focus, no stealing

  static final class TestDisplay extends AndroidEngine.OwnedDisplay {
    boolean released;

    TestDisplay(int id, int flags) {
      super(null, null, null, id, flags);
    }

    @Override
    void release() {
      released = true;
    }
  }

  /** An agent display whose frame the check supplies; it counts every capture. */
  static final class ScriptedFrames extends AndroidEngine.OwnedDisplay {
    final android.graphics.Bitmap frame;
    int captures;

    ScriptedFrames(int id, android.graphics.Bitmap frame) {
      super(null, null, null, id, ISOLATED);
      this.frame = frame;
    }

    // Not annotated: older engines never read the agent display's own frames.
    android.graphics.Bitmap capture(long waitMs) {
      captures++;
      return frame;
    }
  }

  /** An RGBA_8888 frame as ImageReader hands it out; reading it once closed fails as on Android. */
  static final class FakeFrame extends android.media.Image {
    final int width, height, rowStride, format;
    final java.nio.ByteBuffer buffer;
    volatile boolean closed;

    FakeFrame(int width, int height, int rowStride, int format, java.nio.ByteBuffer buffer) {
      this.width = width;
      this.height = height;
      this.rowStride = rowStride;
      this.format = format;
      this.buffer = buffer;
    }

    /**
     * Pixel (x, y) holds R=x, G=y, B=seed, A=0xff. Rows are {@code rowStride} bytes, padded with
     * 0x77, and the last row ends without padding, as some gralloc buffers do.
     */
    static FakeFrame pattern(int width, int height, int rowStride, int seed) {
      java.nio.ByteBuffer b = java.nio.ByteBuffer.allocateDirect(rowStride * (height - 1) + width * 4);
      for (int i = 0; i < b.capacity(); i++) b.put(i, (byte) 0x77);
      for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++) {
          int i = y * rowStride + x * 4;
          b.put(i, (byte) x).put(i + 1, (byte) y).put(i + 2, (byte) seed).put(i + 3, (byte) 0xff);
        }
      return new FakeFrame(width, height, rowStride, android.graphics.PixelFormat.RGBA_8888, b);
    }

    static int expected(int x, int y, int seed) {
      return 0xff000000 | x << 16 | y << 8 | seed;
    }

    private void open() {
      if (closed) throw new IllegalStateException("Image is already closed");
    }

    @Override
    public int getFormat() {
      open();
      return format;
    }

    @Override
    public int getWidth() {
      open();
      return width;
    }

    @Override
    public int getHeight() {
      open();
      return height;
    }

    @Override
    public Plane[] getPlanes() {
      open();
      return new Plane[] {
        new Plane() {
          @Override
          public int getRowStride() {
            return rowStride;
          }

          @Override
          public int getPixelStride() {
            return 4;
          }

          @Override
          public java.nio.ByteBuffer getBuffer() {
            open();
            return buffer; // the same buffer every time, as ImageReader's planes give it
          }
        }
      };
    }

    @Override
    public void close() {
      closed = true;
    }
  }

  /** Calls a static engine method by name, so checks still compile against engines without it. */
  static Object callStatic(String name, Class<?>[] types, Object... args) throws Exception {
    Method m;
    try {
      m = AndroidEngine.class.getDeclaredMethod(name, types);
    } catch (NoSuchMethodException e) {
      throw new AssertionError("No static method " + name + " on AndroidEngine");
    }
    m.setAccessible(true);
    try {
      return m.invoke(null, args);
    } catch (InvocationTargetException e) {
      if (e.getCause() instanceof Exception) throw (Exception) e.getCause();
      throw new RuntimeException(e.getCause());
    }
  }

  /** The coordinate grant a screenshot of {@code s} at {@code width}x{@code height} gives. */
  static Object grant(Screen s, int width, int height) throws Exception {
    java.lang.reflect.Constructor<?> c =
        Class.forName("dev.opencu.android.AndroidEngine$Capture")
            .getDeclaredConstructor(Screen.class, int.class, int.class);
    c.setAccessible(true);
    return c.newInstance(s, width, height);
  }

  /** The image a result carries, decoded; host bitmaps compress to a line naming their source. */
  static String image(Map<String, Object> result) {
    for (Object item : list(result.get("content"))) {
      Map<String, Object> c = map(item);
      if ("image".equals(c.get("type")))
        return new String(
            java.util.Base64.getDecoder().decode((String) c.get("data")),
            java.nio.charset.StandardCharsets.UTF_8);
    }
    return null;
  }

  /** An engine on display 0 whose agent display start is scripted. */
  static ScriptedEngine desktopEngine() {
    ScriptedEngine engine = ScriptedEngine.create(new Scene());
    set(engine, "mainAutomation", allocate(UiAutomation.class));
    set(engine, "automation", get(engine, "mainAutomation"));
    engine.connectScript = id -> allocate(UiAutomation.class);
    return engine;
  }

  static void startDesktop(ScriptedEngine engine) throws Exception {
    invoke(engine, "startDesktop", new Class<?>[0]);
  }

  /**
   * A context that records every package identity and service lookup asked of it. As on the
   * platform, a package context made from the system context keeps the system's op package.
   */
  static class FakeContext extends android.content.ContextWrapper {
    String name, opName;
    android.content.pm.PackageManager packages;
    List<String> asked;

    FakeContext() {
      super(null); // never run: instances are allocated without constructors
    }

    static FakeContext create(String name, android.content.pm.PackageManager packages, List<String> asked) {
      FakeContext c = allocate(FakeContext.class);
      c.name = c.opName = name;
      c.packages = packages;
      c.asked = asked;
      return c;
    }

    @Override
    public String getOpPackageName() {
      asked.add("getOpPackageName -> " + opName);
      return opName;
    }

    @Override
    public String getPackageName() {
      asked.add("getPackageName -> " + name);
      return name;
    }

    @Override
    public android.content.pm.PackageManager getPackageManager() {
      return packages;
    }

    @Override
    public Object getSystemService(String service) {
      asked.add("getSystemService " + service + " as " + name);
      return null;
    }

    @Override
    public android.content.Context createPackageContext(String packageName, int flags) {
      FakeContext c = create(packageName, packages, asked);
      c.opName = opName;
      return c;
    }
  }

  /** Packages by uid, as the platform's package manager reports them. */
  static class UidPackages extends android.test.mock.MockPackageManager {
    Map<Integer, String[]> owners;

    static UidPackages of(int uid, String... packages) {
      UidPackages pm = allocate(UidPackages.class);
      pm.owners = new HashMap<>();
      pm.owners.put(uid, packages.length == 0 ? null : packages);
      return pm;
    }

    @Override
    public String[] getPackagesForUid(int uid) {
      return owners.get(uid);
    }
  }

  static Map<String, Object> args(Object... pairs) {
    Map<String, Object> a = obj("app", PKG);
    a.putAll(obj(pairs));
    return a;
  }

  public static void main(String[] argv) throws Exception {
    if (argv.length == 2 && argv[0].equals("child")) {
      java.nio.file.Files.writeString(java.nio.file.Path.of(argv[1]), Long.toString(ProcessHandle.current().pid()));
      Thread.sleep(10_000);
      return;
    }
    if (argv.length == 1 && argv[0].equals("monitor-stderr")) {
      // Starts the input monitor on a stream that complains on stderr, as getevent does.
      PersonMonitor monitor =
          new PersonMonitor(
              notice -> {},
              () -> 0L,
              new String[] {"/bin/sh", "-c", "printf 'add device 1: /dev/input/event1\\n  KEY_VOLUMEDOWN ABS_MT_POSITION_X\\n'"},
              new String[] {"/bin/sh", "-c", "echo 'could not open /dev/input/event9, Permission denied' >&2; echo 'add device 1: /dev/input/event1'; exec sleep 30"});
      Thread.sleep(200);
      monitor.close();
      return;
    }
    if (argv.length > 0) only = argv[0];

    test("indexed click taps the visible centre through the platform input tool", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("click", args("element_index", 1));
      require(engine.log.contains("shell /system/bin/input tap 200 230"), "tap: " + engine.log);
    });

    test("set_value replaces the editor value through set-text", () -> {
      Scene scene = new Scene();
      Element field = scene.add("/0", "android.widget.EditText", "name", "", 0, 100, 1080, 200);
      field.editable = true;
      FakeNode node = scene.node(field).with(AccessibilityNodeInfo.ACTION_SET_TEXT);
      node.editable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("set_value", args("element_index", 1, "value", "无线调试"));
      require(node.setTexts.equals(List.of("无线调试")), "set-text: " + node.setTexts);
    });

    test("set_value sets a slider's value with set-progress", () -> {
      Scene scene = new Scene();
      Element slider = slider(scene);
      FakeNode node = scene.node(slider);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("set_value", args("element_index", 1, "value", "37"));
      require(node.performed.equals(List.of(SET_PROGRESS)) && node.progress.equals(List.of(37f)),
          "actions " + node.performed + " values " + node.progress);
    });

    test("set_value refuses a slider value outside its range or not a number, sending nothing", () -> {
      Scene scene = new Scene();
      Element slider = slider(scene);
      FakeNode node = scene.node(slider);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      for (String value : List.of("101", "-1", "half")) {
        Failure f = failure(() -> engine.call("set_value", args("element_index", 1, "value", value)));
        require(f.code.equals("INVALID_ARGUMENT"), value + ": " + f.code + ": " + f.getMessage());
      }
      require(node.performed.isEmpty(), "sent " + node.performed);
    });

    test("set_value on a wheel picker says to scroll it and sends nothing", () -> {
      PickerScene picker = new PickerScene();
      ScriptedEngine engine = ScriptedEngine.create(picker.scene);
      engine.read();
      Failure f = failure(() -> engine.call("set_value", args("element_index", 1, "value", "35")));
      require(f.code.equals("VALUE_NOT_SETTABLE"), f.code);
      require(f.getMessage().contains("scroll it, one value per page"), f.getMessage());
      require(picker.node.performed.isEmpty(), "sent " + picker.node.performed);
    });

    test("a range element's line shows its value and range", () -> {
      Element e = new Element();
      e.clazz = "android.widget.SeekBar";
      set(e, "ranged", true);
      set(e, "min", 0f);
      set(e, "max", 100f);
      set(e, "current", 37.5f);
      require(e.line().contains(" value=37.5 range=0..100 "), e.line());
    });

    test("JSON rejects signed or non-hex unicode escapes and non-ASCII digits", () -> {
      String backslash = "\\";
      for (String bad :
          List.of(
              "\"" + backslash + "u+041\"",
              "\"" + backslash + "u-001\"",
              "\"" + backslash + "u 041\"",
              "\"" + backslash + "u004\uff21\"",
              "1\u0661",
              "1.\u0663",
              "1e\u0663",
              "\u0661")) {
        try {
          Object value = Json.read(bad);
          throw new AssertionError("accepted " + bad + " as " + value);
        } catch (IllegalArgumentException expected) {
        }
      }
      require(Json.read("\"" + backslash + "u0041" + backslash + "u00e9\"").equals("Aé"), "valid escapes");
      require(((Number) Json.read("-12.5e3")).doubleValue() == -12500, "valid number");
    });

    test("malformed tools/call line is a parse error and never reaches input", () -> {
      int[] calls = {0};
      Protocol protocol =
          new Protocol((name, values) -> {
            calls[0]++;
            return Protocol.textResult("called");
          }, "host");
      protocol.handle(
          Json.write(
              obj("jsonrpc", "2.0", "id", 1, "method", "initialize", "params",
                  obj("protocolVersion", "2025-11-25", "capabilities", obj(), "clientInfo", obj()))));
      String line =
          "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"type_text\","
              + "\"arguments\":{\"app\":\"" + PKG + "\",\"text\":\"\\u+041\"}}}";
      Map<String, Object> response = protocol.handle(line);
      require(response.containsKey("error"), "accepted: " + response);
      require(map(response.get("error")).get("code").equals(-32700), "code: " + response);
      require(calls[0] == 0, "backend was called");
    });

    test("element identity requires the same window and bounds within 6 px", () -> {
      Scene scene = new Scene();
      Element spec = scene.add("/0", "Button", "button", "Confirm", 10, 100, 110, 150);
      Element old = scene.screen().elements.get(1);
      Element replacement = copy(old);
      replacement.window = old.window + 1;
      Element moved = copy(old);
      moved.top += 300;
      moved.bottom += 300;
      Element jitter = copy(old);
      jitter.left += 3;
      require(!old.same(replacement), "different window accepted");
      require(!old.same(moved), "300 px movement accepted");
      require(old.same(jitter), "3 px jitter rejected");
      require(spec.same(old), "identical element rejected");
    });

    test("index is stale after a same-looking element arrives in a replacement window", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "confirm", "Confirm", 10, 100, 110, 150).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      scene.activity = PKG + "/.Replacement";
      scene.window = 8;
      scene.specs.get(0).window = 8;
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code + ": " + f.getMessage());
      require(engine.log.isEmpty() && engine.events.isEmpty(), "input sent: " + engine.log);
    });

    test("index is stale after the element moved 300 px on the main display", () -> {
      Scene scene = new Scene();
      Element button = scene.add("/0", "android.widget.Button", "confirm", "Confirm", 10, 100, 110, 150);
      button.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      button.top += 300;
      button.bottom += 300;
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code + ": " + f.getMessage());
      require(engine.log.isEmpty(), "input sent: " + engine.log);
    });

    test("indexed click taps the live element after a whole-window settle on a virtual display", () -> {
      Scene scene = new Scene();
      scene.display = 5;
      scene.add("/0", "android.widget.TextView", "", "Title", 0, 0, 1080, 100);
      Element button = scene.add("/1", "android.widget.Button", "ok", "OK", 100, 200, 300, 260);
      button.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "activeDisplay", 5);
      engine.read();
      for (Element e : scene.specs) {
        e.top += 120;
        e.bottom += 120;
      }
      engine.call("click", args("element_index", 2));
      require(engine.log.contains("shell /system/bin/input -d 5 tap 200 350"), "tap: " + engine.log);
    });

    test("one element moving alone on a virtual display is stale", () -> {
      Scene scene = new Scene();
      scene.display = 5;
      scene.add("/0", "android.widget.TextView", "", "Title", 0, 0, 1080, 100);
      Element button = scene.add("/1", "android.widget.Button", "ok", "OK", 100, 200, 300, 260);
      button.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "activeDisplay", 5);
      engine.read();
      button.top += 120;
      button.bottom += 120;
      Failure f = failure(() -> engine.call("click", args("element_index", 2)));
      require(f.code.equals("STALE_ELEMENT"), f.code + ": " + f.getMessage());
      require(engine.log.isEmpty(), "input sent: " + engine.log);
    });

    test("stale-element errors never include node text", () -> {
      Scene scene = new Scene();
      Element secret = scene.add("/0", "android.widget.EditText", "pin", "SYNTHETIC-SECRET-ONLY", 0, 100, 1080, 200);
      secret.password = true;
      secret.editable = true;
      secret.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      secret.text = "SYNTHETIC-CHANGED";
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code);
      require(!f.getMessage().contains("SYNTHETIC"), "diagnostic disclosed text: " + f.getMessage());
    });

    // A wheel that settled on another value after the state was read: same path and position.
    test("a stale element names the text as what changed, without the text", () -> {
      Scene scene = new Scene();
      Element value = scene.add("/0/3/1", "android.widget.TextView", "minute", "SYNTHETIC-20", 96, 427, 984, 560);
      value.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      value.text = "SYNTHETIC-21";
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code);
      require(f.getMessage().contains("changed: text;"), "message: " + f.getMessage());
      require(!f.getMessage().contains("SYNTHETIC"), "diagnostic disclosed text: " + f.getMessage());
      require(engine.log.isEmpty(), "input sent: " + engine.log);
    });

    test("a stale element names a size change and shows both bounds", () -> {
      Scene scene = new Scene();
      Element key = scene.add("/0/5", "android.widget.Button", "equals", "=", 96, 427, 384, 660);
      key.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      key.right = 360; // still scaled by its press animation
      key.bottom = 630;
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code);
      require(f.getMessage().contains("changed: bounds;"), "message: " + f.getMessage());
      require(f.getMessage().contains("96,427,384,660") && f.getMessage().contains("96,427,360,630"),
          "bounds not shown: " + f.getMessage());
    });

    test("a stale element after a new activity names the activity", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      scene.activity = PKG + "/.Details";
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code);
      require(f.getMessage().contains("changed: activity;"), "message: " + f.getMessage());
    });

    test("secondary action whose label changed under the same id is not performed", () -> {
      Scene scene = new Scene();
      Element row = scene.add("/0", "android.widget.LinearLayout", "row", "Message", 0, 100, 1080, 300);
      row.actions.put("action_16777217:Archive", 16777217);
      FakeNode node = scene.node(row).with(16777217);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      row.actions.clear();
      row.actions.put("action_16777217:Delete permanently", 16777217);
      Failure f =
          failure(() -> engine.call(
              "perform_secondary_action", args("element_index", 1, "action", "action_16777217:Archive")));
      require(f.code.equals("STALE_ELEMENT"), f.code + ": " + f.getMessage());
      require(node.performed.isEmpty(), "performed " + node.performed);
    });

    test("unchanged secondary action is performed once", () -> {
      Scene scene = new Scene();
      Element row = scene.add("/0", "android.widget.LinearLayout", "row", "Message", 0, 100, 1080, 300);
      row.actions.put("action_16777217:Archive", 16777217);
      FakeNode node = scene.node(row).with(16777217);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("perform_secondary_action", args("element_index", 1, "action", "action_16777217:Archive"));
      require(node.performed.equals(List.of(16777217)), "performed " + node.performed);
    });

    test("failed screenshot keeps the last returned state in force", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "", "Alpha", 0, 100, 1080, 200).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      Screen previous = engine.read();
      Screen unseen = engine.observe(PKG);
      Failure f =
          failure(() -> invoke(engine, "result", new Class<?>[] {Screen.class, boolean.class}, unseen, true));
      require(f.code.equals("SCREENSHOT_FAILED"), f.code);
      require(get(engine, "latest") == previous, "unreturned state was published");
    });

    test("index from the last returned state is not resolved against an unreturned read", () -> {
      Scene scene = new Scene();
      Element first = scene.add("/0", "android.widget.Button", "", "Alpha", 0, 100, 1080, 200);
      Element second = scene.add("/1", "android.widget.Button", "", "Beta", 0, 300, 1080, 400);
      first.clickable = second.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      first.text = "Beta";
      second.text = "Alpha";
      Failure capture = failure(() -> engine.call("get_app_state", args("includeScreenshot", true)));
      require(capture.code.equals("SCREENSHOT_FAILED"), capture.code);
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("STALE_ELEMENT"), f.code + ": " + f.getMessage() + " " + engine.log);
      require(engine.log.isEmpty(), "input sent: " + engine.log);
    });

    test("failed screenshot after batch input requires a fresh read", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "", "Alpha", 0, 100, 1080, 200).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Failure capture =
          failure(() -> engine.call("run_actions", args(
              "actions", List.of(obj("method", "click", "element_index", 1)), "includeScreenshot", true)));
      require(capture.code.equals("SCREENSHOT_FAILED"), capture.code);
      engine.log.clear();
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("OBSERVATION_REQUIRED"), f.code);
      require(engine.log.isEmpty(), "input sent: " + engine.log);
    });

    test("a tap whose input tool started and failed is never repeated as an accessibility click", () -> {
      Scene scene = new Scene();
      Element button = scene.add("/0", "android.widget.Button", "submit", "Submit", 100, 200, 300, 260);
      button.clickable = true;
      FakeNode node = scene.node(button).with(AccessibilityNodeInfo.ACTION_CLICK);
      node.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.shellHook = tap -> AndroidEngine.command("/bin/sh", "-c", "exit 7");
      engine.read();
      Failure f = failure(() -> engine.call("click", args("element_index", 1)));
      require(f.code.equals("ACTION_UNCONFIRMED"), f.code + ": " + f.getMessage());
      require(node.performed.isEmpty(), "replayed as " + node.performed);
      Failure next = failure(() -> engine.call("click", args("element_index", 1)));
      require(next.code.equals("OBSERVATION_REQUIRED"), "after unknown outcome: " + next.code);
    });

    test("a tap whose input tool could not start falls back and says why", () -> {
      Scene scene = new Scene();
      Element button = scene.add("/0", "android.widget.Button", "submit", "Submit", 100, 200, 300, 260);
      button.clickable = true;
      FakeNode node = scene.node(button).with(AccessibilityNodeInfo.ACTION_CLICK);
      node.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.shellHook = tap -> AndroidEngine.command("/nonexistent/opencu-host-input");
      engine.read();
      Map<String, Object> result = engine.call("click", args("element_index", 1));
      require(node.performed.equals(List.of(AccessibilityNodeInfo.ACTION_CLICK)), "click " + node.performed);
      require(text(result).contains("could not start"), "no reason: " + text(result).split("\n")[0]);
    });

    test("type_text without a focused editor sends nothing", () -> {
      Scene scene = new Scene();
      Element first = scene.add("/0", "android.widget.EditText", "first", "", 0, 100, 1080, 200);
      Element second = scene.add("/1", "android.widget.EditText", "second", "", 0, 300, 1080, 400);
      first.editable = second.editable = true;
      for (Element e : List.of(first, second)) {
        FakeNode n = scene.node(e).with(AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT,
            AccessibilityNodeInfo.ACTION_FOCUS);
        n.editable = true;
      }
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      long started = System.nanoTime();
      Failure f = failure(() -> engine.call("type_text", args("text", "hello")));
      require(f.code.equals("NO_FOCUSED_ELEMENT"), f.code + ": " + f.getMessage());
      require(engine.events.isEmpty() && engine.log.isEmpty(), "input sent: " + engine.log);
      for (FakeNode n : scene.nodes) require(n.performed.isEmpty(), "performed " + n.performed);
      require(System.nanoTime() - started < 2_000_000_000L, "waited for a focus nobody requested");
    });

    test("a scroll that moved the list counts even when the action returned false", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.results.put(DOWN, false);
      rows.node.effects.put(DOWN, () -> rows.show(rows.offset + 2));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 1, "direction", "down"));
      String head = text(result).split("\n")[0];
      require(!head.contains("end") && !head.contains("Nothing"), "claimed no movement: " + head);
      require(rows.offset == 2, "list did not move");
    });

    test("a scroll that changed nothing stops at the first page and says so", () -> {
      ListScene rows = new ListScene(DOWN);
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      Map<String, Object> result =
          engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 3));
      require(rows.node.performed.size() == 1, "kept scrolling: " + rows.node.performed.size() + " actions");
      require(text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
    });

    test("multi-page scroll stops at the first page that did not move", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(Math.min(rows.offset + 2, 4)));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      Map<String, Object> result =
          engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 5));
      require(rows.node.performed.size() == 3, "actions sent: " + rows.node.performed.size());
      require(text(result).startsWith("Scrolled 2 of 5 pages; reached the end"), "notice: " + text(result).split("\n")[0]);
    });

    test("a list that offers no scroll that way gets nothing sent", () -> {
      ListScene rows = new ListScene(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD);
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 1, "direction", "down"));
      require(rows.node.performed.isEmpty(), "sent " + rows.node.performed);
      require(text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
    });

    test("a wheel picker whose new value shows late counts as moved", () -> {
      PickerScene picker = new PickerScene();
      long[] sent = {0};
      picker.node.effects.put(FORWARD, () -> sent[0] = android.os.SystemClock.uptimeMillis());
      ScriptedEngine engine = ScriptedEngine.create(picker.scene);
      // The wheel animates first; its value changes 600 ms after the action.
      engine.onObserve = n -> {
        if (sent[0] > 0 && android.os.SystemClock.uptimeMillis() - sent[0] >= 600) picker.wheel.text = "21";
      };
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 1, "direction", "down"));
      require(picker.node.performed.equals(List.of(FORWARD)), "actions " + picker.node.performed);
      require(!text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
    });

    test("a wheel whose only change is the selected item counts as moved", () -> {
      PickerScene picker = new PickerScene();
      Element[] items = {
        picker.scene.add("/0/1", "android.widget.TextView", "", "19", 600, 900, 900, 1100),
        picker.scene.add("/0/2", "android.widget.TextView", "", "20", 600, 1100, 900, 1300),
        picker.scene.add("/0/3", "android.widget.TextView", "", "21", 600, 1300, 900, 1500)
      };
      items[1].selected = true;
      picker.node.effects.put(FORWARD, () -> {
        items[1].selected = false;
        items[2].selected = true;
      });
      ScriptedEngine engine = ScriptedEngine.create(picker.scene);
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 1, "direction", "down"));
      require(!text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
    });

    test("a list that bounces back at its end has not moved", () -> {
      ListScene rows = new ListScene(DOWN);
      long[] bounce = {0};
      rows.node.effects.put(DOWN, () -> bounce[0] = android.os.SystemClock.uptimeMillis() + 200);
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      // An overscroll spring: the rows shift and glide back to where they were within 200 ms.
      engine.onObserve = n -> {
        int shift = (int) Math.max(0, (bounce[0] - android.os.SystemClock.uptimeMillis()) / 4);
        rows.first.top = 100 - shift;
        rows.second.top = 300 - shift;
      };
      engine.read();
      Map<String, Object> result =
          engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 3));
      require(rows.node.performed.size() == 1, "pages sent: " + rows.node.performed.size());
      require(text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
    });

    test("scroll up uses an enclosing element's scroll-up action when the list offers only forward", () -> {
      NestedListScene nested = new NestedListScene();
      nested.outerNode.with(BACKWARD, UP);
      nested.outerNode.effects.put(UP, () -> nested.rows.show(nested.rows.offset - 2));
      ScriptedEngine engine = ScriptedEngine.create(nested.rows.scene);
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 2, "direction", "up"));
      require(nested.outerNode.performed.equals(List.of(UP)), "enclosing element got " + nested.outerNode.performed);
      require(nested.rows.node.performed.isEmpty(), "list got " + nested.rows.node.performed);
      require(nested.rows.offset == 2, "list offset " + nested.rows.offset);
      require(!text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
      require(text(result).contains("enclosing element"), "path not reported: " + text(result).split("\n")[0]);
    });

    test("an enclosing pager's generic backward is never taken as up; a still swipe inside the list is", () -> {
      NestedListScene nested = new NestedListScene();
      nested.outer.clazz = "androidx.viewpager.widget.ViewPager";
      nested.outerNode.with(FORWARD, BACKWARD); // a horizontal pager: backward is the previous tab
      ScriptedEngine engine = ScriptedEngine.create(nested.rows.scene);
      int[] lifts = {0};
      engine.onObserve = n -> {
        long ups = engine.events.stream().filter(e -> e.action == 1).count();
        for (; lifts[0] < ups; lifts[0]++) nested.rows.show(nested.rows.offset - 2);
      };
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 2, "direction", "up"));
      require(nested.outerNode.performed.isEmpty() && nested.rows.node.performed.isEmpty(),
          "actions: pager " + nested.outerNode.performed + " list " + nested.rows.node.performed);
      List<int[]> points = motions(engine);
      require(!points.isEmpty(), "no swipe sent; notice: " + text(result).split("\n")[0]);
      int[] first = points.get(0), last = points.get(points.size() - 1);
      require(first[0] == 0 && last[0] == 1, "gesture " + engine.log);
      for (int[] p : points)
        require(p[1] == 540 && p[2] > 300 && p[2] < 2000 && p[3] == 0, "point outside the list: " + engine.log);
      require(last[2] > first[2] + 600, "finger did not move down for up: " + first[2] + " to " + last[2]);
      int still = 0;
      for (int i = points.size() - 2; i >= 0 && points.get(i)[2] == last[2]; i--) still++;
      require(still >= 4, "lifted without holding still: " + still + " moves at the end");
      require(nested.rows.offset == 2, "list offset " + nested.rows.offset);
      require(!text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
      require(text(result).contains("swipe"), "path not reported: " + text(result).split("\n")[0]);
    });

    test("scroll by the index of a row moves the list that holds it", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(rows.offset + 2));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      Map<String, Object> result = engine.call("scroll", args("element_index", 2, "direction", "down"));
      require(rows.node.performed.equals(List.of(DOWN)), "list got " + rows.node.performed);
      require(rows.offset == 2 && !text(result).startsWith("Nothing moved"), "notice: " + text(result).split("\n")[0]);
    });

    test("a horizontal list's forward is not taken as down", () -> {
      ListScene rows = new ListScene(FORWARD, RIGHT);
      rows.list.clazz = "android.widget.HorizontalScrollView";
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      engine.call("scroll", args("element_index", 1, "direction", "down"));
      require(rows.node.performed.isEmpty(), "scrolled sideways with " + rows.node.performed);
    });

    test("a scroll swipe stays above the keyboard", () -> {
      ListScene rows = new ListScene(BACKWARD);
      rows.list.bottom = 2300;
      Window keyboard = new Window();
      keyboard.id = 11;
      keyboard.type = 2;
      keyboard.layer = 9;
      keyboard.left = 0;
      keyboard.top = 1500;
      keyboard.right = 1080;
      keyboard.bottom = 2400;
      rows.scene.extraWindows.add(keyboard);
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      engine.call("scroll", args("element_index", 1, "direction", "down"));
      List<int[]> points = motions(engine);
      require(!points.isEmpty(), "no swipe sent: " + engine.log);
      for (int[] p : points) require(p[2] > 100 && p[2] < 1500, "touch on the keyboard or outside the list: " + engine.log);
    });

    test("an element that nothing around scrolls gets nothing sent", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Title", 0, 100, 1080, 300);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Failure f = failure(() -> engine.call("scroll", args("element_index", 1, "direction", "down")));
      require(f.code.equals("ACTION_UNSUPPORTED"), f.code + ": " + f.getMessage());
      require(engine.events.isEmpty() && engine.log.isEmpty(), "input sent: " + engine.log);
    });

    test("a multi-page scroll lists the rows it passed over, in order", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(Math.min(rows.offset + 2, 8)));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 5)));
      require(out.startsWith("Scrolled 4 of 5 pages; reached the end"), "notice: " + out.split("\n")[0]);
      int header = out.indexOf("Passed over while scrolling (8 distinct rows");
      require(header > 0, "no passed-over rows: " + out);
      int at = header;
      for (int row = 1; row <= 8; row++) {
        int next = out.indexOf("\n- Row " + row + "\n", at);
        require(next > at - 1, "Row " + row + " missing or out of order: " + out);
        at = next;
      }
      require(out.indexOf("Foreground:") > at, "rows not before the state: " + out);
    });

    test("a single-page scroll adds no passed-over rows", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(rows.offset + 2));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down")));
      require(!out.contains("Passed over"), "rows for one page: " + out);
    });

    test("passed-over rows are bounded to 200 rows of at most 200 characters", () -> {
      Scene scene = new Scene();
      Element list = scene.add("/0", "androidx.recyclerview.widget.RecyclerView", "rows", "", 0, 100, 1080, 2300);
      list.scrollable = true;
      FakeNode node = scene.node(list).with(DOWN);
      node.scrollable = true;
      List<Element> items = new ArrayList<>();
      for (int i = 0; i < 12; i++)
        items.add(scene.add("/0/" + i, "android.widget.TextView", "", "", 0, 100 + i * 180, 1080, 280 + i * 180));
      int[] offset = {0};
      Runnable show = () -> {
        for (int i = 0; i < 12; i++)
          items.get(i).text = "Item " + (offset[0] + i + 1) + (offset[0] + i == 0 ? " " + "x".repeat(400) : "");
      };
      show.run();
      node.effects.put(DOWN, () -> {
        offset[0] += 12;
        show.run();
      });
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 20)));
      require(out.contains("Passed over while scrolling (240 distinct rows"), "header: " + out.split("\n")[0] + " / " + out.split("\n")[1]);
      long listed = out.lines().filter(l -> l.startsWith("- Item ")).count();
      require(listed == 200, "rows listed: " + listed);
      require(out.contains("- … 40 more rows not shown"), "no overflow line");
      require(out.lines().allMatch(l -> l.length() <= 202), "a row longer than 200 characters");
      require(out.contains("- Item 200\n") && !out.contains("- Item 201\n"), "not the first 200 in order");
    });

    test("a collapsing toolbar that re-indexes the screen does not stop a multi-page scroll", () -> {
      ListScene rows = new ListScene(DOWN);
      Element title = new Element();
      title.window = rows.scene.window;
      title.path = "/1";
      title.pkg = PKG;
      title.clazz = "android.widget.TextView";
      title.text = "Alarms";
      title.left = 0;
      title.top = 0;
      title.right = 1080;
      title.bottom = 100;
      rows.scene.specs.add(0, title);
      rows.scene.nodes.add(0, FakeNode.create());
      rows.node.effects.put(DOWN, () -> {
        rows.show(rows.offset + 2);
        if (rows.scene.specs.get(0) == title) {
          // The toolbar collapses: its title goes and the list grows upwards.
          rows.scene.specs.remove(0);
          rows.scene.nodes.remove(0);
          rows.list.top = 40;
        }
      });
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 2, "direction", "down", "pages", 3)));
      require(rows.node.performed.size() == 3, "pages sent " + rows.node.performed.size() + ": " + out.split("\n")[0]);
      require(rows.offset == 6, "offset " + rows.offset);
      require(!out.startsWith("Scrolled"), "notice: " + out.split("\n")[0]);
    });

    test("a new activity ends a multi-page scroll with a plain notice", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> {
        rows.show(rows.offset + 2);
        rows.scene.activity = PKG + "/.Details";
      });
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 3)));
      require(rows.node.performed.size() == 1, "pages sent " + rows.node.performed.size());
      require(out.startsWith("Scrolled 1 of 3 pages; the scrolled element was not found on the new screen"),
          "notice: " + out.split("\n")[0]);
    });

    test("a multi-page scroll never moves on to another list of the same kind elsewhere", () -> {
      Scene scene = new Scene();
      Element first = scene.add("/0", "androidx.recyclerview.widget.RecyclerView", "", "", 0, 100, 1080, 1000);
      Element other = scene.add("/1", "androidx.recyclerview.widget.RecyclerView", "", "", 0, 1100, 1080, 2000);
      first.scrollable = other.scrollable = true;
      FakeNode firstNode = scene.node(first).with(DOWN), otherNode = scene.node(other).with(DOWN);
      firstNode.scrollable = otherNode.scrollable = true;
      // The first list goes away after its first page, as when a section collapses.
      firstNode.effects.put(DOWN, () -> {
        scene.nodes.remove(scene.specs.indexOf(first));
        scene.specs.remove(first);
      });
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 3)));
      require(otherNode.performed.isEmpty(), "scrolled the other list " + otherNode.performed.size() + " times");
      require(out.startsWith("Scrolled 1 of 3 pages; the scrolled element was not found"), "notice: " + out.split("\n")[0]);
    });

    test("a wheel picker scrolls one value per page across many pages", () -> {
      PickerScene picker = new PickerScene();
      picker.node.effects.put(FORWARD, () ->
          picker.wheel.text = Integer.toString(Integer.parseInt(picker.wheel.text) + 1));
      ScriptedEngine engine = ScriptedEngine.create(picker.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 15)));
      require(picker.node.performed.size() == 15, "pages sent " + picker.node.performed.size() + ": " + out.split("\n")[0]);
      require(picker.wheel.text.equals("35"), "value " + picker.wheel.text);
      require(!out.startsWith("Scrolled"), "notice: " + out.split("\n")[0]);
      require(out.contains("\n- 20\n") && out.contains("\n- 34\n"), "values passed over: " + out);
    });

    test("scroll description explains pages up to 20", () -> {
      String description = (String) Protocol.DEFINITIONS.get("scroll").get("description");
      require(description.contains("pages (up to 20"), description);
      require(description.contains("stops early at the end"), description);
      Protocol.validate("scroll", args("element_index", 1, "direction", "down", "pages", 20));
      Failure f = failure(() -> Protocol.validate("scroll", args("element_index", 1, "direction", "down", "pages", 21)));
      require(f.code.equals("INVALID_ARGUMENT"), f.code);
    });

    test("batch step is checked against a fresh read, not the previous step's state", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "next", "Next", 100, 200, 300, 260).clickable = true;
      scene.add("/1", "android.widget.Button", "send", "Send", 100, 400, 300, 460).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      int[] resolves = {0};
      engine.resolveHook = () -> {
        // The second resolve happens just before step 2: the app opens a dialog right then.
        if (++resolves[0] == 2) {
          Window dialog = new Window();
          dialog.id = 9;
          dialog.type = 1;
          dialog.pkg = PKG;
          dialog.layer = 5;
          dialog.left = 100;
          dialog.top = 800;
          dialog.right = 980;
          dialog.bottom = 1400;
          dialog.focused = dialog.active = true;
          scene.extraWindows.add(dialog);
        }
      };
      Map<String, Object> result =
          engine.call("run_actions", args("actions", List.of(
              obj("method", "click", "element_index", 1),
              obj("method", "click", "element_index", 2, "until", obj("app", PKG)))));
      long taps = engine.log.stream().filter(line -> line.contains(" tap ")).count();
      require(taps == 1, "taps sent: " + engine.log);
      require(String.valueOf(map(result.get("_meta")).get("opencu/batch")).contains("reason=popup"),
          "batch: " + map(result.get("_meta")).get("opencu/batch"));
    });

    test("a batch step that could outlast the batch time limit is not started", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "hold", "Hold", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      // If anything is sent, end the call at once instead of holding for minutes.
      engine.checkHook = () -> {
        if (!engine.events.isEmpty() || !engine.log.isEmpty()) throw Core.fail("PERSON_ACTIVE", "test stop");
      };
      Map<String, Object> result =
          engine.call("run_actions", args("actions", List.of(obj(
              "method", "click", "element_index", 1, "click_count", 3, "duration", 30,
              "until", obj("text", "never", "timeoutMs", 20000)))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require("time_limit".equals(batch.get("reason")) && Integer.valueOf(1).equals(batch.get("stoppedStep")),
          "batch " + batch + " sent " + engine.events.size() + " events");
      require(engine.events.isEmpty() && engine.log.isEmpty(), "input sent: " + engine.log);
      require("BATCH_TIME_LIMIT".equals(map(result.get("_meta")).get("opencu/error")), "error " + result.get("_meta"));
    });

    test("a batch stops before the step that would pass its time limit", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Ready", 0, 100, 1080, 200);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.batchLimit = 3_000L;
      engine.read();
      Map<String, Object> result =
          engine.call("run_actions", args("actions", List.of(
              obj("method", "wait", "ms", 500), obj("method", "wait", "ms", 500), obj("method", "wait", "ms", 500))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require(Integer.valueOf(1).equals(batch.get("completed")) && Integer.valueOf(2).equals(batch.get("stoppedStep"))
          && "time_limit".equals(batch.get("reason")), "batch " + batch);
    });

    test("a scroll step whose pages could outlast the batch limit is not started", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(rows.offset + 2));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.batchLimit = 15_000L;
      engine.read();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "scroll", "element_index", 1, "direction", "down", "pages", 20))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require(rows.node.performed.isEmpty(), "scrolled " + rows.node.performed.size() + " pages; batch " + batch);
      require("time_limit".equals(batch.get("reason")), "batch " + batch);
    });

    test("a key hold that could outlast the batch limit is not started", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Ready", 0, 100, 1080, 200);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.batchLimit = 20_000L;
      engine.read();
      // If the hold starts, end the call at once instead of holding for half a minute.
      engine.checkHook = () -> {
        if (!engine.events.isEmpty()) throw Core.fail("PERSON_ACTIVE", "test stop");
      };
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "press_key", "key", "back", "duration", 30))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require(engine.events.isEmpty() && "time_limit".equals(batch.get("reason")),
          "batch " + batch + " after " + engine.events.size() + " key events");
    });

    test("an until wait without timeoutMs counts its 8 s default", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Ready", 0, 100, 1080, 200);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.batchLimit = 9_000L;
      engine.read();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "wait", "ms", 1, "until", obj("text", "Ready")))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require("time_limit".equals(batch.get("reason")) && Integer.valueOf(0).equals(batch.get("completed")), "batch " + batch);
    });

    test("multi-page scroll stops at the batch deadline", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> {
        android.os.SystemClock.sleep(2_500); // a slow app: each page takes longer than estimated
        rows.show(rows.offset + 2);
      });
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.batchLimit = 5_500L;
      engine.read();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "scroll", "element_index", 1, "direction", "down", "pages", 3))));
      require(rows.node.performed.size() == 2, "pages sent " + rows.node.performed.size());
      require(text(result).contains("stopped at the batch time limit"), "notice: " + text(result).split("\n")[1]);
    });

    test("an until wait ends at the batch deadline", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> {
        android.os.SystemClock.sleep(4_500);
        rows.show(rows.offset + 2);
      });
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.batchLimit = 7_000L;
      engine.read();
      long started = System.nanoTime();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "scroll", "element_index", 1, "direction", "down",
              "until", obj("text", "never", "timeoutMs", 3000)))));
      long ms = (System.nanoTime() - started) / 1_000_000;
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require("time_limit".equals(batch.get("reason")), "batch " + batch + " after " + ms + " ms");
      require(ms < 7_400, "call took " + ms + " ms");
    });

    test("run_actions description states the batch time limit", () -> {
      String description = (String) Protocol.DEFINITIONS.get("run_actions").get("description");
      require(description.contains("100 s") && description.contains("time_limit"), description);
    });

    test("a batch is limited to 100 s, inside a host's two-minute call", () -> {
      // The engine's own limit, as an unconfigured engine applies it.
      long limit = ScriptedEngine.create(new Scene()).batchLimitMs();
      require(limit == 100_000, "engine batch limit " + limit + " ms");
      String description = (String) Protocol.DEFINITIONS.get("run_actions").get("description");
      require(description.contains("limited to " + limit / 1000 + " s:"), "description: " + description);
    });

    test("an input call's final state waits until the animation it started ends", () -> {
      AnimatedScene calc = new AnimatedScene(900);
      ScriptedEngine engine = calc.engine();
      engine.read();
      Map<String, Object> result = engine.call("click", args("element_index", 1));
      require(text(result).contains("text=\"21\" id=result bounds=0,600,1080,800"), "mid-animation state: " + text(result));
      Map<String, Object> settle = map(map(result.get("_meta")).get("opencu/settle"));
      require(Boolean.TRUE.equals(settle.get("stable")), "settle " + settle);
      require(((Number) settle.get("waitedMs")).longValue() >= 400, "settle " + settle);
    });

    test("a batch's final state waits until the animation its last step started ends", () -> {
      AnimatedScene calc = new AnimatedScene(900);
      ScriptedEngine engine = calc.engine();
      engine.read();
      Map<String, Object> result =
          engine.call("run_actions", args("actions", List.of(obj("method", "click", "element_index", 1))));
      require(text(result).contains("text=\"21\" id=result bounds=0,600,1080,800"), "mid-animation state: " + text(result));
      Map<String, Object> meta = map(result.get("_meta"));
      require(meta.get("opencu/settle") != null && Boolean.TRUE.equals(map(meta.get("opencu/settle")).get("stable")),
          "meta " + meta);
      require(Integer.valueOf(1).equals(map(meta.get("opencu/batch")).get("completed")), "batch " + meta);
    });

    test("the wait for a stable final state is bounded to 1.5 s", () -> {
      AnimatedScene clock = new AnimatedScene(60_000);
      ScriptedEngine engine = clock.engine();
      engine.read();
      long started = System.nanoTime();
      Map<String, Object> result = engine.call("click", args("element_index", 1));
      long ms = (System.nanoTime() - started) / 1_000_000;
      Map<String, Object> settle = map(map(result.get("_meta")).get("opencu/settle"));
      require(Boolean.FALSE.equals(settle.get("stable")), "settle " + settle);
      long waited = ((Number) settle.get("waitedMs")).longValue();
      require(waited >= 1300 && waited <= 1700, "settle " + settle);
      require(ms < 3000, "call took " + ms + " ms");
    });

    test("a batch's final-state wait ends at the batch deadline", () -> {
      ListScene rows = new ListScene(DOWN);
      Element ticker = rows.scene.add("/1", "android.widget.TextView", "", "0", 0, 2100, 1080, 2200);
      rows.node.effects.put(DOWN, () -> {
        android.os.SystemClock.sleep(2_500); // a slow app
        rows.show(rows.offset + 2);
      });
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.batchLimit = 3_500L;
      engine.read();
      engine.onObserve = n -> ticker.text = Integer.toString(n); // something always changes
      long started = System.nanoTime();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "scroll", "element_index", 1, "direction", "down"))));
      long ms = (System.nanoTime() - started) / 1_000_000;
      Map<String, Object> meta = map(result.get("_meta"));
      require(meta.get("opencu/batch") != null && map(meta.get("opencu/batch")).get("reason") == null, "batch " + meta);
      require(meta.get("opencu/settle") != null, "no settle reported: " + meta);
      long waited = ((Number) map(meta.get("opencu/settle")).get("waitedMs")).longValue();
      require(waited < 1000, "settle waited " + waited + " ms with less than a second left");
      require(ms < 3_500 + 250, "call took " + ms + " ms");
    });

    test("indexed click settles before its final read", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.trace.clear();
      engine.call("click", args("element_index", 1));
      List<String> before = engine.trace.subList(0, engine.trace.indexOf("shell"));
      require(before.lastIndexOf("idle") < before.lastIndexOf("observe"), "order before tap: " + before);
    });

    test("an interrupted command does not leave its child running", () -> {
      java.nio.file.Path pidFile = java.nio.file.Files.createTempFile("opencu-child", ".pid");
      java.util.concurrent.atomic.AtomicReference<Throwable> error = new java.util.concurrent.atomic.AtomicReference<>();
      Thread worker = new Thread(() -> {
        try {
          AndroidEngine.command(sleeper(pidFile));
        } catch (Throwable t) {
          error.set(t);
        }
      });
      worker.start();
      ProcessHandle child = awaitChild(pidFile);
      try {
        worker.interrupt();
        worker.join(2000);
        require(error.get() instanceof InterruptedException, "worker: " + error.get());
        require(exits(child, 1000), "child still running after its command was interrupted");
      } finally {
        child.destroyForcibly();
        worker.join(1000);
        java.nio.file.Files.deleteIfExists(pidFile);
      }
    });

    test("closing the connection kills running commands and refuses new ones", () -> {
      java.nio.file.Path pidFile = java.nio.file.Files.createTempFile("opencu-child", ".pid");
      ScriptedEngine engine = ScriptedEngine.create(new Scene());
      Thread worker = new Thread(() -> {
        try {
          AndroidEngine.command(sleeper(pidFile));
        } catch (Throwable ignored) {
        }
      });
      worker.start();
      ProcessHandle child = awaitChild(pidFile);
      try {
        try {
          engine.close();
        } catch (Throwable ignored) {
        }
        require(exits(child, 1500), "child survived the connection");
        Exception refused = null;
        try {
          AndroidEngine.command("/bin/sh", "-c", "exit 0");
        } catch (Exception e) {
          refused = e;
        }
        require(refused instanceof Failure && ((Failure) refused).code.equals("ENGINE_STOPPING"),
            "command started after close: " + refused);
      } finally {
        child.destroyForcibly();
        worker.join(1000);
        reopenCommands();
        java.nio.file.Files.deleteIfExists(pidFile);
      }
    });

    test("a key hold is released on the display and connection it started on", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Agent app", 0, 100, 1080, 200);
      ScriptedEngine engine = onAgentDisplay(scene);
      UiAutomation agent = (UiAutomation) get(engine, "automation"), main = (UiAutomation) get(engine, "mainAutomation");
      engine.read();
      boolean[] switched = {false};
      engine.checkHook = () -> {
        if (!engine.events.isEmpty() && !switched[0]) {
          // Shutdown restores the main route while the key is held.
          switched[0] = true;
          set(engine, "activeDisplay", 0);
          set(engine, "automation", main);
          throw Core.fail("ENGINE_STOPPING", "Stdin closed");
        }
      };
      failure(() -> engine.call("press_key", args("key", "back", "duration", 0.3)));
      require(engine.events.size() == 2, "events " + engine.events.size());
      Event release = engine.events.get(1);
      require(release.via == agent && release.display == 5,
          "release went to display " + release.display + (release.via == main ? " via the main connection" : ""));
    });

    test("a long press is cancelled on the display and connection it started on", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "hold", "Hold", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = onAgentDisplay(scene);
      UiAutomation agent = (UiAutomation) get(engine, "automation"), main = (UiAutomation) get(engine, "mainAutomation");
      engine.read();
      boolean[] switched = {false};
      engine.checkHook = () -> {
        if (!engine.events.isEmpty() && !switched[0]) {
          // Shutdown restores the main route while the touch is down.
          switched[0] = true;
          set(engine, "activeDisplay", 0);
          set(engine, "automation", main);
          throw Core.fail("ENGINE_STOPPING", "Stdin closed");
        }
      };
      failure(() -> engine.call("click", args("element_index", 1, "duration", 0.6)));
      require(engine.events.size() == 2, "events " + engine.events.size());
      Event cancel = engine.events.get(1);
      require(cancel.action == 3, "second event " + cancel.action);
      require(cancel.via == agent && cancel.display == 5,
          "cancel went to display " + cancel.display + (cancel.via == main ? " via the main connection" : ""));
    });

    test("a gesture stalled across shutdown never starts on the restored main route", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "hold", "Hold", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = onAgentDisplay(scene);
      engine.read();
      CountDownLatch stalled = new CountDownLatch(1), resume = new CountDownLatch(1);
      engine.beforeInjectHook = () -> {
        // A platform call between the last check and the first event blocks past shutdown's wait.
        stalled.countDown();
        resume.await(10, TimeUnit.SECONDS);
      };
      Thread worker = new Thread(() -> {
        try {
          engine.call("click", args("element_index", 1, "duration", 0.6));
        } catch (Throwable ignored) {
        }
      });
      worker.start();
      require(stalled.await(5, TimeUnit.SECONDS), "gesture never reached injection");
      try {
        engine.close();
      } catch (Throwable ignored) {
      }
      require((Integer) get(engine, "activeDisplay") == 0, "shutdown did not restore the main route");
      resume.countDown();
      worker.join(3000);
      reopenCommands();
      List<String> sentOn = new ArrayList<>();
      for (Event e : engine.events) sentOn.add(e.action + "@" + e.display);
      require(engine.events.isEmpty(), "events after shutdown: " + sentOn);
    });

    // Each first send re-checks the connection after reading its route. Stall the last check
    // before it, let shutdown restore the main route, then let the call resume.
    Object[][] firstSends = {
      {"an activity start", "activate", 2, "activate_app"},
      {"an accessibility action", "accessibility", 1, "set_value"},
      {"a shell tap", "shellTap", 1, "click"},
      {"a key", "key", 1, "press_key"},
      // perform checks at entry and before its switch; the third is the scroll's own.
      {"a scroll action", "perform", 3, "scroll"},
      {"a touch", "touch", 1, "long press"},
    };
    for (Object[] path : firstSends)
      test(path[0] + " stalled across shutdown sends nothing on the restored main route", () -> {
        Scene scene = new Scene();
        Element target = scene.add("/0", "android.widget.EditText", "target", "", 100, 200, 300, 260);
        target.clickable = target.editable = target.scrollable = true;
        FakeNode node = scene.node(target).with(AccessibilityNodeInfo.ACTION_SET_TEXT, DOWN);
        node.editable = node.clickable = node.scrollable = true;
        ScriptedEngine engine = onAgentDisplay(scene);
        engine.read();
        if (path[3].equals("activate_app")) scene.foreground = "example.other";
        engine.stallCaller = (String) path[1];
        engine.stallOccurrence = (Integer) path[2];
        engine.stalled = new CountDownLatch(1);
        engine.resume = new CountDownLatch(1);
        Map<String, Object> request =
            path[3].equals("activate_app") ? args()
                : path[3].equals("set_value") ? args("element_index", 1, "value", "x")
                : path[3].equals("click") ? args("element_index", 1)
                : path[3].equals("press_key") ? args("key", "back")
                : path[3].equals("scroll") ? args("element_index", 1, "direction", "down")
                : args("element_index", 1, "duration", 0.6);
        String tool = path[3].equals("long press") ? "click" : (String) path[3];
        Thread worker = new Thread(() -> {
          try {
            engine.call(tool, request);
          } catch (Throwable ignored) {
          }
        });
        worker.start();
        require(engine.stalled.await(5, TimeUnit.SECONDS), "never reached the check before sending");
        try {
          engine.close();
        } catch (Throwable ignored) {
        }
        require((Integer) get(engine, "activeDisplay") == 0, "shutdown did not restore the main route");
        engine.resume.countDown();
        worker.join(3000);
        reopenCommands();
        List<String> sentOn = new ArrayList<>();
        for (String line : engine.log) if (line.startsWith("shell ")) sentOn.add(line);
        for (Event e : engine.events) sentOn.add(e.kind + " " + e.action + "@" + e.display);
        if (!node.performed.isEmpty()) sentOn.add("accessibility " + node.performed);
        require(sentOn.isEmpty(), "sent after shutdown: " + sentOn);
      });

    test("closing waits for an in-flight gesture before releasing the agent display", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Agent app", 0, 100, 1080, 200);
      ScriptedEngine engine = onAgentDisplay(scene);
      engine.read();
      Thread worker = new Thread(() -> {
        try {
          engine.call("press_key", args("key", "back", "duration", 0.5));
        } catch (Throwable ignored) {
        }
      });
      worker.start();
      long limit = System.nanoTime() + 2_000_000_000L;
      while (engine.events.isEmpty()) {
        require(System.nanoTime() < limit, "key never pressed");
        Thread.sleep(5);
      }
      try {
        engine.close();
      } catch (Throwable ignored) {
      }
      worker.join(2000);
      reopenCommands();
      List<String> order = new ArrayList<>();
      for (String line : engine.log) if (line.startsWith("key") || line.equals("stopDesktop")) order.add(line.split(" code")[0]);
      require(order.equals(List.of("key 0", "key 1", "stopDesktop")), "order " + order);
    });

    test("an idle agent display stops on the connection's worker without any call", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Agent app", 0, 100, 1080, 200);
      ScriptedEngine engine = onAgentDisplay(scene);
      set(engine, "desktopIdleMs", 300L);
      ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
      try {
        invoke(engine, "runOn", new Class<?>[] {ScheduledExecutorService.class}, worker);
        worker.submit(() -> engine.call("get_app_state", args())).get();
        Thread.sleep(900);
        require(engine.log.contains("stopDesktop"), "display still running after the idle time");
        Failure f = failure(() -> {
          try {
            worker.submit(() -> engine.call("get_app_state", args())).get();
          } catch (ExecutionException e) {
            throw (Exception) e.getCause();
          }
        });
        require(f.code.equals("AGENT_DESKTOP_IDLE_STOPPED"), f.code);
      } finally {
        worker.shutdownNow();
      }
    });

    test("status does not keep an expired agent display alive", () -> {
      Scene scene = new Scene();
      ScriptedEngine engine = onAgentDisplay(scene);
      set(engine, "lastCallAt", android.os.SystemClock.uptimeMillis() - 300_001L);
      Map<String, Object> status = engine.call("agent_desktop", obj("action", "status"));
      require(engine.log.contains("stopDesktop"), "expired display kept by status");
      require(text(status).contains("\"started\":false"), "status: " + text(status));
      Failure f = failure(() -> engine.call("get_app_state", args()));
      require(f.code.equals("AGENT_DESKTOP_IDLE_STOPPED"), f.code);
    });

    test("status before the idle deadline does not postpone the idle stop", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Agent app", 0, 100, 1080, 200);
      ScriptedEngine engine = onAgentDisplay(scene);
      set(engine, "desktopIdleMs", 800L);
      ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
      try {
        invoke(engine, "runOn", new Class<?>[] {ScheduledExecutorService.class}, worker);
        worker.submit(() -> engine.call("get_app_state", args())).get();
        long lastCall = System.nanoTime();
        Thread.sleep(400);
        // Status itself cannot render display details on the host; only its effect on the timer matters.
        worker.submit(() -> {
          try {
            engine.call("agent_desktop", obj("action", "status"));
          } catch (Throwable ignored) {
          }
        }).get();
        Thread.sleep(Math.max(0, 1050 - (System.nanoTime() - lastCall) / 1_000_000));
        require(engine.log.contains("stopDesktop"), "status postponed the idle stop");
      } finally {
        worker.shutdownNow();
      }
    });

    test("the idle stop never runs during an in-flight action", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.TextView", "", "Agent app", 0, 100, 1080, 200);
      ScriptedEngine engine = onAgentDisplay(scene);
      set(engine, "desktopIdleMs", 200L);
      engine.read();
      ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
      try {
        invoke(engine, "runOn", new Class<?>[] {ScheduledExecutorService.class}, worker);
        worker.submit(() -> engine.call("get_app_state", args())).get();
        worker.submit(() -> engine.call("press_key", args("key", "back", "duration", 0.6))).get();
        Thread.sleep(700);
        List<String> order = new ArrayList<>();
        for (String line : engine.log) if (line.startsWith("key") || line.equals("stopDesktop")) order.add(line.split(" code")[0]);
        require(order.equals(List.of("key 0", "key 1", "stopDesktop")), "order " + order);
        require(engine.log.stream().anyMatch(line -> line.startsWith("key 1") && line.contains("flags 0 ")),
            "key release was cancelled: " + engine.log);
      } finally {
        worker.shutdownNow();
      }
    });

    test("agent display start succeeds only with every isolation requirement", () -> {
      ScriptedEngine engine = desktopEngine();
      UiAutomation main = (UiAutomation) get(engine, "mainAutomation");
      TestDisplay display = new TestDisplay(5, ISOLATED);
      engine.displayScript = requested -> display;
      startDesktop(engine);
      require((Integer) get(engine, "desktopDisplay") == 5 && (Integer) get(engine, "activeDisplay") == 5, "not started");
      require(engine.disconnected.equals(List.of(main)) && !display.released, "disconnected " + engine.disconnected.size() + " connections");
    });

    test("agent display never falls back to an untrusted display", () -> {
      ScriptedEngine engine = desktopEngine();
      engine.displayScript = requested -> {
        if ((requested & (1 << 10)) != 0) throw new SecurityException("ADD_TRUSTED_DISPLAY");
        return new TestDisplay(5, 0);
      };
      Failure f = failure(() -> startDesktop(engine));
      require(f.code.equals("AGENT_DESKTOP_UNAVAILABLE"), f.code);
      require(engine.requestedFlags.size() == 1, "retried with flags " + engine.requestedFlags);
      require((Integer) get(engine, "desktopDisplay") == -1 && engine.disconnected.isEmpty(), "route changed");
    });

    test("agent display without own focus or focus-steal protection is released", () -> {
      ScriptedEngine engine = desktopEngine();
      TestDisplay display = new TestDisplay(5, 1 << 7);
      engine.displayScript = requested -> display;
      Failure f = failure(() -> startDesktop(engine));
      require(f.code.equals("AGENT_DESKTOP_UNAVAILABLE"), f.code);
      require(f.getMessage().contains("own focus") && f.getMessage().contains("top-focus"), f.getMessage());
      require(display.released && (Integer) get(engine, "desktopDisplay") == -1, "display kept");
      require(engine.disconnected.isEmpty(), "main connection dropped");
    });

    test("agent display whose keyboard policy is not local is released", () -> {
      ScriptedEngine engine = desktopEngine();
      TestDisplay display = new TestDisplay(5, ISOLATED);
      engine.displayScript = requested -> display;
      engine.imeScript = () -> {
        throw Core.fail("AGENT_DESKTOP_UNAVAILABLE", "keyboard policy is 1, not local");
      };
      Failure f = failure(() -> startDesktop(engine));
      require(f.code.equals("AGENT_DESKTOP_UNAVAILABLE"), f.code);
      require(display.released && (Integer) get(engine, "desktopDisplay") == -1, "display kept");
    });

    test("a failed agent connection rolls back the display and restores the main connection", () -> {
      ScriptedEngine engine = desktopEngine();
      UiAutomation restored = allocate(UiAutomation.class);
      TestDisplay display = new TestDisplay(5, ISOLATED);
      engine.displayScript = requested -> display;
      engine.connectScript = id -> {
        if (id == 5) throw new IllegalStateException("connect timed out");
        return restored;
      };
      failure(() -> {
        try {
          startDesktop(engine);
        } catch (IllegalStateException e) {
          throw Core.fail("AGENT_DESKTOP_UNAVAILABLE", e.getMessage());
        }
      });
      require((Integer) get(engine, "desktopDisplay") == -1, "desktop pretends to run on " + get(engine, "desktopDisplay"));
      require(display.released, "display leaked");
      require(get(engine, "automation") == restored && (Integer) get(engine, "activeDisplay") == 0,
          "main connection not restored");
    });

    test("a main connection that cannot be restored latches the route", () -> {
      ScriptedEngine engine = desktopEngine();
      engine.displayScript = requested -> new TestDisplay(5, ISOLATED);
      engine.connectScript = id -> {
        throw new IllegalStateException("no UiAutomation");
      };
      failure(() -> {
        try {
          startDesktop(engine);
        } catch (IllegalStateException e) {
          throw Core.fail("AGENT_DESKTOP_UNAVAILABLE", e.getMessage());
        }
      });
      Failure again = failure(() -> startDesktop(engine));
      require(again.code.equals("DISPLAY_UNAVAILABLE"), "second start: " + again.code);
      Failure read = failure(() -> engine.call("get_app_state", args()));
      require(read.code.equals("DISPLAY_UNAVAILABLE"), "read: " + read.code);
    });

    // On Android 14 a display-bound UiAutomation's takeScreenshot still captures display 0 (seen on
    // the PGBM10: the elements were the agent display's, the image the person's home screen).
    test("an agent-display screenshot is the agent display's own frame, never display 0's", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = onAgentDisplay(scene);
      engine.mainShot = android.graphics.Bitmap.of(1080, 2400, "display 0");
      ScriptedFrames frames = new ScriptedFrames(5, android.graphics.Bitmap.of(1080, 2400, "agent display 5"));
      set(engine, "ownedDisplay", frames);
      Map<String, Object> r;
      try {
        r = engine.call("get_app_state", args("includeScreenshot", true));
      } catch (Failure f) {
        throw new AssertionError("no image (" + f.code + ": " + f.getMessage() + "); agent display frames read "
            + frames.captures + " times");
      }
      require(!Boolean.TRUE.equals(r.get("isError")), text(r));
      String shown = image(r);
      require(shown != null, "no image: " + text(r));
      require(shown.endsWith("from agent display 5"), "image came " + shown);
      require(engine.mainShots == 0, "display 0 was captured " + engine.mainShots + " times");
      require(frames.captures == 1, "agent display frames read " + frames.captures + " times");
      Object display = map(map(r.get("_meta")).get("opencu/screenshot")).get("display");
      require(Integer.valueOf(5).equals(display), "screenshot reported for display " + display);
      // The grant it gives lands on the agent display.
      Map<String, Object> tapped = engine.call("click", args("x", 100, "y", 200));
      require(!engine.events.isEmpty(), "no touch sent: " + text(tapped));
      for (Event e : engine.events) require(e.display == 5, "touch sent to display " + e.display);
      require(engine.mainShots == 0, "display 0 was captured after the tap");
    });

    test("an agent display without a frame fails the screenshot and grants no coordinates", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = onAgentDisplay(scene);
      engine.mainShot = android.graphics.Bitmap.of(1080, 2400, "display 0");
      // The engine's own frame source, which has received no frame.
      set(engine, "ownedDisplay", new AndroidEngine.OwnedDisplay(null, null, null, 5, ISOLATED));
      Failure f = failure(() -> engine.call("get_app_state", args("includeScreenshot", true)));
      require(f.code.equals("SCREENSHOT_FAILED"), f.code + ": " + f.getMessage());
      require(f.getMessage().contains("agent display could not be captured"), f.getMessage());
      require(engine.mainShots == 0, "display 0 was captured instead");
      engine.read();
      Failure tap = failure(() -> engine.call("click", args("x", 100, "y", 200)));
      require(tap.code.equals("SCREENSHOT_REQUIRED"), tap.code + ": " + tap.getMessage());
      require(engine.events.isEmpty() && engine.log.isEmpty(), "input sent: " + engine.log);
      Failure batch =
          failure(() -> engine.call("run_actions", args(
              "actions", List.of(obj("method", "wait", "ms", 10)), "includeScreenshot", true)));
      require(batch.code.equals("SCREENSHOT_FAILED"), "batch: " + batch.code);
      require(engine.mainShots == 0, "display 0 was captured for the batch");
      require(get(engine, "coordinates") == null, "a failed capture left a coordinate grant");
    });

    test("an agent-display state is never paired with display 0's image once the display stopped", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = onAgentDisplay(scene);
      engine.mainShot = android.graphics.Bitmap.of(1080, 2400, "display 0");
      Screen agentState = engine.observe(PKG);
      // Shutdown stops the display on another thread while this response is being built.
      engine.stopDesktop();
      Failure f =
          failure(() -> invoke(engine, "result", new Class<?>[] {Screen.class, boolean.class}, agentState, true));
      require(f.code.equals("SCREENSHOT_FAILED"), f.code);
      require(engine.mainShots == 0, "display 0 was captured for display 5's state");
      require(get(engine, "coordinates") == null, "a grant was given");
    });

    test("a screenshot grant from display 0 does not authorize coordinates on the agent display", () -> {
      Scene scene = new Scene();
      scene.add("/0", "android.widget.Button", "ok", "OK", 100, 200, 300, 260).clickable = true;
      ScriptedEngine engine = desktopEngine();
      engine.scene = scene;
      Screen mainState = engine.read();
      // What a display-0 screenshot of this state granted; agent_desktop calls do not consume it.
      set(engine, "coordinates", grant(mainState, 576, 1280));
      engine.displayScript = requested -> new TestDisplay(5, ISOLATED);
      startDesktop(engine);
      scene.display = 5;
      Failure f = failure(() -> engine.call("click", args("x", 100, "y", 200)));
      require(engine.events.isEmpty() && engine.log.isEmpty(), "tap sent with display 0's grant: " + engine.log);
      require(f.code.equals("STALE_SCREENSHOT"), f.code + ": " + f.getMessage());
    });

    test("the agent display keeps only its newest frame and closes every other", () -> {
      AndroidEngine.OwnedDisplay display = new AndroidEngine.OwnedDisplay(null, null, null, 5, ISOLATED);
      FakeFrame first = FakeFrame.pattern(4, 2, 16, 1), second = FakeFrame.pattern(4, 2, 16, 2);
      Class<?>[] keep = {android.media.Image.class};
      invoke(display, "keep", keep, first);
      invoke(display, "keep", keep, second);
      require(first.closed && !second.closed, "first closed " + first.closed + ", second closed " + second.closed);
      android.graphics.Bitmap shot =
          (android.graphics.Bitmap) invoke(display, "capture", new Class<?>[] {long.class}, 100L);
      require(shot.getPixel(3, 1) == FakeFrame.expected(3, 1, 2), "not the newest frame");
      require(!second.closed, "the kept frame was closed by reading it");
      display.release();
      require(second.closed, "release kept a frame open");
      FakeFrame late = FakeFrame.pattern(4, 2, 16, 3);
      invoke(display, "keep", keep, late);
      require(late.closed, "a frame arriving after release was kept");
      Failure f = failure(() -> invoke(display, "capture", new Class<?>[] {long.class}, 100L));
      require(f.code.equals("SCREENSHOT_FAILED"), f.code);
    });

    test("an agent-display screenshot waits briefly for a first frame and fails without one", () -> {
      AndroidEngine.OwnedDisplay display = new AndroidEngine.OwnedDisplay(null, null, null, 5, ISOLATED);
      long start = System.nanoTime();
      Failure none = failure(() -> invoke(display, "capture", new Class<?>[] {long.class}, 150L));
      long waited = (System.nanoTime() - start) / 1_000_000;
      require(none.code.equals("SCREENSHOT_FAILED"), none.code);
      require(none.getMessage().contains("agent display could not be captured"), none.getMessage());
      require(waited >= 140 && waited < 2000, "waited " + waited + " ms");
      FakeFrame frame = FakeFrame.pattern(4, 2, 16, 9);
      Thread producer = new Thread(() -> {
        try {
          Thread.sleep(100);
          invoke(display, "keep", new Class<?>[] {android.media.Image.class}, frame);
        } catch (Exception ignored) {
        }
      });
      producer.start();
      android.graphics.Bitmap shot =
          (android.graphics.Bitmap) invoke(display, "capture", new Class<?>[] {long.class}, 3000L);
      producer.join();
      require(shot.getPixel(0, 0) == FakeFrame.expected(0, 0, 9), "not the frame that arrived");
    });

    test("padded frame rows become exactly the display's pixels, and a frame reads the same twice", () -> {
      FakeFrame frame = FakeFrame.pattern(5, 3, 32, 4);
      Class<?>[] image = {android.media.Image.class};
      for (int round = 0; round < 2; round++) {
        android.graphics.Bitmap b = (android.graphics.Bitmap) callStatic("frameBitmap", image, frame);
        require(b.getWidth() == 5 && b.getHeight() == 3, "size " + b.getWidth() + "x" + b.getHeight());
        for (int y = 0; y < 3; y++)
          for (int x = 0; x < 5; x++)
            require(b.getPixel(x, y) == FakeFrame.expected(x, y, 4),
                "read " + round + " pixel " + x + "," + y + " = " + Integer.toHexString(b.getPixel(x, y)));
      }
      FakeFrame tight = FakeFrame.pattern(5, 3, 20, 6);
      android.graphics.Bitmap b = (android.graphics.Bitmap) callStatic("frameBitmap", image, tight);
      require(b.getPixel(4, 2) == FakeFrame.expected(4, 2, 6), "unpadded frame");
      FakeFrame other = new FakeFrame(5, 3, 20, 0x23 /* YUV_420_888 */, tight.buffer);
      Failure f = failure(() -> callStatic("frameBitmap", image, other));
      require(f.code.equals("SCREENSHOT_FAILED"), f.code);
    });

    test("a touch before the input monitor is ready still holds off a foreground change", () -> {
      java.nio.file.Path touched = java.nio.file.Files.createTempFile("opencu-touch", "");
      java.nio.file.Files.delete(touched);
      long[] reads = {0};
      PersonMonitor monitor =
          new PersonMonitor(
              notice -> {},
              () -> {
                reads[0]++;
                long now = android.os.SystemClock.uptimeMillis();
                // The platform's last user activity: the touch, if it has happened yet.
                return java.nio.file.Files.exists(touched) ? now - 100 : now - 60_000;
              },
              new String[] {"/bin/sh", "-c", "touch '" + touched + "'; printf 'add device 1: /dev/input/event1\\n  KEY_VOLUMEDOWN ABS_MT_POSITION_X\\n'"},
              new String[] {"/bin/sh", "-c", "echo 'add device 1: /dev/input/event1'; exec sleep 30"});
      try {
        Person person = monitor.person;
        Failure f = failure(() -> person.check(person.token(), android.os.SystemClock.uptimeMillis(), true));
        require(f.code.equals("PERSON_ACTIVE"), f.code);
        require(reads[0] == 1, "platform activity read " + reads[0] + " times");
      } finally {
        monitor.close();
        java.nio.file.Files.deleteIfExists(touched);
      }
    });

    test("a touch while the event stream is still starting holds off a foreground change", () -> {
      java.nio.file.Path touched = java.nio.file.Files.createTempFile("opencu-touch", "");
      java.nio.file.Files.delete(touched);
      PersonMonitor monitor =
          new PersonMonitor(
              notice -> {},
              () -> {
                long now = android.os.SystemClock.uptimeMillis();
                return java.nio.file.Files.exists(touched) ? now - 100 : now - 60_000;
              },
              new String[] {"/bin/sh", "-c", "printf 'add device 1: /dev/input/event1\\n  KEY_VOLUMEDOWN ABS_MT_POSITION_X\\n'"},
              // The person touches after probing, while the stream is opening its devices.
              new String[] {"/bin/sh", "-c", "sleep 0.3; touch '" + touched + "'; echo 'add device 1: /dev/input/event1'; exec sleep 30"});
      try {
        Person person = monitor.person;
        Failure f = failure(() -> person.check(person.token(), android.os.SystemClock.uptimeMillis(), true));
        require(f.code.equals("PERSON_ACTIVE"), f.code);
      } finally {
        monitor.close();
        java.nio.file.Files.deleteIfExists(touched);
      }
    });

    test("a quiet start does not hold off the first foreground change", () -> {
      PersonMonitor monitor =
          new PersonMonitor(
              notice -> {},
              () -> android.os.SystemClock.uptimeMillis() - 60_000,
              new String[] {"/bin/sh", "-c", "printf 'add device 1: /dev/input/event1\\n  KEY_VOLUMEDOWN ABS_MT_POSITION_X\\n'"},
              new String[] {"/bin/sh", "-c", "echo 'add device 1: /dev/input/event1'; exec sleep 30"});
      try {
        Person person = monitor.person;
        person.check(person.token(), android.os.SystemClock.uptimeMillis(), true);
      } finally {
        monitor.close();
      }
    });

    test("an older platform time never hides a touch the monitor saw", () -> {
      Person person = new Person(0);
      person.accept("[ 10.000000] /dev/input/event2: EV_ABS ABS_MT_POSITION_X 00000100", 50_000);
      invoke(person, "seed", new Class<?>[] {long.class}, 1_000L);
      require(person.lastActivity == 50_000, "last activity " + person.lastActivity);
    });

    test("type_text sets the focused editor's text and never pastes", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Map<String, Object> result = engine.call("type_text", args("text", "无线调试"));
      require(node.performed.equals(List.of(AccessibilityNodeInfo.ACTION_SET_TEXT)), "actions " + node.performed);
      require(node.setTexts.equals(List.of("无线调试")), "set-text " + node.setTexts);
      require(!text(result).contains("fallback"), "notice: " + text(result).split("\n")[0]);
    });

    test("type_text inserts at the editor's selection", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_SET_TEXT);
      node.text = "abcdef";
      scene.specs.get(0).text = "abcdef";
      node.selectionStart = 2;
      node.selectionEnd = 4;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("type_text", args("text", "XY"));
      require(node.setTexts.equals(List.of("abXYef")), "set-text " + node.setTexts);
    });

    test("type_text refuses to splice into a password field that has text", () -> {
      Scene scene = new Scene();
      FakeNode node = passwordEditor(scene, "hunter2");
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Failure f = failure(() -> engine.call("type_text", args("text", "x")));
      require(node.setTexts.isEmpty() && node.performed.isEmpty(), "setTexts=" + node.setTexts + " " + f.code);
      require(f.code.equals("PASSWORD_INSERT_UNSUPPORTED") && f.getMessage().contains("set_value"), f.code + ": " + f.getMessage());
      require(node.text.equals("hunter2"), "password now " + node.text);
    });

    test("type_text sets an empty password field and checks it by length", () -> {
      Scene scene = new Scene();
      FakeNode node = passwordEditor(scene, "");
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Map<String, Object> result = engine.call("type_text", args("text", "secret"));
      require(node.setTexts.equals(List.of("secret")), "setTexts=" + node.setTexts);
      require(text(result).contains("checked by length only"), "notice: " + text(result).split("\n")[0]);
    });

    test("type_text replaces a password field whose whole value is selected", () -> {
      Scene scene = new Scene();
      FakeNode node = passwordEditor(scene, "hunter2");
      node.selectionStart = 0;
      node.selectionEnd = 7;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("type_text", args("text", "letmein"));
      require(node.setTexts.equals(List.of("letmein")), "setTexts=" + node.setTexts);
    });

    test("a second type_text after a mid-text insert continues after the insert", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_SET_TEXT, AccessibilityNodeInfo.ACTION_SET_SELECTION);
      node.text = "abcdef";
      scene.specs.get(0).text = "abcdef";
      node.selectionStart = 2;
      node.selectionEnd = 4;
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("type_text", args("text", "XY"));
      engine.call("type_text", args("text", "Z"));
      require(node.text.equals("abXYZef"), "editor: " + node.text + " after " + node.setTexts);
    });

    test("an unconfirmed caret move is reported and not repeated", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_SET_TEXT, AccessibilityNodeInfo.ACTION_SET_SELECTION);
      node.text = "abcdef";
      scene.specs.get(0).text = "abcdef";
      node.selectionStart = node.selectionEnd = 3;
      node.results.put(AccessibilityNodeInfo.ACTION_SET_SELECTION, false);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Map<String, Object> result = engine.call("type_text", args("text", "X"));
      require(node.performed.equals(List.of(AccessibilityNodeInfo.ACTION_SET_TEXT, AccessibilityNodeInfo.ACTION_SET_SELECTION)),
          "actions " + node.performed);
      require(text(result).contains("caret could not be placed"), "notice: " + text(result).split("\n")[0]);
    });

    test("type_text fails when the editor does not hold the requested text afterwards", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_SET_TEXT);
      Element field = scene.specs.get(0);
      // The app accepts set-text but keeps only three characters, as a length filter would.
      node.effects.put(AccessibilityNodeInfo.ACTION_SET_TEXT, () -> {
        node.text = node.text.substring(0, Math.min(3, node.text.length()));
        field.text = node.text;
      });
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Failure f = failure(() -> engine.call("type_text", args("text", "hello")));
      require(f.code.equals("TEXT_INPUT_FAILED"), f.code + ": " + f.getMessage());
    });

    test("a set-text that is not confirmed is never repeated", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_SET_TEXT);
      node.results.put(AccessibilityNodeInfo.ACTION_SET_TEXT, false);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Failure f = failure(() -> engine.call("type_text", args("text", "hello")));
      require(node.performed.equals(List.of(AccessibilityNodeInfo.ACTION_SET_TEXT)), "actions " + node.performed);
      require(f.code.equals("ACTION_UNCONFIRMED"), f.code + ": " + f.getMessage());
      Failure next = failure(() -> engine.call("type_text", args("text", "hello")));
      require(next.code.equals("OBSERVATION_REQUIRED"), "after unknown outcome: " + next.code);
    });

    test("paste inserts through set-text like type_text", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      engine.call("paste", args("text", "hello", "format", "text"));
      require(node.performed.equals(List.of(AccessibilityNodeInfo.ACTION_SET_TEXT)), "actions " + node.performed);
      require(node.setTexts.equals(List.of("hello")), "set-text " + node.setTexts);
    });

    test("EOF finishes in bounded time while an accessibility action blocks", () -> {
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, AccessibilityNodeInfo.ACTION_SET_TEXT);
      CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
      node.effects.put(AccessibilityNodeInfo.ACTION_SET_TEXT, () -> {
        entered.countDown();
        try {
          release.await(10, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
        }
      });
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.read();
      Thread worker = new Thread(() -> {
        try {
          engine.call("type_text", args("text", "agent text"));
        } catch (Throwable ignored) {
        }
      });
      worker.start();
      require(entered.await(5, TimeUnit.SECONDS), "set-text never started");
      long started = System.nanoTime();
      try {
        try {
          engine.close();
        } catch (Throwable ignored) {
        }
        long ms = (System.nanoTime() - started) / 1_000_000;
        require(ms < 2000, "close took " + ms + " ms");
      } finally {
        release.countDown();
        worker.join(3000);
        reopenCommands();
      }
    });

    test("the input monitor's diagnostics never reach the engine's stderr", () -> {
      Process p =
          new ProcessBuilder(
                  System.getProperty("java.home") + "/bin/java", "-cp", System.getProperty("java.class.path"),
                  EngineTests.class.getName(), "monitor-stderr")
              .start();
      p.getOutputStream().close();
      String err = new String(p.getErrorStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
      require(p.waitFor(20, TimeUnit.SECONDS) && p.exitValue() == 0, "monitor run failed: " + err);
      require(!err.contains("could not open"), "stderr: " + err.trim());
    });

    test("startup and doctor failures print one coded stderr line", () -> {
      java.util.regex.Pattern line = java.util.regex.Pattern.compile("^[A-Z][A-Z0-9_]{2,40}: [^\\n]{1,300}\\n$");
      String javaBin = System.getProperty("java.home") + "/bin/java", cp = System.getProperty("java.class.path");
      for (String[] run : new String[][] {{"mcp", "UNSUPPORTED_PLATFORM"}, {"doctor", "UNSUPPORTED_PLATFORM"}, {"bogus", "INVALID_ARGUMENT"}}) {
        Process p = new ProcessBuilder(javaBin, "-cp", cp, "dev.opencu.android.Main", run[0]).redirectInput(ProcessBuilder.Redirect.PIPE).start();
        p.getOutputStream().close();
        String err = new String(p.getErrorStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        String out = new String(p.getInputStream().readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        require(p.waitFor(20, TimeUnit.SECONDS) && p.exitValue() == 1, run[0] + " exit");
        require(line.matcher(err).matches(), run[0] + " stderr: " + err);
        require(err.startsWith(run[1] + ": "), run[0] + " code: " + err);
        if (run[0].equals("doctor"))
          require(String.valueOf(map(Json.read(out.trim())).get("error")).startsWith("UNSUPPORTED_PLATFORM: "), "doctor JSON: " + out);
      }
    });

    test("diagnostic lines are single-line, bounded and coded", () -> {
      Class<?>[] types = {String.class, Throwable.class};
      Object main = allocate(Main.class);
      String wrapped = (String) invoke(main, "diagnostic", types, "ENGINE_START_FAILED",
          new java.lang.reflect.InvocationTargetException(Core.fail("UIAUTOMATION_UNAVAILABLE", "connect\nrefused")));
      require(wrapped.equals("UIAUTOMATION_UNAVAILABLE: connect refused"), wrapped);
      String generic = (String) invoke(main, "diagnostic", types, "ENGINE_START_FAILED",
          new IllegalStateException("first line\r\nsecond\u2028third\t" + "x".repeat(400)));
      require(generic.startsWith("ENGINE_START_FAILED: java.lang.IllegalStateException: first line second third x"), generic);
      require(!generic.contains("\n") && !generic.contains("\u2028") && generic.length() <= "ENGINE_START_FAILED: ".length() + 300, generic);
      String unnamed = (String) invoke(main, "diagnostic", types, "DOCTOR_FAILED", new NullPointerException());
      require(unnamed.equals("DOCTOR_FAILED: java.lang.NullPointerException: null"), unnamed);
      String odd = (String) invoke(main, "diagnostic", types, "ENGINE_FAILED", Core.fail("bad code", "x"));
      require(odd.startsWith("ENGINE_FAILED: "), odd);
    });

    test("system services are called as the package that owns the engine's uid", () -> {
      List<String> asked = Collections.synchronizedList(new ArrayList<>());
      FakeContext system = FakeContext.create("android", UidPackages.of(2000, "example.shell"), asked);
      android.app.ActivityThread.systemContext = system;
      android.os.Build.VERSION.SDK_INT = 34;
      try {
        new AndroidEngine(notice -> {});
      } catch (Throwable hostEndsHere) {
        // The host has no platform past service acquisition; what was asked so far is the point.
      } finally {
        android.os.Build.VERSION.SDK_INT = 0;
        android.app.ActivityThread.systemContext = null;
      }
      List<String> services = new ArrayList<>();
      for (String entry : asked) if (entry.startsWith("getSystemService ")) services.add(entry);
      require(services.size() == 4, "services obtained: " + asked);
      for (String service : services)
        require(service.endsWith(" as example.shell"), "service obtained as the wrong package: " + services);
      require(asked.stream().noneMatch(entry -> entry.endsWith(" android")), "system identity reached the platform: " + asked);
    });

    test("the engine refuses a uid that does not map to exactly one package", () -> {
      Method derive = AndroidEngine.class.getDeclaredMethod("ownPackage", android.content.Context.class, int.class);
      derive.setAccessible(true);
      for (UidPackages packages : List.of(UidPackages.of(2000), UidPackages.of(2000, "example.one", "example.two"))) {
        FakeContext system = FakeContext.create("android", packages, new ArrayList<>());
        Failure f = failure(() -> {
          try {
            derive.invoke(null, system, 2000);
          } catch (InvocationTargetException e) {
            throw (Exception) e.getCause();
          }
        });
        require(f.code.equals("PACKAGE_IDENTITY_UNAVAILABLE"), f.code);
      }
      FakeContext system = FakeContext.create("android", UidPackages.of(2000, "example.shell"), new ArrayList<>());
      require("example.shell".equals(derive.invoke(null, system, 2000)), "derived package");
    });

    secondDeviceRound();

    if (!failures.isEmpty()) {
      System.out.println("Android engine host checks failed: " + failures);
      System.exit(1);
    }
    System.out.println("Android engine host checks passed: " + passed);
  }

  /** Checks for what the second device round (OPPO PGBM10, 2026-11-02) found. */
  static void secondDeviceRound() {
    test("the agent display takes the main display's portrait size even while it is turned", () -> {
      Class<?>[] types = {int.class, int.class, int.class};
      // Display 0 turned by a landscape game: logical 2400x1080 at rotation 1 (90 degrees).
      require(Arrays.equals((int[]) callStatic("naturalSize", types, 2400, 1080, 1), new int[] {1080, 2400}), "rotation 90");
      require(Arrays.equals((int[]) callStatic("naturalSize", types, 2400, 1080, 3), new int[] {1080, 2400}), "rotation 270");
      require(Arrays.equals((int[]) callStatic("naturalSize", types, 1080, 2400, 0), new int[] {1080, 2400}), "rotation 0");
      require(Arrays.equals((int[]) callStatic("naturalSize", types, 1080, 2400, 2), new int[] {1080, 2400}), "rotation 180");
    });

    // Item 1: a swipe fallback set a form's minute wheel from 35 to 33 without an error.
    test("scroll keeps sending the element's own scroll-backward after it stops listing it, never a swipe", () -> {
      FormScene form = new FormScene(2);
      ScriptedEngine engine = ScriptedEngine.create(form.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "up", "pages", 3)));
      require(engine.events.isEmpty(), "swiped: " + engine.log);
      require(form.node.performed.equals(List.of(BACKWARD, BACKWARD, BACKWARD)), "actions " + form.node.performed);
      require(out.startsWith("Scrolled 2 of 3 pages; reached the end"), "notice: " + out.split("\n")[0]);
    });

    test("scroll sends the scroll-backward the element listed in the state read before, never a swipe", () -> {
      FormScene form = new FormScene(1);
      ScriptedEngine engine = ScriptedEngine.create(form.scene);
      engine.read(); // the agent's state lists scroll_forward and scroll_backward
      form.stopListingBackward(); // by the time of the call (another step changed the form) it lists forward only
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "up")));
      require(engine.events.isEmpty(), "swiped: " + engine.log);
      require(form.node.performed.equals(List.of(BACKWARD)), "actions " + form.node.performed);
      require(out.startsWith("Nothing moved"), "notice: " + out.split("\n")[0]);
    });

    test("a scroll sends the generic scroll action an element's line lists before a hidden directional one", () -> {
      PickerScene picker = new PickerScene();
      // The wheel also carries scroll-down/up, which its line does not show and it ignores.
      picker.node.with(DOWN, UP);
      picker.node.effects.put(FORWARD, () -> picker.wheel.text = Integer.toString(Integer.parseInt(picker.wheel.text) + 1));
      ScriptedEngine engine = ScriptedEngine.create(picker.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 2)));
      require(picker.node.performed.equals(List.of(FORWARD, FORWARD)), "actions " + picker.node.performed);
      require(picker.wheel.text.equals("22"), "value " + picker.wheel.text + "; notice: " + out.split("\n")[0]);
    });

    for (String kind : List.of("wheel", "slider", "nested list"))
      test("a swipe never crosses a " + kind + ": the error names it and nothing is sent", () -> {
        ListScene rows = new ListScene(FORWARD); // offers no way up: an upward scroll swipes
        Element blocker;
        if (kind.equals("wheel")) {
          blocker = rows.scene.add("/0/2", "android.widget.NumberPicker", "minute", "35", 0, 900, 1080, 1300);
          blocker.focusable = true;
          blocker.actions.put("scroll_forward", FORWARD);
          blocker.actions.put("scroll_backward", BACKWARD);
          rows.scene.node(blocker).with(FORWARD, BACKWARD);
        } else if (kind.equals("slider")) {
          blocker = rows.scene.add("/0/2", "android.widget.SeekBar", "volume", "", 0, 900, 1080, 1000);
          rows.scene.node(blocker).with(SET_PROGRESS);
        } else {
          blocker = rows.scene.add("/0/2", "android.widget.HorizontalScrollView", "chips", "", 0, 900, 1080, 1100);
          blocker.scrollable = true;
          rows.scene.node(blocker).with(RIGHT);
        }
        ScriptedEngine engine = ScriptedEngine.create(rows.scene);
        engine.read();
        Failure f = failure(() -> engine.call("scroll", args("element_index", 1, "direction", "up")));
        require(f.code.equals("ACTION_UNSUPPORTED"), f.code + ": " + f.getMessage());
        String name = blocker.clazz.substring(blocker.clazz.lastIndexOf('.') + 1);
        require(f.getMessage().contains(name) && f.getMessage().contains("nothing sent"), f.getMessage());
        require(engine.events.isEmpty() && engine.log.isEmpty(), "input sent: " + engine.log);
      });

    test("a swipe goes beside a wheel in the middle of the list", () -> {
      ListScene rows = new ListScene(FORWARD);
      Element wheel = rows.scene.add("/0/2", "android.widget.NumberPicker", "minute", "35", 300, 900, 780, 1300);
      wheel.focusable = true;
      wheel.actions.put("scroll_forward", FORWARD);
      wheel.actions.put("scroll_backward", BACKWARD);
      FakeNode wheelNode = rows.scene.node(wheel).with(FORWARD, BACKWARD);
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      engine.call("scroll", args("element_index", 1, "direction", "up"));
      List<int[]> points = motions(engine);
      require(!points.isEmpty(), "no swipe sent");
      for (int[] p : points)
        require(p[1] < 300 - 24 || p[1] > 780 + 24, "the finger came within reach of the wheel: " + engine.log);
      require(wheelNode.performed.isEmpty(), "wheel got " + wheelNode.performed);
    });

    test("a swipe that changed a switch it crossed says so with the old and new value and stops", () -> {
      ListScene rows = new ListScene(FORWARD);
      Element label = rows.scene.add("/0/2/0", "android.widget.TextView", "", "Vibrate", 0, 1100, 800, 1200);
      Element toggle = rows.scene.add("/0/2/1", "android.widget.Switch", "vibrate", "", 800, 1100, 1080, 1200);
      toggle.checkable = toggle.clickable = true;
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      int[] lifts = {0};
      engine.onObserve = n -> {
        long ups = engine.events.stream().filter(e -> e.action == 1).count();
        for (; lifts[0] < ups; lifts[0]++) {
          rows.show(rows.offset + 2);
          toggle.checked = !toggle.checked; // the finger's path flipped it
        }
      };
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "up", "pages", 3)));
      require(lifts[0] == 1, "swipes sent: " + lifts[0]);
      require(out.startsWith("WARNING: the swipe also changed Switch id=vibrate not checked -> checked"), "notice: " + out.split("\n")[0]);
      require(out.contains("Scrolled 1 of 3 pages"), "pages not stated: " + out.split("\n")[0]);
      require(label.text.equals("Vibrate"), "label");
    });

    test("a coordinate scroll that turned a wheel says so with the old and new value", () -> {
      Scene scene = new Scene();
      Element wheel = scene.add("/1/0", "android.widget.NumberPicker", "minute", "35", 300, 900, 780, 1300);
      wheel.focusable = true;
      wheel.actions.put("scroll_forward", FORWARD);
      wheel.actions.put("scroll_backward", BACKWARD);
      scene.node(wheel).with(FORWARD, BACKWARD);
      scene.add("/1/1", "android.widget.TextView", "", "minutes", 800, 1000, 1000, 1100);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.mainShot = android.graphics.Bitmap.of(1080, 2400, "display 0");
      Screen state = engine.read();
      set(engine, "coordinates", grant(state, 576, 1280));
      int[] lifts = {0};
      engine.onObserve = n -> {
        long ups = engine.events.stream().filter(e -> e.action == 1).count();
        for (; lifts[0] < ups; lifts[0]++) wheel.text = "33";
      };
      String out = text(engine.call("scroll", args("x", 288, "y", 400, "direction", "up")));
      require(out.contains("WARNING: the swipe also changed NumberPicker id=minute 35 -> 33"), "notice: " + out.split("\n")[1]);
    });

    // Item 2: setting 07:35 on the time picker took 14 calls.
    test("set_value turns a wheel to the value in one call, reading it after every step", () -> {
      WheelScene minute = new WheelScene("minute", 47, 0, 59);
      ScriptedEngine engine = minute.engine();
      engine.read();
      String out = text(engine.call("set_value", args("element_index", 2, "value", "35")));
      require(minute.wheel.text.equals("35"), "value " + minute.wheel.text);
      require(minute.node.performed.size() == 12 && minute.node.performed.stream().allMatch(a -> a == BACKWARD),
          "actions " + minute.node.performed);
      require(out.startsWith("Set the wheel to 35 in 12 steps."), "notice: " + out.split("\n")[0]);
    });

    test("set_value learns from the first step which way a wheel's scroll-forward turns", () -> {
      WheelScene minute = new WheelScene("minute", 47, 0, 59);
      minute.forwardDecreases = true;
      ScriptedEngine engine = minute.engine();
      engine.read();
      engine.call("set_value", args("element_index", 2, "value", "50"));
      require(minute.wheel.text.equals("50"), "value " + minute.wheel.text);
      require(minute.node.performed.equals(List.of(FORWARD, BACKWARD, BACKWARD, BACKWARD, BACKWARD)),
          "actions " + minute.node.performed);
    });

    test("set_value goes the short way round a wheel whose range is known", () -> {
      WheelScene minute = new WheelScene("minute", 55, 0, 59);
      minute.ranged();
      ScriptedEngine engine = minute.engine();
      engine.read();
      engine.call("set_value", args("element_index", 2, "value", "05"));
      require(minute.wheel.text.equals("05"), "value " + minute.wheel.text);
      require(minute.node.performed.size() == 10 && minute.node.performed.stream().allMatch(a -> a == FORWARD),
          "actions " + minute.node.performed);
    });

    test("set_value turns back from the end of a wheel that does not wrap", () -> {
      WheelScene digit = new WheelScene("digit", 8, 0, 9);
      digit.ranged();
      digit.wraps = false;
      ScriptedEngine engine = digit.engine();
      engine.read();
      String out = text(engine.call("set_value", args("element_index", 2, "value", "1")));
      require(digit.wheel.text.equals("01"), "value " + digit.wheel.text);
      require(out.startsWith("Set the wheel to 01 in 10 steps."), "notice: " + out.split("\n")[0]);
    });

    test("set_value stops with VALUE_NOT_REACHED, naming the value, when a step changes nothing", () -> {
      WheelScene minute = new WheelScene("minute", 59, 0, 59);
      minute.wraps = false;
      ScriptedEngine engine = minute.engine();
      engine.read();
      Failure f = failure(() -> engine.call("set_value", args("element_index", 2, "value", "75")));
      require(f.code.equals("VALUE_NOT_REACHED"), f.code + ": " + f.getMessage());
      require(f.getMessage().contains("shows 59 after 1 step;") && f.getMessage().contains("did not change"), f.getMessage());
      require(minute.node.performed.size() == 1, "actions " + minute.node.performed);
    });

    test("set_value stops turning a wheel after 70 steps", () -> {
      WheelScene minute = new WheelScene("minute", 47, 0, 59);
      minute.delayMs = 0;
      ScriptedEngine engine = minute.engine();
      engine.read();
      Failure f = failure(() -> engine.call("set_value", args("element_index", 2, "value", "99")));
      require(f.code.equals("VALUE_NOT_REACHED") && f.getMessage().contains("after 70 steps"), f.code + ": " + f.getMessage());
      require(minute.node.performed.size() == 70, "actions " + minute.node.performed.size());
    });

    test("one batch sets the hour and minute wheels of a time with set_value", () -> {
      WheelScene time = new WheelScene("minute", 47, 0, 59);
      WheelScene.Wheel hour = time.addWheel("/0/2", "hour", 21, 0, 23, 100);
      ScriptedEngine engine = time.engine();
      engine.read();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "set_value", "element_index", 3, "value", "07"),
          obj("method", "set_value", "element_index", 2, "value", "35"))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require(Integer.valueOf(2).equals(batch.get("completed")) && batch.get("reason") == null, "batch " + batch + ": " + text(result).split("\n")[0]);
      require(hour.element.text.equals("07") && time.wheel.text.equals("35"), "time " + hour.element.text + ":" + time.wheel.text);
    });

    test("a wheel's scroll page counts only when its selected value changed", () -> {
      WheelScene minute = new WheelScene("minute", 59, 0, 59);
      minute.wraps = false;
      Element ticker = minute.scene.add("/1", "android.widget.TextView", "clock", "0", 0, 100, 1080, 200);
      ScriptedEngine engine = minute.engine();
      engine.read();
      IntConsumer wheelUpdate = engine.onObserve;
      engine.onObserve = n -> {
        wheelUpdate.accept(n);
        ticker.text = Integer.toString(n); // a clock elsewhere in the window ticks on every read
      };
      String out = text(engine.call("scroll", args("element_index", 2, "direction", "down", "pages", 3)));
      require(minute.node.performed.equals(List.of(FORWARD)), "steps " + minute.node.performed);
      require(out.startsWith("Nothing moved"), "notice: " + out.split("\n")[0]);
    });

    test("two steps on one wheel in a batch find it again after the first changed its value", () -> {
      WheelScene minute = new WheelScene("minute", 20, 0, 59);
      ScriptedEngine engine = minute.engine();
      engine.read();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "perform_secondary_action", "element_index", 2, "action", "scroll_forward"),
          obj("method", "perform_secondary_action", "element_index", 2, "action", "scroll_forward"))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require(Integer.valueOf(2).equals(batch.get("completed")) && batch.get("reason") == null,
          "batch " + batch + ": " + text(result).split("\n")[0]);
      require(minute.node.performed.equals(List.of(FORWARD, FORWARD)), "actions " + minute.node.performed);
    });

    test("a batch step on an element whose text changed by itself is still stale", () -> {
      WheelScene minute = new WheelScene("minute", 20, 0, 59);
      Element next = minute.scene.add("/1", "android.widget.Button", "next", "Next", 100, 2000, 300, 2100);
      next.clickable = true;
      ScriptedEngine engine = minute.engine();
      engine.shellHook = tap -> {
        minute.show(30); // the app moved the wheel; this batch did not
        return "";
      };
      engine.read();
      Map<String, Object> result = engine.call("run_actions", args("actions", List.of(
          obj("method", "click", "element_index", 3),
          obj("method", "perform_secondary_action", "element_index", 2, "action", "scroll_forward"))));
      Map<String, Object> batch = map(map(result.get("_meta")).get("opencu/batch"));
      require("stale_element".equals(batch.get("reason")), "batch " + batch);
      require(minute.node.performed.isEmpty(), "actions " + minute.node.performed);
    });

    // Item 6c: scrolling up listed whole rows mixed with parts of rows cut by the list's edge.
    for (String way : List.of("down", "up"))
      test("passed-over rows are whole rows, top to bottom, when scrolling " + way, () -> {
        boolean down = way.equals("down");
        CutListScene alarms = new CutListScene(12, down ? 0 : 1500);
        ScriptedEngine engine = ScriptedEngine.create(alarms.scene);
        engine.read();
        String out = text(engine.call("scroll", args("element_index", 1, "direction", way, "pages", 3)));
        int header = out.indexOf("Passed over while scrolling (9 distinct rows, top to bottom;");
        require(header >= 0, "header: " + out.substring(0, Math.min(out.length(), 400)));
        List<String> rows = new ArrayList<>();
        for (String line : out.substring(header).split("\n"))
          if (line.startsWith("- ")) rows.add(line.substring(2));
        List<String> expected = new ArrayList<>();
        for (int i = down ? 0 : 3; i <= (down ? 8 : 11); i++) expected.add(alarms.time(i) + " | " + alarms.label(i));
        require(rows.equals(expected), "rows " + rows + " expected " + expected);
      });

    // Item 6d: 20 pages up stopped part-way without saying how many pages or why.
    test("a multi-page scroll that a new window stops says how many pages had scrolled", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> {
        rows.show(rows.offset + 2);
        if (rows.offset == 4) {
          Window dialog = new Window();
          dialog.id = 9;
          dialog.type = 1;
          dialog.pkg = "example.other";
          dialog.layer = 5;
          dialog.right = 1080;
          dialog.bottom = 600;
          dialog.focused = dialog.active = true;
          rows.scene.extraWindows.add(dialog);
        }
      });
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      Failure f = failure(() -> engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 5)));
      require(f.code.equals("POPUP"), f.code + ": " + f.getMessage());
      require(f.getMessage().contains("(2 of 5 pages had scrolled)"), f.getMessage());
    });

    test("a multi-page scroll that physical input stops says how many pages had scrolled", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(rows.offset + 2));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      engine.checkHook = () -> {
        if (rows.node.performed.size() >= 2) throw Core.fail("PERSON_ACTIVE", "Physical input detected.");
      };
      Failure f = failure(() -> engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 4)));
      require(f.code.equals("PERSON_ACTIVE"), f.code + ": " + f.getMessage());
      require(f.getMessage().contains("(1 of 4 pages had scrolled)"), f.getMessage());
    });

    test("a multi-page scroll that did every page says so and that there may be more", () -> {
      ListScene rows = new ListScene(DOWN);
      rows.node.effects.put(DOWN, () -> rows.show(rows.offset + 2));
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      String out = text(engine.call("scroll", args("element_index", 1, "direction", "down", "pages", 3)));
      require(out.startsWith("All 3 pages scrolled; there may be more"), "notice: " + out.split("\n")[0]);
    });

    test("a swiped page covers most of the visible list, about as far as an accessibility page", () -> {
      ListScene rows = new ListScene(FORWARD); // no way up: the page is swiped
      ScriptedEngine engine = ScriptedEngine.create(rows.scene);
      engine.read();
      engine.call("scroll", args("element_index", 1, "direction", "up"));
      List<int[]> points = motions(engine);
      require(!points.isEmpty(), "no swipe sent");
      int travel = points.get(points.size() - 1)[2] - points.get(0)[2];
      int visible = 2000 - 144; // the list below the display's top strip
      require(travel >= visible * 3 / 4, "the finger travelled " + travel + " px of " + visible);
    });
  }

  /**
   * A recycled list of {@code count} alarm rows, 200 px each, in a viewport from y=100 to y=1000.
   * Each visible row is a clickable layout at "/0/k" holding a time (upper half) and a label
   * (lower half); a row the viewport's edge cuts has clipped bounds and keeps its own size, and a
   * half outside the viewport is absent, as Android reports them. Scroll-down/up move exactly one
   * viewport, as RecyclerView's accessibility scroll does.
   */
  static final class CutListScene {
    final Scene scene = new Scene();
    final Element list;
    final FakeNode node;
    final int count, top = 100, bottom = 1000, height = 200;
    int offset;

    CutListScene(int count, int offset) {
      this.count = count;
      list = scene.add("/0", "androidx.recyclerview.widget.RecyclerView", "alarms", "", 0, top, 1080, bottom);
      list.scrollable = true;
      node = scene.node(list).with(DOWN, UP);
      node.scrollable = true;
      int end = count * height - (bottom - top);
      node.effects.put(DOWN, () -> layout(Math.min(this.offset + (bottom - top), end)));
      node.effects.put(UP, () -> layout(Math.max(this.offset - (bottom - top), 0)));
      layout(offset);
    }

    String time(int i) {
      return String.format(Locale.ROOT, "%02d:%02d", 6 + i / 4, i % 4 * 15);
    }

    String label(int i) {
      return i % 2 == 0 ? "Daily" : "Once";
    }

    void layout(int offset) {
      this.offset = offset;
      while (scene.specs.size() > 1) {
        scene.specs.remove(1);
        scene.nodes.remove(1);
      }
      int child = 0;
      for (int i = 0; i < count; i++) {
        int y0 = top + i * height - offset, y1 = y0 + height;
        if (y1 <= top || y0 >= bottom) continue;
        String path = "/0/" + child++;
        Element row = scene.add(path, "android.widget.LinearLayout", "row", "", 0, Math.max(y0, top), 1080, Math.min(y1, bottom));
        row.clickable = true;
        own(row, 1080, height);
        int[][] halves = {{y0, y0 + height / 2}, {y0 + height / 2, y1}};
        String[] texts = {time(i), label(i)};
        for (int h = 0; h < 2; h++) {
          int a = halves[h][0], b = halves[h][1];
          if (b <= top || a >= bottom) continue;
          Element t = scene.add(path + "/" + h, "android.widget.TextView", h == 0 ? "time" : "label", texts[h], 0, Math.max(a, top), 800, Math.min(b, bottom));
          own(t, 800, height / 2);
        }
      }
    }

    static void own(Element e, int width, int height) {
      if (!hasField(Element.class, "fullHeight")) return; // older engines did not read a node's own size
      set(e, "fullWidth", width);
      set(e, "fullHeight", height);
    }
  }

  /**
   * A time-picker column: a focusable NumberPicker at "/0/1" under a label, showing its value as
   * two-digit text, with scroll forward and backward. Its new value shows {@code delayMs} after a
   * step, as a wheel that animates first. More wheels can be added beside it.
   */
  static final class WheelScene {
    final class Wheel {
      final Element element;
      final FakeNode node;
      final int min, max;
      int value;
      Integer pending;
      long pendingAt;

      Wheel(String path, String id, int value, int min, int max, int left) {
        element = scene.add(path, "android.widget.NumberPicker", id, "", left, 900, left + 200, 1300);
        element.focusable = true;
        element.actions.put("scroll_forward", FORWARD);
        element.actions.put("scroll_backward", BACKWARD);
        node = scene.node(element).with(FORWARD, BACKWARD);
        this.min = min;
        this.max = max;
        show(value);
        node.effects.put(FORWARD, () -> step(forwardDecreases ? -1 : 1));
        node.effects.put(BACKWARD, () -> step(forwardDecreases ? 1 : -1));
      }

      void step(int by) {
        int next = value + by;
        if (next > max) next = wraps ? min : max;
        if (next < min) next = wraps ? max : min;
        pending = next;
        pendingAt = android.os.SystemClock.uptimeMillis() + delayMs;
      }

      void show(int v) {
        value = v;
        element.text = String.format(Locale.ROOT, "%02d", v);
        node.text = element.text;
        if (element.ranged) set(element, "current", (float) v);
      }

      void tick() {
        if (pending != null && android.os.SystemClock.uptimeMillis() >= pendingAt) {
          show(pending);
          pending = null;
        }
      }
    }

    final Scene scene = new Scene();
    final List<Wheel> wheels = new ArrayList<>();
    final Element wheel;
    final FakeNode node;
    boolean wraps = true, forwardDecreases;
    long delayMs = 120;

    WheelScene(String id, int value, int min, int max) {
      scene.add("/0/0", "android.widget.TextView", "", "Alarm time", 0, 800, 1080, 880);
      Wheel w = addWheel("/0/1", id, value, min, max, 600);
      wheel = w.element;
      node = w.node;
    }

    Wheel addWheel(String path, String id, int value, int min, int max, int left) {
      Wheel w = new Wheel(path, id, value, min, max, left);
      wheels.add(w);
      return w;
    }

    /** Gives the first wheel RangeInfo with its bounds. */
    void ranged() {
      Wheel w = wheels.get(0);
      set(w.element, "ranged", true);
      set(w.element, "min", (float) w.min);
      set(w.element, "max", (float) w.max);
      set(w.element, "current", (float) w.value);
    }

    void show(int value) {
      wheels.get(0).show(value);
    }

    ScriptedEngine engine() {
      ScriptedEngine engine = ScriptedEngine.create(scene);
      engine.onObserve = n -> {
        for (Wheel w : wheels) w.tick();
      };
      return engine;
    }
  }

  /**
   * A form in a ScrollView at "/0" that lists scroll forward and backward while it can still go
   * up; it shows "Row N" at its top and goes up one row per scroll-backward. At row 0 it stops
   * listing scroll-backward and the action does nothing, as a ScrollView at its top.
   */
  static final class FormScene {
    final Scene scene = new Scene();
    final Element form = scene.add("/0", "android.widget.ScrollView", "form", "", 0, 100, 1080, 2000);
    final Element row = scene.add("/0/0", "android.widget.TextView", "", "", 0, 300, 1080, 500);
    final FakeNode node;
    int offset;

    FormScene(int offset) {
      this.offset = offset;
      row.text = "Row " + offset;
      form.scrollable = true;
      form.actions.put("scroll_forward", FORWARD);
      form.actions.put("scroll_backward", BACKWARD);
      node = scene.node(form).with(FORWARD, BACKWARD);
      node.scrollable = true;
      node.effects.put(BACKWARD, () -> {
        this.offset--;
        row.text = "Row " + this.offset;
        if (this.offset == 0) stopListingBackward();
      });
    }

    void stopListingBackward() {
      node.actions.remove(BACKWARD);
      form.actions.remove("scroll_backward");
    }
  }
}
