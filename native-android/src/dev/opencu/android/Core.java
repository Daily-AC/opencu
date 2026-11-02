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

  /** Notice after a scroll, decided by whether each page's content moved. */
  public static String scrollNotice(int moved, int requested) {
    if (moved == 0) return "Nothing moved; the list is at its end or does not scroll this way";
    if (moved < requested)
      return "Scrolled " + moved + " of " + requested + " pages; reached the end";
    return "Scrolled " + moved + " of " + requested + " pages";
  }

  /**
   * What a scroll would change: the scrollable's descendants (path, text, description, bounds), or
   * its whole window when it exposes none. Without a target, the whole screen.
   */
  public static String scrollContent(Screen s, Element scrollable) {
    if (scrollable == null) return s.fingerprint();
    StringBuilder subtree = new StringBuilder(), window = new StringBuilder();
    for (Element e : s.elements.values()) {
      if (e.window != scrollable.window) continue;
      String line =
          e.path + "|" + e.text + "|" + e.desc + "|" + e.left + "," + e.top + "," + e.right + "," + e.bottom + "\n";
      window.append(line);
      if (e.path.startsWith(scrollable.path + "/")) subtree.append(line);
    }
    return subtree.length() > 0 ? subtree.toString() : window.toString();
  }

  /** Time allowed for one scroll page: the action, then waiting for the list to move. */
  public static final long SCROLL_PAGE_MS = 1_000;

  /**
   * The longest a run_actions step can take: its holds, waits, scroll pages and until timeout,
   * plus two seconds for reading and settling.
   */
  public static long stepMaxMs(Map<String, Object> a) {
    String method = (String) a.get("method");
    long ms = 2_000;
    if (method.equals("wait")) ms += ((Number) a.get("ms")).longValue();
    if (method.equals("click")) {
      int count = ((Number) a.getOrDefault("click_count", 1)).intValue();
      double seconds = ((Number) a.getOrDefault("duration", 0)).doubleValue();
      ms += count * (seconds > 0 ? Math.max(600, (long) (seconds * 1000)) : 45) + 70L * (count - 1) + 1_500;
    }
    if (method.equals("press_key")) ms += (long) (((Number) a.getOrDefault("duration", .05)).doubleValue() * 1000);
    if (method.equals("drag")) ms += 450;
    if (method.equals("scroll"))
      ms += (long) Math.ceil(((Number) a.getOrDefault("pages", 1)).doubleValue()) * SCROLL_PAGE_MS;
    if (a.containsKey("until")) {
      Map<?, ?> until = (Map<?, ?>) a.get("until");
      ms += until.containsKey("timeoutMs") ? ((Number) until.get("timeoutMs")).longValue() : 8_000;
    }
    return ms;
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
    public int index, window, display, left, top, right, bottom;
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
      if (!id.isEmpty()) {
        int slash = id.lastIndexOf('/');
        b.append(" id=").append(slash < 0 ? id : id.substring(slash + 1));
      }
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

    /** Same node and same place: display, window, tree path, identity text and bounds within 6 px. */
    public boolean same(Element e) {
      return sameNode(e) && near(e, 0, 0);
    }

    /** Same display, window, tree path, package, class, resource id, text and description. */
    public boolean sameNode(Element e) {
      if (e == null) return false;
      boolean textCompatible = text.equals(e.text)
          || (editable && (text.equals(desc) || e.text.isEmpty() || e.text.equals(desc)));
      return display == e.display
          && window == e.window
          && path.equals(e.path)
          && pkg.equals(e.pkg)
          && clazz.equals(e.clazz)
          && id.equals(e.id)
          && textCompatible
          && desc.equals(e.desc);
    }

    /** Bounds within 6 px of this element's bounds moved by (dx, dy). */
    boolean near(Element e, int dx, int dy) {
      return Math.abs(left + dx - e.left) <= 6
          && Math.abs(top + dy - e.top) <= 6
          && Math.abs(right + dx - e.right) <= 6
          && Math.abs(bottom + dy - e.bottom) <= 6;
    }
  }

  /**
   * The live element in {@code now} that {@code old} from {@code before} names, or null. A new
   * activity invalidates every index. On an owned virtual display a window can move as a whole
   * while its decoration insets settle; that shift (at most 400 px) is accepted only when every
   * other element of the same window that is still present moved by the same amount.
   */
  public static Element live(Screen before, Element old, Screen now) {
    if (old == null || !before.activity.equals(now.activity)) return null;
    for (Element e : now.elements.values()) if (old.same(e)) return e;
    if (old.display == 0) return null;
    for (Element e : now.elements.values()) {
      if (!old.sameNode(e)) continue;
      int dx = e.left - old.left, dy = e.top - old.top;
      if (Math.abs(dx) > 400 || Math.abs(dy) > 400 || !old.near(e, dx, dy)) continue;
      if (windowShifted(before, now, old.window, dx, dy)) return e;
    }
    return null;
  }

  private static boolean windowShifted(Screen before, Screen now, int window, int dx, int dy) {
    for (Element b : before.elements.values()) {
      if (b.window != window) continue;
      for (Element c : now.elements.values())
        if (b.sameNode(c)) {
          if (!b.near(c, dx, dy)) return false;
          break;
        }
    }
    return true;
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

    public String waitContent() {
      StringBuilder b = new StringBuilder();
      for (Element e : elements.values())
        if (!e.password && !(e.focused && e.editable))
          b.append(e.text).append('\n').append(e.desc).append('\n');
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
    String text = s.waitContent();
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

    /**
     * Seeds the last physical activity from the platform once monitoring is live. It replaces the
     * conservative start value, but never hides a touch the monitor has already seen.
     */
    public synchronized void seed(long platformActivity) {
      lastActivity = sequence == 0 ? platformActivity : Math.max(lastActivity, platformActivity);
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
