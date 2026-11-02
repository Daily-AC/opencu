package android.content;

/** Host stand-in: a labelled plain-text clip. */
public class ClipData {
  private final ClipDescription description;
  private final CharSequence text;

  private ClipData(CharSequence label, CharSequence text) {
    description = new ClipDescription(label, new String[] {"text/plain"});
    this.text = text;
  }

  public static ClipData newPlainText(CharSequence label, CharSequence text) {
    return new ClipData(label, text);
  }

  public ClipDescription getDescription() {
    return description;
  }

  /** Host-only accessor for assertions. */
  public CharSequence hostText() {
    return text;
  }
}
