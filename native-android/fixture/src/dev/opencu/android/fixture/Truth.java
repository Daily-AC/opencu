package dev.opencu.android.fixture;

import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

final class Truth {
  static final JSONObject state = new JSONObject();

  static synchronized void put(Context c, String key, Object value) {
    try {
      state.put(key, value);
      File temp = new File(c.getFilesDir(), "truth.tmp");
      try (FileOutputStream out = new FileOutputStream(temp)) {
        out.write(state.toString().getBytes(StandardCharsets.UTF_8));
      }
      if (!temp.renameTo(new File(c.getFilesDir(), "truth.json"))) throw new IOException("rename");
    } catch (Exception e) {
      throw new RuntimeException(e);
    }
  }
}
