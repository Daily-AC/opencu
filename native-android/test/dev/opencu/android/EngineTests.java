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
    Body checkHook;
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
      set(e, "keyboardInputFailure", "");
      set(e, "desktopDisplay", -1);
      set(e, "activeDisplay", 0);
      set(e, "desktopIdleMs", 300_000L);
      set(e, "person", new Person(0));
      set(e, "monitorProblem", "");
      e.scene = scene;
      e.mainForeground = "";
      e.log = Collections.synchronizedList(new ArrayList<>());
      e.events = Collections.synchronizedList(new ArrayList<>());
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
    void waitIdle() {}

    @Override
    String resolve(String name) {
      return name;
    }

    @Override
    String shell(String... args) throws Exception {
      log.add("shell " + String.join(" ", args));
      return shellHook == null ? "" : shellHook.run(args);
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

    @Override
    void stopDesktop() {
      log.add("stopDesktop");
      set(this, "desktopDisplay", -1);
      set(this, "activeDisplay", 0);
      set(this, "automation", get(this, "mainAutomation"));
    }
  }

  static Map<String, Object> args(Object... pairs) {
    Map<String, Object> a = obj("app", PKG);
    a.putAll(obj(pairs));
    return a;
  }

  public static void main(String[] argv) throws Exception {
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

    if (!failures.isEmpty()) {
      System.out.println("Android engine host checks failed: " + failures);
      System.exit(1);
    }
    System.out.println("Android engine host checks passed: " + passed);
  }
}
