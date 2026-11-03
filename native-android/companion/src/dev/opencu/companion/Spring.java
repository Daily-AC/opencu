package dev.opencu.companion;

/**
 * A damped spring toward a target. Position and velocity stay continuous when the target changes
 * mid-flight, so no motion starts or stops abruptly.
 */
final class Spring {
  float value, velocity, target;
  private final float stiffness, damping, rest;

  /** {@code response} is the period in seconds; {@code ratio} below 1 overshoots slightly. */
  Spring(float value, float response, float ratio, float rest) {
    this.value = value;
    this.target = value;
    float omega = (float) (2 * Math.PI / response);
    this.stiffness = omega * omega;
    this.damping = 2 * ratio * omega;
    this.rest = rest;
  }

  void to(float target) {
    this.target = target;
  }

  void snap(float value) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
  }

  boolean moving() {
    return value != target || velocity != 0;
  }

  /** Advances by {@code dt} seconds; false once it has come to rest on the target. */
  boolean step(float dt) {
    if (!moving()) return false;
    int n = Math.max(1, (int) Math.ceil(dt * 240));
    float h = dt / n;
    for (int i = 0; i < n; i++) {
      float a = -stiffness * (value - target) - damping * velocity;
      velocity += a * h;
      value += velocity * h;
    }
    if (Math.abs(value - target) < rest && Math.abs(velocity) < rest * 8) {
      value = target;
      velocity = 0;
      return false;
    }
    return true;
  }
}
