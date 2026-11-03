package android.os;

/** Host stand-in: the engine runs as the shell user. */
public final class Process {
  private Process() {}

  public static int myUid() {
    return 2000;
  }

  public static int myPid() {
    return (int) ProcessHandle.current().pid();
  }
}
