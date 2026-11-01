package dev.opencu.android;

import java.util.*;
import java.util.regex.*;

public final class Core {
  public static long lastUserActivityTime(String powerDump, long fallback) {
    Matcher matcher =
        Pattern.compile("lastUserActivityTime=(\\d+)").matcher(powerDump == null ? "" : powerDump);
    return matcher.find() ? Long.parseLong(matcher.group(1)) : fallback;
  }

  public static final class Failure extends RuntimeException {
    public final String code;

    public Failure(String code, String message) {
      super(message);
      this.code = code;
    }
  }

  public static Failure fail(String code, String message) {
    return new Failure(code, message);
  }

  public static String scrollNotice(int moved, int requested) {
    if (moved == 0) return "Nothing scrolled; already at the end";
    if (moved < requested)
      return "Scrolled " + moved + " of " + requested + " pages; reached the end";
    return "Scrolled " + moved + " of " + requested + " pages";
  }

  public static String screenshotNotice(int imageWidth, int imageHeight, int displayWidth, int displayHeight) {
    return "Screenshot: "
        + imageWidth
        + "x"
        + imageHeight
        + " JPEG of the "
        + displayWidth
        + "x"
        + displayHeight
        + " display; coordinates in later calls use this image";
  }

  public static boolean textInputMatches(String expected, String actual) {
    return expected != null && expected.equals(actual);
  }

  public static boolean textInputSatisfied(String expected, String actual, boolean appReacted) {
    return textInputMatches(expected, actual) || appReacted;
  }

  public static final class Element {
    public int index, window, left, top, right, bottom;
    public String path = "", clazz = "", text = "", desc = "", id = "", pkg = "";
    public boolean visible = true,
        clickable,
        longClickable,
        editable,
        scrollable,
        checkable,
        checked,
        selected,
        focused,
        focusable,
        enabled = true,
        password;
    public final Map<String, Integer> actions = new LinkedHashMap<>();

    public boolean useful() {
      return visible
          && right > left
          && bottom > top
          && (!text.isEmpty()
              || !desc.isEmpty()
              || clickable
              || longClickable
              || editable
              || scrollable
              || checkable
              || !actions.isEmpty()
              || (focused && (editable || clickable)));
    }

    public String line() {
      StringBuilder b =
          new StringBuilder("[")
              .append(index)
              .append("] ")
              .append(clazz.substring(clazz.lastIndexOf('.') + 1));
      if (!text.isEmpty()) b.append(" text=").append(Json.write(password ? "<password>" : text));
      if (!desc.isEmpty()) b.append(" desc=").append(Json.write(desc));
      if (!id.isEmpty()) b.append(" id=").append(id.replaceFirst("^.*:id/", ""));
      if (clickable) b.append(" clickable");
      if (longClickable) b.append(" long-clickable");
      if (editable) b.append(" editable");
      if (scrollable) b.append(" scrollable");
      if (checkable) b.append(" checkable");
      if (checked) b.append(" checked");
      if (selected) b.append(" selected");
      if (focused) b.append(" focused");
      if (!enabled) b.append(" enabled=false");
      if (password) b.append(" password");
      b.append(" bounds=")
          .append(left)
          .append(',')
          .append(top)
          .append(',')
          .append(right)
          .append(',')
          .append(bottom);
      if (!actions.isEmpty()) b.append(" actions=").append(Json.write(actions.keySet()));
      return b.toString();
    }

    public boolean same(Element e) {
      if (e == null) return false;
      boolean textCompatible = text.equals(e.text)
          || (editable && (text.equals(desc) || e.text.isEmpty() || e.text.equals(desc)));
      return path.equals(e.path)
          && pkg.equals(e.pkg)
          && clazz.equals(e.clazz)
          && id.equals(e.id)
          && textCompatible
          && desc.equals(e.desc)
          && Math.abs(left - e.left) <= 400
          && Math.abs(top - e.top) <= 400
          && Math.abs(right - e.right) <= 400
          && Math.abs(bottom - e.bottom) <= 400;
    }
  }

  public static final class Window {
    public int id, type, layer, left, top, right, bottom;
    public String pkg = "", title = "";
    public boolean focused, active;
    public final List<Element> elements = new ArrayList<>();
  }

  public static final class Screen {
    public String target = "", foreground = "", activity = "";
    public int displayId;
    public long id;
    public int width, height, rotation;
    public boolean keyboard, truncated;
    public final List<Window> windows = new ArrayList<>();
    public final Map<Integer, Element> elements = new LinkedHashMap<>();

    public String lines() {
      StringBuilder b = new StringBuilder();
      for (Element e : elements.values()) b.append(e.line()).append('\n');
      return b.toString();
    }

    public String content() {
      StringBuilder b = new StringBuilder();
      for (Element e : elements.values())
        if (!e.password) b.append(e.text).append('\n').append(e.desc).append('\n');
      return b.toString();
    }

    public String text() {
      StringBuilder b =
          new StringBuilder("Foreground: ")
              .append(foreground)
              .append(" activity=")
              .append(activity)
              .append(" display=")
              .append(displayId)
              .append(" size=")
              .append(width)
              .append('x')
              .append(height)
              .append(" keyboard=")
              .append(keyboard ? "shown" : "hidden")
              .append(" state=")
              .append(id)
              .append(truncated ? " tree=truncated" : "")
              .append('\n');
      for (Window w : windows) {
        b.append("Window ")
            .append(w.id)
            .append(" package=")
            .append(w.pkg)
            .append(" type=")
            .append(w.type)
            .append(" layer=")
            .append(w.layer)
            .append(w.focused ? " focused" : "")
            .append(" title=")
            .append(Json.write(w.title))
            .append('\n');
        for (Element e : w.elements) b.append(e.line()).append('\n');
      }
      return b.toString();
    }

    public String fingerprint() {
      return foreground + "\n" + activity + "\n" + lines();
    }
  }

  /**
   * A stable condition means unchanged observable state for 400 ms. All predicates are conjunctive.
   */
  public static boolean until(Map<String, Object> u, Screen s, long stableMs) {
    String text = s.content();
    return (!u.containsKey("text") || text.contains((String) u.get("text")))
        && (!u.containsKey("gone") || !text.contains((String) u.get("gone")))
        && (!u.containsKey("app") || s.foreground.equals(u.get("app")))
        && (!Boolean.TRUE.equals(u.get("stable")) || stableMs >= 400);
  }

  public static String stopReason(Screen before, Screen now, String expectedApp) {
    Set<Integer> ids = new HashSet<>();
    int appLayer = Integer.MIN_VALUE;
    for (Window w : before.windows) {
      ids.add(w.id);
      if (w.pkg.equals(before.foreground) && w.type == 1) appLayer = Math.max(appLayer, w.layer);
    }
    for (Window w : now.windows) {
      if (ids.contains(w.id) || w.type == 2)
        continue; // Opening the ordinary IME is expected after focusing a field.
      if (w.type == 3 && (w.focused || w.active || w.layer > appLayer)) return "system_dialog";
      boolean fullScreen = w.right > w.left && w.bottom > w.top
          && w.right - w.left >= now.width * 0.8 && w.bottom - w.top >= now.height * 0.8;
      if (w.type == 1 && !fullScreen
          && w.pkg.equals(before.foreground)
          && now.foreground.equals(before.foreground)
          && now.activity.equals(before.activity)) return "popup";
      if (!w.pkg.equals(now.foreground) && (w.focused || w.active || w.layer > appLayer))
        return "popup";
    }
    if (!now.foreground.equals(before.foreground) && !now.foreground.equals(expectedApp))
      return "app_switched";
    return null;
  }

  public static final class Await {
    private final Screen before;
    private final Map<String, Object> condition;
    private final String expectedApp;
    private final long start, timeout;
    private long stableSince;
    private String fingerprint = "";

    public Await(Screen before, Map<String, Object> condition, String expectedApp, long now) {
      this.before = before;
      this.condition = condition;
      this.expectedApp = expectedApp;
      start = stableSince = now;
      timeout = ((Number) condition.getOrDefault("timeoutMs", 8000)).longValue();
    }

    public long elapsed(long now) {
      return Math.max(0, now - start);
    }

    public String poll(Screen state, long now) {
      String stop = stopReason(before, state, expectedApp);
      if (stop != null) return stop;
      String next = state.fingerprint();
      if (!next.equals(fingerprint)) {
        fingerprint = next;
        stableSince = now;
      }
      if (condition.isEmpty() && elapsed(now) < 50) return "continue";
      if (condition.isEmpty() || until(condition, state, now - stableSince)) return "complete";
      return elapsed(now) >= timeout ? "timeout" : "continue";
    }
  }

  public static final class Person {
    private static final Pattern EVENT =
        Pattern.compile(
            "\\[\\s*([0-9]+\\.[0-9]+)\\]\\s+(/dev/input/event[0-9]+):\\s+(EV_[A-Z]+)\\s+(\\S+)\\s+(\\S+)");
    public long lastActivity, sequence;
    public boolean stopped;
    private final Deque<Long> down = new ArrayDeque<>();
    private final Set<String> held = new HashSet<>();
    private final Map<String, String> slots = new HashMap<>();

    public Person(long now) {
      lastActivity = now;
    }

    public synchronized boolean accept(String line, long now) {
      Matcher m = EVENT.matcher(line);
      if (!m.find()) return false;
      String type = m.group(3),
          code = m.group(4),
          value = m.group(5),
          key = m.group(2) + ":" + code;
      if (!type.equals("EV_KEY") && !type.equals("EV_ABS") && !type.equals("EV_REL")) return false;
      lastActivity = now;
      sequence++;
      if (type.equals("EV_ABS")) {
        if (code.equals("ABS_MT_SLOT")) slots.put(m.group(2), value);
        if (code.equals("ABS_MT_TRACKING_ID")) {
          String contact = m.group(2) + ":contact:" + slots.getOrDefault(m.group(2), "00000000");
          if (value.equals("ffffffff")) held.remove(contact);
          else held.add(contact);
        }
      }
      if (type.equals("EV_KEY")) {
        if (value.equals("UP") || value.equals("00000000")) held.remove(key);
        else if (value.equals("DOWN") || value.equals("00000001")) {
          boolean fresh = held.add(key);
          if (code.equals("KEY_VOLUMEDOWN") && fresh) {
            long timestamp = (long) (Double.parseDouble(m.group(1)) * 1000);
            while (!down.isEmpty() && timestamp - down.peekFirst() > 1500) down.removeFirst();
            down.addLast(timestamp);
            if (down.size() >= 3 && !stopped) {
              stopped = true;
              return true;
            }
          }
        }
      }
      return false;
    }

    public synchronized long token() {
      return sequence;
    }

    public synchronized void check(long token, long now, boolean changingForeground) {
      if (stopped)
        throw fail(
            "USER_STOPPED",
            "The person stopped this connection. Do not reconnect or retry without explicit"
                + " permission.");
      if (sequence != token
          || !held.isEmpty()
          || (changingForeground && now - lastActivity < 10000))
        throw fail(
            "PERSON_ACTIVE",
            "Physical input detected. Stop and ask the person before continuing; do not retry.");
    }

    public synchronized void checkDesktop() {
      if (stopped)
        throw fail(
            "USER_STOPPED",
            "The person stopped this connection. Do not reconnect or retry without explicit"
                + " permission.");
    }
  }
}
