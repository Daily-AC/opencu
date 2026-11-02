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
    boolean editable, clickable, scrollable, hint, refreshes;
    String text;
    int selectionStart, selectionEnd;
    Set<Integer> actions;
    Map<Integer, Boolean> results;
    Map<Integer, Runnable> effects;
    List<Integer> performed;
    List<String> setTexts;

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
      return n;
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
      if (!actions.contains(action)) return false; // Android ignores actions a node does not list.
      if (action == ACTION_SET_TEXT && arguments != null) {
        CharSequence value = arguments.getCharSequence(ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE);
        setTexts.add(String.valueOf(value));
        text = String.valueOf(value);
      }
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
      return text;
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
    Body checkHook, resolveHook;
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
      if (hasField(AndroidEngine.class, "clipboardLock")) set(e, "clipboardLock", new Object());
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

    @Override
    void check(long token, boolean changing) {
      if ((Boolean) get(this, "closed")) throw Core.fail("ENGINE_STOPPING", "Stdin closed");
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

    // Not annotated: older engines lack this hook and simply never call it.
    boolean displayInputAvailable() {
      return true;
    }

    @Override
    boolean hasAction(AccessibilityNodeInfo n, int id) {
      return ((FakeNode) n).actions.contains(id);
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

    @Override
    void stopDesktop() {
      log.add("stopDesktop");
      set(this, "desktopDisplay", -1);
      set(this, "activeDisplay", 0);
      set(this, "automation", get(this, "mainAutomation"));
    }
  }

  /** A clipboard binder: the person's clip, with reads optionally refused. */
  public static final class ClipService {
    volatile android.content.ClipData clip;
    volatile boolean denyReads;
    final List<String> calls = Collections.synchronizedList(new ArrayList<>());

    public android.content.ClipData getPrimaryClip(String pkg, String tag, int user, int device) {
      calls.add("read");
      if (denyReads) throw new SecurityException("denied");
      return clip;
    }

    public void setPrimaryClip(android.content.ClipData c, String pkg, String tag, int user, int device) {
      calls.add("write");
      clip = c;
    }

    public void clearPrimaryClip(String pkg, String tag, int user, int device) {
      calls.add("clear");
      clip = null;
    }

    String text() {
      return clip == null ? null : String.valueOf(clip.hostText());
    }
  }

  static ShellClipboard clipboard(ClipService service) throws Exception {
    ShellClipboard c = allocate(ShellClipboard.class);
    set(c, "callerPackage", "com.android.shell");
    set(c, "service", service);
    Class<?> s = String.class, i = int.class, clip = android.content.ClipData.class;
    set(c, "getPrimaryClip", ClipService.class.getMethod("getPrimaryClip", s, s, i, i));
    set(c, "setPrimaryClip", ClipService.class.getMethod("setPrimaryClip", clip, s, s, i, i));
    set(c, "clearPrimaryClip", ClipService.class.getMethod("clearPrimaryClip", s, s, i, i));
    return c;
  }

  /** A focused editor whose paste inserts the clipboard text, as an app's editor does. */
  static FakeNode focusedEditor(Scene scene, ClipService service, int... actions) {
    Element field = scene.add("/0", "android.widget.EditText", "query", "", 0, 100, 1080, 200);
    field.editable = true;
    field.focused = true;
    FakeNode node = scene.node(field).with(actions);
    node.editable = true;
    node.effects.put(AccessibilityNodeInfo.ACTION_PASTE, () -> {
      node.text = node.text + service.text();
      field.text = node.text;
    });
    node.effects.put(AccessibilityNodeInfo.ACTION_SET_TEXT, () -> field.text = node.text);
    return node;
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

    test("clipboard read failure is unreadable, not empty", () -> {
      ClipService service = new ClipService();
      service.denyReads = true;
      Object snapshot = invoke(clipboard(service), "read", new Class<?>[0]);
      require(!(Boolean) get(snapshot, "readable"), "refused read reported as readable");
      service.denyReads = false;
      Object empty = invoke(clipboard(service), "read", new Class<?>[0]);
      require((Boolean) get(empty, "readable") && get(empty, "clip") == null, "empty clipboard not readable-empty");
    });

    test("type_text never writes a clipboard it could not read", () -> {
      ClipService service = new ClipService();
      service.clip = android.content.ClipData.newPlainText("person", "PERSON-CLIP");
      service.denyReads = true;
      Scene scene = new Scene();
      FakeNode node =
          focusedEditor(scene, service, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "clipboard", clipboard(service));
      engine.read();
      Map<String, Object> result = engine.call("type_text", args("text", "hello"));
      require(!service.calls.contains("write") && !service.calls.contains("clear"), "clipboard changed: " + service.calls);
      require("PERSON-CLIP".equals(service.text()), "person's clip lost");
      require(!node.performed.contains(AccessibilityNodeInfo.ACTION_PASTE), "pasted");
      require(node.setTexts.equals(List.of("hello")), "set-text " + node.setTexts);
      require(text(result).contains("clipboard could not be read"), "no reason: " + text(result).split("\n")[0]);
    });

    test("type_text pastes and restores the person's clip", () -> {
      ClipService service = new ClipService();
      service.clip = android.content.ClipData.newPlainText("person", "PERSON-CLIP");
      Scene scene = new Scene();
      FakeNode node =
          focusedEditor(scene, service, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "clipboard", clipboard(service));
      engine.read();
      engine.call("type_text", args("text", "无线调试"));
      require(node.text.equals("无线调试"), "editor: " + node.text);
      require("PERSON-CLIP".equals(service.text()), "clipboard now " + service.text());
      require(node.setTexts.isEmpty(), "used set-text");
    });

    test("type_text with an empty clipboard pastes and leaves it empty", () -> {
      ClipService service = new ClipService();
      Scene scene = new Scene();
      FakeNode node =
          focusedEditor(scene, service, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "clipboard", clipboard(service));
      engine.read();
      engine.call("type_text", args("text", "wuxian"));
      require(node.text.equals("wuxian") && node.setTexts.isEmpty(), "editor: " + node.text + " " + node.setTexts);
      require(service.clip == null, "clipboard left with " + service.text());
    });

    test("a rejected paste is unconfirmed and never followed by set-text", () -> {
      ClipService service = new ClipService();
      service.clip = android.content.ClipData.newPlainText("person", "PERSON-CLIP");
      Scene scene = new Scene();
      FakeNode node =
          focusedEditor(scene, service, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      node.results.put(AccessibilityNodeInfo.ACTION_PASTE, false);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "clipboard", clipboard(service));
      engine.read();
      Failure f = failure(() -> engine.call("type_text", args("text", "hello")));
      require(node.setTexts.isEmpty(), "replayed through set-text " + node.setTexts + ", then " + f.code);
      require(f.code.equals("ACTION_UNCONFIRMED"), f.code + ": " + f.getMessage());
      require("PERSON-CLIP".equals(service.text()), "clipboard now " + service.text());
    });

    test("type_text fallback names why paste was unusable", () -> {
      ClipService service = new ClipService();
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, service, AccessibilityNodeInfo.ACTION_SET_TEXT);
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "clipboard", clipboard(service));
      engine.read();
      Map<String, Object> result = engine.call("type_text", args("text", "hello"));
      require(node.setTexts.equals(List.of("hello")), "set-text " + node.setTexts);
      require(service.calls.isEmpty(), "clipboard touched: " + service.calls);
      require(text(result).contains("does not offer paste"), "no reason: " + text(result).split("\n")[0]);
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

    test("scroll description explains pages up to 5", () -> {
      String description = (String) Protocol.DEFINITIONS.get("scroll").get("description");
      require(description.contains("pages (up to 5"), description);
      require(description.contains("stops early at the end"), description);
      Protocol.validate("scroll", args("element_index", 1, "direction", "down", "pages", 5));
      Failure f = failure(() -> Protocol.validate("scroll", args("element_index", 1, "direction", "down", "pages", 6)));
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

    test("EOF during a blocked paste still restores the person's clipboard", () -> {
      ClipService service = new ClipService();
      service.clip = android.content.ClipData.newPlainText("person", "PERSON-CLIP");
      Scene scene = new Scene();
      FakeNode node = focusedEditor(scene, service, AccessibilityNodeInfo.ACTION_PASTE, AccessibilityNodeInfo.ACTION_SET_TEXT);
      CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
      node.effects.put(AccessibilityNodeInfo.ACTION_PASTE, () -> {
        entered.countDown();
        try {
          release.await(10, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
        }
      });
      ScriptedEngine engine = ScriptedEngine.create(scene);
      set(engine, "clipboard", clipboard(service));
      engine.read();
      Thread worker = new Thread(() -> {
        try {
          engine.call("type_text", args("text", "agent text"));
        } catch (Throwable ignored) {
        }
      });
      worker.start();
      require(entered.await(5, TimeUnit.SECONDS), "paste never started");
      try {
        try {
          engine.close();
        } catch (Throwable ignored) {
        }
        require("PERSON-CLIP".equals(service.text()), "clipboard after EOF: " + service.text());
      } finally {
        release.countDown();
        worker.join(2000);
        reopenCommands();
      }
      require("PERSON-CLIP".equals(service.text()), "clipboard after the paste returned: " + service.text());
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

    if (!failures.isEmpty()) {
      System.out.println("Android engine host checks failed: " + failures);
      System.exit(1);
    }
    System.out.println("Android engine host checks passed: " + passed);
  }
}
