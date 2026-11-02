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
   * What a scroll would change: the scrollable itself and its descendants (path, text,
   * description, bounds, selected and checked state), or its whole window when it exposes no
   * descendants. A wheel picker's new value therefore counts, wherever it shows. Without a target,
   * the whole screen.
   */
  public static String scrollContent(Screen s, Element scrollable) {
    if (scrollable == null) return s.fingerprint();
    StringBuilder subtree = new StringBuilder(), window = new StringBuilder();
    boolean descendants = false;
    for (Element e : s.elements.values()) {
      if (e.window != scrollable.window) continue;
      String line =
          e.path + "|" + e.text + "|" + e.desc + "|" + e.left + "," + e.top + "," + e.right + ","
              + e.bottom + (e.selected ? "|selected" : "") + (e.checked ? "|checked" : "")
              + (e.ranged ? "|" + e.current : "") + "\n";
      window.append(line);
      if (e.path.equals(scrollable.path)) subtree.append(line);
      else if (e.path.startsWith(scrollable.path + "/")) {
        subtree.append(line);
        descendants = true;
      }
    }
    return descendants ? subtree.toString() : window.toString();
  }

  /**
   * The element of {@code now} that continues {@code prev} (an element of {@code before}) from
   * one scroll page to the next: the same element, or else the only element in its display, window
   * and package with its class and resource id that still covers at least half of the smaller of
   * the two areas, or among several such the one at its tree path. Its path, bounds and text may
   * change (a collapsing toolbar resizes a list, a wheel shows a new value); a new activity ends it.
   * Null when no single element qualifies.
   */
  public static Element follow(Screen before, Element prev, Screen now) {
    if (prev == null || !before.activity.equals(now.activity)) return null;
    for (Element e : now.elements.values()) if (prev.same(e)) return e;
    Element only = null, atPath = null;
    int count = 0, paths = 0;
    for (Element e : now.elements.values()) {
      if (e.display != prev.display
          || e.window != prev.window
          || !e.pkg.equals(prev.pkg)
          || !e.clazz.equals(prev.clazz)
          || !e.id.equals(prev.id)
          || !overlaps(prev, e)) continue;
      count++;
      only = e;
      if (e.path.equals(prev.path)) {
        paths++;
        atPath = e;
      }
    }
    return count == 1 ? only : paths == 1 ? atPath : null;
  }

  /** Whether the two elements' bounds share at least half of the smaller one's area. */
  static boolean overlaps(Element a, Element b) {
    long w = Math.min(a.right, b.right) - Math.max(a.left, b.left),
        h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    if (w <= 0 || h <= 0) return false;
    long areaA = (long) (a.right - a.left) * (a.bottom - a.top),
        areaB = (long) (b.right - b.left) * (b.bottom - b.top);
    return 2 * w * h >= Math.min(areaA, areaB);
  }

  /** An element for a message: class, resource id, text unless a password, and bounds. */
  public static String describe(Element e) {
    StringBuilder b = new StringBuilder(label(e));
    if (!e.text.isEmpty() && !e.password) b.append(" text=").append(Json.write(e.text));
    return b.append(" at ").append(e.left).append(',').append(e.top).append(',').append(e.right)
        .append(',').append(e.bottom).toString();
  }

  /** An element's class and resource id, as its line shows them. */
  static String label(Element e) {
    String name = e.clazz.substring(e.clazz.lastIndexOf('.') + 1);
    return e.id.isEmpty() ? name : name + " id=" + e.id.substring(e.id.lastIndexOf('/') + 1);
  }

  /**
   * The value an element holds, or null when it holds none: a range's number, an editor's text, a
   * checkable's state, or the selected value a wheel picker shows as its text. Passwords have none.
   */
  public static String value(Element e) {
    if (e.password) return null;
    if (e.ranged) return Element.number(e.current);
    if (e.editable) return e.text;
    if (e.checkable) return e.checked ? "checked" : "not checked";
    if (!e.text.isEmpty()
        && (e.actions.containsKey("scroll_forward") || e.actions.containsKey("scroll_backward")))
      return e.text;
    return null;
  }

  /**
   * The values that changed from {@code before} to {@code after}, as "Class id=… old -> new",
   * other than {@code scope}'s own. A control is the same one when its window, tree path, class
   * and resource id match and so does the text around it (the other non-value text under its
   * parent), so a recycled list row that now shows another item is not taken for it.
   */
  public static List<String> valueChanges(Screen before, Screen after, Element scope) {
    Map<String, Element> was = controls(before, scope), now = controls(after, scope);
    List<String> changes = new ArrayList<>();
    for (Map.Entry<String, Element> entry : was.entrySet()) {
      Element a = entry.getValue(), b = now.get(entry.getKey());
      if (a == null || b == null) continue;
      String from = value(a), to = value(b);
      if (from.equals(to)) continue;
      // A wheel's value as its leading number: its text can carry a unit and spoken hints.
      boolean wheel = !b.ranged && !b.editable && !b.checkable;
      changes.add(label(b) + " " + (wheel ? wheelShort(from) : from) + " -> " + (wheel ? wheelShort(to) : to));
    }
    return changes;
  }

  /** Whether {@code o} is inside an element that holds a value, such as a row of a wheel. */
  private static boolean insideValue(Element o, Screen s) {
    for (Element v : s.elements.values())
      if (v.window == o.window && o.path.startsWith(v.path + "/") && value(v) != null) return true;
    return false;
  }

  /** The value-holding elements of {@code s} by identity; an identity found twice maps to null. */
  private static Map<String, Element> controls(Screen s, Element scope) {
    Map<String, Element> out = new LinkedHashMap<>();
    for (Element e : s.elements.values()) {
      if (value(e) == null) continue;
      if (scope != null && e.window == scope.window && e.path.equals(scope.path)) continue;
      String parent = e.path.substring(0, Math.max(0, e.path.lastIndexOf('/'))) + "/";
      StringBuilder around = new StringBuilder();
      for (Element o : s.elements.values())
        if (o != e
            && o.window == e.window
            && o.path.startsWith(parent)
            && value(o) == null
            && !insideValue(o, s))
          around.append(o.text).append('\u0001').append(o.desc).append('\u0002');
      String key =
          e.display + "|" + e.window + "|" + e.path + "|" + e.clazz + "|" + e.id + "|" + around;
      out.put(key, out.containsKey(key) ? null : e);
    }
    return out;
  }

  /** The selected value a wheel shows: its text, else its range value; null when it shows none. */
  public static String wheelValue(Element e) {
    if (e.password) return null;
    if (!e.text.isEmpty()) return e.text;
    return e.ranged ? Element.number(e.current) : null;
  }

  private static final Pattern DIGITS = Pattern.compile("[0-9]+");

  private static final Pattern LEADING = Pattern.compile("-?[0-9]{1,15}");

  /**
   * The number a wheel value names: its leading integer, as in "07" or a ColorOS picker's "23"
   * followed by a unit and spoken instructions; else its only run of digits; else null.
   */
  public static Long wheelNumber(String value) {
    if (value == null) return null;
    String v = value.trim();
    Matcher lead = LEADING.matcher(v);
    if (lead.lookingAt()) return Long.parseLong(lead.group());
    Matcher m = DIGITS.matcher(v);
    if (!m.find()) return null;
    String digits = m.group();
    if (m.find() || digits.length() > 15) return null;
    return Long.parseLong(digits);
  }

  /** A wheel value as a message shows it: its leading integer as written ("07"), else the value. */
  public static String wheelShort(String value) {
    if (value == null) return "";
    Matcher lead = LEADING.matcher(value.trim());
    return lead.lookingAt() ? lead.group() : value.trim();
  }

  /**
   * The selected value of the wheel {@code w} in {@code s}: the text of the one row inside it that
   * is marked selected, else what the wheel shows itself ({@link #wheelValue}).
   */
  public static String selectedValue(Screen s, Element w) {
    Element selected = null;
    int count = 0;
    for (Element c : s.elements.values())
      if (c.window == w.window && c.path.startsWith(w.path + "/") && c.selected && !c.text.isEmpty()) {
        selected = c;
        count++;
      }
    return count == 1 ? selected.text : wheelValue(w);
  }

  /** What tells a wheel's selected values apart: the number it names, else its whole value. */
  public static String wheelKey(Screen s, Element e) {
    String value = selectedValue(s, e);
    Long number = wheelNumber(value);
    return number != null ? "#" + number : String.valueOf(value);
  }

  /**
   * Whether a wheel showing {@code shown} shows {@code goal}: the same number when the goal names
   * one, else the same text or text that starts with it (a value followed by a unit or a hint).
   */
  public static boolean sameWheelValue(String shown, String goal) {
    if (shown == null) return false;
    String s = shown.trim(), g = goal.trim();
    if (s.equals(g)) return true;
    Long a = wheelNumber(s), b = wheelNumber(g);
    if (b != null && LEADING.matcher(g).matches()) return b.equals(a);
    return !g.isEmpty() && s.startsWith(g);
  }

  /** How many steps {@code from} is from {@code to}: round the wheel when its span is known. */
  public static long wheelDistance(long from, long to, long span) {
    long direct = Math.abs(to - from);
    return span > 0 ? Math.min(direct, Math.abs(span - direct)) : direct;
  }

  /** A copy of {@code e} with {@code text} as its text. */
  static Element copyWithText(Element e, String text) {
    Element c = new Element();
    c.index = e.index;
    c.window = e.window;
    c.display = e.display;
    c.left = e.left;
    c.top = e.top;
    c.right = e.right;
    c.bottom = e.bottom;
    c.path = e.path;
    c.clazz = e.clazz;
    c.text = text;
    c.desc = e.desc;
    c.id = e.id;
    c.pkg = e.pkg;
    c.editable = e.editable;
    return c;
  }

  /** Most rows a multi-page scroll lists as passed over, and most characters shown per row. */
  public static final int PASSED_ROWS = 200, ROW_CHARS = 200;

  /** One row of a scrolled list: the text inside one child of the scrolled element. */
  public static final class Row {
    final String key;
    final List<String> parts = new ArrayList<>();
    int left = Integer.MAX_VALUE, top = Integer.MAX_VALUE, right = Integer.MIN_VALUE, bottom = Integer.MIN_VALUE;
    /** The row's own size when the scrolled element's edge cuts it; 0 when it is whole. */
    int fullWidth, fullHeight;

    Row(String key) {
      this.key = key;
    }

    String text() {
      return String.join(" | ", parts);
    }

    void cover(Element e) {
      left = Math.min(left, e.left);
      top = Math.min(top, e.top);
      right = Math.max(right, e.right);
      bottom = Math.max(bottom, e.bottom);
    }

    boolean cut() {
      return fullHeight > 0;
    }
  }

  /**
   * The visible text of {@code s} as rows: the scope's own text, then one row per child of {@code
   * scope} joining its descendants' text, descriptions and checked state with " | ". Without a
   * scope, one row per element. Password fields are left out.
   */
  public static List<String> rows(Screen s, Element scope) {
    List<String> out = new ArrayList<>();
    for (Row row : rowList(s, scope)) out.add(row.text());
    return out;
  }

  /** {@link #rows} with each row's bounds and, when a parent's edge cuts it, its own size. */
  static List<Row> rowList(Screen s, Element scope) {
    Map<String, Row> rows = new LinkedHashMap<>();
    String prefix = scope == null ? "" : scope.path + "/";
    for (Element e : s.elements.values()) {
      String key;
      if (scope == null) key = Integer.toString(e.index);
      else if (e.window != scope.window) continue;
      else if (e.path.equals(scope.path)) key = e.path;
      else if (!e.path.startsWith(prefix)) continue;
      else {
        int end = e.path.indexOf('/', prefix.length());
        key = end < 0 ? e.path : e.path.substring(0, end);
      }
      Row row = rows.get(key);
      if (row == null) rows.put(key, row = new Row(key));
      row.cover(e);
      if (scope != null && e.path.equals(key) && !key.equals(scope.path) && e.clipped()) {
        row.fullWidth = e.fullWidth;
        row.fullHeight = e.fullHeight;
      }
      String part = rowPart(e);
      if (!part.isEmpty()) row.parts.add(part);
    }
    List<Row> out = new ArrayList<>();
    for (Row row : rows.values()) {
      int[] size = scope == null || row.key.equals(scope.path) ? null : s.clipped.get(row.key);
      if (size != null && row.fullHeight == 0) {
        row.fullWidth = size[0];
        row.fullHeight = size[1];
      }
      if (!row.parts.isEmpty()) out.add(row);
    }
    return out;
  }

  private static String rowPart(Element e) {
    if (e.password) return "";
    String part =
        e.text.isEmpty()
            ? e.desc
            : e.desc.isEmpty() || e.desc.equals(e.text) ? e.text : e.text + " (" + e.desc + ")";
    if (e.checkable) part += (part.isEmpty() ? "" : " ") + (e.checked ? "[checked]" : "[not checked]");
    return part.replaceAll("\\s+", " ").trim();
  }

  /**
   * The rows a multi-page scroll passes over, kept whole. A row that the scrolled element's edge
   * cuts is a fragment: an accessibility page moves exactly one viewport, so a row across the
   * boundary is cut on both pages, its two parts are joined into one row when they fit together
   * (same own size; their visible parts add up to it). A fragment of a row shown whole on the
   * neighbouring page is dropped, and the fragment the first page shows of the row before it.
   * The result lists rows top to bottom (left to right), whichever way the pages went.
   */
  public static final class Passed {
    private final boolean backward, vertical;
    /** Rows in the order the pages met them. */
    private final List<Met> met = new ArrayList<>();
    /** The row the last page cut at its leading edge, where the next page continues. */
    private Row pending;
    /** The whole rows of the last page. */
    private List<Row> previous = new ArrayList<>();
    private boolean first = true;

    /** A row met on a page, and whether it touched the list's edge there (and may be cut). */
    private static final class Met {
      final String text;
      final List<String> parts;
      final boolean edge;

      Met(String text, List<String> parts, boolean edge) {
        this.text = text;
        this.parts = parts;
        this.edge = edge;
      }
    }

    public Passed(String direction) {
      backward = direction.equals("u") || direction.equals("l");
      vertical = direction.equals("u") || direction.equals("d");
    }

    /** Takes the rows of a page that was then scrolled past. */
    public void page(Screen s, Element scope) {
      take(s, scope, true);
    }

    /**
     * The rows passed over, top to bottom (left to right), given the final page (the state shown
     * below the list) or null. Rows of the final page are left out, whichever way the pages went.
     * A row that touched the list's edge may be cut (ColorOS reports a cut row with its clipped
     * bounds only, and without the children outside the list): it is left out when every part of
     * it is in another listed or final row, the row it is part of, and kept otherwise, so a row
     * cut on every page it showed on is not lost.
     */
    public List<String> finish(Screen s, Element scope) {
      List<Row> last = new ArrayList<>();
      if (s != null) {
        take(s, scope, false);
        last = rowList(s, scope);
      } else if (pending != null) met.add(new Met(pending.text(), pending.parts, true));
      pending = null;
      Map<String, Met> unique = new LinkedHashMap<>();
      for (Met m : met) unique.putIfAbsent(m.text, m);
      Set<String> shown = new HashSet<>();
      List<List<String>> all = new ArrayList<>();
      for (Row r : last) {
        shown.add(r.text());
        all.add(r.parts);
      }
      for (Met m : unique.values()) all.add(m.parts);
      List<String> rows = new ArrayList<>();
      for (Met m : unique.values()) {
        if (shown.contains(m.text)) continue;
        boolean part = false;
        if (m.edge)
          for (List<String> other : all)
            if (other.size() > m.parts.size() && other.containsAll(m.parts)) part = true;
        if (!part) rows.add(m.text);
      }
      if (backward) Collections.reverse(rows);
      return rows;
    }

    public String order() {
      return vertical ? "top to bottom" : "left to right";
    }

    /** Whether {@code r} touches {@code scope}'s edge across the scrolling axis. */
    private boolean atEdge(Row r, Element scope) {
      if (scope == null) return false;
      return vertical
          ? r.top <= scope.top + 2 || r.bottom >= scope.bottom - 2
          : r.left <= scope.left + 2 || r.right >= scope.right - 2;
    }

    private void take(Screen s, Element scope, boolean record) {
      List<Row> rows = rowList(s, scope);
      if (backward) Collections.reverse(rows); // in the order the pages travel
      Row lead = null, trail = null;
      List<Row> whole = new ArrayList<>();
      for (Row r : rows) {
        boolean atStart = scope != null && r.cut() && (vertical ? r.top <= scope.top + 2 : r.left <= scope.left + 2),
            atEnd = scope != null && r.cut() && (vertical ? r.bottom >= scope.bottom - 2 : r.right >= scope.right - 2);
        boolean leading = backward ? atStart : atEnd, trailing = backward ? atEnd : atStart;
        if (leading && !trailing) lead = r;
        else if (trailing && !leading && trail == null) trail = r;
        else whole.add(r);
      }
      List<Met> here = new ArrayList<>();
      if (pending != null) {
        if (trail != null && joins(pending, trail)) {
          List<String> parts = join(pending, trail);
          here.add(new Met(String.join(" | ", parts), parts, false));
          trail = null;
        } else if (!within(pending, whole)) here.add(new Met(pending.text(), pending.parts, true));
      }
      if (trail != null && !first && !within(trail, previous))
        here.add(new Met(trail.text(), trail.parts, true));
      if (record) for (Row r : whole) here.add(new Met(r.text(), r.parts, atEdge(r, scope)));
      met.addAll(here);
      pending = lead;
      previous = whole;
      first = false;
    }

    /** Whether {@code a}, cut on one page, and {@code b}, cut on the next, are one row's two parts. */
    private boolean joins(Row a, Row b) {
      int full = vertical ? a.fullHeight : a.fullWidth;
      int shown = vertical ? (a.bottom - a.top) + (b.bottom - b.top) : (a.right - a.left) + (b.right - b.left);
      return full > 0
          && Math.abs(full - (vertical ? b.fullHeight : b.fullWidth)) <= 2
          && Math.abs(full - shown) <= 6;
    }

    /** The parts of one row's two pieces in reading order, without a part both show. */
    private List<String> join(Row earlier, Row later) {
      Row first = backward ? later : earlier, second = backward ? earlier : later;
      List<String> parts = new ArrayList<>(first.parts);
      for (String p : second.parts) if (!parts.contains(p)) parts.add(p);
      return parts;
    }

    /** Whether a whole row of {@code rows} shows every part of the fragment {@code r}. */
    private static boolean within(Row r, List<Row> rows) {
      for (Row w : rows) if (w.parts.containsAll(r.parts)) return true;
      return false;
    }
  }

  /** The labelled list of distinct rows a multi-page scroll passed over, or "" when there are none. */
  public static String passedOver(Collection<String> rows) {
    return passedOver(rows, "in order");
  }

  /** As {@link #passedOver(Collection)}, saying the rows' {@code order}. */
  public static String passedOver(Collection<String> rows, String order) {
    if (rows.isEmpty()) return "";
    StringBuilder b =
        new StringBuilder("Passed over while scrolling (")
            .append(rows.size())
            .append(" distinct rows, ")
            .append(order)
            .append("; the final page is the state below):\n");
    int shown = 0;
    for (String row : rows) {
      if (shown == PASSED_ROWS) break;
      b.append("- ")
          .append(row.length() > ROW_CHARS ? row.substring(0, ROW_CHARS - 1) + "…" : row)
          .append('\n');
      shown++;
    }
    if (rows.size() > shown) b.append("- … ").append(rows.size() - shown).append(" more rows not shown\n");
    return b.toString();
  }

  /** Time allowed for one scroll page: the action, then waiting for the list to move. */
  public static final long SCROLL_PAGE_MS = 1_000;

  /**
   * How long a page whose content has not changed is watched before it counts as not moved: an
   * accessibility scroll can take effect late (a wheel picker animates before its value changes),
   * a touch moves the content while it is still being sent.
   */
  public static final long SCROLL_QUIET_ACTION_MS = 900, SCROLL_QUIET_TOUCH_MS = 500;

  /** Once a page's content changed, how long it must stay unchanged to count as settled. */
  public static final long SCROLL_SETTLED_MS = 100;

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
    /** The node's own size (its bounds in its parent), or 0 when unknown; bounds are clipped. */
    public int fullWidth, fullHeight;

    /** Whether less of the node is visible than its own size: a parent's edge cuts it. */
    public boolean clipped() {
      return fullHeight > 0
          && (bottom - top + 2 < fullHeight || right - left + 2 < fullWidth);
    }

    /** A range element (slider, rating, progress) and its RangeInfo bounds and value. */
    public boolean ranged;
    public float min, max, current;
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
      if (ranged)
        b.append(" value=").append(number(current)).append(" range=").append(number(min)).append("..").append(number(max));
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

    /** A range value as written in element lines: whole numbers without decimals. */
    static String number(float value) {
      if (value == Math.rint(value) && Math.abs(value) < 1e9) return Long.toString((long) value);
      String text = String.format(Locale.ROOT, "%.3f", value);
      return text.replaceAll("0+$", "");
    }

    /** Same node and same place: display, window, tree path, identity text and bounds within 6 px. */
    public boolean same(Element e) {
      return sameNode(e) && near(e, 0, 0);
    }

    /** Same display, window, tree path, package, class, resource id, text and description. */
    public boolean sameNode(Element e) {
      if (e == null) return false;
      return display == e.display
          && window == e.window
          && path.equals(e.path)
          && pkg.equals(e.pkg)
          && clazz.equals(e.clazz)
          && id.equals(e.id)
          && sameText(e)
          && desc.equals(e.desc);
    }

    /** The same text; an editor's text may also change between its hint and empty. */
    boolean sameText(Element e) {
      return text.equals(e.text)
          || (editable && (text.equals(desc) || e.text.isEmpty() || e.text.equals(desc)));
    }

    /** The identity components in which {@code e} differs from this element, by name. */
    List<String> differences(Element e) {
      List<String> changed = new ArrayList<>();
      if (display != e.display) changed.add("display");
      if (window != e.window) changed.add("window");
      if (!pkg.equals(e.pkg)) changed.add("package");
      if (!clazz.equals(e.clazz)) changed.add("class");
      if (!id.equals(e.id)) changed.add("id");
      if (!sameText(e)) changed.add("text");
      if (!desc.equals(e.desc)) changed.add("description");
      if (!path.equals(e.path)) changed.add("path");
      if (!near(e, 0, 0)) changed.add("bounds");
      return changed;
    }

    /** Structure and geometry only, never text: tree path, window and bounds. */
    String where() {
      return path + " window " + window + " bounds " + left + "," + top + "," + right + "," + bottom;
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

  /**
   * Why {@code old} (from {@code before}) names no live element in {@code now}: the components in
   * which its closest counterpart differs, by name, with tree paths and bounds but never node text.
   * The counterpart is the element at the same path or with the same class and resource id that
   * shares the most components with it.
   */
  public static String staleReason(Screen before, Element old, Screen now) {
    List<String> changed = new ArrayList<>();
    if (!before.activity.equals(now.activity)) changed.add("activity");
    Element closest = null;
    int best = -1;
    for (Element e : now.elements.values()) {
      if (!e.path.equals(old.path) && !(e.clazz.equals(old.clazz) && e.id.equals(old.id))) continue;
      int score = 9 - old.differences(e).size() + (e.path.equals(old.path) ? 1 : 0);
      if (score > best) {
        best = score;
        closest = e;
      }
    }
    if (closest == null)
      return "Observed element is gone"
          + (changed.isEmpty() ? "" : " (changed: activity)")
          + ": nothing remains at its path or with its class and id; nothing sent. old="
          + old.where();
    changed.addAll(old.differences(closest));
    return "Observed element changed: "
        + (changed.isEmpty() ? "it is no longer available" : String.join(", ", changed))
        + "; nothing sent. old="
        + old.where()
        + " current="
        + closest.where();
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
    /** Visible nodes cut by a parent's edge, also those without an element: path to own size. */
    public final Map<String, int[]> clipped = new HashMap<>();
    /** Drawing order among its siblings, by tree path, for nodes that report one. */
    public final Map<String, Integer> order = new HashMap<>();

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
