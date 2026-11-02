package android.os;

import java.util.HashMap;
import java.util.Map;

/** Host stand-in holding accessibility action arguments. */
public final class Bundle {
  private final Map<String, CharSequence> values = new HashMap<>();

  public void putCharSequence(String key, CharSequence value) {
    values.put(key, value);
  }

  public CharSequence getCharSequence(String key) {
    return values.get(key);
  }
}
