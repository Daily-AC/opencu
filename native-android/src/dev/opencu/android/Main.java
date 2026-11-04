package dev.opencu.android;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class Main {
  private static final PrintWriter output =
      new PrintWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);

  private static synchronized void emit(Map<String, Object> value) {
    if (value != null) output.println(Json.write(value));
  }

  private static final java.util.regex.Pattern CODE =
      java.util.regex.Pattern.compile("[A-Z][A-Z0-9_]{2,40}");

  /**
   * The single stderr line for a fatal error: {@code CODE: detail}, where detail is one line of at
   * most 300 characters naming the exception. Hosts forward only this form. Startup and doctor
   * failures never involve screen or clipboard content.
   */
  static String diagnostic(String code, Throwable error) {
    Throwable cause = error;
    while ((cause instanceof java.lang.reflect.InvocationTargetException
            || cause instanceof ExecutionException)
        && cause.getCause() != null) cause = cause.getCause();
    String detail = cause.getClass().getName() + ": " + cause.getMessage();
    if (cause instanceof Core.Failure && CODE.matcher(((Core.Failure) cause).code).matches()) {
      code = ((Core.Failure) cause).code;
      detail = String.valueOf(cause.getMessage());
    } else if (cause instanceof IllegalArgumentException && String.valueOf(cause.getMessage()).startsWith("Usage:")) {
      code = "INVALID_ARGUMENT";
      detail = cause.getMessage();
    }
    detail = detail.replaceAll("[\\p{Cntrl}\\s\\x{85}\\x{2028}\\x{2029}]+", " ").trim();
    if (detail.length() > 300) detail = detail.substring(0, 297) + "...";
    return code + ": " + detail;
  }

  /** Parses the small app_process command line before any Android service is touched. */
  static Arguments parseArguments(String[] args) {
    return Arguments.parse(args);
  }

  public static void main(String[] args) {
    AndroidEngine engine = null;
    String stage = "ENGINE_START_FAILED";
    try {
      Arguments parsed = parseArguments(args);
      String mode = parsed.mode;
      engine = new AndroidEngine(Main::emit, parsed.elements, parsed.attachDisplay);
      final AndroidEngine active = engine;
      Runtime.getRuntime().addShutdownHook(new Thread(active::close));
      if (mode.equals("doctor")) {
        stage = "DOCTOR_FAILED";
        emit(engine.doctor());
        engine.close();
        System.exit(0);
      }
      stage = "ENGINE_FAILED";
      engine.startCompanion();
      Protocol protocol = new Protocol(engine, BuildInfo.VERSION);
      // One serialized worker runs every call and the engine's idle timer.
      ScheduledThreadPoolExecutor worker =
          new ScheduledThreadPoolExecutor(
              1,
              r -> {
                Thread t = new Thread(r, "opencu-mcp");
                t.setDaemon(true);
                return t;
              });
      engine.runOn(worker);
      AtomicInteger queued = new AtomicInteger();
      // The reader remains live while a call waits: EOF cancels even a long in-flight batch.
      Reader reader = new InputStreamReader(System.in, StandardCharsets.UTF_8);
      Framing.read(
          reader,
          request -> {
            if (queued.incrementAndGet() > 32)
              throw new IllegalStateException("More than 32 MCP requests are queued");
            worker.execute(
                () -> {
                  try {
                    emit(protocol.handle(request));
                  } finally {
                    queued.decrementAndGet();
                  }
                });
          });
      engine.close();
      worker.shutdownNow();
      System.exit(0);
    } catch (Throwable error) {
      String line = diagnostic(stage, error);
      System.err.println(line);
      if (args.length == 1 && args[0].equals("doctor"))
        emit(
            Json.obj(
                "version",
                BuildInfo.VERSION,
                "sdk",
                android.os.Build.VERSION.SDK_INT,
                "uid",
                android.os.Process.myUid(),
                "uiAutomationConnected",
                false,
                "error",
                line));
      if (engine != null) engine.close();
      System.exit(1);
    }
  }
}
