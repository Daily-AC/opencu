package android.util;

/** Host stand-in: standard Base64 without line breaks. */
public final class Base64 {
  public static final int NO_WRAP = 2;

  private Base64() {}

  public static String encodeToString(byte[] input, int flags) {
    return java.util.Base64.getEncoder().encodeToString(input);
  }
}
