package dev.opencu.android;

import static dev.opencu.android.Core.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.LongSupplier;

/** getevent reads kernel evdev, below InputManager injection; no suppression time windows. */
final class PersonMonitor implements AutoCloseable {
  final Person person = new Person(android.os.SystemClock.uptimeMillis());
  private final Process process;
  private volatile boolean alive, closed;
  private volatile String problem = "Input monitor is starting";
  final List<String> devices = new ArrayList<>();

  PersonMonitor(Consumer<Map<String, Object>> output, LongSupplier lastActivity) throws Exception {
    this(
        output,
        lastActivity,
        new String[] {"/system/bin/getevent", "-lp"},
        new String[] {"/system/bin/getevent", "-lt"});
  }

  /**
   * {@code probe} lists input devices; {@code stream} prints their events (getevent formats).
   * {@code lastActivity} is read only once the stream is live: a touch before that moment is in
   * the platform's last-activity time, and any touch after it is seen by the stream.
   */
  PersonMonitor(
      Consumer<Map<String, Object>> output, LongSupplier lastActivity, String[] probe, String[] stream)
      throws Exception {
    String capabilities = AndroidEngine.command(probe);
    if (!capabilities.contains("KEY_VOLUMEDOWN") || !capabilities.contains("ABS_MT_POSITION"))
      throw fail(
          "PERSON_MONITOR_UNAVAILABLE", "Cannot verify hardware touch and volume-down devices");
    for (String line : capabilities.split("\n"))
      if (line.startsWith("add device ")) devices.add(line.substring(line.indexOf("/dev/input/")));
    if (devices.isEmpty()) throw fail("PERSON_MONITOR_UNAVAILABLE", "No readable input devices");
    process =
        // getevent reports unreadable devices on stderr; the engine's own stderr must start with
        // its coded line, and readiness below decides whether monitoring works.
        new ProcessBuilder(stream)
            .redirectError(ProcessBuilder.Redirect.to(new File("/dev/null")))
            .start();
    Set<String> opened = Collections.synchronizedSet(new HashSet<>());
    Thread reader =
        new Thread(
            () -> {
              try (BufferedReader r =
                  new BufferedReader(
                      new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                  if (line.startsWith("add device ")) {
                    opened.add(line.substring(line.indexOf("/dev/input/")));
                    alive = opened.containsAll(devices);
                  }
                  if (line.startsWith("remove device ")) {
                    alive = false;
                    problem =
                        "Input device removed; observe device availability before a new connection";
                    break;
                  }
                  if (person.accept(line, android.os.SystemClock.uptimeMillis()))
                    output.accept(Protocol.stopNotice());
                }
              } catch (IOException e) {
                problem = "Input monitor stream failed";
              } finally {
                alive = false;
                if (!closed) problem = "Input monitor stopped";
              }
            },
            "opencu-physical-input");
    reader.setDaemon(true);
    reader.start();
    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
    while (!alive && process.isAlive() && System.nanoTime() < deadline) Thread.sleep(5);
    if (!alive) {
      close();
      throw fail("PERSON_MONITOR_UNAVAILABLE", problem);
    }
    person.seed(lastActivity.getAsLong());
  }

  void check(long token, boolean changingForeground, boolean desktop) {
    if (desktop) person.checkDesktop();
    else person.check(token, android.os.SystemClock.uptimeMillis(), changingForeground);
    if (!alive || !process.isAlive())
      throw fail("PERSON_MONITOR_UNAVAILABLE", problem + "; no input sent");
  }

  boolean ready() {
    return alive && process.isAlive();
  }

  public void close() {
    closed = true;
    alive = false;
    process.destroy();
    try {
      if (!process.waitFor(200, TimeUnit.MILLISECONDS)) process.destroyForcibly();
    } catch (InterruptedException e) {
      process.destroyForcibly();
      Thread.currentThread().interrupt();
    }
  }
}
