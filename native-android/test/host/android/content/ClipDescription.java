package android.content;

/** Host stand-in: a clip's label. */
public class ClipDescription {
  private final CharSequence label;

  public ClipDescription(CharSequence label, String[] mimeTypes) {
    this.label = label;
  }

  public CharSequence getLabel() {
    return label;
  }
}
