package android.os;

/** Host stand-in: a monotonic clock and an uninterruptible sleep, as on Android. */
public final class SystemClock {
  private static final long ORIGIN = System.nanoTime() - 1_000_000_000_000L;

  private SystemClock() {}

  public static long uptimeMillis() {
    return (System.nanoTime() - ORIGIN) / 1_000_000L;
  }

  public static long elapsedRealtime() {
    return uptimeMillis();
  }

  public static void sleep(long ms) {
    long end = uptimeMillis() + ms;
    boolean interrupted = false;
    while (uptimeMillis() < end) {
      try {
        Thread.sleep(Math.max(1, end - uptimeMillis()));
      } catch (InterruptedException e) {
        interrupted = true;
      }
    }
    if (interrupted) Thread.currentThread().interrupt();
  }
}
