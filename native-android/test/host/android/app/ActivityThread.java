package android.app;

import android.content.Context;

/** Host stand-in for the hidden ActivityThread: hands out the system context a check supplies. */
public final class ActivityThread {
  public static volatile Context systemContext;

  public static ActivityThread systemMain() {
    return new ActivityThread();
  }

  public Context getSystemContext() {
    return systemContext;
  }
}
