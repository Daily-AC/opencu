package dev.opencu.android.fixture;

import android.app.Activity;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.*;
import java.util.*;

public final class SecondActivity extends Activity {
  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    getWindow()
        .addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);
    LinearLayout content = new LinearLayout(this);
    content.setOrientation(LinearLayout.VERTICAL);
    TextView title = new TextView(this);
    title.setText("Fixture second activity");
    title.setTextSize(24);
    content.addView(title);
    ListView rows = new ListView(this);
    rows.setId(R.id.second_rows);
    List<String> labels = new ArrayList<>();
    for (int i = 1; i <= 200; i++) labels.add("Second row " + i);
    rows.setAdapter(new ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, labels));
    rows.setOnScrollListener(
        new AbsListView.OnScrollListener() {
          public void onScrollStateChanged(AbsListView v, int state) {}

          public void onScroll(AbsListView v, int first, int visible, int total) {
            Truth.put(SecondActivity.this, "secondFirstRow", first + 1);
          }
        });
    content.addView(rows, new LinearLayout.LayoutParams(-1, 0, 1));
    setContentView(content);
    // A real moving accessibility tree, independent of global animation settings.
    content.setTranslationX(getResources().getDisplayMetrics().widthPixels);
    content.animate().translationX(0).setDuration(450).start();
    Truth.put(this, "screen", "second");
  }
}
