package dev.opencu.android;

import java.util.*;

/** Small strict JSON codec shared by the phone and host tests; no runtime dependencies. */
public final class Json {
  public static Map<String, Object> obj(Object... pairs) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i < pairs.length; i += 2) out.put((String) pairs[i], pairs[i + 1]);
    return out;
  }

  @SuppressWarnings("unchecked")
  public static Map<String, Object> map(Object value) {
    if (!(value instanceof Map)) throw new IllegalArgumentException("Expected object");
    return (Map<String, Object>) value;
  }

  @SuppressWarnings("unchecked")
  public static List<Object> list(Object value) {
    if (!(value instanceof List)) throw new IllegalArgumentException("Expected array");
    return (List<Object>) value;
  }

  public static String str(Object value) {
    return value == null ? "" : value.toString();
  }

  public static String write(Object value) {
    if (value == null) return "null";
    if (value instanceof String) {
      StringBuilder b = new StringBuilder("\"");
      for (char c : ((String) value).toCharArray()) {
        switch (c) {
          case '"':
            b.append("\\\"");
            break;
          case '\\':
            b.append("\\\\");
            break;
          case '\n':
            b.append("\\n");
            break;
          case '\r':
            b.append("\\r");
            break;
          case '\t':
            b.append("\\t");
            break;
          default:
            if (c < 32 || Character.isSurrogate(c)) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
      }
      return b.append('"').toString();
    }
    if (value instanceof Boolean || value instanceof Number) {
      if (value instanceof Number && !Double.isFinite(((Number) value).doubleValue()))
        throw new IllegalArgumentException("Nonfinite JSON number");
      return value.toString();
    }
    StringJoiner j =
        new StringJoiner(",", value instanceof Map ? "{" : "[", value instanceof Map ? "}" : "]");
    if (value instanceof Map)
      ((Map<?, ?>) value).forEach((k, v) -> j.add(write(k.toString()) + ":" + write(v)));
    else if (value instanceof Iterable) for (Object v : (Iterable<?>) value) j.add(write(v));
    else throw new IllegalArgumentException("Not JSON: " + value.getClass());
    return j.toString();
  }

  public static Object read(String text) {
    Parser p = new Parser(text);
    Object v = p.value(0);
    p.ws();
    if (p.i != text.length()) throw p.bad();
    return v;
  }

  private static final class Parser {
    final String s;
    int i;

    Parser(String s) {
      this.s = s;
    }

    IllegalArgumentException bad() {
      return new IllegalArgumentException("Invalid JSON at " + i);
    }

    void ws() {
      while (i < s.length() && " \t\r\n".indexOf(s.charAt(i)) >= 0) i++;
    }

    boolean eat(char c) {
      ws();
      if (i < s.length() && s.charAt(i) == c) {
        i++;
        return true;
      }
      return false;
    }

    Object value(int depth) {
      if (depth > 64) throw bad();
      ws();
      if (i == s.length()) throw bad();
      char c = s.charAt(i);
      if (c == '"') return string();
      if (eat('{')) {
        Map<String, Object> m = obj();
        if (eat('}')) return m;
        do {
          ws();
          String k = string();
          if (!eat(':') || m.containsKey(k)) throw bad();
          m.put(k, value(depth + 1));
        } while (eat(','));
        if (!eat('}')) throw bad();
        return m;
      }
      if (eat('[')) {
        List<Object> a = new ArrayList<>();
        if (eat(']')) return a;
        do {
          a.add(value(depth + 1));
        } while (eat(','));
        if (!eat(']')) throw bad();
        return a;
      }
      for (String literal : new String[] {"true", "false", "null"})
        if (s.startsWith(literal, i)) {
          i += literal.length();
          return literal.equals("null") ? null : literal.equals("true");
        }
      int start = i;
      if (c == '-') i++;
      if (i == s.length()) throw bad();
      if (s.charAt(i) == '0') i++;
      else {
        if (s.charAt(i) < '1' || s.charAt(i) > '9') throw bad();
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
      }
      if (i < s.length() && s.charAt(i) == '.') {
        i++;
        int a = i;
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        if (a == i) throw bad();
      }
      if (i < s.length() && "eE".indexOf(s.charAt(i)) >= 0) {
        i++;
        if (i < s.length() && "+-".indexOf(s.charAt(i)) >= 0) i++;
        int a = i;
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        if (a == i) throw bad();
      }
      String n = s.substring(start, i);
      try {
        if (!n.contains(".") && !n.contains("e") && !n.contains("E")) return Long.parseLong(n);
        double d = Double.parseDouble(n);
        if (!Double.isFinite(d)) throw bad();
        return d;
      } catch (NumberFormatException e) {
        throw bad();
      }
    }

    String string() {
      if (i == s.length() || s.charAt(i++) != '"') throw bad();
      StringBuilder b = new StringBuilder();
      while (i < s.length()) {
        char c = s.charAt(i++);
        if (c == '"') return b.toString();
        if (c < 32) throw bad();
        if (c == '\\') {
          if (i == s.length()) throw bad();
          c = s.charAt(i++);
          switch (c) {
            case '"':
            case '\\':
            case '/':
              break;
            case 'n':
              c = '\n';
              break;
            case 'r':
              c = '\r';
              break;
            case 't':
              c = '\t';
              break;
            case 'b':
              c = '\b';
              break;
            case 'f':
              c = '\f';
              break;
            case 'u':
              if (i + 4 > s.length()) throw bad();
              try {
                c = (char) Integer.parseInt(s.substring(i, i + 4), 16);
              } catch (NumberFormatException e) {
                throw bad();
              }
              i += 4;
              break;
            default:
              throw bad();
          }
        }
        b.append(c);
      }
      throw bad();
    }
  }
}
