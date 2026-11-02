package android.os;

/** Host stand-in for the hidden ServiceManager: there are no binders on the host. */
public final class ServiceManager {
  public static IBinder getService(String name) {
    return null;
  }
}
