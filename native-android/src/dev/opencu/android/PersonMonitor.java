package dev.opencu.android;

import static dev.opencu.android.Core.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;

/** getevent reads kernel evdev, below InputManager injection; no suppression time windows. */
final class PersonMonitor implements AutoCloseable {
  final Person person = new Person(android.os.SystemClock.uptimeMillis());
  private final Process process;
  private volatile boolean alive, closed;
  private volatile String problem = "Input monitor is starting";
  final List<String> devices = new ArrayList<>();

  PersonMonitor(Consumer<Map<String, Object>> output, long initialActivity) throws Exception {
    String capabilities = AndroidEngine.command("/system/bin/getevent", "-lp");
    if (!capabilities.contains("KEY_VOLUMEDOWN") || !capabilities.contains("ABS_MT_POSITION"))
      throw fail(
          "PERSON_MONITOR_UNAVAILABLE", "Cannot verify hardware touch and volume-down devices");
    for (String line : capabilities.split("\n"))
      if (line.startsWith("add device ")) devices.add(line.substring(line.indexOf("/dev/input/")));
    if (devices.isEmpty()) throw fail("PERSON_MONITOR_UNAVAILABLE", "No readable input devices");
    process =
        new ProcessBuilder("/system/bin/getevent", "-lt")
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start();
    person.lastActivity = initialActivity;
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
  }

  void check(long token, boolean changingForeground) {
    person.check(token, android.os.SystemClock.uptimeMillis(), changingForeground);
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
  }
}
