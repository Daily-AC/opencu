package dev.opencu.android;

import static dev.opencu.android.Core.*;
import static dev.opencu.android.Json.*;

import java.nio.file.*;
import java.util.*;

public final class OfflineTests {
  static int tests;

  static void check(boolean condition, String message) {
    tests++;
    if (!condition) throw new AssertionError(message);
  }

  static void error(String code, Runnable f) {
    tests++;
    try {
      f.run();
      throw new AssertionError("Expected " + code);
    } catch (Failure e) {
      if (!code.equals(e.code)) throw new AssertionError(e.code + " != " + code);
    }
  }

  static Element element() {
    Element e = new Element();
    e.index = 1;
    e.window = 4;
    e.path = "/0/1";
    e.pkg = "dev.opencu.android.fixture";
    e.clazz = "android.widget.EditText";
    e.id = e.pkg + ":id/chinese";
    e.text = "无线调试 测试";
    e.editable = true;
    e.left = 40;
    e.top = 200;
    e.right = 1000;
    e.bottom = 330;
    return e;
  }

  static Screen screen(String fg, String text, int window) {
    Screen s = new Screen();
    s.foreground = fg;
    s.activity = fg + "/.MainActivity";
    s.target = fg;
    Window w = new Window();
    w.id = window;
    w.pkg = fg;
    w.type = 1;
    w.active = true;
    s.windows.add(w);
    Element e = element();
    e.text = text;
    e.window = window;
    w.elements.add(e);
    s.elements.put(1, e);
    return s;
  }

  static String event(double time, String code, String value) {
    return String.format(Locale.ROOT, "[ %f] /dev/input/event1: EV_KEY %s %s", time, code, value);
  }

  public static void main(String[] args) throws Exception {
    Map<String, Object> recording =
        map(Json.read(Files.readString(Path.of(args[0], "recorded-form.json"))));
    for (Object raw : list(recording.get("nodes"))) {
      Map<String, Object> record = map(raw);
      Element node = new Element();
      for (String key : record.keySet()) {
        if (key.equals("expected") || key.equals("bounds") || key.equals("actions")) continue;
        java.lang.reflect.Field field = Element.class.getField(key);
        Object value = record.containsKey(key) ? record.get(key) : Boolean.FALSE;
        if (field.getType() == int.class) field.setInt(node, ((Number) value).intValue());
        else field.set(node, value);
      }
      List<Object> bounds = list(record.get("bounds"));
      node.left = ((Number) bounds.get(0)).intValue();
      node.top = ((Number) bounds.get(1)).intValue();
      node.right = ((Number) bounds.get(2)).intValue();
      node.bottom = ((Number) bounds.get(3)).intValue();
      if (record.containsKey("actions"))
        for (Object a : list(record.get("actions"))) node.actions.put((String) a, 0);
      check(node.useful(), "recorded visible node retained");
      if (!node.line().equals(record.get("expected")))
        throw new AssertionError(
            "recorded node line fidelity: " + node.line() + " != " + record.get("expected"));
      node.visible = false;
      check(!node.useful(), "recorded node hidden variant omitted");
    }
    Element e = element();
    check(e.useful(), "editable survives");
    check(
        e.line().equals("[1] EditText text=\"无线调试 测试\" id=chinese editable bounds=40,200,1000,330"),
        "compact deterministic format");
    Element hidden = element();
    hidden.visible = false;
    check(!hidden.useful(), "invisible omitted");
    hidden.visible = true;
    hidden.right = hidden.left;
    check(!hidden.useful(), "zero size omitted");
    Element layout = new Element();
    layout.clazz = "android.widget.LinearLayout";
    layout.right = 1000;
    layout.bottom = 1000;
    check(!layout.useful(), "pure layout omitted while child traversal stays independent");
    Element idOnly = element();
    idOnly.text = "";
    idOnly.desc = "";
    idOnly.id = "fixture:id/img_clr";
    idOnly.editable = false;
    idOnly.clickable = false;
    idOnly.longClickable = false;
    idOnly.scrollable = false;
    idOnly.checkable = false;
    idOnly.actions.clear();
    check(!idOnly.useful(), "id-only decorative node omitted");
    e.enabled = false;
    e.password = true;
    e.checked = true;
    check(e.line().contains("enabled=false password"), "flags");
    check(!e.line().contains("无线"), "password hidden");
    Element old = element(), current = element();
    check(old.same(current), "identity matches");
    current.left += 500;
    check(!old.same(current), "moved stale");
    current = element();
    current.text = "different";
    check(!old.same(current), "changed text stale");
    current = element();
    current.path = "/0/2";
    check(!old.same(current), "path stale");
    check(!old.same(null), "vanished stale");
    String app = "dev.opencu.android.fixture";
    Protocol.validate("set_value", obj("app", app, "element_index", 1, "value", "你好"));
    error(
        "INVALID_ARGUMENT",
        () -> Protocol.validate("click", obj("app", app, "element_index", 1, "x", 20, "y", 30)));
    error("INVALID_ARGUMENT", () -> Protocol.validate("click", obj("app", app, "x", 20)));
    error(
        "INVALID_ARGUMENT",
        () -> Protocol.validate("set_value", obj("app", app, "element_index", 1.5, "value", "x")));
    error(
        "INVALID_ARGUMENT",
        () -> Protocol.validate("click", obj("app", app, "element_index", 1, "duration", 31)));
    error(
        "INVALID_ARGUMENT",
        () -> Protocol.validate("press_key", obj("app", app, "key", "volume_down")));
    error(
        "INVALID_ARGUMENT",
        () -> Protocol.validate("run_actions", obj("app", app, "actions", List.of())));
    error(
        "INVALID_ARGUMENT",
        () ->
            Protocol.validate(
                "run_actions",
                obj(
                    "app",
                    app,
                    "actions",
                    Collections.nCopies(17, obj("method", "wait", "ms", 1)))));
    error(
        "INVALID_ARGUMENT",
        () ->
            Protocol.validate(
                "run_actions",
                obj(
                    "app",
                    app,
                    "actions",
                    List.of(
                        obj("method", "wait", "ms", 1), obj("method", "click", "x", 1, "y", 2)))));
    error(
        "INVALID_ARGUMENT",
        () ->
            Protocol.validate(
                "run_actions",
                obj(
                    "app",
                    app,
                    "actions",
                    List.of(obj("method", "wait", "ms", 1, "until", obj("timeoutMs", 9))))));
    error(
        "INVALID_ARGUMENT",
        () ->
            Protocol.validate(
                "run_actions",
                obj(
                    "app",
                    app,
                    "actions",
                    List.of(
                        obj(
                            "method",
                            "wait",
                            "ms",
                            1,
                            "until",
                            obj("text", "ready", "timeoutMs", 20001))))));
    error(
        "INVALID_ARGUMENT", () -> Protocol.validate("get_app_state", obj("app", app, "scope", 1)));
    error(
        "INVALID_ARGUMENT",
        () -> Protocol.validate("paste", obj("app", app, "text", "x", "format", "html")));
    Protocol.validate(
        "run_actions",
        obj(
            "app",
            app,
            "actions",
            List.of(
                obj(
                    "method",
                    "set_value",
                    "element_index",
                    1,
                    "value",
                    "你好",
                    "until",
                    obj(
                        "text",
                        "你好",
                        "gone",
                        "loading",
                        "stable",
                        true,
                        "app",
                        app,
                        "timeoutMs",
                        20000)))));
    Screen loading = screen(app, "Loading fixture data", 10),
        ready = screen(app, "Fixture result ready", 10);
    Map<String, Object> until =
        obj(
            "text",
            "Fixture result ready",
            "gone",
            "Loading fixture data",
            "app",
            app,
            "stable",
            true);
    check(!Core.until(until, loading, 1000), "loading fails conjunctive condition");
    Screen focusedText = screen(app, "无线调试", 10);
    focusedText.elements.get(1).focused = true;
    check(!Core.until(obj("text", "无线调试"), focusedText, 0), "wait text ignores focused editor value");
    check(!Core.until(until, ready, 399), "not stable yet");
    check(Core.until(until, ready, 400), "all predicates hold");
    ready.windows.get(0).title = "needle";
    check(
        !Core.until(obj("text", "needle"), ready, 900),
        "window title cannot satisfy text condition");
    check(Core.stopReason(loading, ready, "") == null, "same windows continue");
    Screen dialog = screen(app, "Choose a fixture button", 11);
    check(Core.stopReason(loading, dialog, "").equals("popup"), "new dialog stops");
    Screen system = screen("com.android.permissioncontroller", "Allow", 12);
    system.windows.get(0).type = 3;
    check(Core.stopReason(loading, system, "").equals("system_dialog"), "system dialog stops");
    Screen switched = screen("another.package", "Other", 12);
    check(Core.stopReason(loading, switched, "").equals("app_switched"), "unexpected app stops");
    check(Core.stopReason(loading, switched, "another.package") == null, "expected app allowed");
    check(
        Core.scrollNotice(0, 1).equals("Nothing moved; the list is at its end or does not scroll this way"),
        "scroll at end notice");
    check(
        Core.scrollNotice(3, 5).equals("Scrolled 3 of 5 pages; reached the end"),
        "partial scroll notice");
    check(Core.scrollNotice(5, 5).equals("Scrolled 5 of 5 pages"), "complete scroll notice");
    check(
        Core.screenshotNotice(576, 1280, 1080, 2400)
            .equals(
                "Screenshot: 576x1280 JPEG of the 1080x2400 display; coordinates in later calls use this image"),
        "screenshot scale notice");
    check(Core.textInputMatches("无线调试", "无线调试"), "text input postcondition matches");
    check(!Core.textInputMatches("无线调试", "搜索设置项"), "text input postcondition rejects unchanged field");
    check(Core.textInputSatisfied("无线调试", null, true), "app reaction satisfies text input");
    check(!Core.textInputSatisfied("无线调试", "搜索设置项", false), "silent text input fails");
    Await deadline = new Await(loading, obj("text", "never", "timeoutMs", 350), "", 0);
    check(deadline.poll(loading, 349).equals("continue"), "wait before deadline");
    check(deadline.poll(loading, 350).equals("timeout"), "wait at deadline");
    Await transition =
        new Await(
            loading, obj("text", "Fixture result ready", "gone", "Loading fixture data"), "", 0);
    check(transition.poll(loading, 20).equals("continue"), "loading sequence waits");
    check(transition.poll(ready, 1500).equals("complete"), "result sequence completes");
    check(
        new Await(loading, obj("text", "never"), "", 0).poll(dialog, 100).equals("popup"),
        "popup wins over pending condition");
    Await stable = new Await(loading, obj("stable", true), "", 0);
    check(stable.poll(loading, 0).equals("continue"), "stable starts");
    check(stable.poll(ready, 350).equals("continue"), "state change restarts stability");
    check(stable.poll(ready, 749).equals("continue"), "stable before 400 ms");
    check(stable.poll(ready, 750).equals("complete"), "stable after 400 ms");
    Person contact = new Person(0);
    contact.accept("[ 10.000000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID 00000007", 10000);
    error("PERSON_ACTIVE", () -> contact.check(contact.token(), 20000, false));
    contact.accept("[ 10.100000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID ffffffff", 10100);
    contact.check(contact.token(), 20000, false);
    Person person = new Person(0);
    person.check(0, 10000, true);
    error("PERSON_ACTIVE", () -> new Person(0).check(0, 9999, true));
    check(
        Core.lastUserActivityTime("lastUserActivityTime=12345\\n", 99) == 12345,
        "PowerManager activity seed parses");
    new Person(Core.lastUserActivityTime("lastUserActivityTime=12345", 99)).check(0, 22345, true);
    error(
        "PERSON_ACTIVE",
        () ->
            new Person(Core.lastUserActivityTime("lastUserActivityTime=22300", 99))
                .check(0, 22345, true));
    person.accept(event(10, "KEY_A", "DOWN"), 11000);
    error("PERSON_ACTIVE", () -> person.check(0, 11001, false));
    long token = person.token();
    error("PERSON_ACTIVE", () -> person.check(token, 11001, false));
    person.accept(event(10.1, "KEY_A", "UP"), 11100);
    person.check(person.token(), 11100, false);
    check(!person.stopped, "ordinary key does not stop");
    Person stop = new Person(0);
    for (double time : new double[] {20, 20.5, 21.5}) {
      stop.accept(event(time, "KEY_VOLUMEDOWN", "DOWN"), (long) (time * 1000));
      stop.accept(event(time + .01, "KEY_VOLUMEDOWN", "UP"), (long) (time * 1000) + 10);
    }
    check(stop.stopped, "three presses within inclusive 1.5 s stop");
    error("USER_STOPPED", () -> stop.check(stop.token(), 999999, false));
    Person slow = new Person(0);
    for (double time : new double[] {20, 20.8, 21.501}) {
      slow.accept(event(time, "KEY_VOLUMEDOWN", "DOWN"), (long) (time * 1000));
      slow.accept(event(time + .01, "KEY_VOLUMEDOWN", "UP"), (long) (time * 1000) + 10);
    }
    check(!slow.stopped, "outside 1.5 s does not stop");
    Person repeat = new Person(0);
    for (int i = 0; i < 5; i++)
      repeat.accept(
          event(20 + i * .1, "KEY_VOLUMEDOWN", i == 0 ? "DOWN" : "REPEAT"), 20000 + i * 100);
    check(!repeat.stopped, "autorepeat is not three presses");
    Person injected = new Person(0);
    for (int i = 0; i < 3; i++) injected.accept("input keyevent 25", i);
    check(!injected.stopped && injected.token() == 0, "injected commands are not evdev records");
    // Read the persisted traces, not just hand-built event calls.
    for (Object raw : list(Json.read(Files.readString(Path.of(args[0], "traces.json"))))) {
      Map<String, Object> trace = map(raw);
      Person p = new Person(0);
      for (Object line : list(trace.get("lines"))) p.accept((String) line, 20000);
      check(p.stopped == Boolean.TRUE.equals(trace.get("stopped")), "trace " + trace.get("name"));
      if (Boolean.TRUE.equals(trace.get("expectActivity"))) {
        check(p.token() > 0, "recorded touch counted");
        p.check(p.token(), 20000, false);
      }
    }
    final int[] calls = {0};
    Protocol protocol =
        new Protocol(
            (name, a) -> {
              calls[0]++;
              return Protocol.textResult("fixture");
            },
            "test");
    check(map(protocol.handle("{bad").get("error")).get("code").equals(-32700), "parse error");
    check(
        map(protocol.handle("[]").get("error")).get("code").equals(-32600),
        "JSON-RPC batching unsupported");
    String init =
        write(
            obj(
                "jsonrpc",
                "2.0",
                "id",
                "a",
                "method",
                "initialize",
                "params",
                obj(
                    "protocolVersion",
                    "2024-11-05",
                    "capabilities",
                    obj(),
                    "clientInfo",
                    obj("name", "test", "version", "1"))));
    Map<String, Object> initialized = map(protocol.handle(init).get("result"));
    check(map(initialized.get("serverInfo")).get("name").equals("opencu"), "server identity");
    check(initialized.get("instructions").equals(Protocol.INSTRUCTIONS), "instructions returned");
    check(
        initialized.get("protocolVersion").equals("2024-11-05"),
        "legacy MCP protocol is negotiated unchanged");
    check(
        protocol.handle(write(obj("jsonrpc", "2.0", "method", "notifications/initialized")))
            == null,
        "no notification response");
    Map<String, Object> first =
        map(
            protocol
                .handle(write(obj("jsonrpc", "2.0", "id", 2, "method", "tools/list")))
                .get("result"));
    check(first.get("nextCursor").equals("8"), "pagination cursor");
    Map<String, Object> second =
        map(
            protocol
                .handle(
                    write(
                        obj(
                            "jsonrpc",
                            "2.0",
                            "id",
                            3,
                            "method",
                            "tools/list",
                            "params",
                            obj("cursor", "8"))))
                .get("result"));
    check(
        list(first.get("tools")).size() + list(second.get("tools")).size() == 13,
        "complete tool list");
    check(
        map(protocol
                .handle(write(obj("jsonrpc", "2.0", "id", 4, "method", "missing")))
                .get("error"))
            .get("code")
            .equals(-32601),
        "unknown method");
    Map<String, Object> invalid =
        map(
            protocol
                .handle(
                    write(
                        obj(
                            "jsonrpc",
                            "2.0",
                            "id",
                            5,
                            "method",
                            "tools/call",
                            "params",
                            obj("name", "click", "arguments", obj("app", app)))))
                .get("result"));
    check(
        Boolean.TRUE.equals(invalid.get("isError"))
            && map(invalid.get("_meta")).get("opencu/error").equals("INVALID_ARGUMENT"),
        "tool error envelope");
    check(calls[0] == 0, "invalid arguments never reach backend");
    List<String> frames = new ArrayList<>();
    Framing.read(new java.io.StringReader("{\"one\":1}\n{\"two\":\"中文\"}\r\npartial"), frames::add);
    check(
        frames.size() == 2 && frames.get(1).contains("中文"),
        "framing handles CRLF, Unicode, multiple lines and partial EOF");
    frames.clear();
    Framing.read(
        new java.io.FilterReader(new java.io.StringReader("ping\npong\n")) {
          public int read(char[] b, int o, int n) throws java.io.IOException {
            return super.read(b, o, Math.min(1, n));
          }
        },
        frames::add);
    check(frames.equals(List.of("ping", "pong")), "framing handles one-character stream chunks");
    String special = "line\n\"quote\"\\backslash 无线调试 😀";
    check(Json.read(Json.write(special)).equals(special), "JSON Unicode and escaping");
    check(
        Protocol.stopNotice().get("method").equals("notifications/message"),
        "stop uses MCP notification framing");
    check(
        String.valueOf(Protocol.stopNotice(Protocol.COMPANION_STOP)).contains("USER_STOPPED")
            && String.valueOf(Protocol.stopNotice(Protocol.COMPANION_STOP)).contains("OpenCU app"),
        "a stop from the companion app is the same USER_STOPPED notice");
    Person stopper = new Person(0);
    check(stopper.stopByPerson() && !stopper.stopByPerson(), "the app's stop latches once");
    try {
      stopper.checkDesktop();
      throw new AssertionError("input allowed after the app's stop");
    } catch (Failure expected) {
      check(expected.code.equals("USER_STOPPED"), "the app's stop refuses later input");
    }
    Element field = new Element();
    field.text = "旧的地址";
    field.editable = true;
    Map<String, Object> typed =
        Core.activity("type_text", Json.obj("text", "北京市顺义区某某路 1 号 2 单元 301 室，请放门口不用敲门谢谢，麻烦了，辛苦师傅"), field, "com.example.food", 2, 5);
    check(
        typed.get("tool").equals("type_text")
            && typed.get("app").equals("com.example.food")
            && ((String) typed.get("text")).codePointCount(0, ((String) typed.get("text")).length()) == 40
            && ((String) typed.get("text")).endsWith("\u2026")
            && typed.get("step").equals(2)
            && typed.get("steps").equals(5),
        "activity carries the tool, app, step and typed text cut to 40 characters");
    field.password = true;
    Map<String, Object> secret = Core.activity("type_text", Json.obj("text", "hunter2"), field, "", 0, 0);
    check(!secret.containsKey("text") && secret.get("chars").equals(7) && !secret.containsKey("target"),
        "a password field shows only its length, never its text or label");
    Map<String, Object> blind = Core.activity("type_text", Json.obj("text", "hunter2"), null, "", 0, 0);
    check(!blind.containsKey("text") && blind.get("chars").equals(7),
        "typing into a field the engine has not identified shows only its length");
    Element pay = new Element();
    pay.desc = "去结算";
    Map<String, Object> tap = Core.activity("click", Json.obj("element_index", 4, "click_count", 2), pay, "", 0, 0);
    check(tap.get("target").equals("去结算") && tap.get("click_count").equals(2) && !tap.containsKey("step"),
        "a click names its element by text or description");
    for (String bad : List.of("01", "1.", "{\"x\":1,\"x\":2}", "true junk", "[1,]")) {
      try {
        Json.read(bad);
        throw new AssertionError("accepted " + bad);
      } catch (IllegalArgumentException expected) {
        tests++;
      }
    }
    System.out.println("Android offline checks passed: " + tests);
  }
}
