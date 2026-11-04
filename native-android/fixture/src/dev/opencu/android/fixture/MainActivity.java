package dev.opencu.android.fixture;

import android.app.*;
import android.content.Intent;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import java.util.*;

public final class MainActivity extends Activity {
  private final Handler handler = new Handler(Looper.getMainLooper());
  private String screen = "form";
  private int generation;
  private LinearLayout layout;

  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    setVolumeControlStream(android.media.AudioManager.STREAM_MUSIC);
    getWindow()
        .addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);
    Truth.put(this, "ascii", "");
    Truth.put(this, "chinese", "");
    Truth.put(this, "checked", false);
    Truth.put(this, "checkboxChanges", 0);
    Truth.put(this, "dialogChoice", "");
    Truth.put(this, "row", 0);
    Truth.put(this, "loads", 0);
    form();
  }

  protected void onResume() {
    super.onResume();
    Truth.put(this, "screen", screen);
  }

  private int dp(int n) {
    return Math.round(getResources().getDisplayMetrics().density * n);
  }

  private void base(String name) {
    screen = name;
    generation++;
    layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    layout.setPadding(dp(14), dp(6), dp(14), dp(6));
    layout.setFocusableInTouchMode(true);
    setContentView(layout);
    Truth.put(this, "screen", name);
  }

  private TextView label(String text, int id) {
    TextView v = new TextView(this);
    v.setText(text);
    v.setTextSize(18);
    if (id != 0) v.setId(id);
    layout.addView(v);
    return v;
  }

  private Button button(String text, int id, Runnable action) {
    Button b = new Button(this);
    b.setId(id);
    b.setText(text);
    b.setAllCaps(false);
    layout.addView(b, new LinearLayout.LayoutParams(-1, dp(44)));
    b.setOnClickListener(v -> action.run());
    return b;
  }

  private EditText field(String name, int id, String key) {
    EditText e = new EditText(this);
    e.setId(id);
    e.setSingleLine(true);
    e.setHint(name);
    e.setContentDescription(name);
    e.setText(Truth.state.optString(key));
    layout.addView(e, new LinearLayout.LayoutParams(-1, dp(48)));
    e.addTextChangedListener(
        new TextWatcher() {
          public void beforeTextChanged(CharSequence s, int st, int c, int a) {}

          public void onTextChanged(CharSequence s, int st, int before, int count) {
            Truth.put(MainActivity.this, key, s.toString());
          }

          public void afterTextChanged(Editable s) {}
        });
    return e;
  }

  private void form() {
    base("form");
    label("OpenCU fixture form", 0);
    field("ASCII field", R.id.ascii, "ascii");
    field("Chinese field", R.id.chinese, "chinese");
    CheckBox check = new CheckBox(this);
    check.setId(R.id.checkbox);
    check.setText("Fixture checkbox");
    check.setChecked(Truth.state.optBoolean("checked"));
    layout.addView(check);
    check.setOnCheckedChangeListener(
        (b, c) -> {
          Truth.put(this, "checked", c);
          Truth.put(this, "checkboxChanges", Truth.state.optInt("checkboxChanges") + 1);
        });
    TextView status = label("Ready", R.id.result);
    button(
        "Load",
        R.id.load,
        () -> {
          int g = generation;
          status.setId(R.id.loading);
          status.setText("Loading fixture data");
          Truth.put(this, "loading", true);
          Truth.put(this, "loads", Truth.state.optInt("loads") + 1);
          handler.postDelayed(
              () -> {
                if (g != generation) return;
                status.setId(R.id.result);
                status.setText("Fixture result ready");
                Truth.put(this, "loading", false);
                Truth.put(this, "result", "Fixture result ready");
              },
              1500);
        });
    button(
        "Open dialog",
        R.id.dialog,
        () -> {
          Truth.put(this, "dialogOpen", true);
          new AlertDialog.Builder(this)
              .setTitle("Fixture dialog")
              .setMessage("Choose a fixture button")
              .setPositiveButton("Accept", (d, w) -> Truth.put(this, "dialogChoice", "accept"))
              .setNegativeButton("Cancel", (d, w) -> Truth.put(this, "dialogChoice", "cancel"))
              .setOnDismissListener(d -> Truth.put(this, "dialogOpen", false))
              .show();
        });
    button(
        "Ask permission",
        R.id.permission,
        () -> requestPermissions(new String[] {"android.permission.POST_NOTIFICATIONS"}, 7));
    button("Open list", R.id.list, this::rows);
    button(
        "Second activity",
        R.id.second,
        () -> startActivity(new Intent(this, SecondActivity.class)));
    button(
        "Move checkbox later",
        R.id.move,
        () ->
            handler.postDelayed(
                () -> {
                  check.setVisibility(View.GONE);
                  Truth.put(this, "checkboxHidden", true);
                },
                600));
    layout.requestFocus();
  }

  @Override
  public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
    if (code == 7)
      Truth.put(
          this,
          "permission",
          results.length == 1 && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
              ? "granted"
              : "denied");
  }

  private void rows() {
    base("list");
    button("Form", R.id.form, this::form);
    ListView list = new ListView(this);
    list.setId(R.id.rows);
    List<String> rows = new ArrayList<>();
    for (int i = 1; i <= 220; i++) rows.add("Fixture row " + i);
    list.setAdapter(new ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, rows));
    layout.addView(list, new LinearLayout.LayoutParams(-1, 0, 1));
    list.setOnItemClickListener(
        (p, v, pos, id) -> {
          Truth.put(this, "row", pos + 1);
          ((TextView) v).setText("Selected row " + (pos + 1));
        });
  }
}
