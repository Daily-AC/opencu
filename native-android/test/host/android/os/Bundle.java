package android.os;

import java.util.HashMap;
import java.util.Map;

/** Host stand-in holding accessibility action arguments. */
public final class Bundle {
  private final Map<String, Object> values = new HashMap<>();

  public void putCharSequence(String key, CharSequence value) {
    values.put(key, value);
  }

  public CharSequence getCharSequence(String key) {
    return (CharSequence) values.get(key);
  }

  public void putInt(String key, int value) {
    values.put(key, value);
  }

  public int getInt(String key) {
    return values.containsKey(key) ? (Integer) values.get(key) : 0;
  }
}
