package dev.opencu.android;

/** Command-line options accepted by the phone app_process entry point. */
final class Arguments {
  final String mode;
  final boolean elements;
  final Integer attachDisplay;

  Arguments(String mode, boolean elements, Integer attachDisplay) {
    this.mode = mode;
    this.elements = elements;
    this.attachDisplay = attachDisplay;
  }

  static Arguments parse(String[] args) {
    if (args.length == 0) return new Arguments("mcp", false, null);
    String mode = args[0];
    if (mode.equals("doctor")) {
      if (args.length != 1) throw new IllegalArgumentException("Usage: dev.opencu.android.Main doctor");
      return new Arguments(mode, false, null);
    }
    if (!mode.equals("mcp"))
      throw new IllegalArgumentException(
          "Usage: dev.opencu.android.Main mcp [--elements] [--attach-display ID]");
    boolean elements = false;
    Integer attach = null;
    for (int i = 1; i < args.length; i++) {
      switch (args[i]) {
        case "--elements":
          if (elements) throw new IllegalArgumentException("Usage: --elements may appear once");
          elements = true;
          break;
        case "--attach-display":
          if (attach != null || i + 1 >= args.length)
            throw new IllegalArgumentException("Usage: --attach-display requires a display ID");
          String value = args[++i];
          try {
            if (!value.matches("[0-9]+")) throw new NumberFormatException();
            long parsed = Long.parseLong(value);
            if (parsed > Integer.MAX_VALUE) throw new NumberFormatException();
            attach = (int) parsed;
          } catch (NumberFormatException e) {
            throw new IllegalArgumentException("Usage: --attach-display requires a numeric display ID");
          }
          break;
        default:
          throw new IllegalArgumentException(
              "Usage: dev.opencu.android.Main mcp [--elements] [--attach-display ID]");
      }
    }
    return new Arguments(mode, elements, attach);
  }
}
