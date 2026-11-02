package dev.opencu.android;

import static dev.opencu.android.Core.*;
import static dev.opencu.android.Json.*;

import java.util.*;

/** MCP surface and validation, also executed on the host JVM in offline tests. */
public final class Protocol {
  public interface Backend {
    Map<String, Object> call(String name, Map<String, Object> args) throws Exception;
  }

  public static final String INSTRUCTIONS =
      "Control Android applications with the independent OpenCU engine. Read"
          + " get_app_state before input. Use observed element indexes; request screenshots before"
          + " coordinate input. Coordinates refer to the scaled full-display JPEG. Actions return"
          + " updated state. Use run_actions for a short known sequence; its indexes refer to the"
          + " state before the batch. Steps may wait locally with until (text, gone, app, stable)."
          + " A new dialog, unexpected app switch, failed step or person activity stops the batch;"
          + " inspect its final state, never replay. type_text and set_value support Unicode."
          + " type_text pastes through the focused editor without changing the keyboard and says"
          + " when it must use an accessibility fallback. Verify actual results before"
          + " reporting success. Input uses the main display and can change foreground only after"
          + " 10 seconds without physical input. A physical touch or key during a call returns"
          + " PERSON_ACTIVE: stop and ask the person, never retry automatically. Three physical"
          + " volume-down presses within 1.5 seconds latch USER_STOPPED for this connection; never"
          + " reconnect or retry without explicit permission. Reads remain available after Stop."
          + " Locked or screen-off phones refuse input without waking or unlocking. There is no"
          + " agent desktop in milestone 1. Keep one connection per agent session and never operate"
          + " the same app concurrently. agent_desktop start creates an owned virtual display with"
          + " the main display's size and density; while it is started all app tools target that"
          + " display and the person's main display is never activated. An app already in front on"
          + " the main display returns APP_IN_USE_BY_PERSON. agent_desktop status reports the flags"
          + " obtained, size, apps and idle time; stop it when finished. The display stops after"
          + " five minutes without calls and the next app call returns AGENT_DESKTOP_IDLE_STOPPED."
          + " Main-display touches do not stop agent-display work, but physical volume-down stop"
          + " still latches USER_STOPPED. A locked or screen-off phone refuses agent input with"
          + " SCREEN_LOCKED. The virtual display uses local IME policy so its keyboard does not"
          + " appear on display 0. Respect user authorization and host approval rules. OpenCU"
          + " runs locally as shell, opens no port, and requires no account or particular agent"
          + " identity.";
  public static final Map<String, Map<String, Object>> DEFINITIONS = new LinkedHashMap<>();

  static Map<String, Object> string() {
    return obj("type", "string");
  }

  static Map<String, Object> nonempty() {
    return obj("type", "string", "minLength", 1);
  }

  static Map<String, Object> num(double min, double max, boolean integer) {
    return obj("type", integer ? "integer" : "number", "minimum", min, "maximum", max);
  }

  static Map<String, Object> bool() {
    return obj("type", "boolean");
  }

  static Map<String, Object> enumeration(String... names) {
    return obj("type", "string", "enum", Arrays.asList(names));
  }

  static Map<String, Object> object(Map<String, Object> props, String... required) {
    return obj(
        "type",
        "object",
        "properties",
        props,
        "required",
        Arrays.asList(required),
        "additionalProperties",
        false);
  }

  static Map<String, Object> props(Object... extras) {
    Map<String, Object> p = obj("app", nonempty());
    p.putAll(obj(extras));
    return p;
  }

  static Map<String, Object> state() {
    return obj(
        "includeScreenshot",
        bool(),
        "waitForText",
        nonempty(),
        "waitTimeoutMs",
        num(0, 15000, true));
  }

  static Map<String, Object> point() {
    return props(
        "element_index",
        num(1, Integer.MAX_VALUE, true),
        "x",
        num(0, 100000, false),
        "y",
        num(0, 100000, false));
  }

  static Map<String, Object> duration() {
    return num(0, 30, false);
  }

  static void add(
      String name, String desc, boolean read, Map<String, Object> p, String... required) {
    DEFINITIONS.put(
        name,
        obj(
            "name",
            name,
            "description",
            desc,
            "inputSchema",
            object(p, required),
            "annotations",
            obj("readOnlyHint", read, "openWorldHint", true)));
  }

  static {
    Map<String, Object> p = props();
    p.putAll(state());
    add(
        "get_app_state",
        "Start here: read an Android package name or launcher label. Ambiguous labels fail."
            + " Launches/brings it forward only under the person rules. Returns compact"
            + " main-display element lines, including covering windows and keyboard. Optional"
            + " full-display JPEG (long side <=1280); text normally suffices. waitForText searches"
            + " visible text/description only, case-sensitive.",
        true,
        p,
        "app");
    p = point();
    p.putAll(obj("click_count", num(1, 3, true), "duration", duration()));
    add(
        "click",
        "Tap an observed Android element or fresh screenshot coordinate; duration >0 holds a long"
            + " press (seconds). Indexed input touches the visible center first and falls back to"
            + " accessibility click only when touch cannot reach it. Returns updated state;"
            + " coordinate input returns a new JPEG. Indexed input revalidates identity and bounds before sending anything.",
        false,
        p,
        "app");
    add(
        "drag",
        "Drag between coordinates in the latest Android full-display screenshot. Returns updated"
            + " state and JPEG; no drag outside display bounds.",
        false,
        props(
            "from_x",
            num(0, 100000, false),
            "from_y",
            num(0, 100000, false),
            "to_x",
            num(0, 100000, false),
            "to_y",
            num(0, 100000, false)),
        "app",
        "from_x",
        "from_y",
        "to_x",
        "to_y");
    p = point();
    p.putAll(
        obj(
            "direction",
            enumeration("up", "down", "left", "right", "u", "d", "l", "r"),
            "pages",
            num(0.01, 5, false)));
    add(
        "scroll",
        "Scroll an indexed Android scrollable element or a fresh screenshot coordinate. pages (up"
            + " to 5, default 1) moves further in one call and stops early at the end: a page that"
            + " does not move ends the call with a notice such as 'Scrolled 3 of 5 pages; reached the"
            + " end', or 'Nothing moved; the list is at its end or does not scroll this way'. Returns"
            + " updated state (and JPEG for coordinates).",
        false,
        p,
        "app",
        "direction");
    add(
        "press_key",
        "Send an Android navigation key: back, home, enter/Return, delete/backspace, tab,"
            + " recents/app_switch or search. No volume, power, arbitrary keycodes or chords."
            + " duration is seconds. Returns updated state, including an app switch caused by the"
            + " key.",
        false,
        props("key", nonempty(), "duration", duration()),
        "app",
        "key");
    add(
        "type_text",
        "Insert Unicode text into the currently focused Android editable node by paste first,"
            + " replacing its selected range without installing or switching a keyboard. If paste"
            + " is unavailable, the result says it used the accessibility set-text fallback; the"
            + " final editor postcondition is still checked. App reactions may arrive later; use"
            + " get_app_state waitForText or run_actions until to observe them.",
        false,
        props("text", string()),
        "app",
        "text");
    add(
        "paste",
        "Paste plain text into the focused Android editable field via its listed accessibility"
            + " paste action. format must be text. Restores the previous clipboard when readable"
            + " and unchanged by another app; reports restoration limitations. Returns updated"
            + " state.",
        false,
        props("text", string(), "format", enumeration("text")),
        "app",
        "text",
        "format");
    add(
        "set_value",
        "Replace the complete value of an observed Android editable field using accessibility."
            + " Supports Unicode. Use click for checkboxes. Returns updated state.",
        false,
        props("element_index", num(1, Integer.MAX_VALUE, true), "value", string()),
        "app",
        "element_index",
        "value");
    add(
        "perform_secondary_action",
        "Perform only an Android accessibility action name listed on that element in the latest"
            + " state. Revalidates the element first and returns updated state. Do not invent"
            + " action names.",
        false,
        props("element_index", num(1, Integer.MAX_VALUE, true), "action", nonempty()),
        "app",
        "element_index",
        "action");
    Map<String, Object> u =
        object(
            obj(
                "text",
                nonempty(),
                "gone",
                nonempty(),
                "app",
                nonempty(),
                "stable",
                bool(),
                "timeoutMs",
                num(0, 20000, true)));
    u.put("minProperties", 1);
    List<Object> shapes = new ArrayList<>();
    for (Map.Entry<String, Map<String, Object>> e : DEFINITIONS.entrySet()) {
      if (e.getKey().equals("get_app_state")) continue;
      Map<String, Object> schema = map(e.getValue().get("inputSchema"));
      Map<String, Object> fields = new LinkedHashMap<>(map(schema.get("properties")));
      fields.remove("app");
      fields.put("method", enumeration(e.getKey()));
      fields.put("until", u);
      List<String> req = new ArrayList<>();
      req.add("method");
      for (Object f : list(schema.get("required"))) if (!f.equals("app")) req.add((String) f);
      shapes.add(object(fields, req.toArray(new String[0])));
    }
    shapes.add(
        object(
            obj("method", enumeration("wait"), "ms", num(1, 15000, true), "until", u),
            "method",
            "ms"));
    add(
        "run_actions",
        "Run 1–16 known Android actions and return final state. Indexes refer to the pre-batch"
            + " state and are revalidated for each step. Any step may carry"
            + " until:{text?,gone?,app?,stable?,timeoutMs?}: all predicates must hold, stable means"
            + " unchanged for 400 ms, default timeout 8000 ms/max 20000 ms. wait uses ms (1–15000)."
            + " Stops before further input on timeout, new popup/system dialog, unexpected"
            + " foreground app, stale element, failure, lock or person activity. Reports stopped"
            + " step, reason and waitedMs plus final state. Coordinates must be first. Never replay"
            + " a stopped batch.",
        false,
        props(
            "actions",
            obj("type", "array", "minItems", 1, "maxItems", 16, "items", obj("oneOf", shapes)),
            "includeScreenshot",
            bool()),
        "app",
        "actions");
    add(
        "list_apps",
        "List launchable Android apps with launcher label, package, running and foreground status."
            + " If the app is known, start with get_app_state directly.",
        true,
        obj());
    p = props();
    p.putAll(state());
    add(
        "activate_app",
        "Bring an Android package or launcher label to the main display and return state. Refuses"
            + " locked/screen-off phones and foreground changes within 10 seconds of physical"
            + " activity. Stop on PERSON_ACTIVE; do not retry.",
        false,
        p,
        "app");
    add(
        "agent_desktop",
        "Start, stop or inspect the Android agent workspace. start is idempotent and creates a"
            + " virtual display matching the main display. All app tools then read and inject on"
            + " that display; status reports display id, size, obtained trusted/own-focus flags,"
            + " apps and the idle deadline. stop releases it without finishing its tasks. A person"
            + " using the target app on display 0 receives APP_IN_USE_BY_PERSON. Main-display touch"
            + " does not interrupt this workspace; volume-down stop and lock rules still apply.",
        false,
        obj("action", enumeration("start", "stop", "status")),
        "action");
  }

  public static void validate(String method, Map<String, Object> args) {
    if (!DEFINITIONS.containsKey(method)) throw fail("METHOD_NOT_FOUND", "Unknown tool: " + method);
    try {
      validateValue(args, map(DEFINITIONS.get(method).get("inputSchema")), "arguments");
      if (method.equals("run_actions")) {
        int i = 0;
        for (Object v : list(args.get("actions"))) {
          Map<String, Object> a = map(v);
          String m = (String) a.get("method");
          extra(m, a);
          if (coordinates(m, a) && i != 0)
            throw new IllegalArgumentException("Coordinate input must be the first batch action");
          i++;
        }
      } else extra(method, args);
    } catch (IllegalArgumentException ex) {
      throw fail("INVALID_ARGUMENT", ex.getMessage());
    }
  }

  static void extra(String m, Map<String, Object> a) {
    if (m.equals("click") || m.equals("scroll")) {
      boolean ix = a.containsKey("element_index"), xy = a.containsKey("x") && a.containsKey("y");
      if (ix == xy || (!xy && (a.containsKey("x") || a.containsKey("y"))))
        throw new IllegalArgumentException("Supply either element_index or both x and y");
    }
    if (m.equals("press_key")
        && !Arrays.asList(
                "back",
                "home",
                "enter",
                "return",
                "delete",
                "backspace",
                "tab",
                "recents",
                "app_switch",
                "search")
            .contains(((String) a.get("key")).toLowerCase(Locale.ROOT)))
      throw new IllegalArgumentException("Unsupported Android key (volume and power excluded)");
    if (a.containsKey("until")) {
      Map<String, Object> u = map(a.get("until"));
      if (!u.containsKey("text")
          && !u.containsKey("gone")
          && !u.containsKey("app")
          && !Boolean.TRUE.equals(u.get("stable")))
        throw new IllegalArgumentException("until needs a condition");
    }
  }

  public static boolean coordinates(String m, Map<String, Object> a) {
    return m.equals("drag") || a.containsKey("x");
  }

  static void validateValue(Object v, Map<String, Object> s, String at) {
    if (s.containsKey("oneOf")) {
      int matches = 0;
      for (Object branch : list(s.get("oneOf")))
        try {
          validateValue(v, map(branch), at);
          matches++;
        } catch (IllegalArgumentException ignored) {
        }
      if (matches != 1) throw new IllegalArgumentException(at + ": invalid action shape");
      return;
    }
    String t = (String) s.get("type");
    boolean valid;
    switch (t) {
      case "object":
        valid = v instanceof Map;
        break;
      case "array":
        valid = v instanceof List;
        break;
      case "string":
        valid = v instanceof String;
        break;
      case "boolean":
        valid = v instanceof Boolean;
        break;
      default:
        valid =
            v instanceof Number
                && Double.isFinite(((Number) v).doubleValue())
                && (!t.equals("integer")
                    || ((Number) v).doubleValue() == Math.rint(((Number) v).doubleValue()));
    }
    if (!valid) throw new IllegalArgumentException(at + ": expected " + t);
    if (s.containsKey("enum") && !list(s.get("enum")).contains(v))
      throw new IllegalArgumentException(at + ": unsupported value");
    if (v instanceof Number) {
      double n = ((Number) v).doubleValue();
      if (n < ((Number) s.get("minimum")).doubleValue()
          || n > ((Number) s.get("maximum")).doubleValue())
        throw new IllegalArgumentException(at + ": out of range");
    }
    if (v instanceof String
        && s.containsKey("minLength")
        && ((String) v).length() < ((Number) s.get("minLength")).intValue())
      throw new IllegalArgumentException(at + ": empty string");
    if (v instanceof Map) {
      Map<String, Object> a = map(v), p = map(s.get("properties"));
      for (Object r : list(s.get("required")))
        if (!a.containsKey(r)) throw new IllegalArgumentException(at + ": missing " + r);
      for (String k : a.keySet()) {
        if (!p.containsKey(k)) throw new IllegalArgumentException(at + ": unknown field " + k);
        validateValue(a.get(k), map(p.get(k)), at + "." + k);
      }
      if (s.containsKey("minProperties") && a.isEmpty())
        throw new IllegalArgumentException(at + ": empty object");
    }
    if (v instanceof List) {
      List<Object> a = list(v);
      if (a.size() < ((Number) s.get("minItems")).intValue()
          || a.size() > ((Number) s.get("maxItems")).intValue())
        throw new IllegalArgumentException(at + ": invalid length");
      for (Object x : a) validateValue(x, map(s.get("items")), at + "[]");
    }
  }

  public static Map<String, Object> textResult(String text) {
    return obj("content", new ArrayList<>(Arrays.asList(obj("type", "text", "text", text))));
  }

  public static Map<String, Object> error(Failure f) {
    Map<String, Object> r = textResult(f.code + ": " + f.getMessage());
    r.put("isError", true);
    r.put("_meta", obj("opencu/error", f.code));
    return r;
  }

  public static Map<String, Object> stopNotice() {
    return obj(
        "jsonrpc",
        "2.0",
        "method",
        "notifications/message",
        "params",
        obj(
            "level",
            "warning",
            "logger",
            "opencu",
            "data",
            obj(
                "event",
                "stop",
                "error",
                obj(
                    "code",
                    "USER_STOPPED",
                    "message",
                    "Three physical volume-down presses. Do not reconnect without explicit"
                        + " permission."))));
  }

  private final Backend backend;
  private final String version;
  private boolean initialized;

  public Protocol(Backend backend, String version) {
    this.backend = backend;
    this.version = version;
  }

  public Map<String, Object> handle(String line) {
    Object raw;
    try {
      raw = Json.read(line);
    } catch (Exception e) {
      return rpc(null, -32700, "Parse error");
    }
    if (!(raw instanceof Map)) return rpc(null, -32600, "Invalid Request");
    Map<String, Object> q = map(raw);
    Object id = q.get("id");
    if (!"2.0".equals(q.get("jsonrpc"))
        || !(q.get("method") instanceof String)
        || (q.containsKey("id") && !(id == null || id instanceof String || id instanceof Number)))
      return rpc(null, -32600, "Invalid Request");
    if (!q.containsKey("id")) return null; // MCP notifications never receive a response.
    String method = (String) q.get("method");
    Map<String, Object> p;
    try {
      p = q.containsKey("params") ? map(q.get("params")) : obj();
    } catch (Exception e) {
      return rpc(id, -32602, "Invalid params");
    }
    Object result;
    try {
      switch (method) {
        case "initialize":
          if (!(p.get("protocolVersion") instanceof String)
              || !(p.get("capabilities") instanceof Map)
              || !(p.get("clientInfo") instanceof Map))
            return rpc(
                id, -32602, "initialize requires protocolVersion, capabilities and clientInfo");
          initialized = true;
          String requested = (String) p.get("protocolVersion");
          String negotiated =
              Arrays.asList("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
                      .contains(requested)
                  ? requested
                  : "2025-11-25";
          result =
              obj(
                  "protocolVersion",
                  negotiated,
                  "capabilities",
                  obj("tools", obj(), "logging", obj()),
                  "serverInfo",
                  obj("name", "opencu", "version", version),
                  "instructions",
                  INSTRUCTIONS);
          break;
        case "ping":
          result = obj();
          break;
        case "tools/list":
          if (!initialized) return rpc(id, -32002, "Initialize first");
          int offset = 0;
          if (p.containsKey("cursor")) {
            if (!"8".equals(p.get("cursor"))) return rpc(id, -32602, "Invalid cursor");
            offset = 8;
          }
          List<Map<String, Object>> tools = new ArrayList<>(DEFINITIONS.values());
          int end = Math.min(offset + 8, tools.size());
          result = obj("tools", tools.subList(offset, end));
          if (end < tools.size()) map(result).put("nextCursor", Integer.toString(end));
          break;
        case "tools/call":
          if (!initialized) return rpc(id, -32002, "Initialize first");
          if (!(p.get("name") instanceof String)
              || (p.containsKey("arguments") && !(p.get("arguments") instanceof Map)))
            return rpc(id, -32602, "Expected tool name and arguments object");
          String name = (String) p.get("name");
          Map<String, Object> a = p.containsKey("arguments") ? map(p.get("arguments")) : obj();
          try {
            validate(name, a);
            result = backend.call(name, a);
          } catch (Failure e) {
            result = error(e);
          } catch (Exception e) {
            result =
                error(fail("RUNTIME_ERROR", e.getClass().getSimpleName() + ": " + e.getMessage()));
          }
          break;
        default:
          return rpc(id, -32601, "Method not found");
      }
      return obj("jsonrpc", "2.0", "id", id, "result", result);
    } catch (Exception e) {
      return rpc(id, -32603, "Internal error");
    }
  }

  static Map<String, Object> rpc(Object id, int code, String message) {
    return obj("jsonrpc", "2.0", "id", id, "error", obj("code", code, "message", message));
  }
}
