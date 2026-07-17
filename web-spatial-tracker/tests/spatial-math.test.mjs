import assert from "node:assert/strict";
import test from "node:test";
import { gazeDirection, projectedTransformSize } from "../public/spatial-math.js";

test("positive Core Motion yaw points gaze left in world coordinates", () => {
  const direction = gazeDirection({ yaw: 20, pitch: 0 });
  assert.ok(direction.x < 0);
  assert.ok(direction.z < 0);
});

test("negative Core Motion yaw points gaze right in world coordinates", () => {
  const direction = gazeDirection({ yaw: -20, pitch: 0 });
  assert.ok(direction.x > 0);
  assert.ok(direction.z < 0);
});

test("WindowTransform3DoF size is interpreted as viewport fractions", () => {
  const size = projectedTransformSize({ width: 0.72, height: 0.68, virtualDistance: 1 });
  assert.equal(size.viewportWidth, 0.72);
  assert.equal(size.viewportHeight, 0.68);
  assert.equal(size.worldWidth, 1.728);
  assert.equal(size.worldHeight, 0.9180000000000001);
  assert.ok(size.worldWidth / size.worldHeight > 1.8);
});

test("virtual distance scales projected window size", () => {
  const size = projectedTransformSize({ width: 0.72, height: 0.68, virtualDistance: 1.5 });
  assert.equal(size.viewportWidth, 0.48);
  assert.ok(Math.abs(size.viewportHeight - 0.45333333333333337) < 0.000001);
});
