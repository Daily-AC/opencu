package android.os;

/** Host stand-in: there is no message loop on the host. */
public final class Looper {
  public static void prepareMainLooper() {}
}
