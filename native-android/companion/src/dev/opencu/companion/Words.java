package dev.opencu.companion;

import java.util.Locale;
import org.json.JSONObject;

/** What the person reads, in Chinese or English by the phone's language. */
final class Words {
  private Words() {}

  static boolean zh() {
    return Locale.getDefault().getLanguage().equals("zh");
  }

  private static String w(String zh, String en) {
    return zh() ? zh : en;
  }

  private static String quoted(String verbZh, String verbEn, String what) {
    return zh() ? verbZh + "「" + what + "」" : verbEn + " “" + what + "”";
  }

  /** The current activity as a short phrase, such as 点击「去结算」. */
  static String action(JSONObject s) {
    String tool = s.optString("tool", "");
    String target = s.optString("target", "");
    String text = s.optString("text", "");
    switch (tool) {
      case "get_app_state":
        return w("读取界面", "Reading");
      case "activate_app":
        return w("切到前台", "Bring to front");
      case "list_apps":
        return w("查看应用列表", "Listing apps");
      case "agent_desktop":
        String a = s.optString("action", "");
        if (a.equals("start")) return w("打开后台屏幕", "Opening the background screen");
        if (a.equals("stop")) return w("关闭后台屏幕", "Closing the background screen");
        return w("查看后台屏幕", "Checking the background screen");
      case "click":
        int count = s.optInt("click_count", 1);
        boolean hold = s.optBoolean("hold", false);
        if (hold) return target.isEmpty() ? w("长按", "Long press") : quoted("长按", "Long press", target);
        if (count >= 2)
          return target.isEmpty() ? w("双击", "Double-tap") : quoted("双击", "Double-tap", target);
        return target.isEmpty() ? w("点击屏幕", "Tap") : quoted("点击", "Tap", target);
      case "type_text":
      case "paste":
        if (s.has("chars")) return zh() ? "输入 " + s.optInt("chars") + " 个字符" : "Type " + s.optInt("chars") + " characters";
        return text.isEmpty() ? w("输入", "Type") : quoted("输入", "Type", text);
      case "set_value":
        if (s.has("chars")) return w("填写密码", "Fill in a password");
        if (!text.isEmpty()) return quoted("设为", "Set to", text);
        return target.isEmpty() ? w("设置", "Set") : quoted("设置", "Set", target);
      case "scroll":
        String d = s.optString("direction", "");
        if (d.equals("up")) return w("向上滚动", "Scroll up");
        if (d.equals("left")) return w("向左滚动", "Scroll left");
        if (d.equals("right")) return w("向右滚动", "Scroll right");
        return w("向下滚动", "Scroll down");
      case "drag":
        return w("拖动", "Drag");
      case "press_key":
        return zh() ? "按下 " + key(s.optString("key", "")) : "Press " + key(s.optString("key", ""));
      case "perform_secondary_action":
        String act = s.optString("action", "");
        String verbZh = act.equals("long_click") ? "长按" : act.equals("expand") ? "展开" : act.equals("collapse") ? "收起" : act.equals("dismiss") ? "关闭" : null;
        if (verbZh != null)
          return target.isEmpty() ? verbZh : quoted(verbZh, act.replace('_', ' '), target);
        return quoted("执行", "Perform", act.replace('_', ' '));
      case "wait":
        return w("等待", "Waiting");
      default:
        return tool;
    }
  }

  private static String key(String key) {
    switch (key.toLowerCase(Locale.ROOT)) {
      case "back":
        return w("返回", "Back");
      case "home":
        return w("主屏幕", "Home");
      case "enter":
      case "return":
        return w("回车", "Return");
      case "delete":
      case "backspace":
        return w("删除", "Delete");
      case "recents":
      case "app_switch":
        return w("最近任务", "Recents");
      case "search":
        return w("搜索", "Search");
      default:
        return key;
    }
  }

  static String using(String app) {
    return zh() ? "OpenCU 正在使用 " + app : "OpenCU is using " + app;
  }

  static String phone() {
    return w("手机", "the phone");
  }

  static String where(boolean background) {
    return background
        ? w("在后台屏幕上操作，不影响你用手机", "On a background screen; your screen stays yours")
        : w("正在操作这块屏幕，碰屏幕会让它暂停", "On this screen; touching it pauses the agent");
  }

  static String step(int step, int steps) {
    return zh() ? "第 " + step + "/" + steps + " 步" : "Step " + step + " of " + steps;
  }

  static String waiting() {
    return w("等待 agent 操作", "Waiting for the agent");
  }

  static String isStopped() {
    return w("OpenCU 已停止", "OpenCU is stopped");
  }

  static String stopped() {
    return w("已被你停止", "Stopped by you");
  }

  static String stopFailed() {
    return w("没能停下，请连按三下音量减", "Not stopped; press volume-down three times");
  }

  static String stop() {
    return w("停止", "Stop");
  }

  static String watch() {
    return w("看画面", "Watch");
  }

  static String hideWatch() {
    return w("收起画面", "Hide");
  }

  static String noFrames() {
    return w("等待画面", "Waiting for the screen");
  }

  static String previewUnavailable() {
    return w("画面不可用", "Screen unavailable");
  }
}
